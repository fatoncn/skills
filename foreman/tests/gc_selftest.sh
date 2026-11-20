# 由 selftest.sh 调用，使用独立的账本、假 gh 和本地裸仓。
gc_selftest() {
  local FOREMAN_HOME="$T/gc-home" GC_PROJECT="$T/gc project" GC_RACE_LOG
  export FOREMAN_HOME GC_PROJECT GC_RACE_LOG
  local GC_REAL_GIT GC_TEST_ORIGIN GC_LATE_ALIAS GC_REOPEN_SEEN
  GC_REAL_GIT="$(command -v git)"
  GC_LATE_ALIAS="$FOREMAN_HOME/projects/gc-nogit/issues/_nogit/late-alias/meta.json"
  GC_REOPEN_SEEN="$T/gc-reopen-seen"
  export GC_REAL_GIT GC_TEST_ORIGIN GC_LATE_ALIAS GC_REOPEN_SEEN
  local PATH="$T/gc-tools:$PATH" PYTHONPATH="$T/gc-tools${PYTHONPATH:+:$PYTHONPATH}"
  export PATH PYTHONPATH
  mkdir -p "$GC_PROJECT" "$T/gc-outside" "$T/gc-nogit" "$T/gc-tools" "$T/gc-snapshot"
  cat > "$T/gc-tools/sitecustomize.py" <<'PY'
import os
from pathlib import Path

kill = os.kill
def kill_with_eperm(pid, sig):
    if sig == 0 and pid in (88888801, 88888802, 88888804):
        raise PermissionError(1, "fixture EPERM")
    if sig == 0 and pid == 88888803:
        raise ProcessLookupError(3, "fixture ESRCH")
    return kill(pid, sig)
os.kill = kill_with_eperm

read_text = Path.read_text
def read_with_unreadable_pids(path, *args, **kwargs):
    if path.parts[-3:] == ("unreadable-hold", "hold-blocked", "bridge.pid"):
        raise PermissionError(13, "fixture EACCES")
    if path.parts[-2:] == ("unreadable-round", "run-1.pid"):
        raise OSError(5, "fixture EIO")
    return read_text(path, *args, **kwargs)
Path.read_text = read_with_unreadable_pids
PY
  cat > "$T/gc-tools/git" <<'SH'
#!/usr/bin/env bash
set -eu
with_base_checkout() {
  local wt="$2" original status=0
  original="$("$GC_REAL_GIT" -C "$wt" symbolic-ref --short HEAD)"
  "$GC_REAL_GIT" -C "$wt" switch -q --detach refs/remotes/origin/main
  "$GC_REAL_GIT" "$@" || status=$?
  "$GC_REAL_GIT" -C "$wt" switch -q "$original"
  touch "$GC_SNAPSHOT/${wt##*/}.checked"
  exit "$status"
}
if [ "${1:-}" = -C ]; then
  case "${3:-}" in
    merge-base)
      if [ "${2##*/}" = foreman-narrow ] && [ -n "${GC_SNAPSHOT:-}" ] &&
        [ -f "$GC_SNAPSHOT/foreman-narrow.fetched" ]; then
        with_base_checkout "$@"
      fi ;;
    remote)
      if [ "${4:-}" = get-url ] && [ "${5:-}" = origin ] && [ -n "${GC_TEST_ORIGIN:-}" ]; then
        printf '%s\n' "$GC_TEST_ORIGIN"; exit 0
      fi ;;
    rev-list)
      if [ "$2" = "${GC_REV_LIST_FAILURE_WT:-}" ]; then
        echo 'fixture rev-list failure' >&2; exit 128
      fi
      if [ "${2##*/}" = foreman-push-snapshot ] && [ -n "${GC_SNAPSHOT:-}" ] &&
        [ -f "$GC_SNAPSHOT/foreman-push-snapshot.fetched" ]; then
        with_base_checkout "$@"
      fi ;;
    fetch)
      if [ -n "${GC_SNAPSHOT:-}" ]; then
        case "${2##*/}" in
          foreman-narrow|foreman-push-snapshot)
            "$GC_REAL_GIT" "$@"
            if [ "${2##*/}" = foreman-push-snapshot ]; then
              "$GC_REAL_GIT" -C "$2" fetch --quiet origin '+refs/heads/main:refs/remotes/origin/feat/gc-push-snapshot'
            fi
            touch "$GC_SNAPSHOT/${2##*/}.fetched"
            exit 0 ;;
        esac
      fi
      if [ "${2##*/}" = foreman-late-ledger ] && [ -n "${GC_LATE_CORRUPT:-}" ]; then
        "$GC_REAL_GIT" "$@"
        printf '{' > "$GC_LATE_CORRUPT"
        exit 0
      fi
      if [ "${GC_INJECT:-}" = 1 ]; then
        case "${2##*/}" in
          foreman-late-hold)
            "$GC_REAL_GIT" "$@"
            mkdir -p "$(dirname "$GC_LATE_HOLD")"
            printf '88888804\n' > "$GC_LATE_HOLD"
            exit 0 ;;
          foreman-late-check)
            "$GC_REAL_GIT" "$@"
            printf 'check started\n' > "$GC_CHECK_LOG_DIR/check-late-fixture.log"
            exit 0 ;;
          foreman-late-shared)
            "$GC_REAL_GIT" "$@"
            mkdir -p "$(dirname "$GC_LATE_ALIAS")"
            printf '{"prs":{"here":{"registered_here":true,"worktree":"%s"}}}\n' "$2" > "$GC_LATE_ALIAS"
            exit 0 ;;
          foreman-head-change)
            "$GC_REAL_GIT" "$@"
            "$GC_REAL_GIT" -C "$2" switch -q --detach
            exit 0 ;;
        esac
      fi ;;
  esac
  if [ "${5:-}" = worktree ] && [ "${6:-}" = remove ]; then
    target="${7:-}"
    case "${target##*/}" in
      foreman-late-dirty)
        if [ "${GC_INJECT:-}" = 1 ]; then touch "$target/untracked-at-remove"; fi ;;
      foreman-partial)
        if [ -n "${GC_BREAK_DELETE:-}" ]; then
          "$GC_REAL_GIT" "$@"
          mv "$GC_BREAK_DELETE" "$GC_BREAK_DELETE.saved"
          mkdir "$GC_BREAK_DELETE"
          exit 0
        fi ;;
    esac
  fi
fi
exec "$GC_REAL_GIT" "$@"
SH
  chmod +x "$T/gc-tools/git"
  git init -q --bare --initial-branch=main "$T/gc-origin.git" &&
    git init -q --initial-branch=main "$GC_PROJECT" &&
    git -C "$GC_PROJECT" -c user.name=test -c user.email=test@example.com commit -qm seed --allow-empty &&
    git -C "$GC_PROJECT" remote add origin "$T/gc-origin.git" &&
    git -C "$GC_PROJECT" push -qu origin main || { bad "gc 裸仓夹具初始化"; return; }
  cd "$GC_PROJECT" || { bad "gc 工作目录夹具初始化"; return; }
  "$F" init >/dev/null || { bad "gc 项目夹具初始化"; return; }
  cat > "$T/gc-gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = pr ]
[ "${@: -2:1}" = --repo ] && [ "${@: -1}" = "$GC_EXPECT_REPO" ] || exit 1
[ "$GH_HOST" = "${GC_EXPECT_HOST:-github.com}" ] || exit 1
case "$2" in
  view) [ "$3" = 41 ]; state=MERGED; number=41; base=retargeted ;;
  list)
    [ "$3" = --state ] && [ "$4" = all ] && [ "$5" = --head ] &&
      [ "$7" = --base ] && [ "$8" = main ] && [ "$9" = --limit ] && [ "${10}" = 2 ] || exit 1
    number=42; base=main
    case "$6" in
      feat/gc-gh-fail) exit 1 ;;
      feat/gc-race) state=MERGED; if [ "${GC_RACE:-}" = 1 ]; then touch "$GC_RACE_LOG"; fi ;;
      feat/gc-closed|feat/gc-ambiguous|feat/gc-push-snapshot) state=CLOSED ;;
      feat/gc-reopened)
        state=CLOSED
        if [ "${GC_INJECT:-}" = 1 ]; then
          if [ -f "$GC_REOPEN_SEEN" ]; then state=OPEN; else touch "$GC_REOPEN_SEEN"; fi
        fi ;;
      *) echo '[]'; exit 0 ;;
    esac
    if [ "${GC_LIST_BASE_MISMATCH:-}" = 1 ]; then base=wrong; fi ;;
  *) exit 1 ;;
esac
printf -v result '{"number":%s,"state":"%s","baseRefName":"%s","headRefName":"%s","headRefOid":"%s","isCrossRepository":false}' \
  "$number" "$state" "$base" "$(git branch --show-current)" "$(git rev-parse HEAD)"
if [ "$2" = view ]; then printf '%s\n' "$result"
elif [ "$6" = feat/gc-ambiguous ]; then printf '[%s,%s]\n' "$result" "$result"
else printf '[%s]\n' "$result"; fi
SH
  chmod +x "$T/gc-gh"
  # 仓库覆盖应优先于项目级 github.gh。
  printf '\n[repos."%s--gc-origin"]\ngithub.gh = "%s"\n' "${T##*/}" "$T/gc-gh" >> "$FOREMAN_HOME/projects/gc project/foreman.toml"
  local id ledger wt repo="${T##*/}/gc-origin"
  local GC_EXPECT_REPO="$repo"
  export GC_EXPECT_REPO
  ledger="$FOREMAN_HOME/projects/gc project/issues/${T##*/}--gc-origin"
  for id in merged active unpushed recent research gh-fail missing race closed dirty protected \
    shared late-shared head-change late-dirty ambiguous reopened recreated manual partial narrow late-ledger zz-following \
    late-check push-snapshot check-lock held gone late-hold unreadable-hold unreadable-round; do
    "$F" bootstrap "$id" --pr work --branch "feat/gc-$id" --no-install >/dev/null 2>&1 ||
      { bad "gc bootstrap $id"; return; }
    wt="$GC_PROJECT/.claude/worktrees/foreman-$id"
    case "$id" in
      merged|unpushed|gh-fail|race|closed|ambiguous|reopened|push-snapshot)
        git -C "$wt" -c user.name=test -c user.email=test@example.com commit --allow-empty -qm "$id" ||
          { bad "gc commit $id"; return; }
        ;;
    esac
    case "$id" in
      merged|gh-fail|race|ambiguous|reopened|push-snapshot) git -C "$wt" push -qu origin HEAD || { bad "gc push $id"; return; } ;;
      closed) git -C "$wt" push -q origin HEAD || { bad "gc push $id"; return; } ;;
      missing) git -C "$GC_PROJECT" worktree remove "$wt" || { bad "gc missing 夹具"; return; } ;;
      dirty) printf dirty > "$wt/untracked" ;;
    esac
  done
  "$F" bootstrap manual --pr second --branch feat/gc-manual-second --no-install >/dev/null 2>&1 &&
    "$F" bootstrap held --pr previous --branch feat/gc-held-previous --no-install >/dev/null 2>&1 &&
    git -C "$GC_PROJECT" config status.showUntrackedFiles no ||
    { bad "gc 手动 check 或 dirty 配置夹具"; return; }
  "$F" here current >/dev/null && (cd "$T/gc-nogit" && "$F" init >/dev/null && "$F" here notes >/dev/null) ||
    { bad "gc here 夹具"; return; }
  python3 - "$ledger" "$$" <<'PY'
import json, os, sys
from datetime import datetime, timezone
from pathlib import Path

ledger, pid = Path(sys.argv[1]), sys.argv[2]
old = 1577836800
old_iso = datetime.fromtimestamp(old, timezone.utc).isoformat()
for d in ledger.iterdir():
    p = d / "meta.json"
    meta = json.loads(p.read_text())
    for pr in meta["prs"].values():
        pr["created"] = old_iso
        marker = Path(pr["worktree"]) / ".git"
        if marker.is_file() and d.name not in ("partial", "narrow", "late-ledger", "zz-following", "check-lock"):
            os.utime(marker, (old, old))
    if d.name == "merged":
        meta["prs"]["work"]["gh_pr"] = 41
        meta["threads"] = {"implement": {"engine": "claude", "role": "implement", "runs": ["run-1"]}}
    p.write_text(json.dumps(meta))
    fixtures = {
        "merged": {"run-1.jsonl": "fixture log", "run-1.rc": "0"},
        "active": {"run-1.rc": "0", "run-1.check.pending": "", "run-1.check.pid": pid,
                   "run-2.rc": "0"},
        "recent": {"run-1.jsonl": "recent activity"},
        "race": {"run-1.jsonl": "idle before gh lookup"},
        "protected": {"run-1.argv": "", "run-1.pid": "88888801", "run-1.thread": "run-locked",
                      "run-2.rc": "0", "run-2.check.pending": "", "run-2.check.pid": "88888802",
                      "run-2.thread": "check-locked"},
        "manual": {"check-2000-fixture.log": "recent manual check"},
        "held": {"run-1.thread": "blocked", "run-1.pr": "previous", "run-1.rc": "0",
                 "run-2.thread": "blocked"},
        "unreadable-round": {"run-1.argv": "", "run-1.pid": "88888803"},
        "gone": {"run-1.argv": "", "run-1.pid": "88888803", "run-1.thread": "exited"},
        "late-hold": {"run-1.thread": "blocked", "run-1.rc": "0"},
    }
    for name, value in fixtures.get(d.name, {}).items():
        f = d / name
        f.write_text(value)
        if d.name not in ("recent", "manual"):
            os.utime(f, (old, old))
PY
  wt="$GC_PROJECT/.claude/worktrees/foreman-recreated"
  git -C "$GC_PROJECT" worktree remove "$wt" &&
    "$F" bootstrap recreated --pr work --branch feat/gc-recreated --no-install >/dev/null 2>&1 ||
    { bad "gc 重建旧登记夹具"; return; }
  python3 - "$FOREMAN_HOME/projects/gc-nogit/issues/_nogit/alias/meta.json" "$GC_PROJECT/.claude/worktrees/foreman-shared" <<'PY'
import json, os, sys
from pathlib import Path
target, original = map(Path, sys.argv[1:])
alias = original.with_name(original.name.upper())
# 大小写敏感的文件系统上用同名差异的符号链接构造相同 inode。
if not alias.is_dir():
    alias.symlink_to(original, target_is_directory=True)
assert os.path.samefile(original, alias) and original != alias
target.parent.mkdir(parents=True)
target.write_text(json.dumps({"prs":{"here":{"registered_here":True, "worktree":str(alias)}}}))
PY
  mkdir -p "$ledger/held/hold-blocked" "$ledger/gone/hold-exited" "$ledger/gone/hold-invalid" \
    "$ledger/unreadable-hold/hold-blocked"
  printf '88888804' > "$ledger/held/hold-blocked/bridge.pid"
  printf '88888803' > "$ledger/gone/hold-exited/bridge.pid"
  printf 'not-a-pid' > "$ledger/gone/hold-invalid/bridge.pid"
  printf '88888803' > "$ledger/unreadable-hold/hold-blocked/bridge.pid"
  chmod 000 "$ledger/unreadable-hold/hold-blocked/bridge.pid" "$ledger/unreadable-round/run-1.pid"
  export GC_RACE_LOG="$ledger/race/run-1.jsonl"
  cd "$T/gc-outside" || { bad "gc 外部目录夹具"; return; }
  local json_rc text_rc preview_rc force_rc
  "$F" list --json --all-projects > "$T/gc-index.json"; json_rc=$?
  "$F" list --all-projects > "$T/gc-text"; text_rc=$?
  if [ "$json_rc" -eq 0 ] && python3 - "$T/gc-index.json" <<'PY'
import json, sys
from datetime import datetime

with open(sys.argv[1]) as handle:
    all_rows = json.load(handle)
    rows = {x["ticket"]: x for x in all_rows}
m = rows["merged"]
assert m.keys() >= {"project", "repo", "ticket", "pr", "worktree", "exists", "branch",
                    "base", "gh_pr", "here", "active", "last_activity", "threads"}, m
assert m["project"] == "gc project" and m["repo"].endswith("--gc-origin") and m["pr"] == "work", m
assert m["exists"] is True and m["active"] is False and m["here"] is False and m["gh_pr"] == 41, m
assert m["branch"] == "feat/gc-merged" and m["base"] == "main", m
assert datetime.fromisoformat(m["last_activity"]).isoformat() == "2020-01-01T00:00:00+00:00", m
assert m["threads"] == [{"name": "implement", "engine": "claude", "role": "implement",
                         "round": "run-1", "state": "DONE"}], m
assert rows["active"]["active"] is True and rows["active"]["threads"][0]["round"] == "run-2", rows["active"]
assert rows["active"]["threads"][0]["state"] == "DONE", rows["active"]
assert rows["missing"]["exists"] is False and rows["missing"]["gh_pr"] is None, rows["missing"]
assert rows["current"]["here"] is True and rows["notes"]["repo"] == "_nogit", rows
assert rows["protected"]["active"] and {t["state"] for t in rows["protected"]["threads"]} == {"DEAD", "DONE"}, rows["protected"]
held = {row["pr"]: row["active"] for row in all_rows if row["ticket"] == "held"}
assert held == {"work": True, "previous": True}, held
assert rows["unreadable-hold"]["active"] and rows["unreadable-round"]["active"], rows
assert not rows["gone"]["active"] and rows["gone"]["threads"][0]["state"] == "DEAD", rows["gone"]
assert not any(k.startswith("_") for row in all_rows for k in row), all_rows
manual = [row["last_activity"] for row in all_rows if row["ticket"] == "manual"]
assert len(manual) == 2 and len(set(manual)) == 1 and manual[0] > m["last_activity"], manual
assert rows["recreated"]["last_activity"] > m["last_activity"], rows["recreated"]
PY
  then ok "list --json --all-projects 返回 PR 字段、最新轮和任意活跃轮"; else bad "list --json --all-projects 字段 / 状态"; fi
  if [ "$text_rc" -eq 0 ] && grep -q '=== gc project /' "$T/gc-text" && grep -q '=== gc-nogit / _nogit' "$T/gc-text"; then
    ok "list --all-projects 从非 git 目录列跨项目文本"
  else bad "list --all-projects 文本"; fi
  GC_TEST_ORIGIN="git@github.com:$repo.git"
  GH_HOST=ghe.example.invalid "$F" gc > "$T/gc-preview"; preview_rc=$?
  gc_has() { grep -Eq " ticket=$2 .* $3$" "$1"; }
  gc_check() {
    if gc_has "$1" "$2" "$3"; then ok "gc $2 $3"; else bad "gc $2 $3" "$(cat "$1")"; fi
  }
  if [ "$preview_rc" -eq 0 ] && [ -d "$GC_PROJECT/.claude/worktrees/foreman-merged" ] &&
    git -C "$GC_PROJECT" show-ref --verify --quiet refs/heads/feat/gc-merged; then
    ok "gc 预览退出 0 且保留 worktree 和分支"
  else bad "gc 预览退出 / 不修改" "rc=$preview_rc"; fi
  gc_check "$T/gc-preview" merged '预览 pr_merged'
  gc_check "$T/gc-preview" active '跳过 active'
  gc_check "$T/gc-preview" unpushed '跳过 unpushed'
  gc_check "$T/gc-preview" recent '跳过 recent_activity'
  gc_check "$T/gc-preview" research '预览 no_commits'
  gc_check "$T/gc-preview" gh-fail '跳过 gh_query_failed'
  gc_check "$T/gc-preview" current '跳过 here'
  gc_check "$T/gc-preview" notes '跳过 non_git'
  gc_check "$T/gc-preview" missing '跳过 missing_worktree'
  gc_check "$T/gc-preview" dirty '跳过 dirty'
  gc_check "$T/gc-preview" closed '预览 pr_closed'
  gc_check "$T/gc-preview" protected '跳过 pid_unverifiable'
  if [ "$(grep -c ' ticket=held .* 跳过 pid_unverifiable$' "$T/gc-preview")" -eq 2 ]; then
    ok "非默认 PR 的 hold 遇到 EPERM，新增未派发轮次后仍保护整个票"
  else bad "未派发轮次后 hold 未保护整票" "$(cat "$T/gc-preview")"; fi
  if [ "$preview_rc" -eq 0 ] &&
    gc_has "$T/gc-preview" unreadable-hold '跳过 pid_unverifiable' &&
    gc_has "$T/gc-preview" unreadable-round '跳过 pid_unverifiable' &&
    gc_has "$T/gc-preview" research '预览 no_commits'; then
    ok "单票 PID 文件不可读时跳过，其他票继续输出且预览退出 0"
  else bad "PID 文件读取失败阻断预览" "$(cat "$T/gc-preview")"; fi
  gc_check "$T/gc-preview" gone '预览 no_commits'
  gc_check "$T/gc-preview" shared '跳过 shared_worktree'
  gc_check "$T/gc-preview" ambiguous '跳过 pr_ambiguous'
  gc_check "$T/gc-preview" recreated '跳过 recent_activity'
  if [ "$(grep -c ' ticket=manual .* 跳过 recent_activity$' "$T/gc-preview")" -eq 2 ]; then
    ok "gc 手动 check 日志保护同票的两个 PR"
  else bad "gc 手动 check 日志保护"; fi
  GC_TEST_ORIGIN= "$F" gc --project 'gc project' > "$T/gc-local-origin"
  gc_check "$T/gc-local-origin" merged '跳过 unknown_host'

  local bad_origin
  for bad_origin in "file:///$repo.git" "https://ghe.example.invalid:8443/$repo.git"; do
    GC_TEST_ORIGIN="$bad_origin" "$F" gc --project 'gc project' > "$T/gc-bad-origin"
    if gc_has "$T/gc-bad-origin" merged '跳过 unknown_host'; then
      ok "gc 跳过无法映射的 origin $bad_origin"
    else bad "gc 无法映射的 origin $bad_origin"; fi
  done
  GC_LIST_BASE_MISMATCH=1 "$F" gc --project 'gc project' > "$T/gc-wrong-base"
  gc_check "$T/gc-wrong-base" closed '跳过 pr_base_mismatch'
  gc_check "$T/gc-wrong-base" merged '预览 pr_merged'

  if [ "$(FOREMAN_SELFTEST=1 "$F" __call_state "$ledger/protected/run-1")" = DEAD ] &&
    [ "$(FOREMAN_SELFTEST=1 "$F" __call_state "$ledger/protected/run-2")" = DONE ]; then
    ok "轮次和自动 check 保留上游 kill -0 语义"
  else bad "轮次或自动 check 判活扩出了 GC 与索引范围"; fi

  # 预览只读本地引用，可用同一裸仓夹具替换 origin 拼法来检验 gh 参数。
  local origin_url expected_repo expected_host
  for origin_url in "git@github.com:$repo.git" "ssh://git@github.com/$repo.git" "https://github.com/$repo.git" \
    "git@ghe.example.invalid:$repo.git" "https://ghe.example.invalid/$repo.git"; do
    expected_repo="$repo"; expected_host=github.com
    case "$origin_url" in
      git@ghe.example.invalid:*|https://ghe.example.invalid/*)
        expected_repo="ghe.example.invalid/$repo"; expected_host=ghe.example.invalid ;;
    esac
    if GH_HOST=not-the-origin.invalid GC_TEST_ORIGIN="$origin_url" GC_EXPECT_HOST="$expected_host" \
      GC_EXPECT_REPO="$expected_repo" "$F" gc --project 'gc project' > "$T/gc-repo-preview" &&
      gc_has "$T/gc-repo-preview" merged '预览 pr_merged' &&
      gc_has "$T/gc-repo-preview" closed '预览 pr_closed'; then
      ok "gc origin $origin_url 用正确的 --repo 查到 MERGED 和 CLOSED"
    else bad "gc origin $origin_url 的 --repo" "$(cat "$T/gc-repo-preview")"; fi
  done
  if (cd "$GC_PROJECT" && PYTHONPROFILEIMPORTTIME=1 "$F" list --json) \
    > "$T/gc-profile.json" 2> "$T/gc-profile.stderr" &&
    grep -q 'import time:' "$T/gc-profile.stderr" &&
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))' "$T/gc-profile.json"; then
    ok "项目根校验只用 stdout，Python 导入诊断保留在 stderr"
  else bad "项目根校验误收导入诊断"; fi

  if (cd "$GC_PROJECT" && "$F" status held) > "$T/gc-hold-status" &&
    ! grep -q 'HOLD.*blocked' "$T/gc-hold-status"; then
    ok "status 保留上游 hold 判活"
  else bad "status 的 hold 判活偏离上游" "$(cat "$T/gc-hold-status")"; fi

  local config="$T/gc-invalid-config.toml" format expected
  for format in 'repos = "invalid"' $'[repos]\nfixture = "invalid"'; do
    expected='get: repos 必须是表'
    if [[ "$format" == *fixture* ]]; then expected="get: repos.'fixture' 必须是表"; fi
    printf '%s\n' "$format" > "$config"
    if ! python3 "${F%/*}/project_config.py" get --path "$config" --repo fixture project.root --default "" \
      > "$T/gc-config-out" 2> "$T/gc-config-err" &&
      [ ! -s "$T/gc-config-out" ] && [ "$(cat "$T/gc-config-err")" = "$expected" ]; then
      ok "结构错误输出单行字段诊断 $expected"
    else bad "结构错误的诊断" "$(cat "$T/gc-config-err")"; fi
  done

  local check_cmd check_pid
  check_cmd="$(cat <<'SH'
python3 - <<'PY'
import fcntl, os
from pathlib import Path
directory = Path(os.environ["GC_CHECK_LOG_DIR"])
with (directory / ".runs.lock").open() as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    assert any(p.read_text().startswith("check started") for p in directory.glob("check-*.log"))
PY
SH
)"
  if (cd "$GC_PROJECT" && GC_CHECK_LOG_DIR="$ledger/manual" "$F" check manual --pr work "$check_cmd") \
    > "$T/gc-check-start" 2>&1 && grep -q 'RESULT: ALL PASS' "$T/gc-check-start"; then
    ok "手动 check 发布开始日志并释放票锁后执行"
  else bad "手动 check 启动顺序" "$(cat "$T/gc-check-start")"; fi

  (cd "$GC_PROJECT" && FOREMAN_SELFTEST_LOCK_READY="$T/gc-check-locked" \
    FOREMAN_SELFTEST_LOCK_RELEASE="$T/gc-check-unlock" "$F" check check-lock --pr work false) \
    > "$T/gc-check-lost-pr" 2>&1 &
  check_pid=$!
  local i
  for i in $(seq 1 200); do [ -f "$T/gc-check-locked" ] && break; sleep 0.05; done
  if [ -f "$T/gc-check-locked" ]; then
    printf '{"issue":"check-lock","prs":{}}\n' > "$ledger/check-lock/meta.json"
  fi
  touch "$T/gc-check-unlock"
  wait "$check_pid"; force_rc=$?
  if [ "$force_rc" -ne 0 ] && [ -f "$T/gc-check-locked" ] &&
    grep -q '没有名为 work 的 PR' "$T/gc-check-lost-pr" &&
    ! grep -q '=== false ===' "$T/gc-check-lost-pr"; then
    ok "手动 check 在票锁内重新确认 PR 登记"
  else bad "手动 check 未复核登记" "rc=$force_rc $(cat "$T/gc-check-lost-pr")"; fi

  local broken="$FOREMAN_HOME/projects/gc-nogit/issues/_nogit/corrupted/meta.json"
  mkdir -p "$(dirname "$broken")"; printf '{' > "$broken"
  "$F" gc > "$T/gc-broken-preview"; preview_rc=$?
  "$F" gc --project 'gc project' --force > "$T/gc-broken-force"; force_rc=$?
  if [ "$preview_rc" -ne 0 ] && [ "$force_rc" -ne 0 ] &&
    gc_has "$T/gc-broken-preview" merged '预览 pr_merged' &&
    gc_has "$T/gc-broken-force" corrupted '跳过 ledger_error' &&
    gc_has "$T/gc-broken-force" merged '跳过 ledger_incomplete' &&
    ! grep -q ' 已回收 ' "$T/gc-broken-force" &&
    [ -d "$GC_PROJECT/.claude/worktrees/foreman-merged" ]; then
    ok "其他项目账本损坏时全局禁止回收，预览仍列候选"
  else bad "账本损坏全局守卫" "$(cat "$T/gc-broken-force")"; fi
  rm -f "$broken"

  wt="$GC_PROJECT/.claude/worktrees/foreman-merged"
  (cd "$GC_PROJECT" && GC_REV_LIST_FAILURE_WT="$(cd "$wt" && pwd -P)" "$F" cleanup merged --force) > "$T/gc-cleanup-rc" 2>&1
  force_rc=$?
  if [ "$force_rc" -eq 128 ] && grep -q 'fixture rev-list failure' "$T/gc-cleanup-rc" &&
    ! grep -q '无法判断是否已推送' "$T/gc-cleanup-rc" && [ -d "$wt" ]; then
    ok "cleanup 保留 rev-list 原始退出码与文案"
  else bad "cleanup rev-list 失败语义" "rc=$force_rc $(cat "$T/gc-cleanup-rc")"; fi
  (cd "$GC_PROJECT" && "$F" cleanup dirty --force) > "$T/gc-cleanup-dirty" 2>&1
  force_rc=$?
  if [ "$force_rc" -ne 0 ] && grep -q 'worktree 有未提交改动' "$T/gc-cleanup-dirty" &&
    [ -f "$GC_PROJECT/.claude/worktrees/foreman-dirty/untracked" ]; then
    ok "cleanup 不接受 Git 配置隐藏的未跟踪文件"
  else bad "cleanup 隐藏的未跟踪文件守卫"; fi

  GC_RACE=1 GC_INJECT=1 GC_CHECK_LOG_DIR="$ledger/late-check" GC_SNAPSHOT="$T/gc-snapshot" \
    GC_LATE_HOLD="$ledger/late-hold/hold-blocked/bridge.pid" "$F" gc --project 'gc project' --idle-hours 24 --force > "$T/gc-force"; force_rc=$?
  if [ "$force_rc" -eq 0 ] && ! grep -q 'project=gc-nogit' "$T/gc-force"; then ok "gc 执行退出 0 且按项目过滤"; else bad "gc 执行 / 项目过滤" "rc=$force_rc"; fi
  gc_check "$T/gc-force" merged '已回收 pr_merged'
  gc_check "$T/gc-force" research '已回收 no_commits'
  gc_check "$T/gc-force" closed '已回收 pr_closed\+branch_kept'
  gc_check "$T/gc-force" race '跳过 recent_activity'
  gc_check "$T/gc-force" gh-fail '跳过 gh_query_failed'
  gc_check "$T/gc-force" unpushed '跳过 unpushed'
  gc_check "$T/gc-force" late-shared '跳过 shared_worktree'
  gc_check "$T/gc-force" head-change '跳过 worktree_changed'
  gc_check "$T/gc-force" late-dirty '跳过 worktree_remove_failed'
  gc_check "$T/gc-force" reopened '跳过 pr_changed'
  gc_check "$T/gc-force" late-check '跳过 recent_activity'
  gc_check "$T/gc-force" held '跳过 pid_unverifiable'
  gc_check "$T/gc-force" late-hold '跳过 pid_unverifiable'
  gc_check "$T/gc-force" gone '已回收 no_commits'
  if [ "$(grep -c ' ticket=held .* 跳过 pid_unverifiable$' "$T/gc-force")" -eq 2 ] &&
    [ -d "$GC_PROJECT/.claude/worktrees/foreman-held-previous" ] &&
    [ ! -e "$ledger/held/hold-blocked/release" ] && [ ! -e "$ledger/late-hold/hold-blocked/release" ]; then
    ok "按票保护全部 PR，初扫和复核均保留权限不明的 hold"
  else bad "hold 整票保护" "$(cat "$T/gc-force")"; fi
  if gc_has "$T/gc-force" push-snapshot '跳过 unpushed' &&
    [ -f "$T/gc-snapshot/foreman-push-snapshot.checked" ] &&
    [ "$(git -C "$GC_PROJECT/.claude/worktrees/foreman-push-snapshot" symbolic-ref --short HEAD)" = feat/gc-push-snapshot ]; then
    ok "gc 未推送检查按首轮 OID，临时换 HEAD 后仍拒绝"
  else bad "gc 未推送检查未固定 OID" "$(cat "$T/gc-force")"; fi
  for id in merged research; do
    if [ ! -e "$GC_PROJECT/.claude/worktrees/foreman-$id" ] &&
      ! git -C "$GC_PROJECT" show-ref --verify --quiet "refs/heads/feat/gc-$id" &&
      python3 -c 'import json,sys; assert not json.load(open(sys.argv[1]))["prs"]' "$ledger/$id/meta.json"; then
      ok "gc $id 删除 worktree、分支和 PR 登记"
    else bad "gc $id 回收结果"; fi
  done
  if [ "$(cat "$ledger/merged/run-1.jsonl")" = 'fixture log' ] &&
    python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["threads"]["implement"]["runs"] == ["run-1"]' "$ledger/merged/meta.json"; then
    ok "gc 保留票、线程和轮次日志"
  else bad "gc 保留票、线程和轮次日志"; fi
  for id in active unpushed recent gh-fail race dirty shared late-shared head-change late-dirty reopened protected held late-hold unreadable-hold unreadable-round; do
    [ -d "$GC_PROJECT/.claude/worktrees/foreman-$id" ] && ok "gc $id 跳过后保留 worktree" || bad "gc $id 跳过后目录丢失"
  done

  touch -t 202001010000 "$GC_PROJECT/.claude/worktrees/foreman-partial/.git"
  GC_BREAK_DELETE="$ledger/partial/meta.json" "$F" gc --project 'gc project' --force > "$T/gc-partial"; force_rc=$?
  if [ "$force_rc" -ne 0 ] && gc_has "$T/gc-partial" partial '部分回收 ledger_update_failed' &&
    grep -q '部分回收=1$' "$T/gc-partial" &&
    [ ! -d "$GC_PROJECT/.claude/worktrees/foreman-partial" ] && [ -f "$ledger/partial/meta.json.saved" ]; then
    ok "目录已删但账本写入失败报告部分回收"
  else bad "部分回收判定" "$(cat "$T/gc-partial")"; fi
  rmdir "$ledger/partial/meta.json" && mv "$ledger/partial/meta.json.saved" "$ledger/partial/meta.json" ||
    { bad "恢复部分回收夹具"; return; }

  touch -t 202001010000 "$GC_PROJECT/.claude/worktrees/foreman-late-ledger/.git" \
    "$GC_PROJECT/.claude/worktrees/foreman-zz-following/.git"
  GC_LATE_CORRUPT="$broken" "$F" gc --project 'gc project' --force > "$T/gc-late-error"; force_rc=$?
  if [ "$force_rc" -ne 0 ] && gc_has "$T/gc-late-error" late-ledger '跳过 ledger_error' &&
    gc_has "$T/gc-late-error" zz-following '跳过 ledger_incomplete' &&
    ! grep -q ' 已回收 ' "$T/gc-late-error" &&
    [ -d "$GC_PROJECT/.claude/worktrees/foreman-late-ledger" ] &&
    [ -d "$GC_PROJECT/.claude/worktrees/foreman-zz-following" ]; then
    ok "删除前发现新账本错误时保留当前与后续候选"
  else bad "gc 删除前账本错误" "$(cat "$T/gc-late-error")"; fi
  rm -f "$broken"
  # 后续用例只验证窄 refspec 的期限已满候选。
  touch "$GC_PROJECT/.claude/worktrees/foreman-late-ledger/.git" \
    "$GC_PROJECT/.claude/worktrees/foreman-zz-following/.git"

  # 远端 main 改到无共同祖先的提交，本地保留旧 origin/main，再缩窄默认 fetch 映射。
  local rewritten
  wt="$GC_PROJECT/.claude/worktrees/foreman-narrow"
  rewritten="$(git -C "$GC_PROJECT" -c user.name=test -c user.email=test@example.com commit-tree 'HEAD^{tree}' -m rewritten)" &&
    git -C "$GC_PROJECT" push -q origin "$rewritten:refs/heads/rewritten" &&
    git -C "$T/gc-origin.git" branch -f main rewritten &&
    git -C "$GC_PROJECT" config remote.origin.fetch '+refs/heads/rewritten:refs/remotes/origin/rewritten' &&
    touch -t 202001010000 "$wt/.git" || { bad "gc 窄 fetch 夹具"; return; }
  GC_SNAPSHOT="$T/gc-snapshot" "$F" gc --project 'gc project' --force > "$T/gc-narrow"; force_rc=$?
  if [ "$force_rc" -eq 0 ] && gc_has "$T/gc-narrow" narrow '跳过 base_changed' && [ -d "$wt" ] &&
    [ "$(git -C "$wt" rev-parse refs/remotes/origin/main)" = "$rewritten" ] &&
    [ -f "$T/gc-snapshot/foreman-narrow.checked" ] &&
    [ "$(git -C "$wt" symbolic-ref --short HEAD)" = feat/gc-narrow ]; then
    ok "gc 窄 fetch 祖先复核用本次取得的 base 和首轮 OID，临时换 HEAD 后仍拒绝"
  else bad "gc 窄 fetch 后复核 base" "$(cat "$T/gc-narrow")"; fi
}
