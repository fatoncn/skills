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
  bad "check 命令通过且 RETURN 后无 unbound —— rc=$check_ok_rc，输出: $(printf '%s\n' "$check_ok_out" | tail -1)"
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
echo dirty > "$T/proj/app/here-dirty.tmp"
expect_grep "脏检出 here cleanup 只删登记" "已删登记" "$F" cleanup 31 --force
[ -f "$T/proj/app/here-dirty.tmp" ] && ok "here cleanup 不动脏检出文件" || bad "here cleanup 动了检出文件"
rm -f "$T/proj/app/here-dirty.tmp"
expect_grep "cleanup 占用测试 PR A" "ready: 40" "$F" bootstrap 40 --slug cleanup-active-a --pr a --no-install
expect_grep "cleanup 占用测试 PR B" "ready: 40" "$F" bootstrap 40 --slug cleanup-active-b --pr b --no-install
cleanup40_dir="$(dirname "$(find "$FOREMAN_HOME/projects/proj/issues" -path '*/40/meta.json' -print -quit)")"
sleep 300 & cleanup40_pid=$!
make_hold_fixture "$cleanup40_dir" shared-pr 301 "$cleanup40_pid" a implement
make_hold_fixture "$cleanup40_dir" shared-pr 302 "$cleanup40_pid" b implement
rm -f "$cleanup40_dir/hold-shared-pr/queue/run-301.request.json"; printf '{"run":"run-301"}' > "$cleanup40_dir/hold-shared-pr/active.json"
expect_grep "cleanup 拒绝删除正在活动的 PR A" "先 foreman release" "$F" cleanup 40 --pr a --force
cleanup40_a="$T/proj/app/.claude/worktrees/foreman-40-a"; [ -d "$cleanup40_a" ] && kill -0 "$cleanup40_pid" 2>/dev/null && ok "cleanup 拒绝后 PR A 工作树与执行体仍在" || bad "cleanup 误删活动 PR A"
expect_grep "cleanup PR B 只取消排队轮次" "已丢弃 run #302" "$F" cleanup 40 --pr b --force
if [ -f "$cleanup40_dir/run-302.cancelled" ] && kill -0 "$cleanup40_pid" 2>/dev/null && [ -d "$cleanup40_a" ]; then ok "cleanup PR B 不杀 PR A 执行体"; else bad "cleanup PR B 影响 PR A 执行体"; fi
kill "$cleanup40_pid" 2>/dev/null; wait "$cleanup40_pid" 2>/dev/null || true
rm -rf "$cleanup40_dir/hold-shared-pr"; rm -f "$cleanup40_dir"/run-301.* "$cleanup40_dir"/run-302.*
expect_grep "cleanup 占用测试清理 PR A" "已清理" "$F" cleanup 40 --pr a --force
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
  queued_elapsed="$($F status 2 | awk -v n="run#$nn" '$2==n {print $6}')"
  rm -f "$d2/hold-implement/queue/run-$nn.request.json"; printf '{"run":"run-%s"}' "$nn" > "$d2/hold-implement/active.json"
  running_elapsed="$($F status 2 | awk -v n="run#$nn" '$2==n {print $6}')"
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
"$F" release 1 --thread cancel-first > "$T/cancel-first.out" 2>&1
python3 - "$SKILL_DIR/scripts/codex_appserver.py" "$cancel_dir" <<'PY2' && ok "取消先到：领取返回 None 且不写 active" || bad "取消先到锁协议"
import importlib.util,pathlib,sys
spec=importlib.util.spec_from_file_location("bridge",sys.argv[1]); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
d=pathlib.Path(sys.argv[2]); hd=d/"hold-cancel-first"; q=hd/"queue/run-91.request.json"
h=b.Holder(str(hd)); assert h._claim(str(q)) is None
assert (d/"run-91.cancelled").is_file() and not q.exists() and not (hd/"active.json").exists()
PY2
rm -rf "$cancel_dir/hold-cancel-first"; rm -f "$cancel_dir"/run-91.*

sleep 300 & claim_first_pid=$!; make_hold_fixture "$cancel_dir" claim-first 92 "$claim_first_pid" here implement
python3 - "$SKILL_DIR/scripts/codex_appserver.py" "$cancel_dir" <<'PY2'
import importlib.util,pathlib,sys
spec=importlib.util.spec_from_file_location("bridge",sys.argv[1]); b=importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
d=pathlib.Path(sys.argv[2]); hd=d/"hold-claim-first"; q=hd/"queue/run-92.request.json"
assert b.Holder(str(hd))._claim(str(q)) is not None and not q.exists() and (hd/"active.json").is_file()
PY2
claim_rc=$?; "$F" release 1 --thread claim-first > "$T/claim-first.out" 2>&1
if [ "$claim_rc" -eq 0 ] && [ ! -f "$cancel_dir/run-92.cancelled" ]; then ok "领取先到：取消方不写 cancelled"; else bad "领取先到锁协议"; fi
rm -rf "$cancel_dir/hold-claim-first"; rm -f "$cancel_dir"/run-92.*
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
echo
echo "通过 $pass 项，失败 ${#fails[@]} 项${fails[@]:+：}"; for f in "${fails[@]:-}"; do [ -n "$f" ] && echo "  - $f"; done
[ "$KEEP" -eq 1 ] && echo "保留临时目录: $T" || rm -rf "$T"
[ "${#fails[@]}" -eq 0 ]
