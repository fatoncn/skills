# 由 selftest.sh 调用，使用独立的账本、假 gh 和本地裸仓。
gc_selftest() {
  local FOREMAN_HOME="$T/gc-home" GC_PROJECT="$T/gc project" GC_RACE_LOG
  export FOREMAN_HOME GC_PROJECT GC_RACE_LOG
  mkdir -p "$GC_PROJECT" "$T/gc-outside" "$T/gc-nogit"
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
case "$2" in
  view) [ "$3" = 41 ]; state=MERGED; begin=""; end="" ;;
  list)
    [ "$3" = --state ] && [ "$4" = all ] && [ "$5" = --head ]
    begin="["; end="]"
    case "$6" in
      feat/gc-gh-fail) exit 1 ;;
      feat/gc-race) state=MERGED; if [ "${GC_RACE:-}" = 1 ]; then touch "$GC_RACE_LOG"; fi ;;
      feat/gc-closed) state=CLOSED ;;
      *) echo '[]'; exit 0 ;;
    esac ;;
  *) exit 1 ;;
esac
printf '%s{"state":"%s","headRefName":"%s","headRefOid":"%s","isCrossRepository":false}%s\n' \
  "$begin" "$state" "$(git branch --show-current)" "$(git rev-parse HEAD)" "$end"
SH
  chmod +x "$T/gc-gh"
  # 仓库覆盖应优先于项目级 github.gh。
  printf '\n[repos."%s--gc-origin"]\ngithub.gh = "%s"\n' "${T##*/}" "$T/gc-gh" >> "$FOREMAN_HOME/projects/gc project/foreman.toml"
  local id ledger wt
  ledger="$FOREMAN_HOME/projects/gc project/issues/${T##*/}--gc-origin"
  for id in merged active unpushed recent research gh-fail missing race closed dirty; do
    "$F" bootstrap "$id" --pr work --branch "feat/gc-$id" --no-install >/dev/null 2>&1 ||
      { bad "gc bootstrap $id"; return; }
    wt="$GC_PROJECT/.claude/worktrees/foreman-$id"
    case "$id" in
      merged|unpushed|gh-fail|race|closed)
        git -C "$wt" -c user.name=test -c user.email=test@example.com commit --allow-empty -qm "$id" ||
          { bad "gc commit $id"; return; }
        ;;
    esac
    case "$id" in
      merged|gh-fail|race) git -C "$wt" push -qu origin HEAD || { bad "gc push $id"; return; } ;;
      closed) git -C "$wt" push -q origin HEAD || { bad "gc push $id"; return; } ;;
      missing) git -C "$GC_PROJECT" worktree remove "$wt" || { bad "gc missing 夹具"; return; } ;;
      dirty) printf dirty > "$wt/untracked" ;;
    esac
  done
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
    }
    for name, value in fixtures.get(d.name, {}).items():
        f = d / name
        f.write_text(value)
        if d.name != "recent":
            os.utime(f, (old, old))
PY
  export GC_RACE_LOG="$ledger/race/run-1.jsonl"
  cd "$T/gc-outside" || { bad "gc 外部目录夹具"; return; }
  local json_rc text_rc preview_rc force_rc
  "$F" list --json --all-projects > "$T/gc-index.json"; json_rc=$?
  "$F" list --all-projects > "$T/gc-text"; text_rc=$?
  if [ "$json_rc" -eq 0 ] && python3 - "$T/gc-index.json" <<'PY'
import json, sys
from datetime import datetime

with open(sys.argv[1]) as handle:
    rows = {x["ticket"]: x for x in json.load(handle)}
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
PY
  then ok "list --json --all-projects 返回 PR 字段、最新轮和任意活跃轮"; else bad "list --json --all-projects 字段 / 状态"; fi
  if [ "$text_rc" -eq 0 ] && grep -q '=== gc project /' "$T/gc-text" && grep -q '=== gc-nogit / _nogit' "$T/gc-text"; then
    ok "list --all-projects 从非 git 目录列跨项目文本"
  else bad "list --all-projects 文本"; fi
  "$F" gc > "$T/gc-preview"; preview_rc=$?
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

  GC_RACE=1 "$F" gc --project 'gc project' --idle-hours 24 --force > "$T/gc-force"; force_rc=$?
  if [ "$force_rc" -eq 0 ] && ! grep -q 'project=gc-nogit' "$T/gc-force"; then ok "gc 执行退出 0 且按项目过滤"; else bad "gc 执行 / 项目过滤" "rc=$force_rc"; fi
  gc_check "$T/gc-force" merged '已回收 pr_merged'
  gc_check "$T/gc-force" research '已回收 no_commits'
  gc_check "$T/gc-force" closed '已回收 pr_closed\+branch_kept'
  gc_check "$T/gc-force" race '跳过 recent_activity'
  gc_check "$T/gc-force" gh-fail '跳过 gh_query_failed'
  gc_check "$T/gc-force" unpushed '跳过 unpushed'
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
  for id in active unpushed recent gh-fail race dirty; do
    [ -d "$GC_PROJECT/.claude/worktrees/foreman-$id" ] && ok "gc $id 跳过后保留 worktree" || bad "gc $id 跳过后目录丢失"
  done
}
