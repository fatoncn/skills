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
expect_grep "无可续接 turn 时 steer 被拒" "用 run 起新一轮" "$F" steer 1 "纠偏"
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
[ -n "$req" ] && python3 -c 'import json,sys; assert dict(json.load(open(sys.argv[1]))["config_overrides"])["features.default_mode_request_user_input"] == "true"' "$req" && ok "提问功能位默认开启" || bad "提问功能位默认开启"
ask_toml="$FOREMAN_HOME/projects/proj/foreman.toml"
python3 - "$ask_toml" <<'PY2'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text(); assert "[codex]" in s
p.write_text(s.replace("[codex]", "[codex]\nrequest_user_input = false",1))
PY2
expect_rc "关闭提问功能仍正常派发（假 codex）" 4 "$F" run 1 --prompt "$T/brief.md" --title "提问关闭" --timeout 30
ask_req="$(ls -t "$FOREMAN_HOME"/projects/proj/issues/*/1/run-*.request.json | head -1)"
python3 -c 'import json,sys; assert dict(json.load(open(sys.argv[1]))["config_overrides"])["features.default_mode_request_user_input"] == "false"' "$ask_req" && ok "项目可关闭提问功能位" || bad "项目关闭提问功能位"
python3 - "$ask_toml" <<'PY2'
import pathlib,sys
p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace("\nrequest_user_input = false", "",1))
PY2
expect_grep "prompt 顶部有「本轮位置」" "本轮位置" head -1 "${req%.request.json}.prompt.md"
expect_grep "release：没有占着的线程" "没有被占着" "$F" release 1
if [ -n "$req" ]; then
  rd="$(dirname "$req")"; mkdir -p "$rd/hold-release-test/queue"
  sh -c 'trap "" TERM; while :; do sleep 1; done' & release_pid=$!
  printf '%s' "$release_pid" > "$rd/hold-release-test/bridge.pid"
  cp "$req" "$rd/hold-release-test/queue/run-88.request.json"; printf '%s' "$release_pid" > "$rd/run-88.pid"
  printf 'release-test' > "$rd/run-88.thread"; : > "$rd/run-88.argv"
  expect_grep "release 丢弃排队轮次" "已丢弃 run #88" "$F" release 1 --thread release-test
  [ "$(cat "$rd/run-88.rc" 2>/dev/null)" = 130 ] && ! kill -0 "$release_pid" 2>/dev/null && ok "release TERM 超时后 KILL 且轮次可读为 CANCELLED" || bad "release 强杀 / CANCELLED 状态"
  rm -rf "$rd/hold-release-test" "$rd"/run-88.*
fi
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
[ -n "$req2" ] && [ "$(cat "${req2%.request.json}.thread")" = "implement@b" ] && ok "非默认 PR 自动使用 角色@PR 线程名" || bad "非默认 PR 自动线程名"
expect_rc   "review 2 --pr b（假 codex）" 4 "$F" review 2 --pr b --title "审 b" --timeout 30
rreq="$(ls -t "$FOREMAN_HOME"/projects/proj/issues/*/2/review-*.request.json 2>/dev/null | head -1)"
[ -n "$rreq" ] && python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["sandbox"]=="read-only" and r.get("ephemeral") is True' "$rreq" && ok "review 请求：只读 + ephemeral" || bad "review 请求"
expect_grep "report 指定 run 轮次并组合 --pr" "run 摘要" "$F" report 2 1 --pr b
expect_grep "report 指定 review 轮次并组合 --pr" "run 摘要" "$F" report 2 review1 --pr b
sleep 300 & report_pid=$!; d2="$(dirname "$req2")"
printf 'b' > "$d2/run-97.pr"; printf 'implement@b' > "$d2/run-97.thread"; printf '%s' "$report_pid" > "$d2/run-97.pid"; : > "$d2/run-97.argv"
printf '{"_fleet":"thread","threadId":"t","workDir":"%s"}\n' "$T/proj/app/.claude/worktrees/foreman-2-b" > "$d2/run-97.jsonl"; : > "$d2/run-97.stderr"
expect_grep "report 最新运行轮正文为空时提示上一轮" "run #97 进行中；上一轮交付" "$F" report 2 --pr b
kill "$report_pid"; wait "$report_pid" 2>/dev/null || true; rm -f "$d2"/run-97.*
expect_grep "check 命令通过" "ALL PASS" "$F" check 2 --pr b true
expect_rc   "check 命令失败返回 1" 1 "$F" check 2 --pr b false
expect_grep "diff 指明 PR" "PR「b」" "$F" diff 2 --pr b
echo body > "$T/body.md"
expect_grep "pr 只打印命令且带 --head" "\-\-head" "$F" pr 2 --pr b --title t --body-file "$T/body.md"
expect_grep "cleanup 一个 PR，票保留" "剩余 PR: a" "$F" cleanup 2 --pr b --force
expect_grep "bootstrap 丢弃分支测试" "ready: 3" "$F" bootstrap 3 --slug discard --no-install
wt3="$T/proj/app/.claude/worktrees/foreman-3"; echo discard > "$wt3/x"; git -C "$wt3" add x; git -C "$wt3" -c user.email=t@t -c user.name=t commit -q -m discard
expect_grep "cleanup --discard-unpushed 强删本地分支" "已清理" "$F" cleanup 3 --force --discard-unpushed
if git -C "$T/proj/app" show-ref --verify --quiet refs/heads/feat/$(date +%y-%m-%d)/discard; then bad "discard 后本地分支仍存在"; else ok "discard 后本地分支已 -D"; fi
expect_grep "bootstrap 已合入 base 测试" "ready: 4" "$F" bootstrap 4 --slug merged --no-install
wt4="$T/proj/app/.claude/worktrees/foreman-4"; echo merged > "$wt4/y"; git -C "$wt4" add y; git -C "$wt4" -c user.email=t@t -c user.name=t commit -q -m merged
merged_sha="$(git -C "$wt4" rev-parse HEAD)"; git -C "$T/proj/app" cherry-pick -q "$merged_sha"; git -C "$T/proj/app" push -q origin main
expect_grep "已合入 base 的未推送分支允许 cleanup" "已清理" "$F" cleanup 4 --force
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
  mkdir -p "$d2/hold-stale"; printf '%s' "$sp" > "$d2/hold-stale/bridge.pid"
  printf 'a' > "$d2/run-98.pr"; printf 'stale' > "$d2/run-98.thread"; printf '%s' "$sp" > "$d2/run-98.pid"; : > "$d2/run-98.argv"
  expect_grep "守卫把 hold 存活但轮次已死判 DEAD" "DEAD" "$F" status 2
  rm -rf "$d2/hold-stale" "$d2"/run-98.*
  rm -f "$d2"/run-99.*
  nn=1; while [ -f "$d2/run-$nn.argv" ] || [ -f "$d2/run-$nn.jsonl" ]; do nn=$((nn+1)); done
  printf 'implement' > "$d2/run-$nn.thread"; printf '%s' "$sp" > "$d2/run-$nn.pid"; : > "$d2/run-$nn.argv"
  mkdir -p "$d2/hold-implement/queue"; : > "$d2/hold-implement/queue/run-$nn.request.json"
  expect_grep "wait 把 QUEUED 轮次当在跑" "等待 1 个会话" "$F" wait 2 --timeout 1 --no-report
  rm -rf "$d2/hold-implement"; printf '{"questions":[{"id":"q1","text":"用哪张任务？"}]}' > "$d2/run-$nn.questions.json"
  expect_rc "wait 遇到提问返回 3" 3 "$F" wait 2 --timeout 30 --no-report
  expect_grep "wait 遇到提问打出提示" "在等你回答提问" "$F" wait 2 --timeout 30 --no-report
  rm -rf "$d2/run-$nn".*
  kill "$sp" 2>/dev/null; rm -f "$d2"/run-99.*
  wtb="$(ls -t "$d2"/run-*.wt-before 2>/dev/null | head -1)"
  if [ -n "$wtb" ]; then
    nn="$(basename "$wtb" .wt-before)"; nn="${nn#run-}"; wt2="$T/proj/app/.claude/worktrees/foreman-2"
    echo dirty > "$wt2/dirty.txt"
    expect_grep "只看不改的角色改了 worktree 被标出" "改动了 worktree" "$F" report 2 "$nn"
    rm -f "$wt2/dirty.txt"
  else bad "只看不改的角色起跑前没记 wt-before"; fi
fi
echo "== 引导通道 =="
if [ -n "$req" ]; then
  sd="$(dirname "$req")"
  sleep 300 & steer_pid=$!
  mkdir -p "$sd/hold-implement/queue"
  printf '%s' "$steer_pid" > "$sd/hold-implement/bridge.pid"
  printf '%s' "$steer_pid" > "$sd/hold-implement/steer.pid"
  cp "$req" "$sd/run-70.request.json"
  cp "${req%.request.json}.prompt.md" "$sd/run-70.prompt.md"
  printf 'implement' > "$sd/run-70.thread"; printf '%s' "$steer_pid" > "$sd/run-70.pid"; : > "$sd/run-70.argv"
  "$F" steer 1 "direct-steer-token" >"$T/steer-direct.out" 2>&1 & steer_cli=$!
  for _ in $(seq 1 100); do
    pending="$(find "$sd/hold-implement/steer" -maxdepth 1 -name '*.json' 2>/dev/null | head -1)"
    [ -z "$pending" ] || break
    sleep 0.1
  done
  if [ -n "$pending" ] && python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["text"] == "direct-steer-token"' "$pending"; then
    ok "RUNNING 时 steer 文件落到 hold-implement/steer"
  else bad "RUNNING 时 steer 文件落盘"; fi
  # 给伪造进程补真实格式的回执，让 CLI 正常完成，而非杀掉等待器。
  mkdir -p "$sd/hold-implement/steer/sent"
  [ -z "$pending" ] || python3 - "$pending" <<'PY2'
import json, pathlib, sys
p=pathlib.Path(sys.argv[1]); (p.parent/"sent"/p.name).write_text(json.dumps({"_fleet":"steer", "turnId":"test-turn"})); p.unlink()
PY2
  wait "$steer_cli"; steer_rc=$?
  [ "$steer_rc" = 0 ] && grep -q '已注入 turn test-turn' "$T/steer-direct.out" && ok "steer 成功回执" || bad "steer 成功回执"
  cp "$req" "$sd/run-71.request.json"; cp "${req%.request.json}.prompt.md" "$sd/run-71.prompt.md"
  printf 'implement' > "$sd/run-71.thread"; printf '%s' "$steer_pid" > "$sd/run-71.pid"; : > "$sd/run-71.argv"
  cp "$sd/run-71.request.json" "$sd/hold-implement/queue/run-71.request.json"
  python3 - "$sd/meta.json" <<'PY2'
import json,sys
p=sys.argv[1]; m=json.load(open(p)); m["threads"]["implement"]["runs"].append("run-71"); json.dump(m,open(p,"w"))
PY2
  "$F" steer 1 --from-queue 71 >"$T/steer-queue.out" 2>&1 & steer_cli=$!
  pending=""
  for _ in $(seq 1 100); do
    pending="$(find "$sd/hold-implement/steer" -maxdepth 1 -name '*.json' 2>/dev/null | head -1)"
    [ -z "$pending" ] || break
    sleep 0.1
  done
  if [ -n "$pending" ] && [ ! -f "$sd/hold-implement/queue/run-71.request.json" ] && python3 - "$sd" "$pending" <<'PY2'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); event=json.load(open(sys.argv[2]))
assert event["fromRun"] == 71 and event["text"] == "task\n", event["text"]
assert not list(p.glob("run-71.*"))
assert "run-71" not in json.load(open(p/"meta.json"))["threads"]["implement"]["runs"]
PY2
  then ok "QUEUED 转引导后 queue 为空、正文完整且账本清理"; else bad "QUEUED 转引导与账本清理"; fi
  [ -z "$pending" ] || python3 - "$pending" <<'PY2'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); (p.parent/"sent"/p.name).write_text(json.dumps({"_fleet":"steer", "turnId":"test-turn"})); p.unlink()
PY2
  wait "$steer_cli"
  expect_grep "已拿起轮次拒绝转换" "本来就是你要的效果" "$F" steer 1 --from-queue 70
  rm -f "$sd"/run-70.* "$sd/hold-implement/bridge.pid"
  kill "$steer_pid"; wait "$steer_pid" 2>/dev/null || true
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
python3 - "$T/steer-summary.jsonl" <<'PY2'
import json,sys
with open(sys.argv[1],"w") as f:
    for e in ({"_fleet":"steer","at":1789135200000,"fromRun":7,"text":"引导正文"},
              {"_fleet":"steer_requeued","at":1789135200000,"fromRun":None,"run":9,"text":"结束后转排队"}):
        f.write(json.dumps(e,ensure_ascii=False)+"\n")
PY2
expect_grep "report 展示引导来源与正文" "fromRun=7.*引导正文" python3 "$SKILL_DIR/scripts/summarize.py" "$T/steer-summary.jsonl"
expect_grep "report 展示 steer_requeued" "steer_requeued" python3 "$SKILL_DIR/scripts/summarize.py" "$T/steer-summary.jsonl"
echo "== 引导竞态与执行体 =="
python3 - "$SKILL_DIR/scripts/codex_appserver.py" "$T" <<'PY2' && ok "执行体引导：成功、WAITING、结束竞态、失败保留、旧正文、空号与 FIFO" || bad "执行体引导竞态"
import importlib.util, json, os, pathlib, tempfile, types, sys
spec=importlib.util.spec_from_file_location("bridge",sys.argv[1]); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
class Server:
    def __init__(self, error=None): self.events=[]; self.calls=[]; self.error=error
    def log_event(self,e): self.events.append(e)
    def request(self,method,params,timeout):
        self.calls.append((method,params))
        if self.error: raise b.ProtocolError(self.error)
        return {"turnId":"turn-A"}
    def respond(self,*args,**kwargs): pass

def fixture(active=True, error=None):
    d=pathlib.Path(tempfile.mkdtemp(dir=sys.argv[2])); hd=d/"hold-implement"; hd.mkdir(); (hd/"queue").mkdir()
    b.write_json(d/"meta.json",{"threads":{"implement":{"engine":"codex","runs":["run-1"]}}})
    b.write_json(hd/"hold.json",{})
    source=d/"original.md"; source.write_text("原任务书\n\n保留尾行\n")
    req={"prompt":"# 本轮位置\n\n- cwd：x\n- 工作目录：x\n\n---\n\n"+source.read_text(),
         "prompt_source":str(source),"cwd":str(d),"timeout":60,"out_jsonl":str(d/"run-1.jsonl")}
    b.write_json(d/"run-1.request.json",req)
    (d/"run-1.prompt.md").write_text(req["prompt"]); (d/"run-1.thread").write_text("implement")
    (d/"run-1.role").write_text("mechanical"); (d/"run-1.engine").write_text("codex")
    (d/"run-1.argv").write_bytes(b"python3\0")
    (hd/"bridge.pid").write_text(str(os.getpid()))
    r=b.Runner({"question_timeout":1,"questions_path":str(d/"questions.json"),"answer_path":str(d/"answer.json")})
    r.turn_id="turn-A"; r.thread_id="thread-A"
    srv=Server(error); r.server=srv
    holder=b.Holder(str(hd)); holder.current=r if active else None
    if active: b.write_json(hd/"active.json",{"turnId":"turn-A"})
    return d, hd, holder, srv, r

# Success: assert actual protocol shape and durable acknowledgement.
d,hd,h,srv,r=fixture(); path=pathlib.Path(b.submit_steer(d,"implement","原文\n", "", None)); h.consume_steers(srv)
assert srv.calls == [("turn/steer",{"threadId":"thread-A","expectedTurnId":"turn-A","input":[{"type":"text","text":"原文\n"}]})]
assert json.loads((hd/"steer/sent"/path.name).read_text())["text"] == "原文\n"
assert not path.exists() and not list((hd/"queue").iterdir())
# WAITING: question polling still consumes steering and answers independently.
d,hd,h,srv,r=fixture(); b.submit_steer(d,"implement","提问期间纠偏", "", None)
def consume():
    h.consume_steers(srv); b.write_json(d/"answer.json",{"all":"回答"})
r.consume_steers=consume; r.handle_questions(1,{"questions":[{"id":"q","question":"问题"}]})
assert any(e.get("_fleet")=="steer" for e in srv.events)
assert any(e.get("_fleet")=="answer" and e["answered"] for e in srv.events)
# Mismatch, completed before processing, idle, and next-turn race all requeue exactly once.
for mode in ("mismatch","completed","idle","next-turn"):
    d,hd,h,srv,r=fixture(active=mode!="idle", error="turn/steer 出错: expected active turn id `turn-A` but found `turn-B`" if mode=="mismatch" else None)
    path=pathlib.Path(b.submit_steer(d,"implement",mode+"\n", "", None))
    if mode=="completed": r.turn_status="completed"
    if mode=="next-turn": r.turn_id="turn-B"
    h.consume_steers(srv); h.consume_steers(srv)
    ack=json.loads((hd/"steer/sent"/path.name).read_text()); assert ack["_fleet"]=="steer_requeued"
    assert len(list((hd/"queue").glob("*.request.json")))==1
    n=ack["run"]; req=json.loads((d/f"run-{n}.request.json").read_text())
    assert req["title"]=="引导转排队" and req["prompt"].endswith(mode+"\n")
    assert b.original_prompt(d,n,b.template_for(d,n))==mode+"\n"
    assert json.loads((d/"meta.json").read_text())["threads"]["implement"]["runs"]==["run-1",f"run-{n}"]
    for suffix in ("argv","prompt.md","request.json","role","thread","timeout","started","pid","jsonl"):
        assert (d/f"run-{n}.{suffix}").is_file(), suffix
    assert len(srv.calls)==(1 if mode=="mismatch" else 0)
# A non-race error is not silently converted or dropped.
d,hd,h,srv,r=fixture(error="turn/steer 出错: permission denied")
path=pathlib.Path(b.submit_steer(d,"implement","失败保留", "", None)); h.consume_steers(srv)
ack=json.loads((hd/"steer/failed"/path.name).read_text()); assert ack["error"]==srv.error and ack["text"]=="失败保留"
assert not list((hd/"queue").iterdir())
# Old prompt fallback strips the whole generated position block, not just its title.
t=b.template_for(d,1); del t["request"]["prompt_source"]
assert b.original_prompt(d,1,t)=="原任务书\n\n保留尾行\n"
# Removing a middle queued run leaves later numbers visible; FIFO is numeric.
for n in (7,9,10):
    req=json.loads((d/"run-1.request.json").read_text()); b.write_json(d/f"run-{n}.request.json",req)
    (d/f"run-{n}.thread").write_text("implement"); (d/f"run-{n}.argv").write_bytes(b"python3\0")
    b.write_json(hd/"queue"/f"run-{n}.request.json",req)
b.submit_steer(d,"implement","","",7)
assert not list(d.glob("run-7.*")) and max(b.run_numbers(d))==10
assert [pathlib.Path(p).name for p in h._queued()]==["run-9.request.json","run-10.request.json"]
print("8 种引导/竞态路径及旧正文、账本、FIFO 断言通过")
PY2
python3 - "$SKILL_DIR/scripts/codex_appserver.py" "$T" <<'PY2' && ok "app-server 实际 argv 默认开启、支持关闭且进程级抑制警告" || bad "app-server 提问功能位 argv"
import importlib.util,pathlib,sys
from unittest.mock import patch
spec=importlib.util.spec_from_file_location("bridge",sys.argv[1]); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
for value in (None,"false"):
    overrides=[] if value is None else [("features.default_mode_request_user_input",value)]
    with patch.object(b.subprocess,"Popen") as popen, patch.object(b.threading.Thread,"start"), patch.object(b,"request_input_feature",return_value={"present":True,"stage":"under development","value":"false"}):
        server=b.AppServer("fake-codex",sys.argv[2],sys.argv[2],overrides,str(pathlib.Path(sys.argv[2])/"ask-argv.jsonl"),str(pathlib.Path(sys.argv[2])/"ask-argv.stderr"))
        try:
            args=popen.call_args.args[0]
            settings=[args[i+1] for i,a in enumerate(args) if a=="-c"]
            assert settings.count("features.default_mode_request_user_input="+(value or "true"))==1, settings
            assert len([s for s in settings if s.startswith("features.default_mode_request_user_input=")])==1
            assert "suppress_unstable_features_warning=true" in settings
        finally:
            server._log.close(); server._stderr.close()
print("默认 true / 显式 false 两种启动 argv 断言通过")
PY2
python3 - "$SKILL_DIR/scripts/codex_appserver.py" "$T" <<'PY2' && ok "功能探测缓存、缺失/失败降级及 doctor 展示" || bad "功能探测与降级"
import importlib.util,json,pathlib,subprocess,sys
from unittest.mock import patch
spec=importlib.util.spec_from_file_location("bridge",sys.argv[1]); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
for output, rc, present in (("default_mode_request_user_input    under development    false\n",0,True),("another_flag stable true\n",0,False),("",1,False)):
    b.request_input_feature.cache_clear()
    with patch.object(b.subprocess,"run",return_value=subprocess.CompletedProcess([],rc,output,"")) as run:
        feature=b.request_input_feature("codex",sys.argv[2],sys.argv[2])
        assert b.request_input_feature("codex",sys.argv[2],sys.argv[2])==feature and run.call_count==1
        assert feature["present"]==present
        shown=b.feature_report(feature,"false")
        assert b.REQUEST_INPUT_FEATURE in shown
        assert ("执行体会否按进程带上=是" if present else "执行体会否按进程带上=否") in shown
        if present: assert "阶段=under development" in shown and "当前生效值（CLI配置）=false" in shown
b.request_input_feature.cache_clear()
with patch.object(b.subprocess,"run",side_effect=subprocess.TimeoutExpired("codex",15)):
    assert not b.request_input_feature("codex",sys.argv[2],sys.argv[2])["present"]
log=pathlib.Path(sys.argv[2])/"feature-missing.jsonl"
with patch.object(b.subprocess,"Popen") as popen, patch.object(b.threading.Thread,"start"), patch.object(b,"request_input_feature",return_value={"present":False,"stage":"未列出","value":"未知","reason":"not_listed"}):
    server=b.AppServer("codex",sys.argv[2],sys.argv[2],[(b.REQUEST_INPUT_KEY,"true")],str(log),str(log)+".stderr")
    try:
        assert not any(b.REQUEST_INPUT_KEY in arg for arg in popen.call_args.args[0])
        events=[json.loads(line) for line in log.read_text().splitlines()]
        assert len(events)==1 and events[0]["_fleet"]=="feature_missing" and events[0]["feature"]==b.REQUEST_INPUT_FEATURE
    finally: server._log.close(); server._stderr.close()
print("存在 / 缺失 / 命令失败 / 超时，缓存及缺失事件断言通过")
PY2
echo
echo "通过 $pass 项，失败 ${#fails[@]} 项${fails[@]:+：}"; for f in "${fails[@]:-}"; do [ -n "$f" ] && echo "  - $f"; done
[ "$KEEP" -eq 1 ] && echo "保留临时目录: $T" || rm -rf "$T"
[ "${#fails[@]}" -eq 0 ]
