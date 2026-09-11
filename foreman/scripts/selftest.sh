#!/usr/bin/env bash
# foreman selftest：零 token 自测。隔离 FOREMAN_HOME + 假 codex（连接被拒）+ 本地 bare 远端，把主要命令和守卫走一遍。
# 改过 scripts/ 就跑它；任何一项 FAIL 都别把 skill 交出去。用法: foreman selftest [--keep]
set -uo pipefail
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"; F="$SKILL_DIR/scripts/foreman.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1
T="$(mktemp -d "${TMPDIR:-/tmp}/foreman-selftest.XXXXXX")"
export FOREMAN_HOME="$T/home" FOREMAN_CODEX_BIN="$T/fake-codex"
printf '#!/bin/sh\necho "fake codex: connection refused" >&2\nexit 1\n' > "$T/fake-codex"; chmod +x "$T/fake-codex"
pass=0; fails=()
ok()   { pass=$((pass+1)); echo "  [OK]  $1"; }
bad()  { fails+=("$1"); echo "  [!!]  $1${2:+ —— $2}"; }
expect_grep() { local name="$1" pat="$2"; shift 2; local out; out="$("$@" 2>&1)"; if printf '%s' "$out" | grep -q -- "$pat"; then ok "$name"; else bad "$name" "没找到「${pat}」；输出尾行: $(printf '%s' "$out" | tail -1 | cut -c1-120)"; fi; }
expect_rc()   { local name="$1" want="$2"; shift 2; "$@" >/dev/null 2>&1; local rc=$?; if [ "$rc" = "$want" ]; then ok "$name"; else bad "$name" "rc=${rc}，期望 ${want}"; fi; }

# ---- 布局：项目 proj（AGENTS.md）/ 仓库 app（origin = 本地 bare）----
mkdir -p "$T/proj/app" "$T/bare"; echo "# rules" > "$T/proj/AGENTS.md"
git init -q --bare "$T/bare"; git -C "$T/proj/app" init -q -b main
git -C "$T/proj/app" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$T/proj/app" remote add origin "$T/bare"; git -C "$T/proj/app" push -q origin main
cd "$T/proj/app" || exit 1
echo "== 本机初始化 =="
expect_rc   "setup --codex-home shared" 0 "$F" setup --codex-home shared
expect_rc   "setup（生成角色表 + 角色文件）" 0 "$F" setup
expect_grep "init 生成骨架" "骨架已生成" "$F" init
echo task > "$T/brief.md"
expect_grep "here 登记为 PR「here」" "PR「here」" "$F" here 1
expect_grep "confirm 前 run 被拒" "确认" "$F" run 1 --prompt "$T/brief.md"
expect_rc   "setup --confirm" 0 "$F" setup --confirm
echo "== 票 / PR / 线程 =="
echo task > "$T/brief.md"
expect_rc   "假 codex 下前台 run 返回 4（ENGINE_DOWN）" 4 "$F" run 1 --prompt "$T/brief.md" --title "自测" --timeout 30
req="$(ls -t "$FOREMAN_HOME"/projects/proj/issues/*/1/run-*.request.json 2>/dev/null | head -1)"
[ -n "$req" ] && python3 - "$req" "$T/proj" "$T/proj/app" <<'PY' && ok "run 请求：cwd = 项目根、work_dir = 票目录、可写根含票目录" || bad "run 请求：cwd / work_dir / 可写根"
import json,sys,os
r=json.load(open(sys.argv[1])); root=os.path.realpath(sys.argv[2]); wt=os.path.realpath(sys.argv[3])
assert os.path.realpath(r["cwd"])==root, r["cwd"]; assert os.path.realpath(r["work_dir"])==wt, r["work_dir"]
ov=dict(r["config_overrides"]); assert wt in ov["sandbox_workspace_write.writable_roots"], ov
PY
expect_grep "prompt 顶部有「本轮位置」" "本轮位置" head -1 "${req%.request.json}.prompt.md"
expect_grep "release：没有占着的线程" "没有被占着" "$F" release 1
expect_grep "status 能跑（无 HOLD）" "本机 codex 线程在跑" "$F" status
expect_grep "续线程不给角色自动取记录" "线程=implement" "$F" run 1 --prompt "$T/brief.md" --title "续" --timeout 30
expect_grep "同名线程换角色被拒" "角色" "$F" run 1 --thread implement --role mechanical --prompt "$T/brief.md" --title x --timeout 30
expect_grep "--new-thread 已取消" "已取消" "$F" run 1 --new-thread --prompt "$T/brief.md" --title x --timeout 30
expect_grep "同名线程换引擎被拒" "引擎" "$F" run 1 --engine pi --prompt "$T/brief.md" --title x --timeout 30
expect_grep "bootstrap 第一个 PR" "ready: 2  PR「a」" "$F" bootstrap 2 --slug a --no-install
expect_grep "bootstrap 第二个 PR（--pr b）" "ready: 2  PR「b」" "$F" bootstrap 2 --slug b --pr b --no-install
expect_grep "threads 列出两个 PR" "PR「b」" "$F" threads 2
expect_grep "多 PR 不带 --pr 被拒" "有多个 PR" "$F" run 2 --prompt "$T/brief.md" --title x --timeout 30
expect_rc   "run 2 --pr b" 4 "$F" run 2 --pr b --prompt "$T/brief.md" --title "b 轮" --timeout 30
req2="$(ls -t "$FOREMAN_HOME"/projects/proj/issues/*/2/run-*.request.json 2>/dev/null | head -1)"
[ -n "$req2" ] && [ "$(cat "${req2%.request.json}.pr")" = "b" ] && ok "run-N.pr 记下针对的 PR" || bad "run-N.pr"
expect_rc   "review 2 --pr b（假 codex）" 4 "$F" review 2 --pr b --title "审 b" --timeout 30
rreq="$(ls -t "$FOREMAN_HOME"/projects/proj/issues/*/2/review-*.request.json 2>/dev/null | head -1)"
[ -n "$rreq" ] && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["sandbox"]=="read-only" and r.get("ephemeral") is True' "$rreq" && ok "review 请求：只读 + ephemeral" || bad "review 请求"
expect_grep "check 命令通过" "ALL PASS" "$F" check 2 --pr b true
expect_rc   "check 命令失败返回 1" 1 "$F" check 2 --pr b false
expect_grep "diff 指明 PR" "PR「b」" "$F" diff 2 --pr b
echo body > "$T/body.md"
expect_grep "pr 只打印命令且带 --head" "\-\-head" "$F" pr 2 --pr b --title t --body-file "$T/body.md"
expect_grep "cleanup 一个 PR，票保留" "剩余 PR: a" "$F" cleanup 2 --pr b --force
echo "== 调研线程 / --writable =="
mkdir -p "$T/deliver"
expect_rc   "run --role research --writable（假 codex）" 4 "$F" run 2 --pr a --role research --writable "$T/deliver" --prompt "$T/brief.md" --title "调研" --timeout 30
req3="$(ls -t "$FOREMAN_HOME"/projects/proj/issues/*/2/run-*.request.json 2>/dev/null | head -1)"
[ -n "$req3" ] && python3 - "$req3" "$T/deliver" <<'PY' && ok "调研请求：可写根含交付目录、沙箱 workspace-write" || bad "调研请求：可写根 / 沙箱"
import json,sys,os
r=json.load(open(sys.argv[1])); ov=dict(r["config_overrides"]); roots=json.loads(ov["sandbox_workspace_write.writable_roots"])
assert r["sandbox"]=="workspace-write", r["sandbox"]
assert any(os.path.realpath(x)==os.path.realpath(sys.argv[2]) for x in roots), roots
PY
expect_grep "threads 记下 research 线程" "research" "$F" threads 2
mkdir -p "$T/evidence"
expect_rc   "run --role accept --writable（假 codex）" 4 "$F" run 2 --pr a --role accept --writable "$T/evidence" --prompt "$T/brief.md" --title "验收" --timeout 30
expect_grep "threads 记下 accept 线程" "accept" "$F" threads 2
if [ -n "$req3" ]; then
  d2="$(dirname "$req3")"; sleep 300 & sp=$!
  printf 'a' > "$d2/run-99.pr"; printf 'implement' > "$d2/run-99.thread"; printf '%s' "$sp" > "$d2/run-99.pid"; : > "$d2/run-99.argv"
  expect_grep "同一 PR 另一条线程在跑时 run 被拒" "只准一条线程" "$F" run 2 --pr a --role accept --prompt "$T/brief.md" --title x --timeout 30
  expect_grep "同一 PR 另一条线程在跑时 review 被拒" "只准一条线程" "$F" review 2 --pr a --title x --timeout 30
  kill "$sp" 2>/dev/null; rm -f "$d2"/run-99.*
  wtb="$(ls -t "$d2"/run-*.wt-before 2>/dev/null | head -1)"
  if [ -n "$wtb" ]; then
    nn="$(basename "$wtb" .wt-before)"; nn="${nn#run-}"; wt2="$T/proj/app/.claude/worktrees/foreman-2"
    echo dirty > "$wt2/dirty.txt"
    expect_grep "只看不改的角色改了 worktree 被标出" "改动了 worktree" "$F" report 2 "$nn"
    rm -f "$wt2/dirty.txt"
  else bad "只看不改的角色起跑前没记 wt-before"; fi
fi
expect_grep "list 能跑" "线程" "$F" list
echo "== 守卫 =="
python3 - "$FOREMAN_HOME/config.toml" <<'PY'
import sys,re; p=sys.argv[1]; s=open(p).read(); s=re.sub(r'(?m)^thread_name = .*$', 'thread_name = "x {ids}"', s); open(p,'w').write(s)
PY
expect_grep "线程名模板缺 {title} 被拒" "thread_name" "$F" run 1 --prompt "$T/brief.md" --title x --timeout 30
python3 - "$FOREMAN_HOME/config.toml" <<'PY'
import sys,re; p=sys.argv[1]; s=open(p).read(); s=re.sub(r'(?m)^thread_name = .*$', 'thread_name = "foreman {ids}: {title}"', s); open(p,'w').write(s)
PY
ptoml="$FOREMAN_HOME/projects/proj/foreman.toml"
python3 -c 'import sys,re; p=sys.argv[1]; s=open(p).read(); s=s.replace("[engines]\n","[engines]\nconcurrency = 0\n",1) if "concurrency" not in s else re.sub(r"(?m)^concurrency = .*$","concurrency = 0",s); open(p,"w").write(s)' "$ptoml"
expect_grep "项目并发上限 0 → 拒绝派发" "并发已达上限" "$F" run 1 --prompt "$T/brief.md" --title x --timeout 30
python3 -c 'import sys,re; p=sys.argv[1]; s=open(p).read(); s=re.sub(r"(?m)^concurrency = .*$","concurrency = 5",s); open(p,"w").write(s)' "$ptoml"
printf '\n[broken\n' >> "$ptoml"
expect_grep "项目 toml 语法错误被拦" "语法错误" "$F" status
python3 -c 'import sys; p=sys.argv[1]; s=open(p).read().replace("\n[broken\n",""); open(p,"w").write(s)' "$ptoml"
mkdir -p "$T/other/proj/r"; echo "# rules" > "$T/other/proj/AGENTS.md"; git -C "$T/other/proj/r" init -q -b main; git -C "$T/other/proj/r" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
expect_grep "同名项目目录撞车被拒" "撞车" bash -c "cd '$T/other/proj/r' && '$F' here 9"
echo "== 摘要器探针 =="
cat > "$T/probe.jsonl" <<EOF2
{"_fleet":"thread","threadId":"t1","model":"m","reasoningEffort":"low","cwd":"$T/proj","workDir":"$T/proj/app"}
{"method":"item/completed","params":{"item":{"type":"fileChange","status":"completed","changes":[{"kind":"update","path":"$T/proj/app/a.ts"},{"kind":"add","path":"$T/proj/other/b.ts"}]}}}
{"_fleet":"thread_busy","hint":"桌面端占着","error":"already has an active writer"}
EOF2
: > "$T/probe.stderr"; echo done > "$T/probe.last.md"
expect_grep "工作目录之外的改动被标出" "工作目录之外" python3 "$SKILL_DIR/scripts/summarize.py" "$T/probe.jsonl" "$T/probe.stderr" "$T/probe.last.md"
expect_grep "THREAD_BUSY 横幅" "THREAD_BUSY" python3 "$SKILL_DIR/scripts/summarize.py" "$T/probe.jsonl" "$T/probe.stderr" "$T/probe.last.md"
cp "$T/probe.jsonl" "$T/probe2.jsonl"; : > "$T/probe2.stderr"; echo done > "$T/probe2.last.md"
python3 -c 'import json,sys; json.dump({"work_dir": sys.argv[2], "config_overrides": [["sandbox_workspace_write.writable_roots", json.dumps([sys.argv[2], sys.argv[3]])]]}, open(sys.argv[1],"w"))' "$T/probe2.request.json" "$T/proj/app" "$T/proj/other"
if python3 "$SKILL_DIR/scripts/summarize.py" "$T/probe2.jsonl" "$T/probe2.stderr" "$T/probe2.last.md" 2>&1 | grep -q "工作目录之外"; then bad "--writable 目录不算越界"; else ok "--writable 目录不算越界（交付目录）"; fi
expect_grep "复审改了文件被标出" "只看不改" python3 "$SKILL_DIR/scripts/summarize.py" --role review "$T/probe.jsonl" "$T/probe.stderr" "$T/probe.last.md"
expect_grep "验收改了文件被标出" "只看不改" python3 "$SKILL_DIR/scripts/summarize.py" --role accept "$T/probe.jsonl" "$T/probe.stderr" "$T/probe.last.md"
echo
echo "通过 $pass 项，失败 ${#fails[@]} 项${fails[@]:+：}"; for f in "${fails[@]:-}"; do [ -n "$f" ] && echo "  - $f"; done
[ "$KEEP" -eq 1 ] && echo "保留临时目录: $T" || rm -rf "$T"
[ "${#fails[@]}" -eq 0 ]
