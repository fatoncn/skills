#!/usr/bin/env bash
# foreman selftest：零 token 自测。隔离 FOREMAN_HOME + 假 codex（连接被拒）+ 本地 bare 远端，把主要命令和守卫走一遍。
# 改过 scripts/ 就跑它；任何一项 FAIL 都别把 skill 交出去。用法: foreman selftest [--keep]
set -uo pipefail
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"; F="$SKILL_DIR/scripts/foreman.sh"
KEEP=0; [ "${1:-}" = "--keep" ] && KEEP=1
T="$(mktemp -d "${TMPDIR:-/tmp}/foreman-selftest.XXXXXX")"
REAL_PYTHON="$(command -v python3)"; export REAL_PYTHON
mkdir -p "$T/bin"
cat > "$T/bin/python3" <<'SH'
#!/bin/sh
case "${1:-} ${2:-}" in
  *codex_appserver.py\ serve)
    { printf '%s\0' python3; for arg in "$@"; do printf '%s\0' "$arg"; done; } > "$3/start.argv"
    ;;
esac
exec "$REAL_PYTHON" "$@"
SH
chmod +x "$T/bin/python3"
export PATH="$T/bin:$PATH"
export FOREMAN_HOME="$T/home" FOREMAN_CODEX_BIN="$T/fake-codex"
printf '#!/bin/sh\necho "fake codex: connection refused" >&2\nexit 1\n' > "$T/fake-codex"; chmod +x "$T/fake-codex"
ln -s "$SKILL_DIR/tests/claude_replay.py" "$T/bin/claude"
pass=0; fails=()
ok()   { pass=$((pass+1)); echo "  [OK]  $1"; }
bad()  { fails+=("$1"); echo "  [!!]  $1${2:+ —— $2}"; }
expect_grep() { local name="$1" pat="$2"; shift 2; local out; out="$("$@" 2>&1)"; if printf '%s' "$out" | grep -q -- "$pat"; then ok "$name"; else bad "$name" "没找到「${pat}」；输出尾行: $(printf '%s' "$out" | tail -1 | cut -c1-120)"; fi; }
expect_no_grep() { local name="$1" pat="$2"; shift 2; local out rc; out="$("$@" 2>&1)"; rc=$?; if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q -- "$pat"; then ok "$name"; else bad "$name" "rc=${rc}，不应出现「${pat}」"; fi; }
expect_rc()   { local name="$1" want="$2"; shift 2; "$@" >/dev/null 2>&1; local rc=$?; if [ "$rc" = "$want" ]; then ok "$name"; else bad "$name" "rc=${rc}，期望 ${want}"; fi; }
make_hold_fixture() { # <票目录> <线程> <轮次> <bridge pid> <PR> <角色>
  local dir="$1" thread="$2" n="$3" pid="$4" pr="$5" role="$6" hd="$1/hold-$2" prefix="$1/run-$3"
  mkdir -p "$hd/queue"
  printf '{"idle_seconds":3600}' > "$hd/hold.json"; printf '%s' "$pid" > "$hd/bridge.pid"
  python3 - "$prefix.request.json" "$prefix" <<'PY2'
import json,sys
p,prefix=sys.argv[1:3]
json.dump({"prompt":"# 本轮位置\n\n---\n\nfixture", "cwd":"/tmp", "timeout":60,
           "out_jsonl":prefix+".jsonl", "out_stderr":prefix+".stderr",
           "out_last":prefix+".last.md", "out_rc":prefix+".rc"}, open(p,"w"))
PY2
  cp "$prefix.request.json" "$hd/queue/run-$n.request.json"
  printf '%s' "$thread" > "$prefix.thread"; printf '%s' "$pr" > "$prefix.pr"; printf '%s' "$role" > "$prefix.role"
  printf '%s' "$pid" > "$prefix.pid"; printf '%s' "$(date +%s)" > "$prefix.started"; printf 'codex' > "$prefix.engine"
  : > "$prefix.argv"; printf 'fixture' > "$prefix.prompt.md"
  python3 - "$dir/meta.json" "$thread" "$role" "$n" <<'PY2'
import json,sys
p,thread,role,n=sys.argv[1:5]; m=json.load(open(p)); t=m.setdefault("threads",{}).setdefault(thread,{"engine":"codex","role":role,"runs":[]})
t["engine"]="codex"; t["role"]=role
if "run-"+n not in t.setdefault("runs",[]): t["runs"].append("run-"+n)
json.dump(m,open(p,"w"),indent=2,ensure_ascii=False)
PY2
}

replay_out="$(python3 -B "$SKILL_DIR/tests/appserver_replay.py" --selftest 2>&1)"; replay_rc=$?
if [ "$replay_rc" -eq 0 ] && printf '%s\n' "$replay_out" | grep -q 'fixture baseline:'; then ok "app-server 可编排 stdio 回放夹具自检"; else bad "app-server 回放夹具" "$replay_out"; fi
for replay_case in outer-first inner-first 'timeout cleanup' 'nested error' 'EOF cleanup' 'unknown/late diagnostic' \
  'EOF-only stderr classification' 'expired nested response' 'pending duplicate + diagnostic suppression' \
  'request_user_input -> consume_steers -> turn/steer'; do
  if printf '%s\n' "$replay_out" | grep -q "request routing: ${replay_case} PASS"; then ok "请求 id 分发：${replay_case}"; else bad "请求 id 分发：${replay_case}"; fi
done
for replay_case in 'root final survives child final' 'stale turn ignored' 'child completion does not settle root' 'pre-response notifications replayed' 'no inferred root completion' 'child second turn tracked'; do
  if printf '%s\n' "$replay_out" | grep -q "turn identity: ${replay_case} PASS"; then ok "主轮身份：${replay_case}"; else bad "主轮身份：${replay_case}"; fi
done

grep -P '' /dev/null >/dev/null 2>&1; grep_p_rc=$?
if [ "$grep_p_rc" -ne 2 ]; then
  bare_unicode_hits="$(grep -nP '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]' "$F" "$SKILL_DIR/scripts/selftest.sh" 2>/dev/null || true)"
else
  bare_unicode_hits="$(python3 - "$F" "$SKILL_DIR/scripts/selftest.sh" <<'PY2'
import re,sys
pattern=re.compile(r'\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]')
for path in sys.argv[1:]:
    for n,line in enumerate(open(path,encoding="utf-8"),1):
        if pattern.search(line): print(f"{path}:{n}:{line.rstrip()}")
PY2
)"
fi
if [ -z "$bare_unicode_hits" ]; then ok "shell 禁止裸变量紧跟非 ASCII 字符"; else bad "shell 存在裸变量的 Unicode 边界"; printf '%s\n' "$bare_unicode_hits"; fi

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
retired_dir="$(dirname "$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/1/meta.json' -print -quit)")"
retired_before="$(find "$retired_dir" -maxdepth 1 \( -name 'run-*' -o -name 'review-*' \) -print | sort)"
retired_run_out="$("$F" run 1 --thread retired-run --engine codex-exec --prompt "$T/brief.md" --title x 2>&1)"; retired_run_rc=$?
retired_after_run="$(find "$retired_dir" -maxdepth 1 \( -name 'run-*' -o -name 'review-*' \) -print | sort)"
if [ "$retired_run_rc" -ne 0 ] && printf '%s' "$retired_run_out" | grep -q '只能是 codex / pi' && [ "$retired_before" = "$retired_after_run" ]; then ok "run 拒绝已退役引擎且不落轮次文件"; else bad "run 已退役引擎守卫" "rc=$retired_run_rc"; fi
retired_review_out="$("$F" review 1 --engine codex-exec 2>&1)"; retired_review_rc=$?
retired_after_review="$(find "$retired_dir" -maxdepth 1 \( -name 'run-*' -o -name 'review-*' \) -print | sort)"
if [ "$retired_review_rc" -ne 0 ] && printf '%s' "$retired_review_out" | grep -q '只能是 codex / pi' && [ "$retired_before" = "$retired_after_review" ]; then ok "review 拒绝已退役引擎且不落轮次文件"; else bad "review 已退役引擎守卫" "rc=$retired_review_rc"; fi
echo "== 票 / PR / 线程 =="
echo task > "$T/brief.md"
expect_rc   "假 codex 下前台 run 返回 4（ENGINE_DOWN）" 4 "$F" run 1 --prompt "$T/brief.md" --title "自测" --timeout 30
req="$(ls -t "$FOREMAN_HOME"/projects/proj/issues/*/1/run-*.request.json 2>/dev/null | head -1)"
steer_dir="$(dirname "$req")"; make_hold_fixture "$steer_dir" steer-path 90 999999 here implement
rm -f "$steer_dir/hold-steer-path/hold.json" "$steer_dir/hold-steer-path/queue/run-90.request.json"
steer_path_out="$("$F" steer 1 --thread steer-path "纠偏" 2>&1)"; steer_path_rc=$?
if [ "$steer_path_rc" -ne 0 ] && printf '%s\n' "$steer_path_out" | grep -q "消息已保留在 .*，用 run 起新一轮"; then ok "steer 保留路径变量边界正确"; else bad "steer 保留路径变量边界正确" "rc=$steer_path_rc"; fi
rm -rf "$steer_dir/hold-steer-path"; rm -f "$steer_dir"/run-90.*
python3 - "$steer_dir/meta.json" <<'PY2'
import json,sys
p=sys.argv[1]; m=json.load(open(p)); m.get("threads",{}).pop("steer-path",None); json.dump(m,open(p,"w"),indent=2,ensure_ascii=False)
PY2
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
expect_grep "位置块按环境写 rg 可用性" "执行环境：rg:" cat "${req%.request.json}.prompt.md"
expect_grep "accept 角色把范围外失败归观察" "通过（范围外 N 条）" cat "$SKILL_DIR/assets/roles/accept.md"
expect_grep "收尾契约禁用 CI 前台 watch" "不要用.*--watch" cat "$SKILL_DIR/assets/CLOSEOUT.md"
expect_grep "收尾契约 push 后立即报告且不等 CI" "push 并回复 / resolve.*立即交报告结束.*不在执行者 turn 里等 CI" cat "$SKILL_DIR/assets/CLOSEOUT.md"
expect_grep "closeout 文档与实现线程筛选一致" "目标 PR 最近的.*implement.*mechanical" "$F" help
python3 - "$F" <<'PY' && ok "release TERM 等待覆盖执行体 interrupt grace" || bad "release grace 不足"
import re,sys
s=open(sys.argv[1]).read(); assert int(re.search(r'^HOLD_TERM_GRACE=(\d+)',s,re.M).group(1)) >= 25
PY
expect_grep "release：没有占着的线程" "没有被占着" "$F" release 1
if [ -n "$req" ]; then
  rd="$(dirname "$req")"; mkdir -p "$rd/hold-release-test/queue"
  sh -c 'trap "" TERM; while :; do sleep 1; done' & release_pid=$!
  printf '%s' "$release_pid" > "$rd/hold-release-test/bridge.pid"
  cp "$req" "$rd/hold-release-test/queue/run-88.request.json"; printf '%s' "$release_pid" > "$rd/run-88.pid"
  printf 'release-test' > "$rd/run-88.thread"; : > "$rd/run-88.argv"
  expect_grep "release 丢弃排队轮次" "已丢弃 run #88" "$F" release 1 --thread release-test
  [ "$(cat "$rd/run-88.rc" 2>/dev/null)" = 130 ] && ! kill -0 "$release_pid" 2>/dev/null && ok "release TERM 超时后 KILL 且轮次可读为 CANCELLED" || bad "release 强杀 / CANCELLED 状态"
  expect_grep "status 展示统一 CANCELLED 状态" "run#88.*CANCELLED.*release" "$F" status 1
  expect_grep "report 对 CANCELLED 不报空日志" "run#88 CANCELLED.*release" "$F" report 1 88
  expect_grep "list 展示 CANCELLED 原因" "CANCELLED:.*release" "$F" list
  expect_grep "wait 展示 CANCELLED 终态" "run#88 CANCELLED.*release" "$F" wait 1 --timeout 1 --no-report
  rm -rf "$rd/hold-release-test" "$rd"/run-88.*
fi
expect_grep "status 能跑（无 HOLD）" "本机 codex 线程在跑" "$F" status
expect_grep "status 说明用时从派发起算且交接不归零" "QUEUED→RUNNING 不归零" "$F" status
expect_grep "超时现场报告测试登记" "PR「here」" "$F" here 47
timeout47_dir="$(dirname "$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/47/meta.json' -print -quit)")"
printf '%s\n' '{"_fleet":"thread","threadId":"timeout-test"}' '{"method":"item/started","params":{"item":{"id":"cmd-1","type":"commandExecution","command":"long-running-command"}}}' '{"method":"item/completed","params":{"item":{"id":"msg-1","type":"agentMessage","text":"partial progress"}}}' '{"_fleet":"turn_summary","rc":143,"status":"interrupted","hasFinalText":false}' > "$timeout47_dir/run-1.jsonl"
: > "$timeout47_dir/run-1.stderr"; : > "$timeout47_dir/run-1.last.md"; printf 143 > "$timeout47_dir/run-1.rc"
printf 'codex' > "$timeout47_dir/run-1.engine"; printf 'implement' > "$timeout47_dir/run-1.role"; printf 'here' > "$timeout47_dir/run-1.pr"; : > "$timeout47_dir/run-1.argv"
timeout47_out="$("$F" report 47 2>&1)"
if printf '%s\n' "$timeout47_out" | grep -q '^--- 超时时的状态 ---$' && printf '%s\n' "$timeout47_out" | grep -q '^已落 commit 列表：$' && printf '%s\n' "$timeout47_out" | grep -q '^工作树改动文件：$' && printf '%s\n' "$timeout47_out" | grep -q '^最后 10 条事件：$' && printf '%s\n' "$timeout47_out" | grep -q '^long-running-command$'; then ok "rc=143 后 report 自动合成超时现场"; else bad "report 超时现场" "$timeout47_out"; fi
cp "$timeout47_dir/run-1.jsonl" "$T/timeout47.jsonl.saved"; : > "$timeout47_dir/run-1.jsonl"
timeout47_empty="$("$F" report 47 1 2>&1)"; timeout47_empty_rc=$?
if [ "$timeout47_empty_rc" -eq 0 ] && printf '%s\n' "$timeout47_empty" | grep -q '^--- 超时时的状态 ---$' && printf '%s\n' "$timeout47_empty" | grep -q '事件尾不可用' && printf '%s\n' "$timeout47_empty" | grep -q '命令状态不可用'; then ok "rc=143 空日志仍独立合成现场"; else bad "report 空日志超时现场" "rc=$timeout47_empty_rc $timeout47_empty"; fi
mv "$timeout47_dir/meta.json" "$timeout47_dir/meta.json.saved"; rm -f "$timeout47_dir/run-1.jsonl"
timeout47_nometa="$("$F" report 47 1 2>&1)"; timeout47_nometa_rc=$?
if [ "$timeout47_nometa_rc" -eq 0 ] && printf '%s\n' "$timeout47_nometa" | grep -q '^--- 超时时的状态 ---$' && printf '%s\n' "$timeout47_nometa" | grep -q '工作树不可用' && printf '%s\n' "$timeout47_nometa" | grep -q '事件日志不可用'; then ok "rc=143 缺 meta / 日志仍合成可用部分"; else bad "report 缺 meta 超时现场" "rc=$timeout47_nometa_rc $timeout47_nometa"; fi
mv "$timeout47_dir/meta.json.saved" "$timeout47_dir/meta.json"; cp "$T/timeout47.jsonl.saved" "$timeout47_dir/run-1.jsonl"
expect_grep "超时现场报告测试清理" "已删登记" "$F" cleanup 47 --force
expect_grep "续线程不给角色自动取记录" "线程=implement" "$F" run 1 --prompt "$T/brief.md" --title "续" --timeout 30
expect_rc "mechanical 实现轮（假 codex）" 4 "$F" run 1 --thread closeout-mech --role mechanical --prompt "$T/brief.md" --title "机械实现" --timeout 30
expect_rc "closeout 默认续最后一条 run 的线程" 4 "$F" run 1 --closeout --prompt "$T/brief.md" --title "收尾" --timeout 30
close_req="$(ls -t "$FOREMAN_HOME"/projects/proj/issues/*/1/run-*.request.json | head -1)"
[ "$(cat "${close_req%.request.json}.thread")" = closeout-mech ] && ok "closeout 续到最后 run 的线程" || bad "closeout 续错线程"
expect_grep "here 登记 closeout 角色筛选测试" "PR「here」" "$F" here 5
expect_rc "closeout 筛选测试 mechanical 轮" 4 "$F" run 5 --role mechanical --prompt "$T/brief.md" --title m --timeout 30
expect_rc "closeout 筛选测试 accept 轮" 4 "$F" run 5 --role accept --prompt "$T/brief.md" --title a --timeout 30
expect_rc "最后一轮 accept 时 closeout 仍续 mechanical" 4 "$F" run 5 --closeout --prompt "$T/brief.md" --title c --timeout 30
close5="$(ls -t "$FOREMAN_HOME"/projects/proj/issues/*/5/run-*.request.json | head -1)"
[ "$(cat "${close5%.request.json}.thread")" = mechanical ] && ok "closeout 只选目标 PR 的实现角色" || bad "closeout 错续 accept"
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
check_ok_out="$("$F" check 2 --pr b true 2>&1)"; check_ok_rc=$?
if [ "$check_ok_rc" -eq 0 ] && printf '%s\n' "$check_ok_out" | grep -q "ALL PASS" && ! printf '%s\n' "$check_ok_out" | grep -q "unbound variable"; then
  ok "check 命令通过且 RETURN 后无 unbound"
else
  bad "check 命令通过且 RETURN 后无 unbound —— rc=${check_ok_rc}，输出: $(printf '%s\n' "$check_ok_out" | tail -1)"
fi
expect_rc   "check 命令失败返回 1" 1 "$F" check 2 --pr b false
expect_grep "diff 指明 PR" "PR「b」" "$F" diff 2 --pr b
echo body > "$T/body.md"
expect_grep "pr 只打印命令且带 --head" "\-\-head" "$F" pr 2 --pr b --title t --body-file "$T/body.md"
expect_grep "cleanup 一个 PR，票保留" "剩余 PR: a" "$F" cleanup 2 --pr b --force
expect_grep "bootstrap 稳定线程测试默认 PR" "ready: 6" "$F" bootstrap 6 --slug stable-a --no-install
expect_grep "bootstrap 稳定线程测试第二 PR" "ready: 6" "$F" bootstrap 6 --slug stable-b --pr b --no-install
expect_rc "第二 PR 首轮自动线程" 4 "$F" run 6 --pr b --prompt "$T/brief.md" --title b1 --timeout 30
stable_dir="$(dirname "$(ls -t "$FOREMAN_HOME"/projects/proj/issues/*/6/run-*.request.json | head -1)")"; stable_before="$(cat "$stable_dir/run-1.thread")"
expect_grep "清理首个 PR" "剩余 PR: b" "$F" cleanup 6 --pr stable-a --force
expect_rc "清理首 PR 后第二 PR 续跑" 4 "$F" run 6 --pr b --prompt "$T/brief.md" --title b2 --timeout 30
[ "$stable_before" = "$(cat "$stable_dir/run-2.thread")" ] && ok "清理默认 PR 后自动线程名保持稳定" || bad "自动线程名漂移"
expect_grep "登记脏检出 here cleanup 测试" "PR「here」" "$F" here 31
printf 'dirty\ncontent must stay\n' > "$T/proj/app/here-dirty.tmp"; here_dirty_sha="$(git hash-object "$T/proj/app/here-dirty.tmp")"
expect_grep "脏检出 here cleanup 只删登记" "已删登记" "$F" cleanup 31 --force
[ "$here_dirty_sha" = "$(git hash-object "$T/proj/app/here-dirty.tmp" 2>/dev/null)" ] && ok "here cleanup 保留脏文件完整内容" || bad "here cleanup 改写了脏文件"
here31_meta="$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/31/meta.json' -print -quit)"
python3 -c 'import json,sys; assert "here" not in (json.load(open(sys.argv[1])).get("prs") or {})' "$here31_meta" && ok "here cleanup 从 meta 删除登记" || bad "here cleanup 遗留 meta 登记"
rm -f "$T/proj/app/here-dirty.tmp"
expect_grep "cleanup 占用测试 PR A" "ready: 40" "$F" bootstrap 40 --slug cleanup-active-a --pr a --no-install
expect_grep "cleanup 占用测试 PR B" "ready: 40" "$F" bootstrap 40 --slug cleanup-active-b --pr b --no-install
cleanup40_dir="$(dirname "$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/40/meta.json' -print -quit)")"
sleep 300 & cleanup40_pid=$!
make_hold_fixture "$cleanup40_dir" shared-pr 301 "$cleanup40_pid" a implement
make_hold_fixture "$cleanup40_dir" shared-pr 302 "$cleanup40_pid" b implement
rm -f "$cleanup40_dir/hold-shared-pr/queue/run-301.request.json"; printf '{"run":"run-301"}' > "$cleanup40_dir/hold-shared-pr/active.json"
cleanup40_a="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prs"]["a"]["worktree"])' "$cleanup40_dir/meta.json")"
cleanup40_b="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prs"]["b"]["worktree"])' "$cleanup40_dir/meta.json")"
cleanup_a_out="$("$F" cleanup 40 --pr a --force 2>&1)"; cleanup_a_rc=$?
if [ "$cleanup_a_rc" -ne 0 ] && printf '%s' "$cleanup_a_out" | grep -q 'run-301: RUNNING' && [ -d "$cleanup40_a" ] && kill -0 "$cleanup40_pid" 2>/dev/null; then ok "cleanup 目标 PR 有 RUNNING 轮时拒绝且保留状态"; else bad "cleanup RUNNING 拒绝" "rc=$cleanup_a_rc"; fi
cleanup_b_out="$("$F" cleanup 40 --pr b --force 2>&1)"; cleanup_b_rc=$?
if [ "$cleanup_b_rc" -ne 0 ] && printf '%s' "$cleanup_b_out" | grep -q 'run-302: QUEUED' && [ -f "$cleanup40_dir/hold-shared-pr/queue/run-302.request.json" ] && kill -0 "$cleanup40_pid" 2>/dev/null; then ok "cleanup 目标 PR 有 QUEUED 轮时拒绝且不取消"; else bad "cleanup QUEUED 拒绝" "rc=$cleanup_b_rc"; fi
printf 0 > "$cleanup40_dir/run-301.rc"; rm -f "$cleanup40_dir/run-301.pid" "$cleanup40_dir/hold-shared-pr/active.json"
rm -f "$T/cleanup-lock.ready" "$T/cleanup-lock.release"; FOREMAN_SELFTEST_LOCK_READY="$T/cleanup-lock.ready" FOREMAN_SELFTEST_LOCK_RELEASE="$T/cleanup-lock.release" "$F" cleanup 40 --pr a --force > "$T/cleanup40-a.out" 2>&1 & cleanup40_cli=$!
for _ in $(seq 1 100); do [ -f "$T/cleanup-lock.ready" ] && break; sleep 0.02; done
"$F" run 40 --pr a --prompt "$T/brief.md" --title blocked-by-cleanup --timeout 30 > "$T/cleanup40-run.out" 2>&1 & cleanup40_run_cli=$!
sleep 1; run_was_blocked=0; kill -0 "$cleanup40_run_cli" 2>/dev/null && run_was_blocked=1
: > "$T/cleanup-lock.release"; wait "$cleanup40_cli"; cleanup40_rc=$?; wait "$cleanup40_run_cli"; cleanup40_run_rc=$?
if [ "$cleanup40_rc" -eq 0 ] && [ "$run_was_blocked" -eq 1 ] && [ "$cleanup40_run_rc" -ne 0 ] && grep -q '没有名为 a 的 PR' "$T/cleanup40-run.out"; then ok "cleanup 全程持锁，run 阻塞后因 PR 已删被拒"; else bad "cleanup 全程持锁"; fi
if [ ! -d "$cleanup40_a" ] && [ -d "$cleanup40_b" ] && kill -0 "$cleanup40_pid" 2>/dev/null && [ -f "$cleanup40_dir/hold-shared-pr/queue/run-302.request.json" ] && python3 -c 'import json,sys; assert "a" not in json.load(open(sys.argv[1]))["prs"]' "$cleanup40_dir/meta.json"; then ok "cleanup 目标 PR 无轮次时成功且保留另一 PR 队列与 hold"; else bad "cleanup 误动另一 PR hold"; fi
expect_grep "release 明确取消 PR B 排队轮" "已丢弃 run #302" "$F" release 40 --thread shared-pr
expect_rc "最后一个存活 hold 属其它 PR 时 cleanup 仍成功" 0 "$F" cleanup 40 --pr b --force
rm -rf "$cleanup40_dir/hold-shared-pr"; rm -f "$cleanup40_dir"/run-301.* "$cleanup40_dir"/run-302.*
git clone -q --bare "$T/bare" "$T/discard-private.git"; git clone -q "$T/discard-private.git" "$T/proj/discard-app"
expect_grep "私有远程 bootstrap 丢弃分支测试" "ready: 30" bash -c "cd '$T/proj/discard-app' && '$F' bootstrap 30 --slug discard-private --no-install"
wt3="$T/proj/discard-app/.claude/worktrees/foreman-30"; echo discard > "$wt3/x"; git -C "$wt3" add x; git -C "$wt3" -c user.email=t@t -c user.name=t commit -q -m discard
discard_branch="$(git -C "$wt3" branch --show-current)"; mv "$T/discard-private.git" "$T/discard-private.offline"
expect_grep "cleanup --discard-unpushed 不 fetch 且打印已清理" "已清理" bash -c "cd '$T/proj/discard-app' && '$F' cleanup 30 --force --discard-unpushed"
if git -C "$T/proj/discard-app" show-ref --verify --quiet "refs/heads/$discard_branch"; then bad "discard 后本地分支仍存在"; else ok "discard 后本地分支已 -D"; fi
mv "$T/discard-private.offline" "$T/discard-private.git"
expect_grep "bootstrap 已合入 base 测试" "ready: 4" "$F" bootstrap 4 --slug merged --no-install
wt4="$T/proj/app/.claude/worktrees/foreman-4"; echo merged > "$wt4/y"; git -C "$wt4" add y; git -C "$wt4" -c user.email=t@t -c user.name=t commit -q -m merged
git -C "$T/proj/app" -c user.email=t@t -c user.name=t merge --no-ff "$(git -C "$wt4" branch --show-current)" -m merged >/dev/null; git -C "$T/proj/app" push -q origin main
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
expect_grep "DEAD TOCTOU 测试登记" "PR「here」" "$F" here 41
toctou_dir="$(dirname "$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/41/meta.json' -print -quit)")"; sleep 300 & toctou_pid=$!
make_hold_fixture "$toctou_dir" toctou 12 "$toctou_pid" here implement; rm -f "$toctou_dir/hold-toctou/queue/run-12.request.json" "$toctou_dir/hold-toctou/active.json"
mkfifo "$toctou_dir/hold-toctou/active.json"; "$F" status 41 > "$T/toctou-status.out" 2>&1 & toctou_status_pid=$!
sleep 1; printf 0 > "$toctou_dir/run-12.rc"; printf '{"run":"run-13"}' > "$toctou_dir/hold-toctou/active.json"; wait "$toctou_status_pid"
toctou_line="$(grep 'run#12' "$T/toctou-status.out" | head -1)"; case " $toctou_line " in *" DONE "*) ok "active 读取期间落 rc 不误判 DEAD" ;; *) bad "DEAD TOCTOU 重读完成标记" "$toctou_line" ;; esac
kill "$toctou_pid" 2>/dev/null; wait "$toctou_pid" 2>/dev/null || true; rm -rf "$toctou_dir/hold-toctou"; rm -f "$toctou_dir"/run-12.*
expect_grep "DEAD TOCTOU 测试清理" "已删登记" "$F" cleanup 41 --force
expect_grep "旧执行体 active 推断测试登记" "PR「here」" "$F" here 46
active46_dir="$(dirname "$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/46/meta.json' -print -quit)")"; sleep 300 & active46_pid=$!
make_hold_fixture "$active46_dir" legacy-active 10 "$active46_pid" here implement; rm -f "$active46_dir/hold-legacy-active/queue/run-10.request.json"; printf 0 > "$active46_dir/run-10.rc"
make_hold_fixture "$active46_dir" legacy-active 11 "$active46_pid" here implement; rm -f "$active46_dir/hold-legacy-active/queue/run-11.request.json"
make_hold_fixture "$active46_dir" legacy-active 12 "$active46_pid" here implement; rm -f "$active46_dir/hold-legacy-active/active.json"
active46="$(FOREMAN_SELFTEST=1 "$F" __hold_active_run "$active46_dir" "$active46_dir/hold-legacy-active" 2>/dev/null)"
[ "$active46" = run-11 ] && ok "无 active 时排除历史 rc 与未来 queue，选当前活动轮" || bad "旧执行体 active 推断" "$active46"
kill "$active46_pid" 2>/dev/null; wait "$active46_pid" 2>/dev/null || true; rm -rf "$active46_dir/hold-legacy-active"; rm -f "$active46_dir"/run-10.* "$active46_dir"/run-11.* "$active46_dir"/run-12.*
expect_grep "旧执行体 active 推断测试清理" "已删登记" "$F" cleanup 46 --force
expect_grep "wait 摘要隔离测试登记" "PR「here」" "$F" here 42
wait42_dir="$(dirname "$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/42/meta.json' -print -quit)")"
sleep 300 & wait42_done_pid=$!; sleep 300 & wait42_running_pid=$!
make_hold_fixture "$wait42_dir" done-no-log 21 "$wait42_done_pid" here implement; rm -f "$wait42_dir/hold-done-no-log/queue/run-21.request.json"; printf '{"run":"run-21"}' > "$wait42_dir/hold-done-no-log/active.json"
make_hold_fixture "$wait42_dir" still-running 22 "$wait42_running_pid" here implement; rm -f "$wait42_dir/hold-still-running/queue/run-22.request.json"; printf '{"run":"run-22"}' > "$wait42_dir/hold-still-running/active.json"
( sleep 1; printf 0 > "$wait42_dir/run-21.rc"; kill "$wait42_done_pid" 2>/dev/null ) &
wait42_out="$("$F" wait 42 --timeout 2 --interval 1 2>&1)"; wait42_rc=$?
if [ "$wait42_rc" -eq 2 ] && printf '%s\n' "$wait42_out" | grep -q '^== 42 run#21 ' && printf '%s\n' "$wait42_out" | grep -q '^== 42 run#22 ' && printf '%s\n' "$wait42_out" | grep -q '无日志，跳过摘要'; then ok "wait 缺日志摘要不覆盖 rc=2 且全表保留"; else bad "wait 摘要 die 隔离" "rc=${wait42_rc}，尾行: $(printf '%s\n' "$wait42_out" | tail -1)"; fi
kill "$wait42_running_pid" 2>/dev/null; wait "$wait42_done_pid" 2>/dev/null || true; wait "$wait42_running_pid" 2>/dev/null || true
rm -rf "$wait42_dir/hold-done-no-log" "$wait42_dir/hold-still-running"; rm -f "$wait42_dir"/run-21.* "$wait42_dir"/run-22.*
expect_grep "wait 摘要隔离测试清理" "已删登记" "$F" cleanup 42 --force
expect_grep "wait 取消尾轮测试登记" "PR「here」" "$F" here 43
wait43_dir="$(dirname "$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/43/meta.json' -print -quit)")"; sleep 300 & wait43_pid=$!
make_hold_fixture "$wait43_dir" cancel-tail 1 "$wait43_pid" here implement; rm -f "$wait43_dir/hold-cancel-tail/queue/run-1.request.json"; printf '{"run":"run-1"}' > "$wait43_dir/hold-cancel-tail/active.json"
make_hold_fixture "$wait43_dir" cancel-tail 2 "$wait43_pid" here implement; rm -f "$wait43_dir/hold-cancel-tail/queue/run-2.request.json" "$wait43_dir/run-2.pid"; printf 130 > "$wait43_dir/run-2.rc"; printf '已取消尾轮' > "$wait43_dir/run-2.cancelled"
wait43_out="$("$F" wait 43 --timeout 1 --interval 1 --no-report 2>&1)"; wait43_rc=$?
if [ "$wait43_rc" -eq 2 ] && printf '%s\n' "$wait43_out" | grep -q '^== 43 run#1 .*RUNNING' && printf '%s\n' "$wait43_out" | grep -q '^== 43 run#2 CANCELLED'; then ok "wait 显示取消尾轮且继续等活动旧轮"; else bad "wait 被 CANCELLED 尾轮提前收敛" "rc=$wait43_rc"; fi
kill "$wait43_pid" 2>/dev/null; wait "$wait43_pid" 2>/dev/null || true; rm -rf "$wait43_dir/hold-cancel-tail"; rm -f "$wait43_dir"/run-1.* "$wait43_dir"/run-2.*
expect_grep "wait 取消尾轮测试清理" "已删登记" "$F" cleanup 43 --force
expect_grep "wait 超时事件尾测试登记" "PR「here」" "$F" here 49
wait49_dir="$(dirname "$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/49/meta.json' -print -quit)")"; sleep 300 & wait49_pid=$!
printf 'implement' > "$wait49_dir/run-1.thread"; printf 'implement' > "$wait49_dir/run-1.role"; printf 'codex' > "$wait49_dir/run-1.engine"; printf 'here' > "$wait49_dir/run-1.pr"
printf '%s' "$wait49_pid" > "$wait49_dir/run-1.pid"; printf '%s' "$(date +%s)" > "$wait49_dir/run-1.started"; printf 30 > "$wait49_dir/run-1.timeout"; : > "$wait49_dir/run-1.argv"
printf '%s\n' '{"_fleet":"thread","threadId":"wait-tail"}' '{"method":"item/completed","params":{"item":{"id":"msg-tail","type":"agentMessage","text":"timeout-tail-marker"}}}' > "$wait49_dir/run-1.jsonl"
wait49_out="$("$F" wait 49 --timeout 1 --interval 1 --progress 0 --no-report 2>&1)"; wait49_rc=$?
if [ "$wait49_rc" -eq 2 ] && printf '%s\n' "$wait49_out" | grep -q 'wait 超时事件尾' && printf '%s\n' "$wait49_out" | grep -q 'timeout-tail-marker'; then ok "wait 超时 rc=2 附事件尾"; else bad "wait 超时事件尾" "rc=$wait49_rc $wait49_out"; fi
kill "$wait49_pid" 2>/dev/null; wait "$wait49_pid" 2>/dev/null || true; rm -f "$wait49_dir"/run-1.*
expect_grep "wait 正常结束测试登记" "PR「here」" "$F" here 50
wait50_dir="$(dirname "$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/50/meta.json' -print -quit)")"; sleep 300 & wait50_pid=$!
printf 'implement' > "$wait50_dir/run-1.thread"; printf 'implement' > "$wait50_dir/run-1.role"; printf 'codex' > "$wait50_dir/run-1.engine"; printf 'here' > "$wait50_dir/run-1.pr"
printf '%s' "$wait50_pid" > "$wait50_dir/run-1.pid"; printf '%s' "$(date +%s)" > "$wait50_dir/run-1.started"; printf 30 > "$wait50_dir/run-1.timeout"; : > "$wait50_dir/run-1.argv"; printf '%s\n' '{"_fleet":"thread","threadId":"wait-done"}' > "$wait50_dir/run-1.jsonl"
( sleep 1.2; printf 0 > "$wait50_dir/run-1.rc"; kill "$wait50_pid" 2>/dev/null ) &
wait50_out="$("$F" wait 50 --timeout 3 --interval 1 --progress 0 --no-report 2>&1)"; wait50_rc=$?
if [ "$wait50_rc" -eq 0 ] && printf '%s\n' "$wait50_out" | grep -q '结束 rc=0'; then ok "wait 正常结束 rc=0 不受影响"; else bad "wait 正常结束" "rc=$wait50_rc $wait50_out"; fi
wait "$wait50_pid" 2>/dev/null || true; rm -f "$wait50_dir"/run-1.*
expect_grep "wait 多线程集中输出测试登记" "PR「here」" "$F" here 51
wait51_dir="$(dirname "$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/51/meta.json' -print -quit)")"; sleep 300 & wait51_pid=$!
make_hold_fixture "$wait51_dir" a-fast 1 "$wait51_pid" here implement; rm -f "$wait51_dir/hold-a-fast/queue/run-1.request.json"; printf '{"run":"run-1"}' > "$wait51_dir/hold-a-fast/active.json"
make_hold_fixture "$wait51_dir" z-slow 2 "$wait51_pid" here implement; rm -f "$wait51_dir/hold-z-slow/queue/run-2.request.json"; printf '{"run":"run-2"}' > "$wait51_dir/hold-z-slow/active.json"
printf 60 > "$wait51_dir/run-1.timeout"; printf 60 > "$wait51_dir/run-2.timeout"
python3 - "$wait51_dir/run-1.jsonl" "$wait51_dir/run-2.jsonl" <<'PY2'
import json,sys,time
stamp=int(time.time()*1000)
with open(sys.argv[1],"w") as f: f.write(json.dumps({"_fleet":"thread","threadId":"fast","_at":stamp})+"\n")
with open(sys.argv[2],"w") as f:
    f.write(json.dumps({"_fleet":"thread","threadId":"slow","_at":stamp})+"\n")
    row=json.dumps({"method":"selftest/noop","params":{},"_at":stamp})+"\n"
    f.write(row*120000)
PY2
( sleep 1.2; python3 - "$wait51_dir/run-1.jsonl" "$wait51_dir/run-2.jsonl" <<'PY2'
import json,sys,time
stamp=int(time.time()*1000)
for path,text in zip(sys.argv[1:],("fast-progress","slow-progress")):
    with open(path,"a") as f: f.write(json.dumps({"method":"item/completed","params":{"item":{"id":text,"type":"agentMessage","text":text}},"_at":stamp})+"\n")
PY2
) &
wait51_timed="$( ( "$F" wait 51 --timeout 3 --interval 1 --progress 1 --no-report 2>&1 || true ) | python3 -c 'import sys,time
for line in sys.stdin: print(f"{time.monotonic():.6f}\t{line.rstrip()}",flush=True)' )"
if printf '%s\n' "$wait51_timed" | python3 -c 'import sys
rows=[line.rstrip().split("\t",1) for line in sys.stdin if "进展 51 run#" in line]
assert len(rows)>=2, rows
pair=rows[:2]; assert "run#1" in pair[0][1] and "run#2" in pair[1][1], pair
assert float(pair[1][0])-float(pair[0][0]) < .2, pair'; then ok "wait 同周期先解析全部线程再集中输出"; else bad "wait 多线程进展未集中" "$wait51_timed"; fi
kill "$wait51_pid" 2>/dev/null; wait "$wait51_pid" 2>/dev/null || true; rm -rf "$wait51_dir/hold-a-fast" "$wait51_dir/hold-z-slow"; rm -f "$wait51_dir"/run-1.* "$wait51_dir"/run-2.*
expect_grep "wait 多线程集中输出测试清理" "已删登记" "$F" cleanup 51 --force
expect_grep "旧轮 closeout 测试登记" "PR「here」" "$F" here 44
old44_dir="$(dirname "$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/44/meta.json' -print -quit)")"; make_hold_fixture "$old44_dir" implement 1 999999 here implement
rm -f "$old44_dir/run-1.pr" "$old44_dir/hold-implement/queue/run-1.request.json"
expect_rc "旧轮缺 .pr 时 closeout 续 implement" 4 "$F" run 44 --closeout --prompt "$T/brief.md" --title old-closeout --timeout 30
old44_latest="$(ls -t "$old44_dir"/run-*.request.json | head -1)"; [ "$(cat "${old44_latest%.request.json}.thread")" = implement ] && ok "旧轮 closeout 线程归属回退 default PR" || bad "旧轮 closeout 未续 implement"
rm -rf "$old44_dir/hold-implement"; rm -f "$old44_dir"/run-*; expect_grep "旧轮 closeout 测试清理" "已删登记" "$F" cleanup 44 --force
expect_grep "旧轮 cleanup 测试登记" "PR「here」" "$F" here 45
old45_dir="$(dirname "$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/45/meta.json' -print -quit)")"; sleep 300 & old45_pid=$!
make_hold_fixture "$old45_dir" implement 1 "$old45_pid" here implement; rm -f "$old45_dir/run-1.pr"
expect_grep "旧轮缺 .pr 时 cleanup 按 default PR 拒绝排队轮" "run-1: QUEUED" "$F" cleanup 45 --force
expect_grep "旧轮 cleanup 前显式 release" "已丢弃 run #1" "$F" release 45 --thread implement
expect_grep "旧轮 release 后 cleanup 成功" "已删登记" "$F" cleanup 45 --force
if [ -f "$old45_dir/run-1.cancelled" ] && ! kill -0 "$old45_pid" 2>/dev/null; then ok "旧轮 cleanup 按 default PR 识别 hold"; else bad "旧轮 cleanup 漏释放 hold"; fi
if [ -n "$req3" ]; then
  d2="$(dirname "$req3")"; sleep 300 & sp=$!
  printf 'a' > "$d2/run-99.pr"; printf 'implement' > "$d2/run-99.thread"; printf '%s' "$sp" > "$d2/run-99.pid"; : > "$d2/run-99.argv"
  expect_grep "同一 PR 另一条线程在跑时 run 被拒" "只准一条线程" "$F" run 2 --pr a --role accept --prompt "$T/brief.md" --title x --timeout 30
  expect_grep "同一 PR 另一条线程在跑时 review 被拒" "只准一条线程" "$F" review 2 --pr a --title x --timeout 30
  make_hold_fixture "$d2" stale 197 "$sp" a implement; rm -f "$d2/hold-stale/queue/run-197.request.json"
  stale_line="$("$F" status 2 | grep 'run#197' | head -1)"
  case " $stale_line " in *" RUNNING "*) ok "bridge 存活且 active 缺失的交接窗口仍为 RUNNING" ;; *) bad "交接窗口被误判 DEAD" "$stale_line" ;; esac
  make_hold_fixture "$d2" stale 198 "$sp" a implement; rm -f "$d2/hold-stale/queue/run-198.request.json"
  printf '{"run":"run-199"}' > "$d2/hold-stale/active.json"
  stale_line="$("$F" status 2 | grep 'run#198' | head -1)"
  case " $stale_line " in *" DEAD "*) ok "active 指向更大轮次时旧轮精确判 DEAD" ;; *) bad "旧轮未判 DEAD" "$stale_line" ;; esac
  make_hold_fixture "$d2" stale 200 "$sp" a implement; rm -f "$d2/hold-stale/queue/run-200.request.json"
  printf '{"run":"run-199"}' > "$d2/hold-stale/active.json"
  stale_line="$("$F" status 2 | grep 'run#200' | head -1)"
  case " $stale_line " in *" RUNNING "*) ok "active 指向更小轮次时当前轮仍为 RUNNING" ;; *) bad "较小 active 误杀当前轮" "$stale_line" ;; esac
  rm -rf "$d2/hold-stale" "$d2"/run-197.* "$d2"/run-198.* "$d2"/run-200.*
  rm -f "$d2"/run-99.*
  nn=1; while [ -f "$d2/run-$nn.argv" ] || [ -f "$d2/run-$nn.jsonl" ]; do nn=$((nn+1)); done
  printf 'implement' > "$d2/run-$nn.thread"; printf '%s' "$sp" > "$d2/run-$nn.pid"; : > "$d2/run-$nn.argv"
  mkdir -p "$d2/hold-implement/queue"; : > "$d2/hold-implement/queue/run-$nn.request.json"
  old_started=$(( $(date +%s) - 65 )); printf '%s' "$old_started" > "$d2/run-$nn.started"
  expect_grep "wait 把 QUEUED 轮次当在跑" "等待 1 个会话" "$F" wait 2 --timeout 1 --no-report
  queued_elapsed="$($F status 2 | awk -v n="run#$nn" '$2==n {print $7}')"
  rm -f "$d2/hold-implement/queue/run-$nn.request.json"; printf '{"run":"run-%s"}' "$nn" > "$d2/hold-implement/active.json"
  running_elapsed="$($F status 2 | awk -v n="run#$nn" '$2==n {print $7}')"
  elapsed_seconds() { case "$1" in *m*s) printf '%s' "$1" | awk -F'm|s' '{print $1*60+$2}' ;; *) return 1 ;; esac; }
  qsec="$(elapsed_seconds "$queued_elapsed")"; rsec="$(elapsed_seconds "$running_elapsed")"
  if [ "$rsec" -ge "$qsec" ] && [ "$(cat "$d2/run-$nn.started")" = "$old_started" ]; then ok "QUEUED→RUNNING 主用时沿用派发时间不归零"; else bad "QUEUED→RUNNING 用时归零"; fi
  rm -f "$d2/hold-implement/active.json"
  printf 'a' > "$d2/run-96.pr"; printf 'parallel' > "$d2/run-96.thread"; printf '%s' "$sp" > "$d2/run-96.pid"; : > "$d2/run-96.argv"
  expect_grep "wait 等票下全部线程" "等待 2 个会话" "$F" wait 2 --timeout 1 --no-report
  rm -f "$d2"/run-96.*
  printf '%s' "$sp" > "$d2/review-96.pid"; : > "$d2/review-96.argv"
  expect_grep "wait 收入无 thread 文件的运行中 review" "等待 2 个会话" "$F" wait 2 --timeout 1 --no-report
  rm -f "$d2"/review-96.*
  rm -rf "$d2/hold-implement"; printf '{"questions":[{"id":"q1","text":"用哪张任务？"}]}' > "$d2/run-$nn.questions.json"
  expect_rc "wait 遇到提问返回 3" 3 "$F" wait 2 --timeout 30 --no-report
  expect_grep "wait 遇到提问首行给票、线程和摘要" "WAITING：票 2 / 线程 implement / 用哪张任务" "$F" wait 2 --timeout 30 --no-report
  rm -f "$d2/run-$nn.questions.json"
  d1="$(dirname "$req")"; printf 'implement' > "$d1/run-95.thread"; printf '%s' "$sp" > "$d1/run-95.pid"; : > "$d1/run-95.argv"; printf '{"questions":[{"text":"无关票问题"}]}' > "$d1/run-95.questions.json"
  expect_rc "wait 指定票不受无关票 WAITING 影响" 2 "$F" wait 2 --timeout 1 --no-report
  wait_all_out="$($F wait --timeout 1 --no-report 2>&1)"; wait_all_rc=$?
  if [ "$wait_all_rc" = 3 ] && printf '%s' "$wait_all_out" | grep -q '^== 1 ' && printf '%s' "$wait_all_out" | grep -q '^== 2 '; then ok "wait 全票 WAITING 返回前照常打印全表"; else bad "wait 全票 WAITING 全表"; fi
  rm -f "$d1"/run-95.*
  rm -rf "$d2/run-$nn".*
  kill "$sp" 2>/dev/null; rm -f "$d2"/run-99.*
  wtb="$(ls -t "$d2"/run-*.wt-before 2>/dev/null | head -1)"
  if [ -n "$wtb" ]; then
    nn="$(basename "$wtb" .wt-before)"; nn="${nn#run-}"; wt2="$T/proj/app/.claude/worktrees/foreman-2"
    echo dirty > "$wt2/dirty.txt"
    expect_grep "只看不改的角色改了 worktree 被标出" "工作树有改动，需人工判" "$F" report 2 "$nn"
    : > "$d2/run-97.jsonl"; printf '{"_fleet":"thread","threadId":"t"}\n' > "$d2/run-97.jsonl"; : > "$d2/run-97.stderr"; : > "$d2/run-97.last.md"
    printf 'accept' > "$d2/run-97.thread"; printf 'accept' > "$d2/run-97.role"; printf 'a' > "$d2/run-97.pr"; printf '%s' "$$" > "$d2/run-97.pid"; : > "$d2/run-97.argv"; cp "$wtb" "$d2/run-97.wt-before"
    (sleep 1; printf 0 > "$d2/run-97.rc"; rm -f "$d2/run-97.pid") &
    expect_grep "wait 摘要经过工作树 porcelain 探针" "工作树有改动，需人工判" "$F" wait 2 --timeout 3 --interval 1
    rm -f "$d2"/run-97.*
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
expect_grep "list here 空分支测试登记" "PR「here」" "$F" here 48
list48_meta="$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/48/meta.json' -print -quit)"
list48_dir="$(dirname "$list48_meta")"
python3 - "$list48_meta" <<'PY2'
import json,sys
p=sys.argv[1]; m=json.load(open(p)); m["prs"]["here"]["branch"]=""; m["prs"]["here"]["base"]=""; json.dump(m,open(p,"w"))
PY2
for list48_n in 1 2 3 4 5; do printf '%s\n' '{"_fleet":"thread","threadId":"list-test"}' '{"method":"turn/completed","params":{"turn":{"status":"completed"}}}' > "$list48_dir/run-$list48_n.jsonl"; done
list48_out="$("$F" list)"
list48_row="$(printf '%s\n' "$list48_out" | grep '^48 ' | head -1)"
if printf '%s\n' "$list48_row" | grep -Eq '^48 +— +— +— +aaaaa ' && ! printf '%s\n' "$list48_row" | grep -q '?'; then ok "list 的 here 空分支 / 基线显示 —，引擎列逐轮保留"; else bad "list here 分支 / 引擎列" "$list48_out"; fi
python3 - "$list48_meta" <<'PY2'
import json,sys
p=sys.argv[1]; m=json.load(open(p)); m["branch"]="old-branch"; m["base"]="old-base"; m["worktree"]="/old/worktree"
m["prs"]["here"].update({"branch":"new-branch","base":"new-base"}); json.dump(m,open(p,"w"))
PY2
list48_mixed="$("$F" list)"; list48_mixed_row="$(printf '%s\n' "$list48_mixed" | grep '^48 ' | head -1)"
if printf '%s\n' "$list48_mixed_row" | grep -Eq '^48 +new-branch +new-base ' && printf '%s\n' "$list48_mixed" | grep -Eq '^  48 +分支 new-branch +' && ! printf '%s\n' "$list48_mixed" | grep -q 'old-branch'; then ok "list 两张表以新版选中 PR 覆盖旧顶层字段"; else bad "list 新旧账本优先级" "$list48_mixed"; fi
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
{"_fleet":"thread","threadId":"t1","model":"m","reasoningEffort":"low","cwd":"/workspace/proj","workDir":"/workspace/proj/app"}
{"method":"item/completed","params":{"item":{"type":"fileChange","status":"completed","changes":[{"kind":"update","path":"/workspace/proj/app/a.ts"},{"kind":"add","path":"/workspace/proj/other/b.ts"}]}}}
{"_fleet":"thread_busy","hint":"桌面端占着","error":"already has an active writer"}
EOF2
: > "$T/probe.stderr"; echo done > "$T/probe.last.md"
expect_grep "工作目录之外的改动被标出" "工作目录之外" python3 "$SKILL_DIR/scripts/summarize.py" "$T/probe.jsonl" "$T/probe.stderr" "$T/probe.last.md"
expect_grep "THREAD_BUSY 横幅" "THREAD_BUSY" python3 "$SKILL_DIR/scripts/summarize.py" "$T/probe.jsonl" "$T/probe.stderr" "$T/probe.last.md"
cp "$T/probe.jsonl" "$T/probe2.jsonl"; : > "$T/probe2.stderr"; echo done > "$T/probe2.last.md"
python3 -c 'import json,sys; json.dump({"work_dir": sys.argv[2], "config_overrides": [["sandbox_workspace_write.writable_roots", json.dumps([sys.argv[2], sys.argv[3]])]]}, open(sys.argv[1],"w"))' "$T/probe2.request.json" "/workspace/proj/app" "/workspace/proj/other"
expect_no_grep "--writable 目录不算越界（交付目录）" "工作目录之外" python3 "$SKILL_DIR/scripts/summarize.py" "$T/probe2.jsonl" "$T/probe2.stderr" "$T/probe2.last.md"
sed "s#/workspace/proj/other/b.ts#$T/system-temp.txt#" "$T/probe.jsonl" > "$T/probe-tmp.jsonl"
expect_no_grep "系统临时目录不计工作目录之外" "工作目录之外" python3 "$SKILL_DIR/scripts/summarize.py" "$T/probe-tmp.jsonl" "$T/probe.stderr" "$T/probe.last.md"
expect_no_grep "accept 交付目录 fileChange 从模型改动列表排除" '/workspace/proj/other/b.ts' python3 "$SKILL_DIR/scripts/summarize.py" --role accept "$T/probe2.jsonl" "$T/probe2.stderr" "$T/probe2.last.md"
expect_no_grep "fileChange 只列事实、不判只看不改角色作废" '改了这轮作废' python3 "$SKILL_DIR/scripts/summarize.py" --role review "$T/probe.jsonl" "$T/probe.stderr" "$T/probe.last.md"
echo "== wait 进展摘要 =="
progress_log="$T/progress.jsonl"; progress_state="$T/progress.state.json"
printf 1000 > "$T/progress.started"; printf 3600 > "$T/progress.timeout"
printf '%s\n' '{"_fleet":"thread","threadId":"progress-test","_at":1000000}' > "$progress_log"
python3 "$SKILL_DIR/scripts/summarize.py" --progress "$progress_log" "$progress_state" "票 p run#1" RUNNING 300 1000 >/dev/null
printf '%s\n' '{"method":"item/completed","params":{"item":{"id":"file-1","type":"fileChange","changes":[{"kind":"update","path":"a.sh"}]}},"_at":1100000}' >> "$progress_log"
progress_early="$(python3 "$SKILL_DIR/scripts/summarize.py" --progress "$progress_log" "$progress_state" "票 p run#1" RUNNING 300 1200)"
progress_due="$(python3 "$SKILL_DIR/scripts/summarize.py" --progress "$progress_log" "$progress_state" "票 p run#1" RUNNING 300 1301)"
if [ -z "$progress_early" ] && printf '%s\n' "$progress_due" | grep -q '新增事件 1.*最后：✎'; then ok "wait 周期到且有新事件才输出进展行"; else bad "wait 有新事件进展周期" "$progress_early / $progress_due"; fi
progress_quiet="$(python3 "$SKILL_DIR/scripts/summarize.py" --progress "$progress_log" "$progress_state" "票 p run#1" RUNNING 300 1602)"
[ -z "$progress_quiet" ] && ok "wait 周期到但无新事件不输出" || bad "wait 无事件仍输出" "$progress_quiet"

idle_log="$T/idle.jsonl"; idle_state="$T/idle.state.json"; printf 1000 > "$T/idle.started"; printf 3600 > "$T/idle.timeout"
printf '%s\n' '{"_fleet":"thread","threadId":"idle-test","_at":1000000}' > "$idle_log"
python3 "$SKILL_DIR/scripts/summarize.py" --progress "$idle_log" "$idle_state" "票 idle run#1" RUNNING 300 1000 >/dev/null
idle_out="$(python3 "$SKILL_DIR/scripts/summarize.py" --progress "$idle_log" "$idle_state" "票 idle run#1" RUNNING 300 1601; python3 "$SKILL_DIR/scripts/summarize.py" --progress "$idle_log" "$idle_state" "票 idle run#1" RUNNING 300 1700)"
[ "$(printf '%s\n' "$idle_out" | grep -c '分钟无新事件')" -eq 1 ] && ok "wait 无事件 10 分钟只提示一次" || bad "wait 无事件重复提示" "$idle_out"

long_log="$T/long-command.jsonl"; long_state="$T/long-command.state.json"; printf 1000 > "$T/long-command.started"; printf 3600 > "$T/long-command.timeout"
printf '%s\n' '{"method":"item/started","params":{"item":{"id":"cmd-long","type":"commandExecution","command":"slow-test"}},"_at":1000000}' > "$long_log"
python3 "$SKILL_DIR/scripts/summarize.py" --progress "$long_log" "$long_state" "票 long run#1" RUNNING 300 1000 >/dev/null
long_out="$(python3 "$SKILL_DIR/scripts/summarize.py" --progress "$long_log" "$long_state" "票 long run#1" RUNNING 300 1601; python3 "$SKILL_DIR/scripts/summarize.py" --progress "$long_log" "$long_state" "票 long run#1" RUNNING 300 1700)"
[ "$(printf '%s\n' "$long_out" | grep -c '命令已跑.*slow-test')" -eq 1 ] && ok "wait 长命令 10 分钟只提示一次" || bad "wait 长命令重复提示" "$long_out"

off_log="$T/progress-off.jsonl"; off_state="$T/progress-off.state.json"; printf 1000 > "$T/progress-off.started"; printf 3600 > "$T/progress-off.timeout"
printf '%s\n' '{"_fleet":"thread","threadId":"off-test","_at":1000000}' > "$off_log"
python3 "$SKILL_DIR/scripts/summarize.py" --progress "$off_log" "$off_state" "票 off run#1" RUNNING 0 1000 >/dev/null
printf '%s\n' '{"method":"item/completed","params":{"item":{"id":"msg-off","type":"agentMessage","text":"new"}},"_at":1100000}' >> "$off_log"
off_out="$(python3 "$SKILL_DIR/scripts/summarize.py" --progress "$off_log" "$off_state" "票 off run#1" RUNNING 0 1301)"
[ -z "$off_out" ] && ok "wait --progress 0 关闭周期进展" || bad "wait --progress 0 仍输出进展" "$off_out"

terminal_log="$T/terminal.jsonl"; printf 1000 > "$T/terminal.started"; printf 3600 > "$T/terminal.timeout"
printf '%s\n' '{"method":"item/started","params":{"item":{"id":"cmd-terminal","type":"commandExecution","command":"still-marked-running"}},"_at":1000000}' > "$terminal_log"
python3 "$SKILL_DIR/scripts/summarize.py" --progress "$terminal_log" "$T/terminal-done.state" "票 done run#1" RUNNING 300 1000 >/dev/null
python3 "$SKILL_DIR/scripts/summarize.py" --progress "$terminal_log" "$T/terminal-live.state" "票 live run#2" RUNNING 300 1000 >/dev/null
terminal_done="$(python3 "$SKILL_DIR/scripts/summarize.py" --progress "$terminal_log" "$T/terminal-done.state" "票 done run#1" DONE 300 1700)"
terminal_live="$(python3 "$SKILL_DIR/scripts/summarize.py" --progress "$terminal_log" "$T/terminal-live.state" "票 live run#2" RUNNING 300 1700)"
if ! printf '%s\n' "$terminal_done" | grep -Eq '无新事件|命令已跑' && printf '%s\n' "$terminal_live" | grep -q '命令已跑' && python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["active_commands"] == {}' "$T/terminal-done.state"; then ok "多线程中先 DONE 的线程清除运行中异常状态"; else bad "终态线程仍报运行中异常" "$terminal_done / $terminal_live"; fi

budget_log="$T/budget.jsonl"; budget_state="$T/budget.state"; printf 1000 > "$T/budget.started"; printf 1800 > "$T/budget.timeout"; : > "$budget_log"
python3 "$SKILL_DIR/scripts/summarize.py" --progress "$budget_log" "$budget_state" "票 budget run#1" QUEUED 300 1000 >/dev/null
budget_queued="$(python3 "$SKILL_DIR/scripts/summarize.py" --progress "$budget_log" "$budget_state" "票 budget run#1" WAITING 300 1301)"
printf '%s\n' '{"method":"item/started","params":{"item":{"id":"cmd-budget","type":"commandExecution","command":"work"}},"_at":2200000}' > "$budget_log"
budget_running="$(python3 "$SKILL_DIR/scripts/summarize.py" --progress "$budget_log" "$budget_state" "票 budget run#1" RUNNING 300 2500)"
if printf '%s\n' "$budget_queued" | grep -q '排队中，未开始计执行预算' && printf '%s\n' "$budget_running" | grep -q '用时 25m00s.*距 run --timeout 25m00s'; then ok "排队时间不扣 run 执行预算"; else bad "run 执行预算起点" "$budget_queued / $budget_running"; fi
printf '%s\n' '{"method":"warning","params":{"message":"warning: Skill descriptions were shortened to fit the context"}}' '{"method":"warning","params":{"message":"keep this warning"}}' > "$T/warnings.jsonl"
: > "$T/warnings.stderr"; echo done > "$T/warnings.last.md"
warning_out="$(python3 "$SKILL_DIR/scripts/summarize.py" "$T/warnings.jsonl" "$T/warnings.stderr" "$T/warnings.last.md" 2>&1)"; warning_rc=$?
if [ "$warning_rc" -eq 0 ] && printf '%s\n' "$warning_out" | grep -q 'keep this warning' && ! printf '%s\n' "$warning_out" | grep -q 'Skill descriptions were shortened'; then ok "report 只过滤 skill descriptions 良性告警"; else bad "report 良性告警过滤" "rc=$warning_rc"; fi
python3 - "$T/steer-summary.jsonl" <<'PY2'
import json,sys
with open(sys.argv[1],"w") as f:
    for e in ({"_fleet":"steer","at":1789135200000,"fromRun":7,"text":"引导正文"},
              {"_fleet":"steer_requeued","at":1789135200000,"fromRun":None,"run":9,"text":"结束后转排队"}):
        f.write(json.dumps(e,ensure_ascii=False)+"\n")
PY2
expect_grep "report 展示引导来源与正文" "fromRun=7.*引导正文" python3 "$SKILL_DIR/scripts/summarize.py" "$T/steer-summary.jsonl"
expect_grep "report 展示 steer_requeued" "steer_requeued" python3 "$SKILL_DIR/scripts/summarize.py" "$T/steer-summary.jsonl"
cat > "$T/command-dedup.jsonl" <<'EOF2'
{"_fleet":"thread","threadId":"t1"}
{"method":"item/completed","params":{"item":{"type":"commandExecution","command":"retry-me","exitCode":1,"status":"failed","aggregatedOutput":"first"}}}
{"method":"item/completed","params":{"item":{"type":"commandExecution","command":"retry-me","exitCode":0,"status":"completed","aggregatedOutput":"ok"}}}
{"method":"item/completed","params":{"item":{"type":"commandExecution","command":"still-bad","exitCode":2,"status":"failed","aggregatedOutput":"last"}}}
{"method":"item/completed","params":{"item":{"type":"commandExecution","command":"same-cwd-command","cwd":"/a","exitCode":1,"status":"failed"}}}
{"method":"item/completed","params":{"item":{"type":"commandExecution","command":"same-cwd-command","cwd":"/b","exitCode":0,"status":"completed"}}}
EOF2
python3 - "$T/command-dedup.jsonl" <<'PY2'
import json,sys
p=sys.argv[1]; prefix="x"*600
with open(p,"a") as f:
  for cmd,code,status in ((prefix+"A",1,"failed"),(prefix+"B",0,"completed")):
    f.write(json.dumps({"method":"item/completed","params":{"item":{"type":"commandExecution","command":cmd,"cwd":"/c","exitCode":code,"status":status}}})+"\n")
PY2
command_out="$(python3 "$SKILL_DIR/scripts/summarize.py" "$T/command-dedup.jsonl")"
if printf '%s' "$command_out" | grep -q '最后仍失败的命令' && printf '%s' "$command_out" | grep -q 'still-bad' && ! printf '%s' "$command_out" | grep -q 'retry-me'; then ok "report 命令失败按命令去重且末次成功消除失败"; else bad "report 命令失败去重"; fi
if printf '%s' "$command_out" | grep -q '最后仍失败的命令 3 条' && printf '%s' "$command_out" | grep -q '迭代中命令失败 4 次'; then ok "摘要去重键区分 cwd 与 500 字后缀并保留失败次数"; else bad "摘要完整命令 cwd 去重键"; fi
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
cancel_dir="$(dirname "$req")"
sleep 300 & cancel_first_pid=$!; make_hold_fixture "$cancel_dir" cancel-first 91 "$cancel_first_pid" here implement
rm -f "$T/cancel-lock.ready" "$T/cancel-lock.release" "$T/cancel-claim.result"
FOREMAN_SELFTEST_LOCK_READY="$T/cancel-lock.ready" FOREMAN_SELFTEST_LOCK_RELEASE="$T/cancel-lock.release" "$F" release 1 --thread cancel-first > "$T/cancel-first.out" 2>&1 & cancel_cli=$!
for _ in $(seq 1 100); do [ -f "$T/cancel-lock.ready" ] && break; sleep 0.02; done
cancel_blocked_at="$(date +%s)"
python3 - "$SKILL_DIR/scripts/codex_appserver.py" "$cancel_dir" "$T/cancel-claim.result" <<'PY2' & cancel_claim_cli=$!
import importlib.util,pathlib,sys
spec=importlib.util.spec_from_file_location("bridge",sys.argv[1]); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
d=pathlib.Path(sys.argv[2]); hd=d/"hold-cancel-first"; q=hd/"queue/run-91.request.json"
result=b.Holder(str(hd))._claim(str(q)); pathlib.Path(sys.argv[3]).write_text(str(result is None))
PY2
sleep 1; cancel_was_blocked=0; kill -0 "$cancel_claim_cli" 2>/dev/null && cancel_was_blocked=1
: > "$T/cancel-lock.release"; wait "$cancel_claim_cli"; wait "$cancel_cli"; cancel_elapsed=$(( $(date +%s) - cancel_blocked_at ))
if [ "$cancel_was_blocked" -eq 1 ] && [ "$cancel_elapsed" -ge 1 ] && [ "$(cat "$T/cancel-claim.result")" = True ] && [ -f "$cancel_dir/run-91.cancelled" ] && [ ! -f "$cancel_dir/hold-cancel-first/active.json" ]; then ok "取消先持锁：_claim 真阻塞后返回 None"; else bad "取消先到并发锁协议"; fi
rm -rf "$cancel_dir/hold-cancel-first"; rm -f "$cancel_dir"/run-91.*

sleep 300 & claim_first_pid=$!; make_hold_fixture "$cancel_dir" claim-first 92 "$claim_first_pid" here implement
rm -f "$T/claim-lock.ready" "$T/claim-lock.release" "$T/claim-first.result"
python3 - "$SKILL_DIR/scripts/codex_appserver.py" "$cancel_dir" "$T/claim-lock.ready" "$T/claim-lock.release" "$T/claim-first.result" <<'PY2' & claim_cli=$!
import contextlib,importlib.util,pathlib,sys,time
spec=importlib.util.spec_from_file_location("bridge",sys.argv[1]); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
d=pathlib.Path(sys.argv[2]); hd=d/"hold-claim-first"; q=hd/"queue/run-92.request.json"
real_lock=b.runs_lock
@contextlib.contextmanager
def held_lock(path):
    with real_lock(path):
        pathlib.Path(sys.argv[3]).write_text("ready")
        while not pathlib.Path(sys.argv[4]).exists(): time.sleep(.02)
        yield
b.runs_lock=held_lock
result=b.Holder(str(hd))._claim(str(q)); pathlib.Path(sys.argv[5]).write_text(str(result is not None))
PY2
for _ in $(seq 1 100); do [ -f "$T/claim-lock.ready" ] && break; sleep 0.02; done
claim_blocked_at="$(date +%s)"; "$F" release 1 --thread claim-first > "$T/claim-first.out" 2>&1 & claim_release_cli=$!
sleep 1; release_was_blocked=0; kill -0 "$claim_release_cli" 2>/dev/null && release_was_blocked=1
: > "$T/claim-lock.release"; wait "$claim_cli"; wait "$claim_release_cli"; claim_elapsed=$(( $(date +%s) - claim_blocked_at ))
if [ "$release_was_blocked" -eq 1 ] && [ "$claim_elapsed" -ge 1 ] && [ "$(cat "$T/claim-first.result")" = True ] && [ ! -f "$cancel_dir/run-92.cancelled" ]; then ok "领取先持锁：cleanup 真阻塞且不写 cancelled"; else bad "领取先到并发锁协议"; fi
rm -rf "$cancel_dir/hold-claim-first"; rm -f "$cancel_dir"/run-92.*
make_hold_fixture "$cancel_dir" cancelled-visible 93 999999 here implement; printf '预先取消' > "$cancel_dir/run-93.cancelled"
python3 - "$SKILL_DIR/scripts/codex_appserver.py" "$cancel_dir" <<'PY2' && ok "队列与 cancelled 并存时 _claim 删队列且不写 active" || bad "_claim 未优先尊重 cancelled"
import importlib.util,pathlib,sys
spec=importlib.util.spec_from_file_location("bridge",sys.argv[1]); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
d=pathlib.Path(sys.argv[2]); hd=d/"hold-cancelled-visible"; q=hd/"queue/run-93.request.json"
assert b.Holder(str(hd))._claim(str(q)) is None and not q.exists() and not (hd/"active.json").exists()
PY2
rm -rf "$cancel_dir/hold-cancelled-visible"; rm -f "$cancel_dir"/run-93.*
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
    with patch.object(b.subprocess,"run",return_value=subprocess.CompletedProcess([],rc,output,"warning: Skill descriptions were shortened")) as run:
        feature=b.request_input_feature("codex",sys.argv[2],sys.argv[2])
        assert b.request_input_feature("codex",sys.argv[2],sys.argv[2])==feature and run.call_count==1
        assert run.call_args.kwargs["capture_output"] is True
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
echo "== 自动 check =="
auto="$T/auto-check"; mkdir -p "$auto"
printf 'true\n' > "$auto/run-1.check.commands"; : > "$auto/run-1.check.pending"; printf 0 > "$auto/run-1.rc"
"$F" __auto_check "$auto" run 1 "$T/proj/app"
[ "$(cat "$auto/run-1.check.rc")" = 0 ] && grep -q '### true -> exit 0' "$auto/run-1.check.log" && ok "自动 check PASS 写 log / rc" || bad "自动 check PASS 产物"
[ "$(FOREMAN_SELFTEST=1 "$F" __call_state "$auto/run-1")" = DONE ] && ok "check PASS 后 call_state=DONE" || bad "check PASS 终态"
printf 'false\n' > "$auto/run-2.check.commands"; : > "$auto/run-2.check.pending"; printf 0 > "$auto/run-2.rc"
"$F" __auto_check "$auto" run 2 "$T/proj/app"
[ "$(cat "$auto/run-2.check.rc")" = 1 ] && [ "$(cat "$auto/run-2.check.failed-command")" = false ] && ok "自动 check FAIL 记录失败命令" || bad "自动 check FAIL 产物"
expect_grep "report check FAIL 带人工判断与输出尾" "check：FAIL" env FOREMAN_SELFTEST=1 "$F" __check_report "$auto/run-2"
printf 'true\n' > "$auto/run-3.check.commands"; : > "$auto/run-3.check.pending"; printf 4 > "$auto/run-3.rc"
"$F" __auto_check "$auto" run 3 "$T/proj/app"
grep -q 'SKIPPED: 执行体 rc=4' "$auto/run-3.check.status" && [ ! -f "$auto/run-3.check.log" ] && ok "执行体 rc 非零跳过 check" || bad "非零 rc 仍跑 check"
: > "$auto/run-4.check.pending"; printf 0 > "$auto/run-4.rc"; printf '%s' "$$" > "$auto/run-4.check.pid"
[ "$(FOREMAN_SELFTEST=1 "$F" __call_state "$auto/run-4")" = CHECKING ] && ok "call_state 暴露 CHECKING" || bad "CHECKING 状态"
FOREMAN_SELFTEST=1 "$F" __prepare_auto_check "$auto/run-5" implement 1
grep -q -- '--no-check' "$auto/run-5.check.status" && ok "run --no-check 标记跳过" || bad "--no-check"
FOREMAN_SELFTEST=1 "$F" __prepare_auto_check "$auto/run-6" research 0
grep -q '只读角色' "$auto/run-6.check.status" && ok "只读角色跳过 check" || bad "只读角色 check"
FOREMAN_SELFTEST=1 "$F" __prepare_auto_check "$auto/run-7" implement 0
grep -q 'UNCONFIGURED' "$auto/run-7.check.status" && ok "无 verify / package scripts 显示未配置" || bad "check 未配置"

printf "printf checked > '%s'\n" "$auto/empty.checked" > "$auto/run-8.check.commands"; : > "$auto/run-8.check.pending"; : > "$auto/run-8.rc"
FOREMAN_SELFTEST=1 "$F" __start_auto_check "$auto" run 8 "$T/proj/app"
for _ in $(seq 1 100); do [ -f "$auto/run-8.check.empty-rc-seen" ] && break; sleep .02; done
if [ -f "$auto/run-8.check.empty-rc-seen" ] && [ ! -f "$auto/run-8.check.rc" ] && [ ! -f "$auto/run-8.check.status" ]; then ok "worker 观察空 rc 后继续等待"; else bad "空 rc 未被 worker 观察或被当成终态"; fi
printf 0 > "$auto/run-8.rc"
for _ in $(seq 1 100); do [ -f "$auto/run-8.check.rc" ] && break; sleep .05; done
[ "$(cat "$auto/run-8.check.rc" 2>/dev/null)" = 0 ] && [ -f "$auto/empty.checked" ] && ok "rc 写完整后 detached check 执行" || bad "完整 rc 未触发 check"

printf 'sleep 30\n' > "$auto/run-9.check.commands"; : > "$auto/run-9.check.pending"; printf 0 > "$auto/run-9.rc"
FOREMAN_SELFTEST=1 "$F" __start_auto_check "$auto" run 9 "$T/proj/app"
for _ in $(seq 1 100); do [ -f "$auto/run-9.check.started" ] && break; sleep .02; done
run9_pid="$(cat "$auto/run-9.check.pid")"; kill -KILL "-$run9_pid" 2>/dev/null || kill -KILL "$run9_pid" 2>/dev/null || true
for _ in $(seq 1 100); do kill -0 "$run9_pid" 2>/dev/null || break; sleep .02; done
if [ "$(FOREMAN_SELFTEST=1 "$F" __call_state "$auto/run-9")" = DONE ] && [ "$(FOREMAN_SELFTEST=1 "$F" __check_result "$auto/run-9")" = 'FAIL（worker 消失）' ]; then ok "worker 消失不永久 CHECKING"; else bad "worker 消失状态"; fi

printf 'sleep 30\n' > "$auto/run-13.check.commands"; : > "$auto/run-13.check.pending"; mkdir -p "$auto/hold-dispatch/queue"; printf queued > "$auto/hold-dispatch/queue/run-13.request.json"
FOREMAN_SELFTEST=1 "$F" __start_auto_check "$auto" run 13 "$T/proj/app"
for _ in $(seq 1 100); do [ -f "$auto/run-13.check.pid" ] && break; sleep .02; done
run13_pid="$(cat "$auto/run-13.check.pid")"
( exec 9>"$auto/.runs.lock"; python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)' 9>&9; FOREMAN_SELFTEST=1 "$F" __cleanup_failed_dispatch "$auto/run-13" )
if ! kill -0 "$run13_pid" 2>/dev/null && [ ! -f "$auto/run-13.check.pending" ] && [ ! -f "$auto/hold-dispatch/queue/run-13.request.json" ] && [ -f "$auto/run-13.cancelled" ] && grep -q '^FAILED: 派发失败$' "$auto/run-13.check.status"; then ok "派发失败撤回未领取队列并写终态"; else bad "派发失败清理残留"; fi
printf queued > "$auto/hold-dispatch/queue/run-14.request.json"; printf 999999 > "$auto/run-14.pid"
( exec 9>"$auto/.runs.lock"; python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)' 9>&9; FOREMAN_SELFTEST=1 "$F" __cleanup_failed_dispatch "$auto/run-14" )
if [ -f "$auto/hold-dispatch/queue/run-14.request.json" ] && [ ! -f "$auto/run-14.cancelled" ]; then ok "派发失败清理不撤回已交接请求"; else bad "已交接请求被误清"; fi

python3 -B - "$F" "$SKILL_DIR/scripts/check_state.py" "$auto/parity" <<'PY2'
import importlib.util,os,pathlib,subprocess,sys
shell,module_path,base=sys.argv[1:]; spec=importlib.util.spec_from_file_location("check_state",module_path); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
cases=[({},"TERMINAL"),({"pending":""},"PENDING_RUN"),({"pending":"","rc":""},"PENDING_RUN"),
       ({"pending":"","rc":" 0 ","pid":str(os.getpid())},"CHECKING"),
       ({"pending":"","rc":"0"},"WORKER_GONE"),({"pending":"","rc":"0","pid":"bad"},"WORKER_GONE"),
       ({"pending":"","rc":"0","pid":"99999999"},"WORKER_GONE"),
       ({"pending":"","rc":"0","pid":str(os.getpid()),"status":"FAILED unexpected"},"CHECKING"),
       ({"pending":"","status":"FAILED: boom"},"TERMINAL"),({"pending":"","rc":" 4 "},"TERMINAL"),
       ({"pending":"","check_rc":"1","rc":"0","pid":str(os.getpid())},"TERMINAL"),
       ({"pending":"","status":"SKIPPED"},"TERMINAL"),({"pending":"","status":"SKIPPED: why"},"TERMINAL"),
       ({"pending":"","status":"UNCONFIGURED"},"TERMINAL"),({"pending":"","status":"UNCONFIGURED: why"},"TERMINAL")]
base=pathlib.Path(base); base.mkdir()
for i,(files,want) in enumerate(cases):
    stem=base/f"case-{i}"
    for suffix,value in files.items(): pathlib.Path(str(stem)+(".check.pending" if suffix=="pending" else ".check.rc" if suffix=="check_rc" else f".check.{suffix}" if suffix in ("pid","status") else f".{suffix}")).write_text(value)
    py=m.check_state(stem)
    sh=subprocess.check_output([shell,"__check_state",str(stem)],env={**os.environ,"FOREMAN_SELFTEST":"1"},text=True)
    assert py==sh==want,(i,py,sh,want)
PY2
[ "$?" -eq 0 ] && ok "shell/Python check_state 表驱动 parity" || bad "check_state parity"

printf "sleep 1; date +%%s > '%s'\n" "$auto/check-ended" > "$auto/run-10.check.commands"; : > "$auto/run-10.check.pending"
( exec 9>"$auto/.runs.lock"; python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)' 9>&9
  FOREMAN_SELFTEST=1 "$F" __start_auto_check "$auto" run 10 "$T/proj/app" )
if python3 - "$auto/.runs.lock" <<'PY2'
import fcntl,sys
with open(sys.argv[1], "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
PY2
then ok "detached check 不继承 runs lock"; else bad "check worker 泄漏 fd 9"; fi
mkdir -p "$auto/hold-check/queue"; printf '{"thread_id":"root","idle_seconds":5}' > "$auto/hold-check/hold.json"
python3 -B - "$SKILL_DIR/scripts/codex_appserver.py" "$auto" <<'PY2'
import importlib.util,json,pathlib,sys,time
spec=importlib.util.spec_from_file_location("bridge",sys.argv[1]); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
root=pathlib.Path(sys.argv[2]); hold=root/"hold-check"
for n in (10, 12):
    req={"out_rc":str(root/f"run-{n}.rc"), "out_jsonl":str(root/f"run-{n}.jsonl"),
         "out_stderr":str(root/f"run-{n}.stderr"), "timeout":5}
    (hold/"queue"/f"run-{n}.request.json").write_text(json.dumps(req))
class Proc:
    def poll(self): return None
class Server:
    proc=Proc()
    def set_log(self, path): pass
    def next_message(self, timeout): return {}
    def dispatch(self, msg): pass
    def close(self): pass
    def log_event(self, event):
        if event.get("_fleet") == "hold_turn_done" and event.get("run") == "run-12.jsonl":
            (hold/"release").touch()
class Runner:
    def __init__(self, cfg):
        self.cfg=cfg; self.thread_id="root"; self.boot_info={}; self.server=None
        self.turn_id=None; self.turn_status=None; self.interrupt_requested=False
    def boot(self): self.server=Server(); return self.server
    def turn(self):
        stem=pathlib.Path(self.cfg["out_jsonl"]).stem
        if stem == "run-10":
            (root/"first-started").write_text(str(time.monotonic()))
        if stem == "run-12":
            assert (root/"check-ended").exists(), "second turn started before check ended"
            (root/"next-started").write_text(str(int(time.time())))
        return 0
    def finish(self, rc): pass
    def handle_server_request(self, msg): pass
    def handle_notification(self, msg): pass
    def _classify_failure(self, exc): return 3
b.Runner=Runner
started=time.monotonic(); assert b.Holder(str(hold)).serve() == 0
assert float((root/"first-started").read_text()) - started < 2
PY2
[ -f "$auto/run-10.check.rc" ] && [ "$(cat "$auto/check-ended")" -le "$(cat "$auto/next-started")" ] && ok "Holder 双队列等 check 终态才领取下一轮" || bad "Holder/check 双队列互斥"

printf "while [ ! -f '%s' ]; do sleep .02; done; : > '%s'\n" "$auto/release-check-gate" "$auto/release-check-ended" > "$auto/run-15.check.commands"; : > "$auto/run-15.check.pending"
FOREMAN_SELFTEST=1 "$F" __start_auto_check "$auto" run 15 "$T/proj/app"
mkdir -p "$auto/hold-release-check/queue"; printf '{"thread_id":"root","idle_seconds":5}' > "$auto/hold-release-check/hold.json"
python3 -B - "$SKILL_DIR/scripts/codex_appserver.py" "$auto" <<'PY2' &
import importlib.util,json,pathlib,sys
spec=importlib.util.spec_from_file_location("bridge",sys.argv[1]); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
root=pathlib.Path(sys.argv[2]); hold=root/"hold-release-check"; n=15
(hold/"queue"/f"run-{n}.request.json").write_text(json.dumps({"out_rc":str(root/f"run-{n}.rc"),"out_jsonl":str(root/f"run-{n}.jsonl"),"out_stderr":str(root/f"run-{n}.stderr"),"timeout":5}))
class Proc:
    def poll(self): return None
class Server:
    proc=Proc()
    def set_log(self,path): pass
    def next_message(self,timeout): return {}
    def dispatch(self,msg): pass
    def close(self): pass
    def log_event(self,event): pass
class Runner:
    def __init__(self,cfg): self.cfg=cfg; self.thread_id="root"; self.boot_info={}; self.server=None; self.turn_id=None; self.turn_status=None; self.interrupt_requested=False
    def boot(self): self.server=Server(); return self.server
    def turn(self): return 0
    def finish(self,rc): pass
    def handle_server_request(self,msg): pass
    def handle_notification(self,msg): pass
    def _classify_failure(self,exc): return 3
b.Runner=Runner; assert b.Holder(str(hold)).serve()==0
PY2
release_holder_pid=$!
for _ in $(seq 1 100); do [ -f "$auto/run-15.check.started" ] && break; sleep .02; done
: > "$auto/hold-release-check/release"
for _ in $(seq 1 100); do [ -f "$auto/hold-release-check/hold.rc" ] && break; sleep .02; done
release_fast=0; [ -f "$auto/hold-release-check/hold.rc" ] && [ ! -f "$auto/run-15.check.rc" ] && [ ! -f "$auto/release-check-ended" ] && release_fast=1
wait "$release_holder_pid" 2>/dev/null; release_holder_rc=$?
: > "$auto/release-check-gate"
for _ in $(seq 1 150); do [ -f "$auto/run-15.check.rc" ] && break; sleep .02; done
if [ "$release_fast" -eq 1 ] && [ "$release_holder_rc" -eq 0 ] && [ "$(cat "$auto/run-15.check.rc" 2>/dev/null)" = 0 ] && [ -f "$auto/release-check-ended" ]; then ok "release 先退出 Holder、再放行 detached check"; else bad "Holder release/check 屏障收尾"; fi

printf "while [ ! -f '%s' ]; do sleep .02; done; : > '%s'\n" "$auto/prior-check-gate" "$auto/prior-check-ended" > "$auto/run-16.check.commands"; : > "$auto/run-16.check.pending"; printf 0 > "$auto/run-16.rc"; printf restart > "$auto/run-16.thread"; printf restart > "$auto/run-17.thread"
FOREMAN_SELFTEST=1 "$F" __start_auto_check "$auto" run 16 "$T/proj/app"
for _ in $(seq 1 100); do [ -f "$auto/run-16.check.started" ] && break; sleep .02; done
[ -f "$auto/run-16.check.started" ] && [ ! -f "$auto/prior-check-ended" ] || bad "Holder 重启前 check 屏障未建立"
mkdir -p "$auto/hold-restart/queue"; printf '{"thread_id":"root","idle_seconds":5}' > "$auto/hold-restart/hold.json"
python3 -B - "$SKILL_DIR/scripts/codex_appserver.py" "$auto" <<'PY2' &
import importlib.util,json,pathlib,sys
spec=importlib.util.spec_from_file_location("bridge",sys.argv[1]); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
root=pathlib.Path(sys.argv[2]); hold=root/"hold-restart"; n=17
(hold/"queue"/f"run-{n}.request.json").write_text(json.dumps({"out_rc":str(root/f"run-{n}.rc"),"out_jsonl":str(root/f"run-{n}.jsonl"),"out_stderr":str(root/f"run-{n}.stderr"),"timeout":5}))
class Proc:
    def poll(self): return None
class Server:
    proc=Proc()
    def set_log(self,path): pass
    def next_message(self,timeout): return {}
    def dispatch(self,msg): pass
    def close(self): pass
    def log_event(self,event):
        if event.get("_fleet")=="hold_started": (root/"restart-holder-started").touch()
        if event.get("_fleet")=="hold_turn_done": (hold/"release").touch()
class Runner:
    def __init__(self,cfg): self.cfg=cfg; self.thread_id="root"; self.boot_info={}; self.server=None; self.turn_id=None; self.turn_status=None; self.interrupt_requested=False
    def boot(self): self.server=Server(); return self.server
    def turn(self): assert (root/"prior-check-ended").exists(); (root/"restart-claimed").touch(); return 0
    def finish(self,rc): pass
    def handle_server_request(self,msg): pass
    def handle_notification(self,msg): pass
    def _classify_failure(self,exc): return 3
b.Runner=Runner; assert b.Holder(str(hold)).serve()==0
PY2
restart_holder_pid=$!
for _ in $(seq 1 100); do [ -f "$auto/restart-holder-started" ] && break; sleep .02; done
restart_waited=0; [ -f "$auto/restart-holder-started" ] && [ ! -f "$auto/restart-claimed" ] && [ ! -f "$auto/prior-check-ended" ] && restart_waited=1
: > "$auto/prior-check-gate"
wait "$restart_holder_pid"; restart_holder_rc=$?
if [ "$restart_waited" -eq 1 ] && [ "$restart_holder_rc" -eq 0 ] && [ -f "$auto/restart-claimed" ] && [ -f "$auto/prior-check-ended" ]; then ok "Holder 重启在屏障前等待上一轮 check"; else bad "Holder 重启越过 check 屏障"; fi

printf 'false\n' > "$auto/run-11.check.commands"; : > "$auto/run-11.check.pending"; printf 0 > "$auto/run-11.rc"; "$F" __auto_check "$auto" run 11 "$T/proj/app"
printf 'true\n' > "$auto/run-11.check.commands"; : > "$auto/run-11.check.pending"; rm -f "$auto/run-11.check.rc" "$auto/run-11.check.status"; "$F" __auto_check "$auto" run 11 "$T/proj/app"
[ ! -f "$auto/run-11.check.failed-command" ] && ok "成功重跑清理旧 failed-command" || bad "failed-command 残留"

printf 'here' > "$steer_dir/run-94.pr"; printf 'implement' > "$steer_dir/run-94.thread"; printf 0 > "$steer_dir/run-94.rc"; : > "$steer_dir/run-94.check.pending"; printf '%s' "$$" > "$steer_dir/run-94.check.pid"
before94="$(find "$steer_dir" -maxdepth 1 -name 'run-*' | sort)"; run94_out="$("$F" run 1 --thread implement --prompt "$T/brief.md" --title blocked-by-check 2>&1)"; run94_rc=$?; after94="$(find "$steer_dir" -maxdepth 1 -name 'run-*' | sort)"
if [ "$run94_rc" -ne 0 ] && printf '%s' "$run94_out" | grep -q CHECKING && [ "$before94" = "$after94" ]; then ok "同线程 CHECKING 守卫拒绝且不落新轮"; else bad "CHECKING 守卫或残留" "$run94_out"; fi
rm -f "$steer_dir"/run-94.*

printf '%s\n' '{"_fleet":"thread","threadId":"root"}' '{"method":"turn/completed","params":{"threadId":"root","turn":{"id":"turn","status":"completed"}}}' '{"_fleet":"turn_summary","threadId":"root","turnId":"turn","status":"completed"}' > "$steer_dir/run-93.jsonl"
: > "$steer_dir/run-93.stderr"; printf '## STATUS\nDONE\n' > "$steer_dir/run-93.last.md"; printf 0 > "$steer_dir/run-93.rc"; printf 1 > "$steer_dir/run-93.check.rc"; printf false > "$steer_dir/run-93.check.failed-command"; printf 'failed output\n' > "$steer_dir/run-93.check.log"; printf implement > "$steer_dir/run-93.role"
report_check_out="$("$F" report 1 93 2>&1)"
if printf '%s\n' "$report_check_out" | grep -q '需要人工/编排者判断' && printf '%s\n' "$report_check_out" | grep -q '失败命令: false'; then ok "report 完整 check FAIL 横幅"; else bad "report check FAIL 横幅" "$report_check_out"; fi
rm -f "$steer_dir"/run-93.*

printf '%s\n' '{"_fleet":"thread","threadId":"root"}' '{"_fleet":"turn_summary","threadId":"root","turnId":"turn","status":"completed"}' > "$steer_dir/run-95.jsonl"
: > "$steer_dir/run-95.check.pending"; printf 0 > "$steer_dir/run-95.rc"; printf 'FAILED: fixture' > "$steer_dir/run-95.check.status"
list_failed="$($F list 2>&1)"; rm -f "$steer_dir/run-95.check.status"; printf '%s' "$$" > "$steer_dir/run-95.check.pid"
list_checking="$($F list 2>&1)"; printf 999999 > "$steer_dir/run-95.check.pid"; list_gone="$($F list 2>&1)"
printf 0 > "$steer_dir/run-95.check.rc"; list_pass="$($F list 2>&1)"
rm -f "$steer_dir/run-95.check.rc" "$steer_dir/run-95.check.pending"; printf 'SKIPPED: fixture' > "$steer_dir/run-95.check.status"; list_skipped="$($F list 2>&1)"
printf 'UNCONFIGURED: fixture' > "$steer_dir/run-95.check.status"; list_unconfigured="$($F list 2>&1)"
list_failed_value="$(printf '%s\n' "$list_failed" | grep '^1[[:space:]]' | head -1)"; list_checking_value="$(printf '%s\n' "$list_checking" | grep '^1[[:space:]]' | head -1)"; list_gone_value="$(printf '%s\n' "$list_gone" | grep '^1[[:space:]]' | head -1)"
list_pass_value="$(printf '%s\n' "$list_pass" | grep '^1[[:space:]]' | head -1)"; list_skipped_value="$(printf '%s\n' "$list_skipped" | grep '^1[[:space:]]' | head -1)"; list_unconfigured_value="$(printf '%s\n' "$list_unconfigured" | grep '^1[[:space:]]' | head -1)"
if printf '%s' "$list_failed_value" | grep -q '  FAIL  ' && printf '%s' "$list_checking_value" | grep -q '  中  ' && printf '%s' "$list_gone_value" | grep -q 'FAIL（worker 消失）'; then ok "list 复用统一 check 判定"; else bad "list check 六态口径" "$list_failed_value / $list_checking_value / $list_gone_value"; fi
if printf '%s' "$list_pass_value" | grep -q '  PASS  ' && printf '%s' "$list_skipped_value" | grep -q '  跳过  ' && printf '%s' "$list_unconfigured_value" | grep -q '  未配置  '; then ok "list 补齐 PASS/跳过/未配置"; else bad "list check 终态口径" "$list_pass_value / $list_skipped_value / $list_unconfigured_value"; fi
rm -f "$steer_dir"/run-95.*

manual_before="$(find "$steer_dir" -name 'check-*.log' | wc -l | tr -d ' ')"; FOREMAN_SELFTEST=1 FOREMAN_CHECK_LOG_STAMP=fixed "$F" check 1 true >/dev/null; FOREMAN_SELFTEST=1 FOREMAN_CHECK_LOG_STAMP=fixed "$F" check 1 true >/dev/null
manual_after="$(find "$steer_dir" -name 'check-*.log' | wc -l | tr -d ' ')"
[ "$manual_after" -eq $((manual_before+2)) ] && ok "手动 check 同秒日志名唯一" || bad "手动 check 日志覆盖"

echo "== claude 引擎 =="
claude_replay_out="$(python3 -B "$SKILL_DIR/tests/claude_replay.py" --selftest 2>&1)"; claude_replay_rc=$?
for claude_case in snapshot_date_normalization success mcp_private_cleanup first_line_paths deny eof no_session bad_json bad_json_raw_drain unknown question_timeout signal signal_ignore_hard_deadline mcp_missing invalid_decision invalid_decision_deny forbidden closeout non_closeout_graphql deny_rules_shared_source success_stderr_warning resume_mismatch_no_ledger_write full_access_strict_boolean review_tools_only full_access; do
  if [ "$claude_replay_rc" -eq 0 ] && printf '%s\n' "$claude_replay_out" | grep -q "claude replay: ${claude_case} PASS"; then
    ok "Claude 回放：${claude_case}"
  else
    bad "Claude 回放：${claude_case}" "$(printf '%s\n' "$claude_replay_out" | tail -3 | tr '\n' ' ')"
  fi
done

echo "== claude 摘要器 =="
python3 -B "$SKILL_DIR/tests/claude_events_replay.py" --selftest && ok "claude 事件夹具与旧引擎黄金输出" || bad "claude 事件夹具与旧引擎黄金输出"

expect_rc "Claude --model haiku 可单次覆盖" 0 env FOREMAN_SELFTEST=1 CLAUDE_BIN="$SKILL_DIR/tests/claude_replay.py" CLAUDE_REPLAY_SCENARIO=success "$F" run 1 --thread claude-haiku --engine claude --model haiku --effort low --prompt "$T/brief.md" --title haiku --timeout 30 --no-check
claude_req="$(find "$steer_dir" -maxdepth 1 -name 'run-*.request.json' -print | sort -V | tail -1)"
python3 - "$claude_req" <<'PY2' && ok "Claude 首轮写 session 且 argv 使用真实模板" || bad "Claude 首轮 argv / session"
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); stem=str(p)[:-len('.request.json')]
m=json.load(open(p.parent/'meta.json')); assert m['threads']['claude-haiku']['ref']=='session-replay-001'
a=pathlib.Path(stem+'.argv').read_bytes().split(b'\0'); assert b'claude_replay.py' in a[0] and b'--permission-mode' in a and b'auto' in a
PY2
expect_rc "Claude resume 轮次成功" 0 env FOREMAN_SELFTEST=1 CLAUDE_BIN="$SKILL_DIR/tests/claude_replay.py" CLAUDE_REPLAY_SCENARIO=success "$F" run 1 --thread claude-haiku --prompt "$T/brief.md" --title resume --timeout 30 --no-check
claude_resume_req="$(find "$steer_dir" -maxdepth 1 -name 'run-*.request.json' -print | sort -V | tail -1)"
python3 - "$claude_resume_req" <<'PY2' && ok "Claude resume argv 带同一 session" || bad "Claude resume argv"
import pathlib,sys
p=pathlib.Path(sys.argv[1]); a=pathlib.Path(str(p)[:-len('.request.json')]+'.argv').read_bytes().split(b'\0')
i=a.index(b'--resume'); assert a[i+1]==b'session-replay-001'
PY2

env FOREMAN_SELFTEST=1 CLAUDE_BIN="$SKILL_DIR/tests/claude_replay.py" CLAUDE_REPLAY_SCENARIO=question_answered "$F" run 1 --thread claude-question --engine claude --prompt "$T/brief.md" --title question --question-timeout 10 --detach --no-check >/dev/null
question_req="$(find "$steer_dir" -maxdepth 1 -name 'run-*.request.json' -print | sort -V | tail -1)"
question_stem="${question_req%.request.json}"
for _ in $(seq 1 100); do [ -f "$question_stem.questions.json" ] && break; sleep 0.05; done
questions_out="$("$F" questions 1 2>&1)"
question_qid="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["questions"][0]["id"])' "$question_stem.questions.json" 2>/dev/null)"
if [ -n "$question_qid" ] && printf '%s\n' "$questions_out" | grep -q "$question_qid"; then ok "Claude 提问可由 foreman questions 列出 qid"; else bad "Claude questions 未列出问题或 qid" "$questions_out"; fi
expect_rc "Claude 提问经 foreman answer 写回答" 0 "$F" answer 1 --qid "$question_qid" "蓝色"
for _ in $(seq 1 100); do [ -f "$question_stem.rc" ] && break; sleep 0.05; done
python3 - "$question_stem" <<'PY2' && ok "Claude 提问回答消费、MCP 回包与事件顺序" || bad "Claude 提问回答回路"
import json,pathlib,sys
s=pathlib.Path(sys.argv[1]); events=[json.loads(x) for x in pathlib.Path(str(s)+'.jsonl').read_text().splitlines() if x]
states=[e['_foreman']['state'] for e in events if e.get('_foreman',{}).get('type')=='question']
answer=next(e for e in events if e.get('type')=='foreman_replay_answer')['answers']['选择颜色？']
meta=json.load(open(str(s)+'.claude.json'))
assert states==['asked','answered'] and answer=='蓝色'
assert pathlib.Path(str(s)+'.questions.answered.json').is_file() and not pathlib.Path(str(s)+'.questions.json').exists()
assert not pathlib.Path(str(s)+'.mcp.json').exists() and isinstance(meta['mcp_servers'],list) and 'mcp_config' not in meta
assert pathlib.Path(str(s)+'.rc').read_text().strip()=='0'
PY2

cat >> "$FOREMAN_HOME/config.toml" <<'EOF'

[roles.noclaude]
engine = "codex"
model = "gpt-5.6-terra"
effort = "low"
EOF
cp "$FOREMAN_HOME/roles/mechanical.md" "$FOREMAN_HOME/roles/noclaude.md"
expect_grep "角色缺 claude 档位拒绝" "没有 claude 档位" env FOREMAN_SELFTEST=1 CLAUDE_BIN="$SKILL_DIR/tests/claude_replay.py" "$F" run 1 --thread no-claude-tier --role noclaude --engine claude --prompt "$T/brief.md" --title missing
python3 - "$FOREMAN_HOME/config.toml" <<'PY2'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text(); s=re.sub(r'(\[engines\.claude\][^\[]*?concurrency\s*=\s*)3',r'\g<1>0',s,count=1); p.write_text(s)
PY2
expect_grep "Claude 独立池满拒绝" "claude 线程在跑" env FOREMAN_SELFTEST=1 CLAUDE_BIN="$SKILL_DIR/tests/claude_replay.py" "$F" run 1 --thread claude-pool-full --engine claude --prompt "$T/brief.md" --title pool --detach --no-check
python3 - "$FOREMAN_HOME/config.toml" <<'PY2'
import pathlib,re,sys
p=pathlib.Path(sys.argv[1]); s=p.read_text(); s=re.sub(r'(\[engines\.claude\][^\[]*?concurrency\s*=\s*)0',r'\g<1>3',s,count=1); p.write_text(s)
PY2

expect_rc "Claude 复审使用只读工具集" 0 env FOREMAN_SELFTEST=1 CLAUDE_BIN="$SKILL_DIR/tests/claude_replay.py" CLAUDE_REPLAY_SCENARIO=success "$F" review 1 --engine claude --model sonnet --effort low --timeout 30
claude_review_req="$(find "$steer_dir" -maxdepth 1 -name 'review-*.request.json' -print | sort -V | tail -1)"
python3 - "$claude_review_req" <<'PY2' && ok "Claude 复审 argv / MCP / 标记契约" || bad "Claude 复审契约"
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]); stem=str(p)[:-len('.request.json')]; req=json.load(open(p))
argv=pathlib.Path(stem+'.argv').read_bytes().split(b'\0'); settings=json.load(open(stem+'.settings.json')); meta=json.load(open(stem+'.claude.json'))
events=[json.loads(line) for line in pathlib.Path(stem+'.jsonl').read_text().splitlines() if line]
assert req['review_readonly']=='tools_only' and req['inherit_user_mcp'] is False and req['question_timeout']==0
assert b'--no-session-persistence' in argv and b'--tools' in argv and b'Read,Glob,Grep' in argv
assert meta['mcp_servers']==['foreman'] and all(x in settings['permissions']['deny'] for x in ('Bash(*)','Write(*)','Edit(*)','MultiEdit(*)'))
assert events[0]['_foreman']['review_readonly']=='tools_only'
PY2
expect_grep "Claude 复审拒绝 --full-access" "未知参数" "$F" review 1 --engine claude --full-access x
expect_grep "Claude steer 只排下一轮" "claude 引擎：steer 已排队，下一轮 run 生效（当前轮不中断）" "$F" steer 1 --thread claude-haiku "只使用追加说明"
expect_grep "status 标出 Claude 待生效 steer" "claude.*NEXT" "$F" status 1
expect_rc "Claude 下一轮消费 steer" 0 env FOREMAN_SELFTEST=1 CLAUDE_BIN="$SKILL_DIR/tests/claude_replay.py" CLAUDE_REPLAY_SCENARIO=success "$F" run 1 --thread claude-haiku --prompt "$T/brief.md" --title steer-next --timeout 30 --no-check
claude_steer_req="$(find "$steer_dir" -maxdepth 1 -name 'run-*.request.json' -print | sort -V | tail -1)"
if grep -q '^## 编排者追加说明$' "${claude_steer_req%.request.json}.prompt.md" && grep -q '只使用追加说明' "${claude_steer_req%.request.json}.prompt.md"; then ok "Claude steer 在下轮 prompt 顶部生效"; else bad "Claude steer 未进入下轮 prompt"; fi
expect_grep "doctor 包含 claude 零 token 节" "--- claude ---" "$F" doctor "$T/proj/app"

# 快照夹具在基线生成，保存完整归一化 JSON；失败直接打印逐字段 unified diff。
snapshot_mode=(--compare "$SKILL_DIR/tests/fixtures/codex-snapshot/dispatch.json")
[ "${FOREMAN_UPDATE_CODEX_SNAPSHOT:-}" = 1 ] && snapshot_mode=(--write "$SKILL_DIR/tests/fixtures/codex-snapshot/dispatch.json")
snapshot_out="$(python3 -B "$SKILL_DIR/tests/claude_replay.py" --codex-snapshot --d1 "$steer_dir" --d2 "$d2" --tmp-root "$T" --skill-dir "$SKILL_DIR" "${snapshot_mode[@]}" 2>&1)"; snapshot_rc=$?
if [ "$snapshot_rc" -eq 0 ]; then ok "Codex 分发完整快照：run / resume / writable / full-access / mechanical / review / hold argv 不变"
else bad "Codex 分发快照漂移（下方为逐字段 diff）"; printf '%s\n' "$snapshot_out"; fi
snapshot_mutation_out="$(python3 -B "$SKILL_DIR/tests/claude_replay.py" --codex-snapshot --d1 "$steer_dir" --d2 "$d2" --tmp-root "$T" --skill-dir "$SKILL_DIR" --compare "$SKILL_DIR/tests/fixtures/codex-snapshot/dispatch.json" --mutate-codex-argv 2>&1)"; snapshot_mutation_rc=$?
if [ "$snapshot_mutation_rc" -eq 1 ] && printf '%s\n' "$snapshot_mutation_out" | grep -q -- '--deliberate-snapshot-mutation'; then ok "Codex 分发快照能检出 argv 参数漂移"
else bad "Codex 分发快照未检出故意参数漂移" "$snapshot_mutation_out"; fi
echo
echo "通过 $pass 项，失败 ${#fails[@]} 项${fails[@]:+：}"; for f in "${fails[@]:-}"; do [ -n "$f" ] && echo "  - $f"; done
[ "$KEEP" -eq 1 ] && echo "保留临时目录: $T" || rm -rf "$T"
[ "${#fails[@]}" -eq 0 ]
