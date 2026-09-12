#!/usr/bin/env bash
# foreman — 机械动作层：项目规则、worktree 生命周期、执行器调用、日志解析、验证命令。
# 所有判断（拆任务、写任务书、验收）都在 SKILL.md 里由编排者做，不在这里。
# 默认执行器是 codex（app-server 协议）；claude 为 Claude Code CLI 非交互引擎；pi 可选。
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_PATH="$SKILL_DIR/scripts/foreman.sh"
ASSETS_DIR="$SKILL_DIR/assets"
PY_APPSERVER="$SKILL_DIR/scripts/codex_appserver.py"
PY_CLAUDE="$SKILL_DIR/scripts/claude_code.py"
PY_SUMMARIZE="$SKILL_DIR/scripts/summarize.py"
PY_CONFIG="$SKILL_DIR/scripts/project_config.py"

FOREMAN_ROOT="${FOREMAN_HOME:-$HOME/.foreman}"
CODEX_HOME_DIR="${FOREMAN_CODEX_HOME:-}"   # 由 resolve_codex_home 按全局 [codex] home 决定；初始化时必须显式选 shared / isolated
CODEX_HOME_MODE=""
GLOBAL_TOML="$FOREMAN_ROOT/config.toml"
ROLES_DIR="$FOREMAN_ROOT/roles"   # 每个角色一份角色文件（契约），foreman setup 从 assets/roles/ 拷参考角色样例
REQUIRED_ROLES="implement review mechanical"   # 三个参考角色全必需；再多的自定义可选。收尾不是角色：实现者续线程，见 assets/CLOSEOUT.md
HOLD_TERM_GRACE=25  # 必须 >= codex_appserver.py INTERRUPT_GRACE(20) + 5，给执行体写 rc/last 的收尾窗口

die() { printf 'foreman: %s\n' "$*" >&2; exit 1; }

# 解析到真实路径：0.153.4 的 shell 工具要 spawn 同目录的 codex-code-mode-host，argv[0] 若是 ~/.local/bin 里的软链，
# 它会去 ~/.local/bin 找兄弟程序而找不到（实测：Code Mode is unavailable … fail closed，模型一条命令都跑不了）。
resolve_codex_bin() {
  local bin=""
  if [ -n "${FOREMAN_CODEX_BIN:-}" ]; then bin="$FOREMAN_CODEX_BIN"
  elif command -v codex >/dev/null 2>&1; then bin="$(command -v codex)"
  elif [ -x /Applications/ChatGPT.app/Contents/Resources/codex ]; then bin=/Applications/ChatGPT.app/Contents/Resources/codex
  fi
  [ -n "$bin" ] || { printf ''; return; }
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$bin"
}
CODEX_BIN="$(resolve_codex_bin)"

# ---------- 仓库、项目目录、配置 ----------

resolve_main_repo() {
  local common
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  printf '%s' "$(cd "$(dirname "$common")" && pwd)"
}

slug_of_origin() {
  local o="$1" a b
  o="${o%.git}"; o="${o#*://}"; o="${o#*@}"; o="${o//:/\/}"
  b="${o##*/}"; o="${o%/*}"; a="${o##*/}"
  if [ -n "$a" ] && [ "$a" != "$b" ]; then printf '%s--%s' "$a" "$b"; else printf '%s' "$b"; fi
}

MAIN_REPO=""; REPO_SLUG=""; REPO_NAME=""; PROJECT_ROOT=""; PROJECT_SLUG=""; PROJECT_DIR=""; PROJECT_TOML=""; ISSUES_DIR=""; REPO_FACTS="{}"; IN_GIT=0
# 项目根 = Claude 的工作目录：从起点向上找第一个带 AGENTS.md / CLAUDE.md 的目录，找不到用默认。
find_project_root() {  # <起点> <默认>
  local p="$1"
  while [ -n "$p" ] && [ "$p" != "/" ]; do
    if [ -f "$p/AGENTS.md" ] || [ -f "$p/CLAUDE.md" ]; then printf '%s' "$p"; return 0; fi
    p="$(dirname "$p")"
  done
  printf '%s' "$2"
}
# 每个命令都从当前目录推上下文。在 git 仓库里：仓库事实运行时推导（origin / 远端默认分支 / 装依赖 / 验收命令）；
# 不在 git 仓库里也能用（跟仓库无关的活）：执行目录 = 当前目录，只有 bootstrap / diff / review / pr 这类依赖 git 的命令不可用。
init_repo_context() {
  if MAIN_REPO="$(resolve_main_repo)"; then
    IN_GIT=1
    local origin; origin="$(git -C "$MAIN_REPO" remote get-url origin 2>/dev/null || true)"
    if [ -n "$origin" ]; then REPO_SLUG="$(slug_of_origin "$origin")"; else REPO_SLUG="$(basename "$MAIN_REPO")"; fi
    REPO_NAME="$(basename "$MAIN_REPO")"
    PROJECT_ROOT="$(find_project_root "$(dirname "$MAIN_REPO")" "$MAIN_REPO")"
    REPO_FACTS="$(python3 "$PY_CONFIG" facts --main-repo "$MAIN_REPO")"
  else
    IN_GIT=0; MAIN_REPO="$PWD"; REPO_SLUG="_nogit"; REPO_NAME="$(basename "$PWD")"
    PROJECT_ROOT="$(find_project_root "$PWD" "$PWD")"
    REPO_FACTS="{}"
  fi
  PROJECT_SLUG="$(basename "$PROJECT_ROOT")"
  PROJECT_DIR="$FOREMAN_ROOT/projects/$PROJECT_SLUG"
  PROJECT_TOML="$PROJECT_DIR/foreman.toml"
  ISSUES_DIR="$PROJECT_DIR/issues/$REPO_SLUG"
}
require_git() { [ "$IN_GIT" -eq 1 ] || die "这个命令需要在 git 仓库里（当前目录不是 git 检出；跟仓库无关的活只能用 here / run / status / report / check / cleanup）"; }
repo_fact() { python3 -c 'import json,sys; v=(json.loads(sys.argv[1]) or {}).get(sys.argv[2],""); print("\n".join(v) if isinstance(v,list) else v)' "$REPO_FACTS" "$1"; }
base_of_repo() { local v; v="$(cfg_opt repo.default_base)"; [ -n "$v" ] || v="$(repo_fact remote_default_branch)"; printf '%s' "$v"; }
install_of_repo() { local v; v="$(cfg_opt repo.install_cmd)"; [ -n "$v" ] || v="$(repo_fact install_cmd)"; printf '%s' "$v"; }
verify_of_repo() { local v; v="$(cfg_opt verify.commands)"; [ -n "$v" ] || v="$(repo_fact verify_commands)"; printf '%s' "$v"; }
expand_path_tpl() { local s="$1"; s="${s//\{repo\}/$MAIN_REPO}"; s="${s//\{project\}/$PROJECT_ROOT}"; s="${s//\{name\}/$REPO_NAME}"; printf '%s' "$s"; }

require_project() {
  [ -f "$PROJECT_TOML" ] || die "项目 ${PROJECT_SLUG}（${PROJECT_ROOT}）还没初始化。先跑: foreman init   （然后和用户过一遍 ${PROJECT_TOML}）"
  python3 -c 'import tomllib,sys; tomllib.load(open(sys.argv[1],"rb"))' "$PROJECT_TOML" 2>"$FOREMAN_ROOT/.toml-err" || die "项目配置有语法错误（cfg 会静默回落到默认值，所以先拦）: ${PROJECT_TOML}
$(tail -1 "$FOREMAN_ROOT/.toml-err")"
  local root; root="$(cfg_opt project.root)"
  if [ -n "$root" ] && ! same_path "$root" "$PROJECT_ROOT"; then
    die "项目目录名撞车：${PROJECT_TOML} 属于 ${root}，当前项目根却是 ${PROJECT_ROOT}。给其中一个项目换个目录名，或用 FOREMAN_HOME 分开。"
  fi
}

# cfg <dotted.key> [default]  —— 缺失且无默认时报错退出
# 读项目配置：[repos."<当前仓库 slug>"] 里的同名键优先于顶层
cfg() {
  if [ $# -ge 2 ]; then
    python3 "$PY_CONFIG" get --path "$PROJECT_TOML" --repo "$REPO_SLUG" "$1" --default "$2"
  else
    python3 "$PY_CONFIG" get --path "$PROJECT_TOML" --repo "$REPO_SLUG" "$1" || die "foreman.toml 缺字段 $1"
  fi
}
cfg_opt() { python3 "$PY_CONFIG" get --path "$PROJECT_TOML" --repo "$REPO_SLUG" "$1" --default "" 2>/dev/null || true; }

# 全局配置（本机一份，所有项目共用）：并发上限放这里，因为 codex 额度是按账号算的，不分项目
ensure_global_config() {
  mkdir -p "$FOREMAN_ROOT"
  [ -f "$GLOBAL_TOML" ] && return 0
  cat > "$GLOBAL_TOML" <<'EOF'
# foreman 全局配置（本机一份，所有项目共用）。项目配置在 projects/<项目>/foreman.toml。
schema = 1
# 角色分工必须先由使用者过目确认，skill 才能派活：foreman setup 看表 → 和用户确认 → foreman setup --confirm 把它置 true。
# 以后改角色直接编辑本文件即可，不用重新确认。
roles_confirmed = false

[engines]
# 同时在跑的 codex 线程上限（run / review 都算，计数是本机所有项目合计）。codex 走 ChatGPT 订阅额度，
# 和你自己开的 Codex 抢同一份配额。这里是本机默认；项目 foreman.toml 的 [engines] concurrency 可覆盖。到上限拒绝派发。
concurrency = 5

[engines.claude]
# Claude Code 使用独立订阅池；按本机所有项目的 claude 活进程计数。
concurrency = 3

# 角色分工（跨项目）：按活分档，每个角色 = 执行器 + 模型 + 推理档 + 角色文件。
# 三个参考角色 implement / review / mechanical 都必需（foreman setup --confirm 会查）；再多的自己起名，foreman run --role <名> 取用。
# 档位按「描述」定，不绑死模型名——模型会迭代，届时按描述重选（foreman doctor 打印当前可用模型与推理档）：
#   implement  = 旗舰或次旗舰 + medium
#   review     = 旗舰 + high
#   mechanical = 次旗舰 + low～medium（便宜但精准）
#   research   = 旗舰 + high 及以上（只读调研：排查、核事实、找锚点、复现，交事实清单不下判断；调研线程 run --role research）
#   accept     = 旗舰或次旗舰 + high，比实现者高一档（验收：把产品真跑起来对清单看，证据落交付目录，发现问题只报不修；验收线程 run --role accept）
# 下面的 model 是 2026-09-12 的对应：旗舰 gpt-6-astra；日常写码与验收用 gpt-5.6-sol（cookie 09-12：验收多是浏览器脏活、实现日常量，gpt-6 太奢侈）；轻活 gpt-5.6-terra。
# 收尾不是角色：PR 收尾由实现者带着原口径续同一线程做（foreman run --closeout），skill 会把收尾阶段契约放进那一轮的 prompt。
# 项目文件里写同名 [roles.<名>] 可以覆盖。可用模型与推理档用 foreman doctor 看。
# 每个角色还有一份「角色文件」= 注入执行者的契约（位置 / 沙箱事实 / 分工边界 / 提问 / 输出格式，不含干活纪律），
# 默认在 ~/.foreman/roles/<名>.md，foreman setup 会从 skill 的 assets/roles/ 拷五份参考角色样例，可随意改；要用别的路径就写 prompt = "<路径>"。
# 干活纪律不写在角色文件里，每轮由编排者写进任务书。
[roles.implement]
# 实现 + 测试等一切写码活；foreman run 的默认角色。档位：旗舰或次旗舰 + medium
engine = "codex"
model = "gpt-5.6-sol"
effort = "medium"
# prompt = "~/.foreman/roles/implement.md"   # 默认值，可省略

[roles.implement.claude]
model = "sonnet"
effort = "medium"

[roles.review]
# 对抗性复审：只看 diff，挑破坏项目约定 / 仓库约定 / 最佳实践的地方，只提意见编排者拍板；foreman review 用，只读沙箱。档位：旗舰 + high。硬规矩：复审永远开新线程，绝不沿用实现的会话
engine = "codex"
model = "gpt-6-astra"
effort = "high"

[roles.review.claude]
model = "fable"
effort = "high"

[roles.mechanical]
# 轻活：补测试 / 按既定契约接线 / 改文案 / 批量重命名，不做设计取舍；foreman run --role mechanical 用。档位：次旗舰 + low～medium（便宜但精准）
engine = "codex"
model = "gpt-5.6-terra"
effort = "medium"

[roles.mechanical.claude]
model = "sonnet"
effort = "low"

[roles.research]
# 只读调研：排查、核事实、找代码锚点、复现问题，交事实清单不下判断；调研线程用 foreman run --role research --writable <交付目录>。档位：旗舰 + high 及以上
engine = "codex"
model = "gpt-6-astra"
effort = "high"

[roles.research.claude]
model = "sonnet"
effort = "xhigh"

[roles.accept]
# 验收：把产品真跑起来对清单看（浏览器 / 预览 / 查库），证据落交付目录，发现问题只报不修；验收线程用 foreman run --role accept --writable <证据目录>。档位：旗舰或次旗舰 + high，比实现者高一档（假「通过」最贵）
engine = "codex"
model = "gpt-5.6-sol"
effort = "high"

[roles.accept.claude]
model = "sonnet"
effort = "high"

# 再多的角色照样子加，名字自定，foreman run --role <名> 取用。

[codex]
# 执行者用哪个 CODEX_HOME，初始化时必须显式二选一（foreman setup --codex-home shared|isolated），不设不能派活：
#   shared   = 共用桌面端的 ~/.codex：桌面端能看到 foreman 线程；执行者继承桌面端的 MCP / 插件 / notify / 全局 AGENTS.md
#   isolated = 独立的 ~/.foreman/codex-home：只共用登录态；桌面端看不到线程，用 foreman tail / report 看
# home = "shared"
# 线程命名模板（使用者自定）：run / review 会把 codex 线程命名成它。必须含 {ids}（这张票相关的 issue / PR 号，+ 连接）和 {title}（具体工作内容）。
thread_name = "foreman {ids}: {title}"
EOF
}
gcfg() { ensure_global_config; python3 "$PY_CONFIG" get --path "$GLOBAL_TOML" "$1" --default "${2:-}" 2>/dev/null || printf '%s' "${2:-}"; }

# 角色分工确认门槛（用户 09-11）：初始化并确认角色之后才能用 skill 派活
require_roles_confirmed() {
  [ "$(gcfg roles_confirmed false)" = "true" ] || die "角色分工还没初始化确认。先 foreman setup 看角色表 → 和用户确认（模型 / 推理档 / 要不要加角色）→ foreman setup --confirm"
}

set_codex_home_mode() {
  local mode="$1"
  case "$mode" in shared|isolated) ;; *) die "--codex-home 只能是 shared 或 isolated（收到 '${mode}'）" ;; esac
  python3 - "$GLOBAL_TOML" "$mode" <<'PY2'
import re, sys
p, mode = sys.argv[1], sys.argv[2]; s = open(p).read()
line = f'home = "{mode}"'
if re.search(r'^\[codex\]', s, re.M):
    sec = re.search(r'^\[codex\][^\[]*', s, re.M)
    body = sec.group(0)
    if re.search(r'^home\s*=', body, re.M): body2 = re.sub(r'^home\s*=.*$', line, body, count=1, flags=re.M)
    else: body2 = body.rstrip("\n") + "\n" + line + "\n\n"
    s = s[:sec.start()] + body2 + s[sec.end():]
else:
    s = s.rstrip("\n") + "\n\n[codex]\n" + line + "\n"
open(p, "w").write(s)
PY2
  CODEX_HOME_MODE=""; resolve_codex_home
  echo "codex home 模式已设为 ${mode}：CODEX_HOME=${CODEX_HOME_DIR}"
  [ "$mode" = "shared" ] && echo "  共用桌面端 home：桌面端能看到 foreman 线程；执行者会继承桌面端 config.toml 里的 MCP / 插件 / notify / 全局 AGENTS.md。不想继承就改 isolated。"
  [ "$mode" = "isolated" ] && echo "  独立 home：只共用登录态；桌面端看不到线程，用 foreman tail / report / status 看进度。"
  return 0
}

cmd_setup() {
  local confirm=0 mode=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --confirm) confirm=1; shift ;;
      --codex-home) mode="$2"; shift 2 ;;
      *) die "setup: 未知参数 $1（用法: foreman setup [--codex-home shared|isolated] [--confirm]）" ;;
    esac
  done
  ensure_global_config
  [ -z "$mode" ] || set_codex_home_mode "$mode"
  if [ "$confirm" -eq 1 ]; then
    resolve_codex_home
    require_required_roles
    local r
    for r in $(list_global_roles); do role_prompt_file "$r" >/dev/null; done
    python3 - "$GLOBAL_TOML" <<'PY2'
import re, sys
p=sys.argv[1]; s=open(p).read()
s2=re.sub(r'^roles_confirmed\s*=\s*(true|false)\s*$', 'roles_confirmed = true', s, count=1, flags=re.M)
if s2==s and 'roles_confirmed' not in s: s2 = s.replace('schema = 1', 'schema = 1\nroles_confirmed = true', 1)
open(p,'w').write(s2)
PY2
    echo "已确认角色分工（$GLOBAL_TOML roles_confirmed = true）。以后改角色直接编辑该文件与 ${ROLES_DIR}/ 下的角色文件。"
    return 0
  fi
  echo "全局配置: $GLOBAL_TOML   （roles_confirmed = $(gcfg roles_confirmed false)）"
  echo "本机并发上限默认: $(gcfg engines.concurrency 5)（项目 foreman.toml 的 engines.concurrency 可覆盖）"
  echo "线程命名模板: $(gcfg codex.thread_name 'foreman {ids}: {title}')（本机 config.toml 的 codex.thread_name，须含 {ids} 与 {title}）"
  local cur; cur="$(gcfg codex.home "")"
  if [ -n "$cur" ]; then echo "codex home 模式: ${cur}（$([ "$cur" = shared ] && echo "共用 ~/.codex，桌面端能看到线程、执行者继承桌面端配置" || echo "独立 ~/.foreman/codex-home，只共用登录态")）"
  else echo "codex home 模式: 未设置 ← 必须显式选一个：foreman setup --codex-home shared | isolated（不设不能派活）"; fi
  echo "角色文件目录: $ROLES_DIR"
  seed_role_files
  echo "角色分工（跨项目；项目 foreman.toml 同名 [roles.<名>] 可覆盖）:"
  python3 - "$GLOBAL_TOML" "$ROLES_DIR" "$REQUIRED_ROLES" <<'PY2'
import tomllib, sys, os
cfg = tomllib.load(open(sys.argv[1], "rb")); roles_dir = sys.argv[2]
roles = cfg.get("roles") or {}
required = sys.argv[3].split()
for name in required:
    if name not in roles: print(f"  {name:12} ← 必需角色，未定义")
for name, r in roles.items():
    p = os.path.expanduser(r.get("prompt") or f"{roles_dir}/{name}.md")
    mark = "" if os.path.isfile(p) else "   ← 缺角色文件"
    kind = "必需" if name in required else "可选"
    print(f"  {name:12} [{kind}] engine={r.get('engine','codex'):10} model={r.get('model','?'):18} effort={r.get('effort','?'):8} 角色文件={p}{mark}")
extra = sorted(fn[:-3] for fn in os.listdir(roles_dir) if fn.endswith(".md") and fn[:-3] not in roles)
if extra: print("  参考角色样例、未在表里（档位没定义时 run --role 会拒）: " + ", ".join(extra))
PY2
  echo
  echo "implement / review / mechanical 三个参考角色必需；research（只读调研）、accept（验收）随样例一起给，建议保留；再多的自己起名。收尾不是角色，由实现者续线程做。"
  echo "档位口径（按描述选，模型迭代后重选，foreman doctor 看当前可用模型）：实现者 = 旗舰或次旗舰 + low～medium；复审 = 旗舰 + high；轻活 = 次旗舰 + low～medium（便宜但精准）；调研 = 与实现者同级 + high 及以上；验收 = 与实现者同级 + medium。"
  echo "角色文件 = 注入执行者的契约（位置 / 沙箱事实 / 分工边界 / 提问 / 输出格式），不含干活纪律；干活纪律每轮写进任务书。"
  echo "改角色：直接编辑角色文件；加角色：加 [roles.<名>] + 同名 .md（或 prompt = \"<路径>\"）。"
  echo "下一步：把这张表和角色文件念给用户过目；用户确认后执行: foreman setup --confirm 。确认前 run / review 会拒绝派活。"
}

# 角色 → 执行器 / 模型 / 推理档：项目 foreman.toml 的 [roles.<名>] 优先，其次全局 config.toml；都没有就是未定义
role_cfg() { local v; v="$(cfg_opt "roles.$1.$2")"; if [ -n "$v" ]; then printf '%s' "$v"; else gcfg "roles.$1.$2" ""; fi; }
claude_role_cfg() { role_cfg "$1" "claude.$2"; }
role_defined() { [ -n "$(role_cfg "$1" model)" ]; }
require_role() { role_defined "$1" || die "角色 '$1' 未定义。在 $GLOBAL_TOML 的 [roles.$1] 里定义 engine / model / effort（跨项目），或在 $PROJECT_TOML 里覆盖"; }

# 角色文件 = 注入执行者的契约（位置 / 沙箱事实 / 分工边界 / 提问 / 输出格式，不含干活纪律）。
# 解析顺序：项目或全局 [roles.<名>].prompt 指定的路径 > ~/.foreman/roles/<名>.md。缺文件直接拒绝，不回落到 skill 内置样例。
role_prompt_file() {
  local role="$1" p
  p="$(role_cfg "$role" prompt)"
  case "$p" in "~/"*) p="$HOME/${p#\~/}" ;; esac
  if [ -n "$p" ]; then
    [ -f "$p" ] || die "角色 '${role}' 的 prompt 指向的文件不存在: ${p}"
    printf '%s' "$p"; return 0
  fi
  p="$ROLES_DIR/$role.md"
  [ -f "$p" ] || die "角色 '${role}' 没有角色文件: ${p}
先跑 foreman setup（会从 skill 的 assets/roles/ 拷参考角色样例到 ${ROLES_DIR}/），或自己写一份，或在 [roles.${role}] 里用 prompt = \"<路径>\" 指定。"
  printf '%s' "$p"
}
list_global_roles() {
  python3 -c 'import tomllib,sys; print("\n".join((tomllib.load(open(sys.argv[1],"rb")).get("roles") or {}).keys()))' "$GLOBAL_TOML"
}
seed_role_files() {
  mkdir -p "$ROLES_DIR"
  local src dst
  for src in "$ASSETS_DIR"/roles/*.md; do
    dst="$ROLES_DIR/$(basename "$src")"
    if [ ! -f "$dst" ]; then cp "$src" "$dst"; echo "  已从参考角色样例生成: ${dst}"; fi
  done
}
require_required_roles() {
  local r
  for r in $REQUIRED_ROLES; do
    role_defined "$r" || die "必需角色 '${r}' 未定义：$GLOBAL_TOML 里必须有 [roles.${r}]（engine / model / effort）"
    role_prompt_file "$r" >/dev/null
  done
}

# 本机所有项目里仍在跑的 codex 线程数（run + review）
active_codex_runs() {
  local n=0 d f eng seen=""
  for d in "$FOREMAN_ROOT"/projects/*/issues/*/*; do
    [ -f "$d/meta.json" ] || continue
    for f in "$d"/run-*.pid "$d"/review-*.pid; do
      [ -f "$f" ] || continue
      eng="$(cat "${f%.pid}.engine" 2>/dev/null || echo codex)"
      case "$eng" in codex) ;; *) continue ;; esac
      [ -f "${f%.pid}.rc" ] && continue
      kill -0 "$(cat "$f")" 2>/dev/null && seen="$seen $(cat "$f")"
    done
  done
  printf '%s' "$(printf '%s
' $seen | sort -u | grep -c .)"
}
active_claude_runs() {
  local d f eng seen=""
  for d in "$FOREMAN_ROOT"/projects/*/issues/*/*; do
    [ -f "$d/meta.json" ] || continue
    for f in "$d"/run-*.pid "$d"/review-*.pid; do
      [ -f "$f" ] || continue
      eng="$(cat "${f%.pid}.engine" 2>/dev/null || true)"
      [ "$eng" = "claude" ] || continue
      [ -f "${f%.pid}.rc" ] && continue
      kill -0 "$(cat "$f")" 2>/dev/null && seen="$seen $(cat "$f")"
    done
  done
  printf '%s' "$(printf '%s
' $seen | sort -u | grep -c .)"
}
concurrency_limit() { local l; l="$(cfg_opt engines.concurrency)"; [ -n "$l" ] || l="$(gcfg engines.concurrency 5)"; printf '%s' "$l"; }  # 项目覆盖 > 本机默认
claude_concurrency_limit() { local l; l="$(cfg_opt engines.claude.concurrency)"; [ -n "$l" ] || l="$(gcfg engines.claude.concurrency 3)"; printf '%s' "$l"; }
require_concurrency_slot() {  # 派发前调用；只对 codex 系执行器
  local limit running; limit="$(concurrency_limit)"; running="$(active_codex_runs)"
  if [ "$running" -ge "$limit" ]; then
    die "本机并发已达上限：$running 个 codex 线程在跑（所有项目合计），上限 ${limit}。先 foreman wait，或改上限（项目 ${PROJECT_TOML} 的 engines.concurrency 覆盖本机 ${GLOBAL_TOML} 的默认）"
  fi
}
require_claude_slot() {
  local limit running; limit="$(claude_concurrency_limit)"; running="$(active_claude_runs)"
  if [ "$running" -ge "$limit" ]; then
    die "本机并发已达上限：$running 个 claude 线程在跑（所有项目合计），上限 ${limit}。先 foreman wait，或改 [engines.claude] concurrency"
  fi
}

issue_dir() { printf '%s/%s' "$ISSUES_DIR" "$1"; }
require_issue() { [ -f "$(issue_dir "$1")/meta.json" ] || die "未知 issue '$1'（先跑 bootstrap，或用 list 查看）"; }

meta_get() {
  python3 -c 'import json,sys
print(json.load(open(sys.argv[1])).get(sys.argv[2], "") or "")' "$(issue_dir "$1")/meta.json" "$2"
}
# 票下的线程账本（与引擎无关）：meta.threads.<名> = {engine, ref（引擎内引用）, role, kind, home, runs[], created}
thread_get() {  # <issue> <线程名> <字段>
  python3 -c 'import json,sys
m=json.load(open(sys.argv[1])); t=(m.get("threads") or {}).get(sys.argv[2]) or {}; v=t.get(sys.argv[3],""); print("" if v is None else (",".join(v) if isinstance(v,list) else v))' "$(issue_dir "$1")/meta.json" "$2" "$3"
}
thread_set() {  # <issue> <线程名> <字段> <值>   （字段 runs = 追加一轮）
  python3 -c 'import json,sys,time
p,name,field,value=sys.argv[1:5]
try: m=json.load(open(p))
except Exception: m={}
t=m.setdefault("threads",{}).setdefault(name,{"created":time.strftime("%Y-%m-%dT%H:%M:%S%z")})
if field=="runs":
    runs=t.setdefault("runs",[]); value in runs or runs.append(value)
else:
    t[field]=value
json.dump(m,open(p,"w"),indent=2,ensure_ascii=False)' "$(issue_dir "$1")/meta.json" "$2" "$3" "$4"
}
meta_set() {
  python3 -c 'import json,sys
path, key, value = sys.argv[1:4]
try: meta = json.load(open(path))
except Exception: meta = {}
meta[key] = value
json.dump(meta, open(path, "w"), indent=2, ensure_ascii=False)' "$(issue_dir "$1")/meta.json" "$2" "$3"
}

# 票下的 PR 账本：meta.prs.<名> = {worktree, branch, base, registered_here, gh_pr, created}。一张票可以有多个 PR（各自一个 worktree）。
# 旧格式（顶层 worktree / branch / base）按名 default 读，兼容在途的票。
pr_set() {  # <issue> <pr名> <字段> <值>
  python3 -c 'import json,sys,time
p,name,field,value=sys.argv[1:5]
try: m=json.load(open(p))
except Exception: m={}
prs=m.setdefault("prs",{})
if not prs and m.get("worktree"):
    prs["default"]={"worktree":m.get("worktree"),"branch":m.get("branch",""),"base":m.get("base",""),"registered_here":bool(m.get("registered_here"))}
pr=prs.setdefault(name,{"created":time.strftime("%Y-%m-%dT%H:%M:%S%z")})
pr[field]= (value=="1") if field=="registered_here" else value
json.dump(m,open(p,"w"),indent=2,ensure_ascii=False)' "$(issue_dir "$1")/meta.json" "$2" "$3" "$4"
}
pr_del() {  # <issue> <pr名>
  python3 -c 'import json,sys
p,name=sys.argv[1:3]; m=json.load(open(p)); (m.get("prs") or {}).pop(name,None)
if name=="default":
    for k in ("worktree","branch","base","registered_here"): m.pop(k,None)
json.dump(m,open(p,"w"),indent=2,ensure_ascii=False)' "$(issue_dir "$1")/meta.json" "$2"
}
pr_names() { python3 -c 'import json,sys
m=json.load(open(sys.argv[1])); prs=m.get("prs") or ({"default":{}} if m.get("worktree") else {}); print("\n".join(prs.keys()))' "$(issue_dir "$1")/meta.json"; }
default_pr_of_dir() {  # 旧票缺 default_pr 时按首个登记 PR 回填
  python3 -c 'import json,sys
p=sys.argv[1]; m=json.load(open(p)); prs=m.get("prs") or ({"default":{}} if m.get("worktree") else {}); name=m.get("default_pr") or (next(iter(prs),""));
if name and not m.get("default_pr"): m["default_pr"]=name; json.dump(m,open(p,"w"),indent=2,ensure_ascii=False)
print(name)' "$1/meta.json"
}
default_pr_name() { default_pr_of_dir "$(issue_dir "$1")"; }
# 选定这轮针对哪个 PR：给了名就用它；没给且只有一个就用那个；没有 PR 则全空（纯调研 / 无工作目录）；多个不给名就拒绝。
# 设 PR_NAME PR_WT PR_BRANCH PR_BASE PR_HERE
resolve_pr() {  # <issue> [<pr名>]
  local out; out="$(python3 -c 'import json,sys
p,name=sys.argv[1:3]; m=json.load(open(p)); prs=m.get("prs") or {}
if not prs and m.get("worktree"): prs={"default":{"worktree":m.get("worktree"),"branch":m.get("branch",""),"base":m.get("base",""),"registered_here":bool(m.get("registered_here"))}}
if name:
    if name not in prs: print("ERR\t票 %s 没有名为 %s 的 PR，现有: %s"%(m.get("issue"),name,", ".join(prs) or "无")); sys.exit(0)
elif len(prs)==1: name=next(iter(prs))
elif len(prs)==0: print("\t\t\t\t"); sys.exit(0)
else: print("ERR\t票 %s 有多个 PR（%s），用 --pr <名> 指定这轮针对哪个"%(m.get("issue"),", ".join(prs))); sys.exit(0)
pr=prs[name]; print("\t".join([name,pr.get("worktree","") or "",pr.get("branch","") or "",pr.get("base","") or "","1" if pr.get("registered_here") else ""]))' "$(issue_dir "$1")/meta.json" "${2:-}")"
  case "$out" in ERR*) die "${out#ERR	}" ;; esac
  IFS=$'\t' read -r PR_NAME PR_WT PR_BRANCH PR_BASE PR_HERE <<<"$out"
}
pr_gh_numbers() { python3 -c 'import json,sys
m=json.load(open(sys.argv[1])); print(" ".join(str(v.get("gh_pr")) for v in (m.get("prs") or {}).values() if v.get("gh_pr")))' "$(issue_dir "$1")/meta.json"; }

validate_id() {
  case "$1" in *[!a-zA-Z0-9._-]*|'') die "issue id 只能用字母数字和 . _ -（收到 '$1'）" ;; esac
}
validate_thread_id() {
  case "$1" in *[!a-zA-Z0-9._@-]*|'') die "线程名只能用字母数字和 . _ @ -（收到 '$1'）" ;; esac
}

# ---------- init / config ----------

cmd_init() {
  local force=""
  [ "${1:-}" = "--force" ] && force="--force"
  init_repo_context
  ensure_global_config
  mkdir -p "$PROJECT_DIR" "$ISSUES_DIR"
  python3 "$PY_CONFIG" init --project-dir "$PROJECT_DIR" --project-root "$PROJECT_ROOT" --main-repo "$MAIN_REPO" $force
  [ "$(gcfg roles_confirmed false)" = "true" ] || echo "提示：本机角色分工还没确认，先 foreman setup（看表）→ foreman setup --confirm。"
  echo
  echo "下一步：按上面的清单读项目规则填 ${PROJECT_TOML}，填完把它念给用户过一遍，改定之后再 bootstrap。"
}

cmd_config() {
  init_repo_context
  case "${1:-show}" in
    path) printf '%s\n' "$PROJECT_TOML" ;;
    show) require_project; python3 "$PY_CONFIG" dump --path "$PROJECT_TOML" ;;
    get)  require_project; shift; cfg "$@" ;;
    *) die "config: 用法 foreman config [show|path|get <key> [default]]" ;;
  esac
}

# ---------- codex home（全 skill 一份，不按票拆） ----------

# 执行者用哪个 CODEX_HOME：初始化时必须显式二选一（foreman setup --codex-home shared|isolated），不设不派活（用户 09-11）。
#   shared   = 共用桌面端的 ~/.codex：桌面端能看到 foreman 线程；执行者继承桌面端的 MCP / 插件 / notify / 全局 AGENTS.md
#   isolated = 独立的 ~/.foreman/codex-home：只共用登录态；桌面端看不到线程，用 foreman tail / report 看
# 环境变量 FOREMAN_CODEX_HOME 指定路径可绕过配置（指到 ~/.codex 即视为 shared）。
CODEX_HOME_HINT="codex home 模式未设置：foreman setup --codex-home shared（共用 ~/.codex，桌面端能看到线程，执行者继承桌面端的 MCP / 插件 / notify / 全局 AGENTS.md）或 foreman setup --codex-home isolated（独立 ~/.foreman/codex-home，只共用登录态）"
resolve_codex_home() {
  [ -n "$CODEX_HOME_MODE" ] && return 0
  local mode
  if [ -n "${FOREMAN_CODEX_HOME:-}" ]; then
    CODEX_HOME_DIR="$FOREMAN_CODEX_HOME"
    if [ "$(cd "$CODEX_HOME_DIR" 2>/dev/null && pwd -P)" = "$(cd "$HOME/.codex" 2>/dev/null && pwd -P)" ]; then CODEX_HOME_MODE=shared; else CODEX_HOME_MODE=env; fi
    return 0
  fi
  mode="$(gcfg codex.home "")"
  case "$mode" in
    shared)   CODEX_HOME_DIR="$HOME/.codex"; CODEX_HOME_MODE=shared ;;
    isolated) CODEX_HOME_DIR="$FOREMAN_ROOT/codex-home"; CODEX_HOME_MODE=isolated ;;
    "")       die "$CODEX_HOME_HINT" ;;
    *)        die "全局配置 [codex] home 只能是 shared / isolated（收到 '${mode}'）" ;;
  esac
}
# 续线程时用它创建时的 home（切换模式后旧线程仍能续上）：meta.codex_home > 在两个 home 的 sessions/ 里找 rollout > 当前 home
home_for_thread() {  # <issue> <线程名> <线程 id>
  local issue="$1" tname="$2" tid="$3" rec h
  rec="$(thread_get "$issue" "$tname" home)"
  if [ -n "$rec" ] && [ -d "$rec" ]; then printf '%s' "$rec"; return 0; fi
  for h in "$CODEX_HOME_DIR" "$HOME/.codex" "$FOREMAN_ROOT/codex-home"; do
    [ -d "$h/sessions" ] || continue
    if [ -n "$(find "$h/sessions" -name "*-${tid}.jsonl" -print -quit 2>/dev/null)" ]; then printf '%s' "$h"; return 0; fi
  done
  printf '%s' "$CODEX_HOME_DIR"
}
ensure_codex_home() {
  resolve_codex_home
  [ -n "$CODEX_BIN" ] || die "找不到 codex 二进制：装 ChatGPT 桌面端（/Applications/ChatGPT.app）或设 FOREMAN_CODEX_BIN"
  [ -f "$HOME/.codex/auth.json" ] || die "codex 未登录（缺 ~/.codex/auth.json），先跑 codex login"
  # 共用桌面端 home：什么都不写（绝不能把 auth.json 软链到自己、也不碰桌面端的 config.toml）
  [ "$CODEX_HOME_MODE" = "shared" ] && return 0
  mkdir -p "$CODEX_HOME_DIR"
  ln -sfn "$HOME/.codex/auth.json" "$CODEX_HOME_DIR/auth.json"
  if [ ! -f "$CODEX_HOME_DIR/config.toml" ]; then
    cat > "$CODEX_HOME_DIR/config.toml" <<'EOF'
# foreman 专用 CODEX_HOME。有意不继承 ~/.codex 的 MCP / 插件 / notify / 全局 AGENTS.md：
# 执行者的角色边界经 developerInstructions 注入，模型与推理档由每次请求指定，这里只是兜底默认值。
# 会话 rollout 落在本目录 sessions/ 下 —— 不要整目录重建，否则 thread/resume 找不到历史。
model = "gpt-5.6-terra"
model_reasoning_effort = "high"

[tools]
web_search = true
EOF
  fi
}

# ---------- 硬规矩：派活目录必须等于编排者当前所在的检出目录 ----------
#
# 用户 2026-09-11：「codex-server 选择的项目目录一定要和 claude 这边的项目目录保持一致」「开出去的线程要跟编排者同一个工作目录」。
# 落法：每条线程的 cwd 永远 = 编排者的项目根（PROJECT_ROOT，Claude 的工作目录），和编排者一模一样；桌面端也据此把线程归到项目下。
# 票下的 PR（worktree / 分支 / 基线）是框架对编排者的约束，线程感觉不到框架：在它看来就是在项目目录下干一个 prompt 顶部「本轮位置」说明的活。
# 唯一的守卫：PR 的目录必须在项目根之内，否则线程以项目根为 cwd 够不着它。
orchestrator_toplevel() { git rev-parse --show-toplevel 2>/dev/null || true; }
under_project_root() { case "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1")/" in "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$PROJECT_ROOT")/"*) return 0 ;; *) return 1 ;; esac; }
same_path() { [ "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1")" = "$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$2")" ]; }
require_work_dir_in_project() {  # <目录>
  [ -z "$1" ] || under_project_root "$1" || die "硬规矩：工作目录 $1 不在编排者的项目目录 ${PROJECT_ROOT} 之内；线程的 cwd 就是项目目录，够不着它。换个落点（repo.worktree_root）或在项目内 here 登记。"
}

cmd_here() {
  local issue="" context="" gh_issue="" base=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --context) context="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
      --gh-issue) gh_issue="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      -*) die "here: 未知参数 $1" ;;
      *) [ -z "$issue" ] && issue="$1" || die "here: 多余参数 $1"; shift ;;
    esac
  done
  [ -n "$issue" ] || die "用法: foreman here <票 id> [--base <分支>] [--copy-env <文件>]... [--context <file>] [--gh-issue <n>]   把当前所在的 git 检出登记为这张票的执行目录（不建 worktree）"
  validate_id "$issue"
  init_repo_context; require_project
  local wt branch=""
  if [ "$IN_GIT" -eq 1 ]; then
    wt="$(orchestrator_toplevel)"
    branch="$(git -C "$wt" branch --show-current)"; [ -n "$branch" ] || die "当前检出处于 detached HEAD，先切到一条分支"
    [ -n "$base" ] || base="$(base_of_repo)"
  else
    wt="$PWD"; base=""
  fi
  require_work_dir_in_project "$wt"
  local dir; dir="$(issue_dir "$issue")"; mkdir -p "$dir"
  python3 - "$dir/meta.json" "$issue" "$context" "$gh_issue" <<'PY2'
import json, sys, time
path, issue, ctx, ghi = sys.argv[1:5]
try: meta = json.load(open(path))
except Exception: meta = {}
meta["issue"] = issue
meta.setdefault("created", time.strftime("%Y-%m-%dT%H:%M:%S%z"))
if ctx: meta["context"] = ctx
if ghi: meta["gh_issue"] = ghi
json.dump(meta, open(path, "w"), indent=2, ensure_ascii=False)
PY2
  pr_set "$issue" here worktree "$wt"; pr_set "$issue" here branch "$branch"; pr_set "$issue" here base "$base"; pr_set "$issue" here registered_here 1
  default_pr_name "$issue" >/dev/null
  if [ "$IN_GIT" -eq 1 ]; then echo "==> 已登记 $issue 的 PR「here」→ 当前检出 ${wt}（分支 ${branch}，base ${base}）。线程 cwd 仍是项目根 ${PROJECT_ROOT}；cleanup 对 here 只删登记不删目录。"
  else echo "==> 已登记 $issue 的工作目录「here」→ ${wt}（非 git：只有 run / status / report / check / cleanup 可用）。"; fi
}

# ---------- bootstrap ----------

cmd_bootstrap() {
  local issue="" branch="" btype="feat" bslug="" base="" context="" gh_issue="" no_install=0 copy_extra="" prname=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr) prname="$2"; shift 2 ;;
      --branch) branch="$2"; shift 2 ;;
      --type) btype="$2"; shift 2 ;;
      --slug) bslug="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --copy-env) copy_extra="$copy_extra
$2"; shift 2 ;;
      --context) context="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
      --gh-issue) gh_issue="$2"; shift 2 ;;
      --no-install) no_install=1; shift ;;
      -*) die "bootstrap: 未知参数 $1" ;;
      *) [ -z "$issue" ] && issue="$1" || die "bootstrap: 多余参数 $1"; shift ;;
    esac
  done
  [ -n "$issue" ] || die "用法: foreman bootstrap <票 id> (--branch <b> | --slug <s> [--type feat]) [--pr <名>] [--base <分支>] [--context <file>] [--gh-issue <n>] [--no-install]   给这张票建一个 PR（worktree + 分支）；一票可多次 bootstrap 建多个 PR，用 --pr 起名"
  validate_id "$issue"
  init_repo_context; require_git; require_project
  [ -n "$base" ] || base="$(base_of_repo)"

  if [ -z "$branch" ]; then
    [ -n "$bslug" ] || die "必须给 --branch 或 --slug"
    local tpl; tpl="$(cfg repo.branch_template '{type}/{yy}-{mm}-{dd}/{slug}')"
    branch="$tpl"
    branch="${branch//\{type\}/$btype}"; branch="${branch//\{slug\}/$bslug}"
    branch="${branch//\{yy\}/$(date +%y)}"; branch="${branch//\{mm\}/$(date +%m)}"; branch="${branch//\{dd\}/$(date +%d)}"
  fi
  local pattern check; pattern="$(cfg_opt repo.branch_pattern)"; check="$(cfg repo.branch_check warn)"
  if [ -n "$pattern" ] && ! printf '%s' "$branch" | grep -Eq "$pattern"; then
    if [ "$check" = "strict" ]; then die "分支名不符合项目规范 $pattern: $branch"; else echo "!! 分支名不符合项目规范（warn 模式，继续）: $branch" >&2; fi
  fi
  [ -z "$context" ] || [ -f "$context" ] || die "--context 文件不存在: $context"

  local root prefix wt dir
  root="$(expand_path_tpl "$(cfg repo.worktree_root '{repo}/.claude/worktrees')")"; prefix="$(expand_path_tpl "$(cfg repo.worktree_prefix 'foreman-')")"
  dir="$(issue_dir "$issue")"; mkdir -p "$dir"
  [ -n "$prname" ] || prname="${bslug:-${branch##*/}}"
  # 第一个 PR 的 worktree 用 <前缀><票>，之后的加 -<PR 名>，别和第一个撞路径
  if [ -f "$dir/meta.json" ] && [ -n "$(pr_names "$issue")" ] && ! printf '%s\n' "$(pr_names "$issue")" | grep -qx "$prname"; then wt="$root/$prefix$issue-$prname"; else wt="$root/$prefix$issue"; fi
  require_work_dir_in_project "$wt"

  if [ -d "$wt" ]; then
    echo "worktree 已存在，复用: $wt"
  else
    echo "==> fetch origin"
    git -C "$MAIN_REPO" fetch origin --quiet
    echo "==> 创建 worktree $wt (branch $branch, base origin/$base)"
    mkdir -p "$root"
    if git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
      git -C "$MAIN_REPO" worktree add "$wt" "$branch"
    else
      git -C "$MAIN_REPO" worktree add -b "$branch" "$wt" "origin/$base"
    fi
  fi

  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if [ -f "$MAIN_REPO/$f" ] && [ ! -f "$wt/$f" ]; then cp "$MAIN_REPO/$f" "$wt/$f"; echo "==> 复制 $f"; fi
  done <<EOF
$(cfg_opt repo.copy_env)$copy_extra
EOF

  local install; install="$(install_of_repo)"
  if [ "$no_install" -eq 0 ] && [ -n "$install" ] && [ ! -d "$wt/node_modules" ]; then
    echo "==> ${install}（首次较慢）"
    (cd "$wt" && eval "$install")
  fi

  python3 - "$dir/meta.json" "$issue" "$context" "$gh_issue" <<'PY'
import json, sys, time
path, issue, ctx, ghi = sys.argv[1:5]
try: meta = json.load(open(path))
except Exception: meta = {}
meta["issue"] = issue
meta.setdefault("created", time.strftime("%Y-%m-%dT%H:%M:%S%z"))
if ctx: meta["context"] = ctx
if ghi: meta["gh_issue"] = ghi
json.dump(meta, open(path, "w"), indent=2, ensure_ascii=False)
PY
  pr_set "$issue" "$prname" worktree "$wt"; pr_set "$issue" "$prname" branch "$branch"; pr_set "$issue" "$prname" base "$base"; pr_set "$issue" "$prname" repo_slug "$REPO_SLUG"
  default_pr_name "$issue" >/dev/null
  echo "==> ready: $issue  PR「${prname}」"
  echo "    线程 cwd 永远是项目根 ${PROJECT_ROOT}，不用 cd；这个 PR 的 worktree 会写进每轮 prompt 顶部的「本轮位置」"
  echo "    worktree: $wt"
  echo "    branch:   $branch"
  echo "    logs:     $dir"
}

# ---------- 会话执行：前台与后台走同一条路 ----------

watchdog() {
  local target="$1" limit="$2" waited=0
  while [ "$waited" -lt "$limit" ]; do
    sleep 5; waited=$((waited + 5))
    kill -0 "$target" 2>/dev/null || return 0
  done
  kill -TERM "$target" 2>/dev/null || true
}
mark_dispatched() { [ -s "$1.started" ] || date +%s > "$1.started"; }
# 一次调用的全部输入先落盘，后台执行体只认这些文件。文件族: <kind>-<n>.{argv,cwd,timeout,rmwt,engine,started,pid,rc,jsonl,stderr}
stage_call() {
  local dir="$1" kind="$2" n="$3" cwd="$4" timeout="$5" rmwt="$6" engine="$7"; shift 7
  [ "${1:-}" = "--" ] && shift
  local f="$dir/$kind-$n" a
  printf '%s' "$cwd" > "$f.cwd"; printf '%s' "$timeout" > "$f.timeout"
  printf '%s' "$rmwt" > "$f.rmwt"; printf '%s' "$engine" > "$f.engine"
  : > "$f.argv"
  for a in "$@"; do printf '%s\0' "$a" >> "$f.argv"; done
  : > "$f.jsonl"
  rm -f "$f.rc" "$f.pid"
}

exec_call() {
  local dir="$1" kind="$2" n="$3"
  local f="$dir/$kind-$n"
  [ -f "$f.argv" ] || die "没有 $kind-$n 的调用记录: $f.argv"
  local cwd timeout rmwt engine
  cwd="$(cat "$f.cwd")"; timeout="$(cat "$f.timeout")"; rmwt="$(cat "$f.rmwt" 2>/dev/null || true)"
  engine="$(cat "$f.engine" 2>/dev/null || true)"; [ -n "$engine" ] || engine=codex
  local argv=() a
  while IFS= read -r -d '' a; do argv[${#argv[@]}]="$a"; done < "$f.argv"
  mark_dispatched "$f"
  rm -f "$f.rc"
  local rc=0 pid wd
  if [ "$engine" = "pi" ]; then
    ( cd "$cwd" && exec "${argv[@]}" >"$f.jsonl" 2>"$f.stderr" ) &
  else
    # codex（app-server）：python 执行体自己写 jsonl / stderr，这里只收它的诊断输出
    ( cd "$cwd" && exec "${argv[@]}" </dev/null >"$f.driver.log" 2>&1 ) &
  fi
  pid=$!
  printf '%s' "$pid" > "$f.pid"
  [ -n "${DISPATCH_STEM:-}" ] && DISPATCHED=1
  watchdog "$pid" "$timeout" >/dev/null 2>&1 &
  wd=$!
  wait "$pid" || rc=$?
  { kill "$wd" && wait "$wd"; } >/dev/null 2>&1 || true
  printf '%s' "$rc" > "$f.rc"
  rm -f "$f.pid"
  if [ -n "$rmwt" ] && [ -d "$rmwt" ]; then
    git -C "$MAIN_REPO" worktree remove --force "$rmwt" || echo "!! 一次性副本未能删除: $rmwt" >&2
  fi
  return 0
}

# ---------- hold：codex 线程由常驻执行体占着（写锁），直到编排者 release / cleanup ----------
# 用户 2026-09-11：「foreman 管理的线程需要加锁，解锁最好是编排者明确结束工作再解锁」。每轮起一个进程、跑完就退的话，
# 轮间锁是空的，桌面端一点开线程就抢走（already has an active writer）。现在一条线程一个常驻执行体（codex_appserver.py serve），
# 每轮只往它的队列丢请求；release 文件出现才退；空闲超过 codex.hold_idle_minutes 也退（编排者会话没了不至于永久占着）。
# fd 9 的 flock 与 Python 执行体共享；仅覆盖轮次/队列账本写入，不覆盖等待 turn。
lock_runs() {
  exec 9>"$1/.runs.lock"; python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)' 9>&9
  if [ -n "${FOREMAN_SELFTEST_LOCK_READY:-}" ] && [ -n "${FOREMAN_SELFTEST_LOCK_RELEASE:-}" ]; then
    : > "$FOREMAN_SELFTEST_LOCK_READY"
    while [ ! -f "$FOREMAN_SELFTEST_LOCK_RELEASE" ]; do sleep 0.05; done
  fi
}
unlock_runs() { exec 9>&-; }

hold_start() {  # <hold 目录>，调用者已确认没有活执行体
  local hd="$1"
  rm -f "$hd/release" "$hd/hold.rc" "$hd/active.json"
  python3 -c 'import os, sys
try: os.setsid()
except OSError: pass
os.execvp(sys.argv[1], sys.argv[1:])' python3 "$PY_APPSERVER" serve "$hd" </dev/null >"$hd/driver.log" 2>&1 9>&- &
  printf '%s' "$!" > "$hd/bridge.pid"; disown >/dev/null 2>&1 || true
}

hold_dir() { printf '%s/hold-%s' "$1" "$2"; }   # <票目录> <线程名>
hold_alive() { local pid; pid="$(cat "$1/bridge.pid" 2>/dev/null || true)"; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; }
hold_cancel_queued() {  # <票目录> <hold 目录>
  local dir="$1" hd="$2" q base n
  lock_runs "$dir"
  for q in "$hd"/queue/run-*.request.json; do
    [ -f "$q" ] || continue
    base="${q##*/}"; n="${base#run-}"; n="${n%.request.json}"
    rm -f "$q" "$dir/run-$n.pid" "$dir/run-$n.questions.json"
    printf '130' > "$dir/run-$n.rc"
    printf '线程被 release，排队轮次未开跑' > "$dir/run-$n.cancelled"
    echo "  已丢弃 run #$n"
  done
  unlock_runs
}
hold_release_wait() {  # <hold 目录> [秒]
  local hd="$1" secs="${2:-$HOLD_TERM_GRACE}" pid i
  hold_alive "$hd" || return 0
  pid="$(cat "$hd/bridge.pid")"; : > "$hd/release"; kill -TERM "$pid" 2>/dev/null || true
  for i in $(seq 1 "$secs"); do hold_alive "$hd" || { echo "  已释放线程（$(basename "$hd" | sed 's/^hold-//')，TERM）"; return 0; }; sleep 1; done
  kill -KILL "$pid" 2>/dev/null || true
  while hold_alive "$hd"; do sleep 0.1; kill -KILL "$pid" 2>/dev/null || true; done
  echo "  已释放线程（$(basename "$hd" | sed 's/^hold-//')，TERM 超时后 KILL）"
}
hold_dispatch() {  # <issue> <票目录> <n> <线程名> <detach> <timeout>
  local issue="$1" dir="$2" n="$3" tname="$4" detach="$5" timeout="$6"
  local hd; hd="$(hold_dir "$dir" "$tname")"; mkdir -p "$hd/queue"
  local active_n="" tf st
  for tf in "$dir"/run-*.thread; do
    [ -f "$tf" ] && [ "$(cat "$tf")" = "$tname" ] || continue
    st="$(call_state "${tf%.thread}")"
    case "$st" in RUNNING|WAITING) active_n="${tf##*/run-}"; active_n="${active_n%.thread}"; break ;; esac
  done
  python3 - "$dir/run-$n.request.json" "$dir/run-$n.rc" "$timeout" <<'PY'
import json, sys
p, rc, t = sys.argv[1:4]; r = json.load(open(p)); r["out_rc"] = rc; r["timeout"] = int(t)
json.dump(r, open(p, "w"), ensure_ascii=False, indent=1)
PY
  rm -f "$dir/run-$n.rc"; mark_dispatched "$dir/run-$n"
  python3 - "$PY_APPSERVER" "$dir/run-$n.request.json" "$hd/queue/run-$n.request.json" <<'PY2'
import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("bridge", sys.argv[1]); bridge = importlib.util.module_from_spec(spec); spec.loader.exec_module(bridge)
bridge.write_json(sys.argv[3], json.load(open(sys.argv[2])))
PY2
  local bpid=""
  if ! hold_alive "$hd"; then
    python3 - "$dir/run-$n.request.json" "$hd/hold.json" "$(cfg codex.hold_idle_minutes 360)" <<'PY'
import json, sys
src, dst, idle = sys.argv[1:4]; r = json.load(open(src))
keep = ["codex_bin", "home", "cwd", "config_overrides", "thread_id", "developer_instructions", "sandbox", "approval_policy",
        "approvals_reviewer", "approvals", "model", "effort", "thread_name", "meta_path", "meta_thread_key", "work_dir",
        "question_timeout", "questions_path", "answer_path"]
h = {k: r[k] for k in keep if k in r}; h["idle_seconds"] = int(float(idle) * 60); h["ephemeral"] = False
json.dump(h, open(dst, "w"), ensure_ascii=False, indent=1)
PY
    hold_start "$hd"
    bpid="$(cat "$hd/bridge.pid")"
    echo "==> 常驻执行体已起：占着线程「${tname}」直到 foreman release / cleanup，或空闲 $(cfg codex.hold_idle_minutes 360) 分钟"
  fi
  [ -n "$bpid" ] || bpid="$(cat "$hd/bridge.pid" 2>/dev/null || true)"
  printf '%s' "$bpid" > "$dir/run-$n.pid"
  [ -n "${DISPATCH_STEM:-}" ] && DISPATCHED=1
  unlock_runs
  if [ -n "$active_n" ]; then
    echo "线程「${tname}」正在跑 run #${active_n}，这一轮 run #${n} 排队；要立刻纠偏：foreman steer ${issue} --from-queue ${n} --thread ${tname}"
    if [ "$(cat "$dir/run-$active_n.pr" 2>/dev/null || true)" != "$(cat "$dir/run-$n.pr" 2>/dev/null || true)" ]; then
      echo "    占着线程的是另一 PR 的轮次；另一 PR 想并行：--thread <角色>@<pr>"
    fi
  fi
  if [ "$detach" -eq 1 ]; then
    echo "==> run #$n 已进线程队列（$dir/run-$n.jsonl 持续写入）"
    echo "    进度: foreman status $issue   /   foreman tail $issue"
    echo "    收敛: foreman wait $issue --timeout 300"
    return 0
  fi
  local waited=0
  while [ ! -f "$dir/run-$n.rc" ]; do
    if ! hold_alive "$hd"; then sleep 1; [ -f "$dir/run-$n.rc" ] || printf '3' > "$dir/run-$n.rc"; break; fi
    sleep 1; waited=$((waited+1))
    [ "$waited" -le $((timeout+60)) ] || { printf '143' > "$dir/run-$n.rc"; break; }
  done
  rm -f "$dir/run-$n.pid"
}
cmd_release() {
  local issue="$1"; shift || true
  local tname=""; if [ "${1:-}" = "--thread" ]; then tname="$2"; shift 2; fi
  [ -n "$issue" ] || die "用法: foreman release <票 id> [--thread <线程名>]   释放常驻执行体占着的线程（编排者明确结束这轮工作时用；cleanup 也会做）"
  init_repo_context; require_project; require_issue "$issue"
  local dir hd any=0; dir="$(issue_dir "$issue")"
  for hd in "$dir"/hold-*; do
    [ -d "$hd" ] || continue
    [ -z "$tname" ] || [ "$(basename "$hd")" = "hold-$tname" ] || continue
    hold_alive "$hd" || continue
    any=1; hold_cancel_queued "$dir" "$hd"; hold_release_wait "$hd"
  done
  [ "$any" -eq 1 ] || echo "$issue 没有被占着的线程"
}

launch_call() {
  local issue="$1" dir="$2" kind="$3" n="$4" detach="$5"
  if [ "$detach" -eq 0 ]; then exec_call "$dir" "$kind" "$n"; return 0; fi
  # 宿主 shell 有超时上限且命令返回后可能收掉进程组，后台档必须 setsid 脱离；macOS 没有 setsid(1)，借 python3。
  python3 -c 'import os, sys
try: os.setsid()
except OSError: pass
os.execvp(sys.argv[1], sys.argv[1:])' bash "$SCRIPT_PATH" __exec "$MAIN_REPO" "$dir" "$kind" "$n" </dev/null >/dev/null 2>&1 &
  printf '%s' "$!" > "$dir/$kind-$n.pid"
  [ -n "${DISPATCH_STEM:-}" ] && DISPATCHED=1
  mark_dispatched "$dir/$kind-$n"
  disown >/dev/null 2>&1 || true
  echo "==> $kind #$n 已在后台启动（$dir/$kind-$n.jsonl 持续写入）"
  echo "    进度: foreman status $issue   /   foreman tail $issue"
  echo "    收敛: foreman wait $issue --timeout 300"
}

# ---------- 组装 codex 请求 ----------

# 开发者指令 = 角色提示词 + 批次背景（meta.context）+ 额外 --context 文件
# 本轮位置：每轮生成、放在 prompt 顶部（不放开发者指令：常驻线程的开发者指令在载入时定死，而位置每轮可能换 PR）
POSITION_WRITABLE=""   # run --writable 放开的目录，写进位置块；review 没有
position_block() {   # 只写事实（规矩在角色文件里说一遍，这里不重复）
  echo "# 本轮位置（foreman 生成，以此为准；规矩见角色文件）"; echo
  echo "- cwd：\`${PROJECT_ROOT}\`（项目根）"
  if command -v rg >/dev/null 2>&1; then echo "- 执行环境：rg: 有"
  else echo "- 执行环境：rg: 无（用 git grep）"; fi
  if [ -n "${PR_WT:-}" ]; then
    local loc="- 工作目录：\`${PR_WT}\`" extra=""
    [ -n "${PR_BRANCH:-}" ] && extra="分支 \`${PR_BRANCH}\`"
    [ -n "${PR_BASE:-}" ] && extra="${extra:+${extra}，}基线 \`origin/${PR_BASE}\`"
    [ -n "$extra" ] && loc="${loc}（${extra}）"
    echo "$loc"
  else
    echo "- 工作目录：无（只读的活；任务书没让改文件就不要改）"
  fi
  local d; for d in $POSITION_WRITABLE; do echo "- 交付目录（额外可写）：\`${d}\`"; done
}
prepend_position() {  # <prompt 文件>
  local tmp; tmp="$(mktemp)"; { position_block; printf '\n---\n\n'; cat "$1"; } > "$tmp" && mv "$tmp" "$1"
}
assemble_dev_instructions() {
  local role_file="$1" issue="$2" extra_ctx="$3" out="$4" with_context="$5"
  cat "$role_file" > "$out"
  if [ "$with_context" -eq 1 ]; then
    local ctx; ctx="$(meta_get "$issue" context)"
    if [ -n "$ctx" ] && [ -f "$ctx" ]; then printf '\n\n---\n\n# 批次背景\n\n' >> "$out"; cat "$ctx" >> "$out"; fi
  fi
  local one
  while IFS= read -r one; do
    [ -n "$one" ] && [ -f "$one" ] || continue
    printf '\n\n---\n\n' >> "$out"; cat "$one" >> "$out"
  done <<EOF
$extra_ctx
EOF
}

# write_request <out.json> <key=value ...>   值以 @file 开头表示读文件内容；@json: 开头表示原样 JSON
write_request() {
  local out="$1"; shift
  python3 - "$out" "$@" <<'PY'
import json, sys
out = sys.argv[1]
req = {}
for kv in sys.argv[2:]:
    key, _, value = kv.partition("=")
    if value.startswith("@file:"):
        req[key] = open(value[6:], encoding="utf-8").read()
    elif value.startswith("@json:"):
        req[key] = json.loads(value[6:])
    else:
        req[key] = value
json.dump(req, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
}

# 沙箱只走两处：thread/start 的 sandbox 模式 + 进程级 -c 覆盖（writable_roots / network_access）。
# **不要**再往 turn/start 传结构化 sandboxPolicy：0.153.4 实测带上它后 git 写 worktree gitdir 的 index.lock / HEAD.lock
# 一律 Operation not permitted，而且那些命令不产生 commandExecution 事件（编排者看不见失败）。见 references/codex-app-server.md。
config_overrides_json() {  # <mode> <worktree> <effort> <extra writable>
  local mode="$1" wt="$2" effort="$3" extra="$4"
  local gitdir=""; if [ "$mode" != "read-only" ] && [ "$IN_GIT" -eq 1 ]; then gitdir="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"; fi
  local net web ask; net="$(cfg codex.sandbox_network true)"; web="$(cfg codex.web_search true)"; ask="$(cfg codex.request_user_input true)"
  case "$ask" in true|false) ;; *) die "codex.request_user_input 必须是 true 或 false" ;; esac
  python3 - "$mode" "$gitdir" "$net" "$web" "$effort" "$ask" $extra <<'PY'
import json, sys
mode, gitdir, net, web, effort, ask, *extra = sys.argv[1:]
ov = [["tools.web_search", web], ["features.default_mode_request_user_input", ask]]
if effort: ov.append(["model_reasoning_effort", json.dumps(effort)])
if mode != "read-only":
    roots = [r for r in [gitdir, *extra] if r]
    ov.append(["sandbox_workspace_write.writable_roots", "[" + ", ".join(json.dumps(r) for r in roots) + "]"])
    ov.append(["sandbox_workspace_write.network_access", net])
print(json.dumps(ov))
PY
}

# 同一 PR 同时只准一条线程在跑（单执行者，框架层强制；cookie 09-11）：别的线程的轮次还在 RUNNING / QUEUED / WAITING 就拒绝派发。
# 同一线程自己的轮次在常驻执行体里排队是设计内的（QUEUED），不在此限。
require_pr_idle() {  # <issue> <PR 名> <本线程名>
  local dir f k th st; dir="$(issue_dir "$1")"
  for f in "$dir"/run-*.pr "$dir"/review-*.pr; do
    [ -f "$f" ] || continue
    [ "$(cat "$f")" = "$2" ] || continue
    k="${f##*/}"; k="${k%.pr}"
    if [ -f "$dir/$k.thread" ]; then th="$(cat "$dir/$k.thread")"; else case "$k" in review-*) th="$k" ;; *) th=implement ;; esac; fi
    st="$(call_state "$dir/$k")"
    if [ "$th" = "$3" ] && [ "$st" != CHECKING ]; then continue; fi
    case "$st" in RUNNING|QUEUED|WAITING|CHECKING) die "PR「$2」上线程 '${th}' 的 $k 还在 ${st}：同一 PR 同时只准一条线程在跑（单执行者）。等它结束（foreman wait / status），或 release 后再派" ;; esac
  done
}

# ---------- run ----------

# 线程名：按本机 config.toml 的 codex.thread_name 模板，{ids} = 所有相关 issue / PR 号（+ 连接），{title} = 具体工作内容
thread_ids() {
  local issue="$1" gh pr out
  gh="$(meta_get "$issue" gh_issue)"; pr="$(pr_gh_numbers "$issue" | tr ' ' '+')"; [ -n "$pr" ] || pr="$(meta_get "$issue" pr_number)"; [ -n "$pr" ] || pr="$(meta_get "$issue" pr)"
  out="$issue"
  [ -n "$gh" ] && [ "$gh" != "$issue" ] && out="${out}+${gh}"
  [ -n "$pr" ] && [ "$pr" != "$issue" ] && [ "$pr" != "$gh" ] && out="${out}+${pr}"
  printf '%s' "$out"
}
prompt_title() {   # 任务书首个 markdown 标题，去掉 # 与前导票号，截 60 字
  local f="$1" t
  t="$(grep -m1 -E '^#{1,3} ' "$f" 2>/dev/null | sed -E 's/^#{1,3} +//; s/^#?[0-9A-Za-z-]+[：: ]+//' | cut -c1-60)"
  printf '%s' "$t"
}
build_thread_name() {   # $1 issue $2 显式标题 $3 任务书路径 $4 阶段默认
  local issue="$1" title="$2" f="$3" dflt="$4"
  [ -n "$title" ] || title="$(prompt_title "$f")"
  [ -n "$title" ] || { title="$dflt"; echo "!! 线程名回落到阶段词「${dflt}」：下次用 --title 写真实工作内容（返的是什么 / 审的是什么）" >&2; }
  local tpl; tpl="$(gcfg codex.thread_name 'foreman {ids}: {title}')"
  case "$tpl" in *"{ids}"*"{title}"*|*"{title}"*"{ids}"*) ;; *) die "本机 config.toml 的 codex.thread_name 必须同时含 {ids} 和 {title}（现在是: ${tpl}）" ;; esac
  local ids; ids="$(thread_ids "$issue")"; tpl="${tpl//\{ids\}/$ids}"; tpl="${tpl//\{title\}/$title}"
  printf '%s' "$tpl"
}

claude_apply_steers() {  # <票目录> <线程> <prompt>
  local dir="$1" tname="$2" prompt="$3" inbox="$1/hold-$2/steer" pending=()
  CLAUDE_STEER_INBOX=""; CLAUDE_STEER_PENDING=()
  [ -d "$inbox" ] || return 0
  while IFS= read -r path; do [ -n "$path" ] && pending[${#pending[@]}]="$path"; done <<EOF
$(find "$inbox" -maxdepth 1 -name 'claude-*.json' -type f -print 2>/dev/null | sort)
EOF
  [ ${#pending[@]} -gt 0 ] || return 0
  python3 - "$prompt" "${pending[@]}" <<'PY'
import json, pathlib, sys
prompt, *paths = sys.argv[1:]
messages = [json.loads(pathlib.Path(path).read_text(encoding="utf-8"))["text"] for path in paths]
target = pathlib.Path(prompt)
target.write_text("## 编排者追加说明\n\n" + "\n\n".join(messages) + "\n\n---\n\n" + target.read_text(encoding="utf-8"), encoding="utf-8")
PY
  CLAUDE_STEER_INBOX="$inbox"; CLAUDE_STEER_PENDING=("${pending[@]}")
}

claude_mark_steers_sent() {
  [ ${#CLAUDE_STEER_PENDING[@]} -gt 0 ] || return 0
  python3 - "$CLAUDE_STEER_INBOX" "${CLAUDE_STEER_PENDING[@]}" <<'PY'
import os, pathlib, sys
inbox, *paths = sys.argv[1:]
sent = pathlib.Path(inbox) / "sent"; sent.mkdir(parents=True, exist_ok=True)
for path in paths:
    os.replace(path, sent / pathlib.Path(path).name)
PY
  CLAUDE_STEER_INBOX=""; CLAUDE_STEER_PENDING=()
}

cmd_run() {
  local issue="" prompt_file="" role="" closeout=0 engine="" model="" effort="" detach=0 timeout=1800 title="" tname="" prname=""
  local writable="" extra_ctx="" thinking="" qtimeout="" full_access_reason="" full_access_flag=0 no_check=0
  local max_turns="" max_budget_usd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --prompt) prompt_file="$2"; shift 2 ;;
      --full-access) full_access_flag=1; full_access_reason="${2:-}"; shift 2 ;;
      --role) role="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --thread) tname="$2"; shift 2 ;;
      --pr) prname="$2"; shift 2 ;;
      --closeout) closeout=1; shift ;;
      --engine) engine="$2"; shift 2 ;;
      --model) model="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;;
      --thinking) thinking="$2"; shift 2 ;;
      --detach) detach=1; shift ;;
      --timeout) timeout="$2"; shift 2 ;;
      --no-check) no_check=1; shift ;;
      --writable) writable="$writable $2"; shift 2 ;;
      --new-thread|--new-session) die "run: --new-thread 已取消。同名线程不覆盖：要重开就 foreman release <id> --thread <名> 放掉旧的，再 run --thread <新名> 另起（旧线程的账本保留）" ;;
      --question-timeout) qtimeout="$2"; shift 2 ;;
      --max-turns) max_turns="$2"; shift 2 ;;
      --max-budget-usd) max_budget_usd="$2"; shift 2 ;;
      --context) extra_ctx="$extra_ctx$2
"; shift 2 ;;
      -*) die "run: 未知参数 $1" ;;
      *) [ -z "$issue" ] && issue="$1" || die "run: 多余参数 $1"; shift ;;
    esac
  done
  [ -n "$issue" ] || die "用法: foreman run <票 id> --prompt <file> [--role <名>] [--thread <线程名>] [--closeout] [--engine codex|pi|claude] [--model m] [--effort e] [--detach] [--timeout 1800] [--no-check] [--writable <dir>] [--context <file>] [--full-access \"<原话>\"]"
  [ -n "$prompt_file" ] || die "必须给 --prompt <file>"
  [ -f "$prompt_file" ] || die "prompt 文件不存在: $prompt_file"
  # 完全权限的口子：只有用户在本会话明确要求时才用，且必须把用户原话作为理由传进来（进日志、进摘要横幅）。
  init_repo_context; require_project; require_issue "$issue"
  require_roles_confirmed
  local full_access=0
  if [ "$full_access_flag" -eq 1 ] && [ -z "$full_access_reason" ]; then
    die "run: --full-access 必须带用户明确要求的原话作为理由（会进日志与摘要横幅）；用户没有明确要求就不要用这个口子"
  fi
  if [ -n "$full_access_reason" ]; then
    full_access=1
    echo "!! 本轮按用户明确要求使用完全权限（无沙箱、无审批）。理由记录: $full_access_reason" >&2
  fi

  local dir wt; dir="$(issue_dir "$issue")"
  lock_runs "$dir"
  resolve_pr "$issue" "$prname"; wt="$PR_WT"
  [ -z "$wt" ] || [ -d "$wt" ] || die "PR「${PR_NAME}」的 worktree 不存在（被清理过？）: $wt"
  require_work_dir_in_project "$wt"

  # ---- 对象模型：票下若干线程，每条线程建立时绑定一个角色和一个引擎（用户 09-11） ----
  # 线程名：显式 --thread > 收尾所在线程 > 按角色命名；非默认 PR 自动加 @<pr>，避免多 PR 串行排队。
  if [ -z "$tname" ]; then
    if [ "$closeout" -eq 1 ]; then
      if [ -n "$role" ]; then tname="$role"
      else
        tname="$(last_implementation_thread "$dir" "$PR_NAME")"
        [ -n "$tname" ] || die "PR「${PR_NAME}」没有 implement / mechanical 实现轮；closeout 请显式给 --thread <实现线程>"
      fi
    else
      local desired_role existing_thread default_pr; desired_role="${role:-implement}"
      existing_thread="$(thread_for_pr_role "$dir" "$PR_NAME" "$desired_role")"
      if [ -n "$existing_thread" ]; then tname="$existing_thread"
      else default_pr="$(default_pr_name "$issue")"; tname="$desired_role"; [ "$PR_NAME" = "$default_pr" ] || tname="${desired_role}@${PR_NAME}"; fi
    fi
  fi
  validate_thread_id "$tname"
  require_pr_idle "$issue" "$PR_NAME" "$tname"
  local rec_role rec_engine; rec_role="$(thread_get "$issue" "$tname" role)"; rec_engine="$(thread_get "$issue" "$tname" engine)"
  if [ -n "$rec_role" ]; then
    # 已有线程：角色与引擎以线程记录为准；显式给的不一致就拒绝（角色不中途换，跨引擎绝不共用一条线程）
    if [ -n "$role" ] && [ "$role" != "$rec_role" ]; then die "线程 '${tname}' 的角色是 ${rec_role}，线程建立时就绑定了：换角色请 --thread <别的名字> 另起一条"; fi
    if [ -n "$engine" ] && [ "$engine" != "$rec_engine" ]; then die "线程 '${tname}' 是 ${rec_engine} 引擎的，跨引擎不能共用一条线程：换引擎请 --thread <别的名字> 另起一条"; fi
    role="$rec_role"; engine="$rec_engine"
  else
    [ -n "$role" ] || role="implement"
  fi
  require_role "$role"
  local rf_role; rf_role="$role"
  [ -n "$engine" ] || engine="$(role_cfg "$role" engine)"; [ -n "$engine" ] || engine="$(cfg engines.default codex)"
  case "$engine" in codex|pi|claude) ;; *) die "run: --engine 只能是 codex / pi / claude（收到 '$engine'）" ;; esac
  if [ "$engine" != "claude" ] && [ -n "$max_turns$max_budget_usd" ]; then die "run: --max-turns / --max-budget-usd 只对 claude 引擎有效"; fi
  if [ "$engine" = "claude" ]; then
    local claude_model claude_effort; claude_model="$(claude_role_cfg "$role" model)"; claude_effort="$(claude_role_cfg "$role" effort)"
    [ -n "$claude_model" ] && [ -n "$claude_effort" ] || die "角色 ${role} 没有 claude 档位，在 [roles.${role}.claude] 配 model / effort"
    [ -n "$model" ] || model="$claude_model"; [ -n "$effort" ] || effort="$claude_effort"
    case "$model" in sonnet|fable|opus|best|haiku|claude-*) ;; *) die "run: Claude --model 只接受 sonnet / fable / opus / best / haiku 或 claude- 开头的完整模型 id（收到 '$model'）" ;; esac
    case "$effort" in low|medium|high|xhigh|max) ;; *) die "run: Claude --effort 只接受 low / medium / high / xhigh / max（收到 '$effort'）" ;; esac
    require_claude_slot
    [ -n "$max_turns" ] || max_turns="$(cfg claude.max_turns 80)"
    [ -n "$max_budget_usd" ] || max_budget_usd="$(cfg claude.max_budget_usd 5)"
    case "$max_turns" in ''|*[!0-9]*|0) die "run: --max-turns 必须是正整数" ;; esac
    python3 -c 'import sys; assert float(sys.argv[1]) > 0' "$max_budget_usd" 2>/dev/null || die "run: --max-budget-usd 必须是正数"
  else
    [ -n "$model" ] || model="$(role_cfg "$role" model)"
    [ -n "$effort" ] || effort="$(role_cfg "$role" effort)"
  fi

  local n; n=$(( $(latest_n "$dir" run) + 1 ))
  local orig_prompt; orig_prompt="$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$prompt_file")"
  if [ "$closeout" -eq 1 ]; then
    # 收尾轮：prompt = 收尾阶段契约（skill 持有，只给实现者）+ 编排者写的收尾任务书
    local tmp_prompt; tmp_prompt="$(mktemp)"
    { cat "$ASSETS_DIR/CLOSEOUT.md"; cat "$prompt_file"; } > "$tmp_prompt"
    mv "$tmp_prompt" "$dir/run-$n.prompt.md"
  elif [ "$(cd "$(dirname "$prompt_file")" && pwd)/$(basename "$prompt_file")" != "$dir/run-$n.prompt.md" ]; then
    cp "$prompt_file" "$dir/run-$n.prompt.md"
  fi
  prompt_file="$dir/run-$n.prompt.md"
  [ "$engine" != "claude" ] || claude_apply_steers "$dir" "$tname" "$prompt_file"
  POSITION_WRITABLE="$writable"; prepend_position "$prompt_file"; POSITION_WRITABLE=""
  # run-N.role 给 summarize 选探针放行表：收尾轮写 closeout（阶段标记，放行对自己 PR 的 push / gh 写），其它写角色名
  if [ "$closeout" -eq 1 ]; then printf 'closeout' > "$dir/run-$n.role"; else printf '%s' "$role" > "$dir/run-$n.role"; fi
  if [ "$full_access" -eq 1 ]; then printf '%s' "$full_access_reason" > "$dir/run-$n.full-access"; else rm -f "$dir/run-$n.full-access"; fi
  printf '%s' "$tname" > "$dir/run-$n.thread"
  thread_set "$issue" "$tname" engine "$engine"; thread_set "$issue" "$tname" role "$role"; thread_set "$issue" "$tname" kind run; thread_set "$issue" "$tname" runs "run-$n"
  # 只看不改的角色：起跑前记一份 worktree 的 git status，report 时比对。事件流里的 fileChange 只有 apply_patch 才有，
  # 执行者用 heredoc / 脚本写文件探针看不见，所以这道用 git 事实兜底。
  case "$role" in review|accept|research) [ -n "$wt" ] && [ "$IN_GIT" -eq 1 ] && git -C "$wt" status --porcelain > "$dir/run-$n.wt-before" 2>/dev/null || true ;; esac

  case "$engine" in
    codex)
      [ -z "$thinking" ] || die "run: --thinking 是 pi 档的开关；codex 用 --effort"
      ensure_codex_home
      local role_file
      role_file="$(role_prompt_file "$rf_role")"
      assemble_dev_instructions "$role_file" "$issue" "$extra_ctx" "$dir/run-$n.dev.md" 1
      # 上一轮若是 --detach 且没走过 wait，thread_id 已由执行体直接写进 meta；这里只需读
      local thread; thread="$(thread_get "$issue" "$tname" ref)"
      [ -n "$qtimeout" ] || qtimeout="$(cfg codex.question_timeout 1800)"
      local thread_name; thread_name="$(build_thread_name "$issue" "$title" "$orig_prompt" "$( [ "$closeout" -eq 1 ] && echo 收尾 || { [ "$n" -gt 1 ] && echo "返工 第${n}轮" || echo 实现; } )")"
      local run_home="$CODEX_HOME_DIR"
      if [ -n "$thread" ]; then
        run_home="$(home_for_thread "$issue" "$tname" "$thread")"
        [ "$run_home" = "$CODEX_HOME_DIR" ] || echo "    （续线程用它创建时的 CODEX_HOME=${run_home}，与当前模式 ${CODEX_HOME_MODE} 不同；新线程才按当前模式）"
      else
        thread_set "$issue" "$tname" home "$CODEX_HOME_DIR"
      fi
      if [ -n "$thread" ]; then echo "==> codex run #$n  issue=$issue  线程=$tname role=$role$([ "$closeout" -eq 1 ] && echo '(收尾)')  续 ${thread:0:8}…  model=$model effort=$effort"
      else echo "==> codex run #$n  issue=$issue  线程=$tname role=$role$([ "$closeout" -eq 1 ] && echo '(收尾)')  新开  model=$model effort=$effort"; fi
      local sb ap ar; sb="workspace-write"; ap="$(cfg codex.approval_policy on-request)"; ar="$(cfg codex.approvals_reviewer auto_review)"   # review 之外的角色一律 workspace-write + 替我审批（cookie 09-11）；复审只看 diff，固定 read-only；完全权限只走 --full-access
      if [ "$full_access" -eq 1 ]; then sb="danger-full-access"; ap="never"; ar=""; fi
      write_request "$dir/run-$n.request.json" \
        "codex_bin=$CODEX_BIN" "home=$run_home" "cwd=$PROJECT_ROOT" "work_dir=$wt" \
        "thread_name=$thread_name" "title=$title" "prompt_source=$orig_prompt" \
        "sandbox=$sb" "user_explicitly_approved_full_access=@json:$([ "$full_access" -eq 1 ] && echo true || echo false)" "full_access_reason=$full_access_reason" \
        "config_overrides=@json:$(config_overrides_json workspace-write "$wt" "$effort" "$wt $writable")" \
        "approval_policy=$ap" "approvals_reviewer=$ar" "approvals=$(cfg codex.approvals decline)" \
        "model=$model" "effort=$effort" \
        "developer_instructions=@file:$dir/run-$n.dev.md" "prompt=@file:$prompt_file" \
        "thread_id=$thread" "ephemeral=@json:false" \
        "out_jsonl=$dir/run-$n.jsonl" "out_stderr=$dir/run-$n.stderr" "out_last=$dir/run-$n.last.md" \
        "meta_path=$dir/meta.json" "meta_thread_key=threads.$tname.ref" \
        "questions_path=$dir/run-$n.questions.json" "answer_path=$dir/run-$n.answer.json" \
        "question_timeout=@json:$qtimeout"
      printf '%s' "$PR_NAME" > "$dir/run-$n.pr"
      echo "    cwd=$PROJECT_ROOT  PR=${PR_NAME:-无}  工作目录=${wt:-无}  timeout=${timeout}s  CODEX_HOME=$run_home"
      stage_call "$dir" run "$n" "$wt" "$timeout" "" codex -- python3 "$PY_APPSERVER" run "$dir/run-$n.request.json"
      ;;
    pi)
      command -v pi >/dev/null || die "pi 未安装（可选执行器）。装法见 references/pi-cli.md，或改用默认的 codex"
      [ -z "$writable" ] || die "run: --writable 只对 codex 有意义（pi 没有沙箱）"
      local role_file
      role_file="$(role_prompt_file "$rf_role")"
      thread_set "$issue" "$tname" ref "${issue}-${tname}"
      set -- pi -p --mode json --session-id "${issue}-${tname}" --append-system-prompt "$role_file"
      local ctx; ctx="$(meta_get "$issue" context)"
      [ -z "$ctx" ] || set -- "$@" --append-system-prompt "$ctx"
      if [ -n "$extra_ctx" ]; then
        while IFS= read -r line; do [ -n "$line" ] && set -- "$@" --append-system-prompt "$line"; done <<EOF
$extra_ctx
EOF
      fi
      [ -z "$model" ] || set -- "$@" --model "$model"
      [ -z "$thinking" ] || set -- "$@" --thinking "$thinking"
      printf '%s' "$PR_NAME" > "$dir/run-$n.pr"
      echo "==> pi run #$n  issue=$issue  role=$role  cwd=$PROJECT_ROOT  工作目录=${wt:-无}  timeout=${timeout}s"
      stage_call "$dir" run "$n" "$wt" "$timeout" "" pi -- "$@" "$(cat "$prompt_file")"
      ;;
    claude)
      [ -z "$thinking" ] || die "run: --thinking 是 pi 档的开关；claude 用 --effort"
      local role_file thread thread_json thread_name roots_json
      role_file="$(role_prompt_file "$rf_role")"
      assemble_dev_instructions "$role_file" "$issue" "$extra_ctx" "$dir/run-$n.dev.md" 1
      thread="$(thread_get "$issue" "$tname" ref)"
      if [ -n "$thread" ]; then thread_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$thread")"; else thread_json=null; fi
      [ -n "$qtimeout" ] || qtimeout="$(cfg claude.question_timeout 1800)"
      thread_name="$(build_thread_name "$issue" "$title" "$orig_prompt" "$( [ "$closeout" -eq 1 ] && echo 收尾 || { [ "$n" -gt 1 ] && echo "返工 第${n}轮" || echo 实现; } )")"
      roots_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' $writable)"
      if [ -n "$thread" ]; then echo "==> claude run #$n  issue=$issue  线程=$tname role=$role$([ "$closeout" -eq 1 ] && echo '(收尾)')  续 ${thread:0:8}…  model=$model effort=$effort"
      else echo "==> claude run #$n  issue=$issue  线程=$tname role=$role$([ "$closeout" -eq 1 ] && echo '(收尾)')  新开  model=$model effort=$effort"; fi
      write_request "$dir/run-$n.request.json" \
        "issue=$issue" "thread=$tname" "role=$role" "model=$model" "effort=$effort" \
        "prompt_path=$prompt_file" "dev_instructions_path=$dir/run-$n.dev.md" \
        "cwd=$PROJECT_ROOT" "work_dir=$wt" "writable_roots=@json:$roots_json" "session_id=@json:$thread_json" \
        "timeout=@json:$timeout" "questions_path=$dir/run-$n.questions.json" "answer_path=$dir/run-$n.answer.json" \
        "question_timeout=@json:$qtimeout" "user_explicitly_approved_full_access=@json:$([ "$full_access" -eq 1 ] && echo true || echo false)" \
        "full_access_reason=$full_access_reason" "closeout=@json:$([ "$closeout" -eq 1 ] && echo true || echo false)" \
        "jsonl_path=$dir/run-$n.jsonl" "stderr_path=$dir/run-$n.stderr" "last_path=$dir/run-$n.last.md" "claude_json_path=$dir/run-$n.claude.json" \
        "thread_title=$thread_name" "meta_path=$dir/meta.json" \
        "max_turns=@json:$max_turns" "max_budget_usd=@json:$max_budget_usd"
      printf '%s' "$PR_NAME" > "$dir/run-$n.pr"
      echo "    cwd=$PROJECT_ROOT  PR=${PR_NAME:-无}  工作目录=${wt:-无}  timeout=${timeout}s"
      stage_call "$dir" run "$n" "$wt" "$timeout" "" claude -- python3 "$PY_CLAUDE" run "$dir/run-$n.request.json"
      claude_mark_steers_sent
      ;;
    *) die "run: --engine 只能是 codex / pi / claude（收到 '$engine'）" ;;
  esac

  prepare_auto_check "$dir/run-$n" "$role" "$no_check"

  # 已在跑的 hold 只是追加队列，不新增并发线程。
  case "$engine" in
    codex) hold_alive "$(hold_dir "$dir" "$tname")" || require_concurrency_slot ;;
  esac
  DISPATCH_STEM="$dir/run-$n"; DISPATCHED=0
  trap '[ "${DISPATCHED:-1}" -eq 1 ] || cleanup_failed_dispatch "${DISPATCH_STEM:-}"' EXIT
  start_auto_check "$dir" run "$n" "$wt"
  if [ "$engine" = "codex" ]; then
    hold_dispatch "$issue" "$dir" "$n" "$tname" "$detach" "$timeout"
  else
    unlock_runs
    launch_call "$issue" "$dir" run "$n" "$detach"
  fi
  DISPATCHED=1; DISPATCH_STEM=""; trap - EXIT
  if [ "$detach" -eq 0 ]; then
    wait_auto_check "$dir/run-$n"
    local rc; rc="$(cat "$dir/run-$n.rc" 2>/dev/null || echo '?')"
    [ "$rc" = "0" ] || echo "!! 执行体非零退出 rc=${rc}（1=turn failed 2=被中断 3=没跑起来 4=执行器不可用 5=线程被桌面端占着 143=超时被杀）" >&2
    cmd_report_inner "$issue" "$n" || true
    case "$rc" in 0) return 0 ;; [0-9]*) return "$rc" ;; *) return 1 ;; esac   # 前台跑完把执行体退出码传出去
  fi
}

# ---------- review ----------

# 复审关注点：编排者用 --prompt 给；不给就只按任务书核对（角色文件不含「看什么」）
append_review_focus() {
  local out="$1" focus="$2"
  if [ -n "$focus" ]; then
    { printf '\n## 需求口径与关注点（编排者给的，按这个看）\n\n'; cat "$focus"; printf '\n'; } >> "$out"
  else
    printf '\n编排者没有给需求口径与关注点：按角色文件的默认清单看；需求边界以任务书为准，任务书没写的不当遗漏报。\n' >> "$out"
  fi
}

cmd_review() {
  local issue="" model="" effort="" timeout=1800 detach=0 engine="" focus="" rtitle="" prname=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --model) model="$2"; shift 2 ;;
      --effort) effort="$2"; shift 2 ;;
      --engine) engine="$2"; shift 2 ;;
      --prompt) focus="$2"; shift 2 ;;
      --title) rtitle="$2"; shift 2 ;;
      --pr) prname="$2"; shift 2 ;;
      --detach) detach=1; shift ;;
      --timeout) timeout="$2"; shift 2 ;;
      -*) die "review: 未知参数 $1" ;;
      *) [ -z "$issue" ] && issue="$1" || die "review: 多余参数 $1"; shift ;;
    esac
  done
  [ -n "$issue" ] || die "用法: foreman review <票 id> [--prompt REVIEW.md] [--engine codex|pi|claude] [--model m] [--effort e] [--detach] [--timeout 1800]"
  if [ -n "$focus" ]; then [ -f "$focus" ] || die "review: --prompt 文件不存在: ${focus}"; focus="$(cd "$(dirname "$focus")" && pwd)/$(basename "$focus")"; fi
  init_repo_context; require_git; require_project; require_issue "$issue"
  require_roles_confirmed
  require_role review
  local review_role_file
  review_role_file="$(role_prompt_file review)"
  [ -n "$engine" ] || engine="$(role_cfg review engine)"; [ -n "$engine" ] || engine="$(cfg engines.default codex)"
  case "$engine" in codex|pi|claude) ;; *) die "review: --engine 只能是 codex / pi / claude（收到 '$engine'）" ;; esac
  if [ "$engine" = claude ]; then
    [ -n "$model" ] || model="$(claude_role_cfg review model)"
    [ -n "$effort" ] || effort="$(claude_role_cfg review effort)"
    [ -n "$model" ] && [ -n "$effort" ] || die "角色 review 没有 claude 档位，在 [roles.review.claude] 配 model / effort"
    case "$model" in sonnet|fable|opus|best|haiku|claude-*) ;; *) die "review: Claude --model 非法（收到 '$model'）" ;; esac
    case "$effort" in low|medium|high|xhigh|max) ;; *) die "review: Claude --effort 非法（收到 '$effort'）" ;; esac
  else
    [ -n "$model" ] || model="$(role_cfg review model)"
    [ -n "$effort" ] || effort="$(role_cfg review effort)"
  fi
  # 硬规矩（用户 09-11）：复审永远是新线程（ephemeral、thread_id 为空），绝不沿用实现或收尾的会话

  local dir wt base; dir="$(issue_dir "$issue")"; resolve_pr "$issue" "$prname"; wt="$PR_WT"; base="$PR_BASE"
  [ -n "$wt" ] || die "review: 票 $issue 没有登记 PR / 工作目录，没有 diff 可审"
  [ -d "$wt" ] || die "worktree 不存在: $wt"
  local unclean; unclean="$(git -C "$wt" status --porcelain | grep -v '^??' || true)"
  [ -z "$unclean" ] || die "$issue 的 worktree 有未提交的已跟踪改动，先让它提交再审:
$unclean"


  lock_runs "$dir"
  local last; last="$(latest_n "$dir" run)"
  local n; n=$(( $(latest_n "$dir" review) + 1 ))
  require_pr_idle "$issue" "$PR_NAME" "review-$n"

  local inbox
  if [ "$engine" = "codex" ] || [ "$engine" = "claude" ]; then
    inbox="$dir/review-$n-inputs"; rm -rf "$inbox"; mkdir -p "$inbox"
  else
    local rwt; rwt="$(cfg repo.worktree_root)/$(cfg repo.worktree_prefix '')review-$issue"
    [ ! -d "$rwt" ] || git -C "$MAIN_REPO" worktree remove --force "$rwt"
    local head; head="$(git -C "$wt" rev-parse HEAD)"
    echo "==> 建一次性复审副本 $rwt @ ${head:0:8}"
    git -C "$MAIN_REPO" worktree add --detach --quiet "$rwt" "$head"
    inbox="$rwt"
    git -C "$wt" ls-files --others --exclude-standard | while IFS= read -r f; do
      [ -n "$f" ] || continue; mkdir -p "$rwt/$(dirname "$f")"; cp "$wt/$f" "$rwt/$f"
    done
  fi

  git -C "$wt" rev-parse --verify -q "origin/$base" >/dev/null || die "review: 基线 origin/${base} 在本地不存在，先 git -C '$wt' fetch origin ${base}"
  git -C "$wt" diff "origin/$base"...HEAD > "$inbox/REVIEW_DIFF.patch"
  if [ "$last" -gt 0 ]; then cp "$dir/run-$last.prompt.md" "$inbox/REVIEW_BRIEF.md"; else echo "(没有留存任务书)" > "$inbox/REVIEW_BRIEF.md"; fi
  if [ -f "$dir/run-$last.report.md" ]; then cp "$dir/run-$last.report.md" "$inbox/REVIEW_REPORT.md"
  elif [ -s "$dir/run-$last.last.md" ]; then cp "$dir/run-$last.last.md" "$inbox/REVIEW_REPORT.md"
  elif [ -f "$dir/run-$last.jsonl" ]; then python3 "$PY_SUMMARIZE" --final "$dir/run-$last.jsonl" > "$inbox/REVIEW_REPORT.md"
  else echo "(没有留存交付报告)" > "$inbox/REVIEW_REPORT.md"; fi

  echo "==> $engine 复审 #$n  model=$model effort=$effort  diff=$(wc -l < "$inbox/REVIEW_DIFF.patch") 行"
  printf 'review' > "$dir/review-$n.role"; printf '%s' "$PR_NAME" > "$dir/review-$n.pr"
  [ "$IN_GIT" -eq 1 ] && git -C "$wt" status --porcelain > "$dir/review-$n.wt-before" 2>/dev/null || true

  if [ "$engine" = "codex" ]; then
    ensure_codex_home
    cp "$review_role_file" "$dir/review-$n.dev.md"
    cat > "$dir/review-$n.prompt.md" <<EOF
对这次改动做对抗性复审。

你在被审 worktree 本身的只读沙箱里：任何写操作都会被 OS 拒绝（不是你的错，也不必重试），
而且没有 shell 网络。需要查外部资料时用你的联网搜索工具，不要 curl。

你不判「需求做对没有」（那是编排者的活）；你看的是这次改动有没有破坏项目约定、仓库约定、最佳实践，
给意见和依据，采不采纳由编排者拍板。prompt 里编排者给的需求口径是最重要的输入。

输入（绝对路径，直接读）：
  改动 diff:              $inbox/REVIEW_DIFF.patch
  任务书:                 $inbox/REVIEW_BRIEF.md
  被审 agent 的交付报告:  $inbox/REVIEW_REPORT.md
线程 cwd 是项目根；被审 worktree 以本轮位置块的工作目录为准，可以读原始代码与约定文件做上下文。

环境提示：只读沙箱下 macOS 自带 git 会往 stderr 打 \`couldn't create cache file '/tmp/xcrun_db-…'\`，那是 xcrun 缓存写不了，不是 git 命令失败，按 stdout 判断即可。

按你的输出格式给意见。
EOF
    append_review_focus "$dir/review-$n.prompt.md" "$focus"; prepend_position "$dir/review-$n.prompt.md"
    thread_set "$issue" "review-$n" engine codex; thread_set "$issue" "review-$n" role review; thread_set "$issue" "review-$n" kind review; thread_set "$issue" "review-$n" ephemeral "@json:true" >/dev/null 2>&1 || true; thread_set "$issue" "review-$n" runs "review-$n"
    write_request "$dir/review-$n.request.json" \
      "codex_bin=$CODEX_BIN" "home=$CODEX_HOME_DIR" "cwd=$PROJECT_ROOT" "work_dir=$wt" \
      "thread_name=$(build_thread_name "$issue" "$rtitle" /dev/null "复审 #$n")" \
      "sandbox=read-only" \
      "config_overrides=@json:$(config_overrides_json read-only "$wt" "$effort" "")" \
      "approval_policy=$(cfg codex.approval_policy on-request)" "approvals_reviewer=$(cfg codex.approvals_reviewer auto_review)" "approvals=decline" \
      "model=$model" "effort=$effort" \
      "developer_instructions=@file:$dir/review-$n.dev.md" "prompt=@file:$dir/review-$n.prompt.md" \
      "thread_id=" "ephemeral=@json:true" \
      "meta_path=$dir/meta.json" "meta_thread_key=threads.review-$n.ref" \
      "out_jsonl=$dir/review-$n.jsonl" "out_stderr=$dir/review-$n.stderr" "out_last=$dir/review-$n.last.md" \
      "questions_path=$dir/review-$n.questions.json" "answer_path=$dir/review-$n.answer.json" \
      "question_timeout=@json:0"
    stage_call "$dir" review "$n" "$wt" "$timeout" "" codex -- python3 "$PY_APPSERVER" run "$dir/review-$n.request.json"
  elif [ "$engine" = "claude" ]; then
    assemble_dev_instructions "$review_role_file" "$issue" "" "$dir/review-$n.dev.md" 1
    cat > "$dir/review-$n.prompt.md" <<EOF
对这次改动做对抗性复审。

你在只读工具集里，只能用 Read / Glob / Grep；没有 Bash / Write / Edit / Agent。
diff、任务书、交付报告与被审 worktree 里的上下文都用 Read 读，不要尝试写文件或调用 shell。

你不判「需求做对没有」；你看的是这次改动有没有破坏项目约定、仓库约定、最佳实践，
给意见和依据，采不采纳由编排者拍板。

输入（绝对路径，直接用 Read 读）：
  改动 diff:              $inbox/REVIEW_DIFF.patch
  任务书:                 $inbox/REVIEW_BRIEF.md
  被审 agent 的交付报告:  $inbox/REVIEW_REPORT.md
线程 cwd 是项目根；被审 worktree 以本轮位置块的工作目录为准。

按你的输出格式给意见。
EOF
    append_review_focus "$dir/review-$n.prompt.md" "$focus"; prepend_position "$dir/review-$n.prompt.md"
    thread_set "$issue" "review-$n" engine claude; thread_set "$issue" "review-$n" role review; thread_set "$issue" "review-$n" kind review; thread_set "$issue" "review-$n" ephemeral "@json:true" >/dev/null 2>&1 || true; thread_set "$issue" "review-$n" runs "review-$n"
    local claude_max_turns claude_max_budget
    claude_max_turns="$(cfg claude.max_turns 80)"; claude_max_budget="$(cfg claude.max_budget_usd 5)"
    write_request "$dir/review-$n.request.json" \
      "issue=$issue" "thread=review-$n" "role=review" "model=$model" "effort=$effort" \
      "prompt_path=$dir/review-$n.prompt.md" "dev_instructions_path=$dir/review-$n.dev.md" \
      "cwd=$PROJECT_ROOT" "work_dir=$wt" "writable_roots=@json:[]" "session_id=@json:null" \
      "timeout=@json:$timeout" "questions_path=$dir/review-$n.questions.json" "answer_path=$dir/review-$n.answer.json" \
      "question_timeout=@json:0" "user_explicitly_approved_full_access=@json:false" "full_access_reason=" \
      "closeout=@json:false" "review_readonly=tools_only" "inherit_user_mcp=@json:false" \
      "persist_session=@json:false" "tools=Read,Glob,Grep" "no_session_persistence=@json:true" \
      "jsonl_path=$dir/review-$n.jsonl" "stderr_path=$dir/review-$n.stderr" "last_path=$dir/review-$n.last.md" "claude_json_path=$dir/review-$n.claude.json" \
      "thread_title=$(build_thread_name "$issue" "$rtitle" /dev/null "复审 #$n")" "meta_path=$dir/meta.json" \
      "max_turns=@json:$claude_max_turns" "max_budget_usd=@json:$claude_max_budget"
    stage_call "$dir" review "$n" "$wt" "$timeout" "" claude -- python3 "$PY_CLAUDE" run "$dir/review-$n.request.json"
  else
    command -v pi >/dev/null || die "pi 未安装"
    thread_set "$issue" "review-$n" engine pi; thread_set "$issue" "review-$n" role review; thread_set "$issue" "review-$n" kind review; thread_set "$issue" "review-$n" runs "review-$n"
    stage_call "$dir" review "$n" "$inbox" "$timeout" "$inbox" pi -- \
      pi -p --mode json --model "${model:-deepseek/deepseek-v4-pro-0813}" --no-session \
      --append-system-prompt "$review_role_file" \
      "复审 REVIEW_DIFF.patch 里的改动。任务书在 REVIEW_BRIEF.md，被审 agent 自己的交付报告在 REVIEW_REPORT.md。按你的输出格式给结论。$( [ -n "$focus" ] && printf '\n\n## 复审关注点（编排者给的，按这个看）\n%s' "$(cat "$focus")" || printf '\n没有额外关注点：按任务书「要求」逐条核对。' )"
  fi

  case "$engine" in codex) require_concurrency_slot ;; claude) require_claude_slot ;; esac
  unlock_runs
  launch_call "$issue" "$dir" review "$n" "$detach"
  if [ "$detach" -eq 0 ]; then
    local rc; rc="$(cat "$dir/review-$n.rc" 2>/dev/null || echo '?')"
    [ "$rc" = "0" ] || echo "!! 复审执行体非零退出 rc=$rc" >&2
    python3 "$PY_SUMMARIZE" "$dir/review-$n.jsonl" "$dir/review-$n.stderr" "$dir/review-$n.last.md" || true
    case "$rc" in 0) return 0 ;; [0-9]*) return "$rc" ;; *) return 1 ;; esac   # 前台复审同样透传执行体退出码
  fi
}

# ---------- 提问 / 回答 ----------

pending_question_file() {  # <issue> → 最近一个待答的 questions 文件路径（无则空）
  local dir; dir="$(issue_dir "$1")"
  ls -t "$dir"/run-*.questions.json "$dir"/review-*.questions.json 2>/dev/null | head -1 || true
}

cmd_questions() {
  init_repo_context; require_project
  local ids=("$@") id f
  if [ ${#ids[@]} -eq 0 ]; then
    while IFS= read -r id; do [ -n "$id" ] && ids[${#ids[@]}]="$id"; done <<EOF
$(all_issues)
EOF
  fi
  local any=0
  for id in ${ids[@]+"${ids[@]}"}; do
    f="$(pending_question_file "$id")"; [ -n "$f" ] || continue
    any=1
    echo "########## $id  $(basename "$f") ##########"
    python3 - "$f" <<'PY'
import json, sys, time
d = json.load(open(sys.argv[1]))
print(f"asked {time.strftime('%H:%M:%S', time.localtime(d.get('askedAt', 0)/1000))}  blocking={d.get('isBlocking')}  timeout={d.get('timeoutSeconds')}s")
for q in d.get("questions") or []:
    print(f"  [{q.get('id')}] {q.get('header','')}: {q.get('question')}")
    for o in q.get("options") or []:
        print(f"       - {o.get('label')}: {o.get('description')}")
PY
  done
  [ "$any" -eq 1 ] || echo "（没有待回答的提问）"
}

cmd_steer() {
  local issue="" tname="implement" text="" file="" from="" path hd
  while [ $# -gt 0 ]; do
    case "$1" in
      --thread|--file|--from-queue)
        [ $# -ge 2 ] || die "steer: $1 缺少参数"
        case "$1" in --thread) tname="$2" ;; --file) file="$2" ;; --from-queue) from="$2" ;; esac
        shift 2 ;;
      -*) die "steer: 未知参数 $1" ;;
      *) if [ -z "$issue" ]; then issue="$1"; elif [ -z "$text" ]; then text="$1"; else die "steer: 文本请放在同一组引号里"; fi; shift ;;
    esac
  done
  [ -n "$issue" ] || die "用法: foreman steer <票 id> [--thread <名>] (<文本> | --file <f> | --from-queue N)"
  validate_thread_id "$tname"
  if [ -n "$from" ]; then
    case "$from" in *[!0-9]*|0) die "--from-queue 必须是正整数" ;; esac
    [ -z "$text$file" ] || die "--from-queue 不能与文本 / --file 混用"
  else
    [ -z "$text" ] || [ -z "$file" ] || die "文本与 --file 只能选一个"
    [ -n "$text$file" ] || die "steer: 引导消息不能为空"
  fi
  init_repo_context; require_project; require_issue "$issue"
  local dir thread_engine; dir="$(issue_dir "$issue")"; thread_engine="$(thread_get "$issue" "$tname" engine)"
  if [ "$thread_engine" = "claude" ]; then
    [ -z "$from" ] || die "claude 引擎没有当前轮注入；--from-queue 只用于 codex 常驻执行体"
    [ -z "$file" ] || text="$(cat "$file")"
    local inbox; inbox="$dir/hold-$tname/steer"; mkdir -p "$inbox"
    path="$(python3 - "$inbox" "$text" <<'PY'
import json, pathlib, sys, time, uuid
inbox, text = pathlib.Path(sys.argv[1]), sys.argv[2]
path = inbox / f"claude-{time.time_ns()}-{uuid.uuid4().hex}.json"
path.write_text(json.dumps({"text": text, "at": int(time.time()*1000), "state": "queued_next_run"}, ensure_ascii=False) + "\n", encoding="utf-8")
print(path)
PY
)" || return $?
    echo "claude 引擎：steer 已排队，下一轮 run 生效（当前轮不中断）"
    return 0
  fi
  hd="$(hold_dir "$dir" "$tname")"
  if hold_alive "$hd" && [ "$(cat "$hd/steer.pid" 2>/dev/null || true)" != "$(cat "$hd/bridge.pid")" ]; then
    die "当前常驻执行体尚不支持 steer（升级前启动）；等它结束后 release，再用 run 新起执行体。队列未改动。"
  fi
  path="$(python3 "$PY_APPSERVER" steer-submit "$dir" "$tname" "$text" "$file" "$from")" || return $?
  # 已结束且释放的线程也能恢复：执行体会把未命中活动 turn 的消息转排队。
  if ! hold_alive "$hd"; then
    [ -f "$hd/hold.json" ] || die "没有 hold 配置；消息已保留在 ${path}，用 run 起新一轮"
    require_concurrency_slot
    lock_runs "$dir"
    if ! hold_alive "$hd"; then
      python3 - "$hd/hold.json" "$(thread_get "$issue" "$tname" ref)" <<'PY2'
import json,sys
p,ref=sys.argv[1:]; cfg=json.load(open(p)); cfg["thread_id"]=ref; json.dump(cfg,open(p,"w"),ensure_ascii=False)
PY2
      hold_start "$hd"
    fi
    unlock_runs
  fi
  python3 "$PY_APPSERVER" steer-wait "$path"
}

cmd_answer() {
  local issue="" qid="" file="" text=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --qid) qid="$2"; shift 2 ;;
      --file) file="$2"; shift 2 ;;
      -*) die "answer: 未知参数 $1" ;;
      *) if [ -z "$issue" ]; then issue="$1"; else text="${text:+$text }$1"; fi; shift ;;
    esac
  done
  [ -n "$issue" ] || die "用法: foreman answer <票 id> [--qid <id>] (<回答文本> | --file <f>)"
  init_repo_context; require_project; require_issue "$issue"
  [ -n "$file" ] && text="$(cat "$file")"
  [ -n "$text" ] || die "answer: 回答不能为空"
  local qf; qf="$(pending_question_file "$issue")"
  [ -n "$qf" ] || die "$issue 没有待回答的提问（foreman questions 看）"
  local af="${qf%.questions.json}.answer.json"
  python3 - "$af" "$qid" "$text" <<'PY'
import json, sys
path, qid, text = sys.argv[1:4]
payload = {"answers": {qid: [text]}} if qid else {"all": text}
json.dump(payload, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
  echo "已写入 ${af}，执行体最多 ${FOREMAN_QUESTION_POLL:-2}s 内会读到并继续"
}

# ---------- report / tail / diff / check ----------

# 只看不改的角色（review / accept / research）：与起跑前的 git status 比对，worktree 变了就是改了代码，阻塞
wt_touched_probe() {  # <issue> <票目录> <kind> <n>
  local issue="$1" dir="$2" kind="$3" n="$4" f="$2/$3-$4.wt-before" prname wtp now
  [ -f "$f" ] && [ -f "$dir/$kind-$n.pr" ] || return 0
  prname="$(cat "$dir/$kind-$n.pr")"
  wtp="$(python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print((m.get("prs") or {}).get(sys.argv[2], {}).get("worktree", ""))' "$dir/meta.json" "$prname" 2>/dev/null || true)"
  [ -n "$wtp" ] && [ -d "$wtp" ] || return 0
  now="$(git -C "$wtp" status --porcelain 2>/dev/null || true)"
  if [ "$now" != "$(cat "$f")" ]; then
    echo "!!!! 探针：只看不改的角色工作树有改动，需人工判（$kind-$n 起跑前后的 git status 不一样）："
    diff "$f" <(printf '%s\n' "$now") | grep -E '^[<>]' | sed 's/^/    /' | head -20
    echo
  fi
}
cmd_report_inner() {
  local issue="$1" n="${2:-}" filter_pr="${3:-}" kind=run
  local dir summary_rc=0 timed_out=0; dir="$(issue_dir "$issue")"
  case "$n" in review*) kind=review; n="${n#review}" ;; esac
  if [ -z "$n" ]; then
    if [ -n "$filter_pr" ]; then
      n="$(python3 - "$dir" "$kind" "$filter_pr" <<'PY'
import pathlib,re,sys
d=pathlib.Path(sys.argv[1]); kind=sys.argv[2]; pr=sys.argv[3]; nums=[]
for p in d.glob(f"{kind}-*.pr"):
    m=re.fullmatch(rf"{re.escape(kind)}-(\d+)\.pr",p.name)
    if m and p.read_text().strip()==pr: nums.append(int(m[1]))
print(max(nums,default=0))
PY
)"
    else n="$(latest_n "$dir" "$kind")"; fi
    [ "$n" -gt 0 ] || die "$issue 还没有任何 $kind"
  fi
  if [ -n "$filter_pr" ] && [ "$(cat "$dir/$kind-$n.pr" 2>/dev/null || true)" != "$filter_pr" ]; then die "$kind-$n 不属于 PR「${filter_pr}」"; fi
  if [ "$(call_state "$dir/$kind-$n")" = "CANCELLED" ]; then echo "== $issue $kind#$n CANCELLED：$(cat "$dir/$kind-$n.cancelled")"; print_check_report "$dir/$kind-$n"; return 0; fi
  [ "$(cat "$dir/$kind-$n.rc" 2>/dev/null || true)" = 143 ] && timed_out=1
  wt_touched_probe "$issue" "$dir" "$kind" "$n"
  if [ ! -f "$dir/$kind-$n.jsonl" ]; then
    [ "$timed_out" -eq 1 ] || die "没有 $kind-$n"
    echo "!! $kind-$n 事件日志不可用"
    timeout_state_report "$dir" "$kind" "$n"
    print_check_report "$dir/$kind-$n"
    return 0
  fi
  if [ "$(call_state "$dir/$kind-$n")" = "RUNNING" ]; then
    if [ ! -s "$dir/$kind-$n.last.md" ]; then
      echo "run #$n 进行中；上一轮交付：foreman report $issue $((n-1))"
    else echo "（$kind-$n 仍在运行中，以下为截至此刻的部分事件流）"; fi
  fi
  local role=""; [ -f "$dir/$kind-$n.role" ] && role="$(cat "$dir/$kind-$n.role")"
  case "$(check_result "$dir/$kind-$n")" in FAIL*)
    echo "!!!! 需要人工/编排者判断 !!!!"
    echo "  - 执行者自报完成，但自动 check 失败"
  ;; esac
  python3 "$PY_SUMMARIZE" ${role:+--role "$role"} "$dir/$kind-$n.jsonl" "$dir/$kind-$n.stderr" "$dir/$kind-$n.last.md" || summary_rc=$?
  print_check_report "$dir/$kind-$n"
  timeout_state_report "$dir" "$kind" "$n"
  [ "$timed_out" -eq 1 ] && return 0
  return "$summary_rc"
}
timeout_round_exists() { # <票目录>；meta 丢失时只为 rc=143 的 report 放行
  local rc
  for rc in "$1"/run-*.rc "$1"/review-*.rc; do
    [ -f "$rc" ] || continue
    [ "$(cat "$rc" 2>/dev/null || true)" = 143 ] && return 0
  done
  return 1
}
cmd_report() {
  local issue="${1:-}" n="" prname=""; [ -n "$issue" ] || die "用法: foreman report <票 id> [N|reviewN] [--pr <名>]"; shift || true
  while [ $# -gt 0 ]; do case "$1" in --pr) prname="$2"; shift 2 ;; -*) die "report: 未知参数 $1" ;; *) [ -z "$n" ] && n="$1" || die "report: 多余参数 $1"; shift ;; esac; done
  init_repo_context; require_project
  [ -f "$(issue_dir "$issue")/meta.json" ] || timeout_round_exists "$(issue_dir "$issue")" || require_issue "$issue"
  [ -z "$prname" ] || resolve_pr "$issue" "$prname"
  cmd_report_inner "$issue" "$n" "$prname"
}

cmd_tail() {
  local issue="${1:-}" count="${2:-20}"
  [ -n "$issue" ] || die "用法: foreman tail <票 id> [N]"
  init_repo_context; require_project; require_issue "$issue"
  local dir; dir="$(issue_dir "$issue")"
  local kind n f
  for kind in run review; do
    n="$(latest_n "$dir" "$kind")"; [ "$n" -gt 0 ] || continue
    f="$dir/$kind-$n"
    echo "== $issue $kind#$n $(call_state "$f") $(elapsed_of "$f")"
    python3 "$PY_SUMMARIZE" --tail "$f.jsonl" "$count"
  done
}

cmd_diff() {
  local issue="$1"; shift || true
  init_repo_context; require_git; require_project; require_issue "$issue"
  local prname=""; if [ "${1:-}" = "--pr" ]; then prname="$2"; shift 2; fi
  local wt base; resolve_pr "$issue" "$prname"; wt="$PR_WT"; base="$PR_BASE"; [ -n "$wt" ] || die "diff: 票 $issue 没有登记 PR / 工作目录"
  echo "=== PR「${PR_NAME}」 $wt ==="
  echo "=== git status ==="; git -C "$wt" status --short; echo
  echo "=== 相对 origin/$base 的改动统计 ==="; git -C "$wt" diff --stat "origin/$base"...HEAD || true; git -C "$wt" diff --stat; echo
  echo "=== 完整 diff（已提交 + 工作区）==="; git -C "$wt" diff "origin/$base"...HEAD "$@" || true; git -C "$wt" diff "$@" || true
}

run_check_commands() { # <worktree> <日志> <命令...>
  local wt="$1" out="$2"; shift 2
  local failed=0 c rc tmp; tmp="$(mktemp)"; : > "$out"; rm -f "${out%.log}.failed-command"
  for c in "$@"; do
    echo "=== $c ==="; rc=0
    ( cd "$wt" && eval "$c" ) >"$tmp" 2>&1 || rc=$?
    tail -40 "$tmp"; cat "$tmp" >>"$out"
    echo "--- exit $rc"; printf '\n### %s -> exit %s\n' "$c" "$rc" >>"$out"
    if [ "$rc" -ne 0 ]; then [ -s "${out%.log}.failed-command" ] || printf '%s' "$c" > "${out%.log}.failed-command"; failed=1; fi
  done
  rm -f "$tmp"
  return "$failed"
}

cmd_check() {
  local issue="$1"; shift || true
  local prname=""; if [ "${1:-}" = "--pr" ]; then prname="$2"; shift 2; fi
  init_repo_context; require_project; require_issue "$issue"
  local wt; resolve_pr "$issue" "$prname"; wt="$PR_WT"; [ -n "$wt" ] || die "check: 票 $issue 没有登记 PR / 工作目录"
  local cmds=("$@")
  if [ ${#cmds[@]} -eq 0 ]; then
    while IFS= read -r line; do [ -n "$line" ] && cmds[${#cmds[@]}]="$line"; done <<EOF
$(verify_of_repo)
EOF
  fi
  [ ${#cmds[@]} -gt 0 ] || die "check: 没有验收命令（foreman.toml 的 verify.commands 为空且当前仓库 package.json 没有 type-check / lint），请显式给命令"
  local dir out failed=0 stamp
  dir="$(issue_dir "$issue")"; stamp="$(date +%Y%m%dT%H%M%S)"
  [ "${FOREMAN_SELFTEST:-}" = 1 ] && [ -n "${FOREMAN_CHECK_LOG_STAMP:-}" ] && stamp="$FOREMAN_CHECK_LOG_STAMP"
  out="$dir/check-${stamp}-$$.log"
  run_check_commands "$wt" "$out" "${cmds[@]}" || failed=$?
  echo; echo "完整输出: $out"
  [ "$failed" -eq 0 ] && echo "RESULT: ALL PASS" || echo "RESULT: FAIL"
  return "$failed"
}

prepare_auto_check() { # <run stem> <role> <no-check>
  local f="$1" role="$2" no_check="$3" commands
  rm -f "$f.check.rc" "$f.check.log" "$f.check.pending" "$f.check.status" "$f.check.failed-command"
  if [ "$no_check" -eq 1 ]; then printf 'SKIPPED: --no-check' > "$f.check.status"; return 0; fi
  case "$role" in review|accept|research) printf 'SKIPPED: 只读角色' > "$f.check.status"; return 0 ;; esac
  commands="$(verify_of_repo)"
  if [ -z "$commands" ]; then printf 'UNCONFIGURED' > "$f.check.status"; return 0; fi
  printf '%s\n' "$commands" > "$f.check.commands"
  : > "$f.check.pending"
}

auto_check_wait() { # <dir> <kind> <n> <worktree>
  local dir="$1" kind="$2" n="$3" wt="$4" f="$1/$2-$3" rc cmds=() line check_rc=0
  AUTO_CHECK_F="$f"
  auto_check_cleanup() {
    local worker_rc=$? target="${AUTO_CHECK_F:-}"
    [ -n "$target" ] || return 0
    if [ ! -f "$target.check.rc" ] && ! grep -qE '^(SKIPPED|UNCONFIGURED|FAILED)(:|$)' "$target.check.status" 2>/dev/null; then
      printf 'FAILED: check worker 异常退出 rc=%s' "$worker_rc" > "$target.check.status"
      printf '\ncheck worker 异常退出 rc=%s\n' "$worker_rc" >> "$target.check.log"
    fi
    rm -f "$target.check.pending" "$target.check.pid"
  }
  trap auto_check_cleanup EXIT
  trap 'exit 143' TERM INT
  printf '%s' "$$" > "$f.check.pid"
  while :; do
    rc="$(cat "$f.rc" 2>/dev/null || true)"
    rc="$(printf '%s' "$rc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ "${FOREMAN_SELFTEST:-}" = 1 ] && [ -z "$rc" ] && : > "$f.check.empty-rc-seen"
    case "$rc" in ''|*[!0-9]*) sleep 1 ;; *) break ;; esac
  done
  if [ "$rc" != 0 ]; then printf 'SKIPPED: 执行体 rc=%s' "$rc" > "$f.check.status"; rm -f "$f.check.pending"; return 0; fi
  : > "$f.check.started"
  while IFS= read -r line; do [ -n "$line" ] && cmds[${#cmds[@]}]="$line"; done < "$f.check.commands"
  run_check_commands "$wt" "$f.check.log" "${cmds[@]}" >/dev/null 2>&1 || check_rc=$?
  printf '%s' "$check_rc" > "$f.check.rc.$$" && mv "$f.check.rc.$$" "$f.check.rc"
  rm -f "$f.check.pending"
}

start_auto_check() { # <dir> <kind> <n> <worktree>
  local f="$1/$2-$3" worker
  [ -f "$f.check.pending" ] || return 0
  python3 -c 'import os,sys
try: os.setsid()
except OSError: pass
os.execvp(sys.argv[1],sys.argv[1:])' bash "$SCRIPT_PATH" __auto_check "$1" "$2" "$3" "$4" </dev/null >>"$f.check.log" 2>&1 9>&- &
  worker=$!; printf '%s' "$worker" > "$f.check.pid"
  disown >/dev/null 2>&1 || true
}

cleanup_failed_dispatch() { # <stem>
  local f="$1" pid i dir base active q claimed=0
  [ -n "$f" ] || return 0
  dir="$(dirname "$f")"; base="${f##*/}"
  [ -f "$f.pid" ] && claimed=1
  for active in "$dir"/hold-*/active.json; do
    [ -f "$active" ] || continue
    grep -q '"run"[[:space:]]*:[[:space:]]*"'"$base"'"' "$active" && claimed=1
  done
  [ "$claimed" -eq 0 ] || return 0
  for q in "$dir"/hold-*/queue/"$base.request.json"; do [ -f "$q" ] && rm -f "$q"; done
  pid="$(cat "$f.check.pid" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) ;; *)
    kill -TERM "$pid" 2>/dev/null || true
    for i in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep .05; done
    kill -KILL "$pid" 2>/dev/null || true
  ;; esac
  rm -f "$f.check.pid" "$f.check.pending"
  printf 'FAILED: 派发失败' > "$f.check.status"
  printf '派发失败，队列请求未被领取，已撤回' > "$f.cancelled"
}

wait_auto_check() { while [ "$(call_state "$1")" = CHECKING ]; do sleep 1; done; }
check_state() { # <stem>: TERMINAL / PENDING_RUN / CHECKING / WORKER_GONE
  local f="$1" rc pid status
  [ -f "$f.check.pending" ] || { printf TERMINAL; return; }
  [ ! -f "$f.check.rc" ] || { printf TERMINAL; return; }
  status="$(cat "$f.check.status" 2>/dev/null || true)"
  status="$(printf '%s' "$status" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$status" in SKIPPED|SKIPPED:*|UNCONFIGURED|UNCONFIGURED:*|FAILED|FAILED:*) printf TERMINAL; return ;; esac
  rc="$(cat "$f.rc" 2>/dev/null || true)"
  rc="$(printf '%s' "$rc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$rc" in ''|*[!0-9]*) printf PENDING_RUN; return ;; esac
  [ "$rc" = 0 ] || { printf TERMINAL; return; }
  pid="$(cat "$f.check.pid" 2>/dev/null || true)"
  pid="$(printf '%s' "$pid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then printf CHECKING; else printf WORKER_GONE; fi
}
check_result() {
  local f="$1" status phase check_rc; phase="$(check_state "$f")"
  [ "$phase" = CHECKING ] && { printf '中'; return; }
  [ "$phase" = WORKER_GONE ] && { printf 'FAIL（worker 消失）'; return; }
  if [ -f "$f.check.rc" ]; then
    check_rc="$(cat "$f.check.rc" 2>/dev/null || true)"
    check_rc="$(printf '%s' "$check_rc" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ "$check_rc" = 0 ] && printf PASS || printf FAIL; return
  fi
  status="$(cat "$f.check.status" 2>/dev/null || true)"
  status="$(printf '%s' "$status" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  case "$status" in UNCONFIGURED|UNCONFIGURED:*) printf '未配置' ;; SKIPPED|SKIPPED:*) printf '跳过' ;; FAILED|FAILED:*) printf FAIL ;; *) [ -f "$f.rc" ] && printf '跳过' || printf '—' ;; esac
}
print_check_report() {
  local f="$1" result; result="$(check_result "$f")"
  echo; echo "--- check：${result} ---"
  case "$result" in
    FAIL*) [ -s "$f.check.failed-command" ] && echo "失败命令: $(cat "$f.check.failed-command")"; tail -40 "$f.check.log" 2>/dev/null || true ;;
    跳过) if [ -s "$f.check.status" ]; then cat "$f.check.status"; else echo "旧轮无自动 check 记录"; fi ;;
  esac
}

# ---------- status / wait / list ----------

call_state() {
  local f="$1" pid=""
  [ -f "$f.cancelled" ] && { printf 'CANCELLED'; return 0; }
  if [ -f "$f.rc" ]; then
    if [ "$(check_state "$f")" = CHECKING ]; then printf 'CHECKING'; return 0; fi
    case "$(cat "$f.rc")" in 4) printf 'ENGINE_DOWN' ;; 5) printf 'THREAD_BUSY' ;; *) printf 'DONE' ;; esac
    return 0
  fi
  if [ -f "$f.pid" ]; then pid="$(cat "$f.pid")"; fi
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    local tn hd active; tn="$(cat "$f.thread" 2>/dev/null || true)"; hd="$(dirname "$f")/hold-$tn"
    if [ -n "$tn" ] && [ -f "$hd/queue/$(basename "$f").request.json" ]; then printf 'QUEUED'; return 0; fi
    if [ -n "$tn" ] && [ -f "$hd/bridge.pid" ] && [ "$(cat "$hd/bridge.pid" 2>/dev/null)" = "$pid" ]; then
      active="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("run", ""))' "$hd/active.json" 2>/dev/null || true)"
      if [ -n "$active" ] && [ "$active" != "$(basename "$f")" ]; then
        local active_n current_n; active_n="${active#*-}"; current_n="${f##*-}"
        case "$active_n:$current_n" in
          *[!0-9:]*) ;;
          *) if [ "$active_n" -gt "$current_n" ]; then
               [ -f "$f.cancelled" ] && { printf 'CANCELLED'; return 0; }
               if [ -f "$f.rc" ]; then
                 case "$(cat "$f.rc")" in 4) printf 'ENGINE_DOWN' ;; 5) printf 'THREAD_BUSY' ;; *) printf 'DONE' ;; esac
                 return 0
               fi
               printf 'DEAD'; return 0
             fi ;;
        esac
      fi
    fi
    if [ -f "$f.questions.json" ]; then printf 'WAITING'; else printf 'RUNNING'; fi
    return 0
  fi
  if [ -f "$f.argv" ]; then printf 'DEAD'; return 0; fi
  if [ -f "$f.jsonl" ]; then printf 'PAST'; return 0; fi
  printf 'NONE'
}
timeout_state_report() { # <票目录> <kind> <n>；只在硬超时 rc=143 后合成现场
  local dir="$1" kind="$2" n="$3" f="$1/$2-$3" pr wt base out
  [ "$(cat "$f.rc" 2>/dev/null || true)" = 143 ] || return 0
  pr="$(round_pr "$dir" "$kind-$n" 2>/dev/null || true)"
  wt="$(python3 - "$dir/meta.json" "$pr" 2>/dev/null <<'PY2' || true
import json,sys
m=json.load(open(sys.argv[1])); p=(m.get("prs") or {}).get(sys.argv[2],m)
print(p.get("worktree") or "")
PY2
)"
  base="$(python3 - "$dir/meta.json" "$pr" 2>/dev/null <<'PY2' || true
import json,sys
m=json.load(open(sys.argv[1])); p=(m.get("prs") or {}).get(sys.argv[2],m)
print(p.get("base") or "")
PY2
)"
  echo; echo "--- 超时时的状态 ---"
  echo "已落 commit 列表："
  if [ -n "$wt" ] && [ -d "$wt" ] && [ -n "$base" ]; then
    out="$(git -C "$wt" log --oneline "origin/$base..HEAD" 2>&1 || true)"; [ -n "$out" ] && printf '%s\n' "$out" || echo "（无）"
  else echo "（工作树或基线不可用）"; fi
  echo "工作树改动文件："
  if [ -n "$wt" ] && [ -d "$wt" ]; then out="$(git -C "$wt" status --short 2>&1 || true)"; [ -n "$out" ] && printf '%s\n' "$out" || echo "（无）"
  else echo "（工作树不可用）"; fi
  echo "最后 10 条事件："
  if [ -s "$f.jsonl" ]; then python3 "$PY_SUMMARIZE" --tail "$f.jsonl" 10 || echo "（事件尾不可用）"
  else echo "（事件尾不可用）"; fi
  echo "被打断时正在跑的命令："
  if [ -s "$f.jsonl" ]; then python3 - "$f.jsonl" <<'PY2' || echo "（命令状态不可用）"
import json,sys
active={}
for line in open(sys.argv[1],encoding="utf-8",errors="replace"):
    try: event=json.loads(line)
    except ValueError: continue
    method=event.get("method"); item=(event.get("params") or {}).get("item") or {}; ident=item.get("id")
    if method=="item/started" and item.get("type")=="commandExecution" and ident:
        active[ident]=item.get("command") or "（命令文本缺失）"
    elif method=="item/completed" and ident:
        active.pop(ident,None)
if active:
    for command in active.values(): print(command)
else: print("（事件流中没有未完成的 commandExecution）")
PY2
  else echo "（命令状态不可用）"; fi
}
latest_n() {
  python3 - "$1" "$2" <<'PY2'
import pathlib, re, sys
pattern = re.compile(re.escape(sys.argv[2]) + r"-(\d+)\.(?:argv|jsonl)$")
print(max((int(m[1]) for p in pathlib.Path(sys.argv[1]).iterdir() if (m := pattern.fullmatch(p.name))), default=0))
PY2
}
last_implementation_thread() {  # <票目录> <PR 名>
  python3 - "$1" "$2" "$(default_pr_of_dir "$1")" <<'PY2'
import pathlib,re,sys
d=pathlib.Path(sys.argv[1]); pr,default=sys.argv[2:]; found=[]
numbers={int(m[1]) for p in d.iterdir() if (m:=re.match(r"run-(\d+)\.",p.name))}
for n in numbers:
    pf=d/f"run-{n}.pr"; actual=pf.read_text().strip() if pf.is_file() else default
    if actual!=pr: continue
    role=(d/f"run-{n}.role").read_text().strip() if (d/f"run-{n}.role").is_file() else "implement"
    if role not in ("implement","mechanical"): continue
    thread=(d/f"run-{n}.thread").read_text().strip() if (d/f"run-{n}.thread").is_file() else "implement"
    found.append((n,thread))
print(max(found)[1] if found else "")
PY2
}
thread_for_pr_role() {  # <票目录> <PR 名> <角色>
  python3 - "$1" "$2" "$3" "$(default_pr_of_dir "$1")" <<'PY2'
import pathlib,re,sys
d=pathlib.Path(sys.argv[1]); pr,role,default=sys.argv[2:]; found=[]
numbers={int(m[1]) for p in d.iterdir() if (m:=re.match(r"run-(\d+)\.",p.name))}
for n in numbers:
    pf=d/f"run-{n}.pr"; actual=pf.read_text().strip() if pf.is_file() else default
    if actual!=pr: continue
    rr=(d/f"run-{n}.role").read_text().strip() if (d/f"run-{n}.role").is_file() else "implement"
    if rr!=role: continue
    tf=d/f"run-{n}.thread"; found.append((n,tf.read_text().strip() if tf.is_file() else "implement"))
print(max(found)[1] if found else "")
PY2
}
thread_last_pr() {  # <票目录> <线程名>
  python3 - "$1" "$2" "$(default_pr_of_dir "$1")" <<'PY2'
import pathlib,re,sys
d=pathlib.Path(sys.argv[1]); wanted,default=sys.argv[2:]; found=[]
numbers={int(m[1]) for p in d.iterdir() if (m:=re.match(r"run-(\d+)\.",p.name))}
for n in numbers:
    tf=d/f"run-{n}.thread"; thread=tf.read_text().strip() if tf.is_file() else "implement"
    pf=d/f"run-{n}.pr"; actual=pf.read_text().strip() if pf.is_file() else default
    if thread==wanted: found.append((n,actual))
print(max(found)[1] if found else "")
PY2
}
round_pr() { # <票目录> <run-N|review-N>
  if [ -s "$1/$2.pr" ]; then cat "$1/$2.pr"; else default_pr_of_dir "$1"; fi
}
hold_active_run() { # <票目录> <hold 目录>；兼容没有 active.json 的旧执行体
  python3 - "$1" "$2" <<'PY2'
import json,os,pathlib,re,sys
d,hd=map(pathlib.Path,sys.argv[1:]); active=hd/"active.json"
try:
    run=json.load(open(active)).get("run","")
    if re.fullmatch(r"(?:run|review)-\d+",run): print(run); raise SystemExit
except (OSError,ValueError): pass
try: bridge=int((hd/"bridge.pid").read_text())
except (OSError,ValueError): raise SystemExit
try: os.kill(bridge,0)
except OSError: raise SystemExit
thread=hd.name[5:]; found=[]
for tf in d.glob("run-*.thread"):
    m=re.fullmatch(r"run-(\d+)\.thread",tf.name)
    if not m or tf.read_text().strip()!=thread: continue
    stem=f"run-{m[1]}"
    try: pid=int((d/(stem+".pid")).read_text())
    except (OSError,ValueError): continue
    if pid!=bridge or (d/(stem+".rc")).exists() or (d/(stem+".cancelled")).exists(): continue
    if (hd/"queue"/(stem+".request.json")).exists(): continue
    found.append((int(m[1]),stem))
if found: print(max(found)[1])
PY2
}
cleanup_require_pr_idle() { # <票目录> <PR>；调用者已持 runs lock
  local dir="$1" pr="$2" p="" stem="" st="" seen=""
  for p in "$dir"/run-*.* "$dir"/review-*.*; do
    [ -f "$p" ] || continue; stem="${p%.*}"
    case " $seen " in *" ${stem} "*) continue ;; esac; seen="$seen $stem"
    [ "$(round_pr "$dir" "${stem##*/}")" = "$pr" ] || continue; st="$(call_state "$stem")"
    case "$st" in RUNNING|WAITING|QUEUED|CHECKING) die "PR「${pr}」还有轮次在跑 / 排队（${stem##*/}: ${st}），先 foreman release 释放线程再 cleanup" ;; esac
  done
  return 0
}
cleanup_release_idle_holds() { # <票目录> <PR>；调用者已持 runs lock
  local dir="$1" pr="$2" hd="" ht="" active="" q=""
  for hd in "$dir"/hold-*; do
    [ -d "$hd" ] && hold_alive "$hd" || continue; ht="${hd##*/hold-}"
    active="$(hold_active_run "$dir" "$hd")"
    if [ -z "$active" ]; then
      q="$(find "$hd/queue" -type f -name 'run-*.request.json' -print -quit 2>/dev/null || true)"
      if [ -z "$q" ] && [ "$(thread_last_pr "$dir" "$ht")" = "$pr" ]; then hold_release_wait "$hd"; fi
    fi
  done
  return 0
}
elapsed_of() {
  local f="$1" start now
  if [ ! -s "$f.started" ]; then printf '—'; return 0; fi
  start="$(cat "$f.started")"; now="$(date +%s)"
  case "$start" in ''|*[!0-9]*) printf '—'; return 0 ;; esac
  printf '%dm%02ds' $(( (now - start) / 60 )) $(( (now - start) % 60 ))
}
all_issues() {
  [ -d "$ISSUES_DIR" ] || return 0
  local d
  for d in "$ISSUES_DIR"/*; do [ -f "$d/meta.json" ] && basename "$d"; done
}
latest_calls_by_thread() {  # <票目录>；每条线程只取最后一轮
  python3 - "$1" <<'PY2'
import pathlib,re,sys
d=pathlib.Path(sys.argv[1]); calls={}
for p in d.iterdir():
    m=re.match(r"^(run|review)-(\d+)\.",p.name)
    if not m: continue
    kind,n=m[1],int(m[2]); stem=f"{kind}-{n}"; tf=d/(stem+".thread")
    key=tf.read_text().strip() if tf.is_file() else (stem if kind=="review" else "implement")
    calls.setdefault(key,{})[(kind,n)]=(d/(stem+".cancelled")).is_file()
for items in calls.values():
    live=[(n,kind) for (kind,n),cancelled in items.items() if not cancelled]
    cancelled=[(n,kind) for (kind,n),is_cancelled in items.items() if is_cancelled]
    if live:
        n,kind=max(live); print(f"{kind}|{n}")
    if cancelled:
        n,kind=max(cancelled); print(f"{kind}|{n}")
PY2
}

# 票下的全部线程（与引擎无关）
cmd_threads() {
  local issue="${1:-}"; [ -n "$issue" ] || die "用法: foreman threads <票 id>"
  init_repo_context; require_project; require_issue "$issue"
  python3 - "$(issue_dir "$issue")" <<'PY2'
import json, os, sys
d = sys.argv[1]; m = json.load(open(os.path.join(d, "meta.json")))
th = m.get("threads") or {}
print(f"票 {m.get('issue')}  线程 cwd = 项目根")
for name, pr in (m.get('prs') or ({'default': m} if m.get('worktree') else {})).items():
    print(f"  PR「{name}」 目录 {pr.get('worktree')}  分支 {pr.get('branch') or '-'}  base {pr.get('base') or '-'}{'  (here)' if pr.get('registered_here') else ''}{'  gh#'+str(pr.get('gh_pr')) if pr.get('gh_pr') else ''}")
if not th:
    print("（还没有线程；run / review 会按需开）"); sys.exit(0)
print(f"{'线程':12} {'引擎':10} {'角色':10} {'类型':6} {'引擎内引用':16} {'轮次':26} 最近一轮")
for name, t in th.items():
    runs = t.get("runs") or []
    last = runs[-1] if runs else ""
    st = "-"
    if last:
        f = os.path.join(d, last)
        if os.path.exists(f + ".rc"): st = "rc=" + open(f + ".rc").read().strip()
        elif os.path.exists(f + ".pid"): st = "在跑/未收尾"
    ref = t.get("ref") or ""
    ref = ref[:14] + ("…" if len(ref) > 14 else "")
    print(f"{name:12} {t.get('engine','?'):10} {t.get('role','?'):10} {t.get('kind','run'):6} {ref or '-':16} {','.join(runs)[:26]:26} {st}")
PY2
}

cmd_status() {
  init_repo_context; require_project
  local ids=("$@") id kind n f st
  if [ ${#ids[@]} -eq 0 ]; then
    while IFS= read -r id; do [ -n "$id" ] && ids[${#ids[@]}]="$id"; done <<EOF
$(all_issues)
EOF
  fi
  [ ${#ids[@]} -gt 0 ] || { echo "（$REPO_SLUG 还没有任何 foreman issue）"; return 0; }
  printf '%-16s %-9s %-6s %-10s %-8s %-8s %s\n' "票" "轮次" "引擎" "角色" "状态" "check" "用时 / 详情"
  local any=0
  for id in ${ids[@]+"${ids[@]}"}; do
    for kind in run review; do
      n="$(latest_n "$(issue_dir "$id")" "$kind")"; [ "$n" -gt 0 ] || continue
      f="$(issue_dir "$id")/$kind-$n"; st="$(call_state "$f")"
      case "$st" in PAST|NONE) continue ;; esac
      any=1
      local eng role check; eng="$(cat "$f.engine" 2>/dev/null || echo codex)"; role="$(cat "$f.role" 2>/dev/null || true)"; check="$(check_result "$f")"
      local tn; tn="$(cat "$f.thread" 2>/dev/null || true)"; [ -n "$tn" ] && [ "$tn" != "$role" ] && role="$role@$tn"
      [ -f "$f.full-access" ] && role="$role!FULL"
      if [ "$eng" = "claude" ] && find "$(issue_dir "$id")/hold-${tn:-implement}/steer" -maxdepth 1 -name 'claude-*.json' -type f -print -quit 2>/dev/null | grep -q .; then role="$role+NEXT"; fi
      case "$st" in
        CANCELLED)       printf '%-16s %-9s %-6s %-10s %-8s %-8s %s  %s\n' "$id" "$kind#$n" "$eng" "$role" "$st" "$check" "$(elapsed_of "$f")" "$(cat "$f.cancelled")" ;;
        RUNNING|WAITING) printf '%-16s %-9s %-6s %-10s %-8s %-8s %s  pid %s\n' "$id" "$kind#$n" "$eng" "$role" "$st" "$check" "$(elapsed_of "$f")" "$(cat "$f.pid")" ;;
        CHECKING)        printf '%-16s %-9s %-6s %-10s %-8s %-8s %s  check 中\n' "$id" "$kind#$n" "$eng" "$role" "$st" "$check" "$(elapsed_of "$f")" ;;
        DONE)            printf '%-16s %-9s %-6s %-10s %-8s %-8s %s  rc=%s\n' "$id" "$kind#$n" "$eng" "$role" "$st" "$check" "$(elapsed_of "$f")" "$(cat "$f.rc")" ;;
        ENGINE_DOWN)     printf '%-16s %-9s %-6s %-10s %-8s %-8s %s  执行器暂时不可用（看 report 顶部的原始报错），告知用户\n' "$id" "$kind#$n" "$eng" "$role" "$st" "$check" "$(elapsed_of "$f")" ;;
        THREAD_BUSY)     printf '%-16s %-9s %-6s %-10s %-8s %-8s %s  线程被别的客户端占着（桌面端打开了它），关掉再续，急就 release 后 run --thread <新名> 另起\n' "$id" "$kind#$n" "$eng" "$role" "$st" "$check" "$(elapsed_of "$f")" ;;
        *)               printf '%-16s %-9s %-6s %-10s %-8s %-8s %s\n' "$id" "$kind#$n" "$eng" "$role" "$st" "$check" "$(elapsed_of "$f")" ;;
      esac
    done
    local steer_file steer_thread steer_count
    for steer_file in "$(issue_dir "$id")"/hold-*/steer/claude-*.json; do
      [ -f "$steer_file" ] || continue
      steer_thread="$(basename "$(dirname "$(dirname "$steer_file")")")"; steer_thread="${steer_thread#hold-}"
      steer_count="$(find "$(dirname "$steer_file")" -maxdepth 1 -name 'claude-*.json' -type f | wc -l | tr -d ' ')"
      printf '%-16s %-9s %-6s %-10s %-8s %-8s %s\n' "$id" "steer" "claude" "${steer_thread}+NEXT" "QUEUED" "—" "$steer_count 条，下一轮 run 生效"
      any=1; break
    done
  done
  [ "$any" -eq 1 ] || echo "（没有本机制下的会话记录；历史轮次用 list 看）"
  echo "状态: RUNNING 在跑（主用时从本轮派发、即 request 写入账本起算，QUEUED→RUNNING 不归零）| WAITING 执行者在等编排者回答（foreman questions / answer）| CHECKING 自动 check 中 | DONE 结束（看 rc）| QUEUED 在常驻执行体队列里等上一轮 | ENGINE_DOWN 执行器不可用（404 / 5xx / 额度 / 登录）→ 告知用户 | THREAD_BUSY 线程被桌面端占着 → 关掉再续，急就 release 后 run --thread <新名> 另起 | DEAD 进程消失且无完成标记=按失败处理"
  local hd hid; for hd in "$ISSUES_DIR"/*/hold-*; do [ -d "$hd" ] && hold_alive "$hd" || continue; hid="$(basename "$(dirname "$hd")")"; echo "HOLD   $hid  线程「$(basename "$hd" | sed 's/^hold-//')」由常驻执行体占着（pid $(cat "$hd/bridge.pid")；桌面端此时打不开它；foreman release $hid 释放）"; done
  echo "本机 codex 线程在跑: $(active_codex_runs) / 上限 $(concurrency_limit) | claude: $(active_claude_runs) / 上限 $(claude_concurrency_limit)"
}

cmd_wait() {
  init_repo_context; require_project
  local timeout=300 interval=20 progress=300 report=1 ids=() targets=()
  local id="" kind="" n="" f="" st="" t="" left=0 still=0 waited=0 waiting=0 timed_out=0 progress_dir="" cycle_out=""
  local waiting_id="" waiting_thread="" waiting_summary=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      --interval) interval="$2"; shift 2 ;;
      --progress) progress="$2"; shift 2 ;;
      --no-report) report=0; shift ;;
      -*) die "wait: 未知参数 $1" ;;
      *) ids[${#ids[@]}]="$1"; shift ;;
    esac
  done
  case "$progress" in ''|*[!0-9]*) die "wait: --progress 必须是非负整数秒" ;; esac
  if [ ${#ids[@]} -eq 0 ]; then
    while IFS= read -r line; do [ -n "$line" ] && ids[${#ids[@]}]="$line"; done <<EOF
$(all_issues)
EOF
  fi
  for id in ${ids[@]+"${ids[@]}"}; do
    require_issue "$id"
    while IFS='|' read -r kind n; do
      [ -n "$kind" ] || continue
      f="$(issue_dir "$id")/$kind-$n"; st="$(call_state "$f")"
      case "$st" in RUNNING|QUEUED|WAITING|CHECKING|CANCELLED) targets[${#targets[@]}]="$id|$kind|$n" ;; esac
    done <<EOF
$(latest_calls_by_thread "$(issue_dir "$id")")
EOF
  done
  if [ ${#targets[@]} -eq 0 ]; then echo "没有正在运行的会话（用 status 看最近一轮的结果）"; return 0; fi
  progress_dir="$(mktemp -d)"
  for t in "${targets[@]}"; do
    id="${t%%|*}"; kind="$(printf '%s' "$t" | cut -d'|' -f2)"; n="${t##*|}"
    f="$(issue_dir "$id")/$kind-$n"
    python3 "$PY_SUMMARIZE" --progress "$f.jsonl" "$progress_dir/$id-$kind-$n.json" "$id $kind#$n" "$(call_state "$f")" "$progress" >/dev/null
  done
  echo "==> 等待 ${#targets[@]} 个会话，最多 ${timeout}s，进展周期 ${progress}s"
  while [ "$waited" -lt "$timeout" ]; do
    left=0; cycle_out="$progress_dir/cycle.out"; : > "$cycle_out"
    for t in "${targets[@]}"; do
      id="${t%%|*}"; kind="$(printf '%s' "$t" | cut -d'|' -f2)"; n="${t##*|}"
      f="$(issue_dir "$id")/$kind-$n"; st="$(call_state "$f")"
      python3 "$PY_SUMMARIZE" --progress "$f.jsonl" "$progress_dir/$id-$kind-$n.json" "$id $kind#$n" "$st" "$progress" >> "$cycle_out"
      case "$st" in RUNNING|QUEUED|WAITING|CHECKING) left=$((left+1)) ;; esac
      if [ "$st" = "WAITING" ] && [ "$waiting" -eq 0 ]; then
        waiting_id="$id"
        waiting_thread="$(cat "$f.thread" 2>/dev/null || echo '?')"
        waiting_summary="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); q=(d.get("questions") or [{}])[0]; print((q.get("question") or q.get("text") or "无题目文本").replace("\n"," ")[:100])' "$f.questions.json" 2>/dev/null || echo 无题目文本)"
        waiting=1
      fi
    done
    [ ! -s "$cycle_out" ] || cat "$cycle_out"
    [ "$waiting" -eq 0 ] || break
    [ "$left" -eq 0 ] && break
    sleep "$interval"; waited=$((waited + interval))
  done
  [ "$waited" -lt "$timeout" ] || timed_out=1
  [ "$waiting" -eq 0 ] || echo "⏳ WAITING：票 $waiting_id / 线程 $waiting_thread / ${waiting_summary}；将照常打印全表后返回 rc=3"
  for t in "${targets[@]}"; do
    id="${t%%|*}"; kind="$(printf '%s' "$t" | cut -d'|' -f2)"; n="${t##*|}"
    f="$(issue_dir "$id")/$kind-$n"; st="$(call_state "$f")"
    case "$st" in
      CANCELLED) echo "== $id $kind#$n CANCELLED：$(cat "$f.cancelled")" ;;
      DONE) echo "== $id $kind#$n 结束 rc=$(cat "$f.rc") 用时 $(elapsed_of "$f")" ;;
      ENGINE_DOWN) echo "== $id $kind#$n ENGINE_DOWN：执行器暂时不可用（404 / 5xx / 额度 / 登录），foreman report $id 看原始报错；告知用户，不要自行排障" ;;
      RUNNING|QUEUED|WAITING) echo "== $id $kind#$n 仍在运行 $(elapsed_of "$f") ($st)"; still=$((still+1)) ;;
      CHECKING) echo "== $id $kind#$n check 中 $(elapsed_of "$f")"; still=$((still+1)) ;;
      *) echo "== $id $kind#$n ${st}（进程消失但没有完成标记，按失败处理）" ;;
    esac
  done
  if [ "$timed_out" -eq 1 ] && [ "$waiting" -eq 0 ] && [ "$still" -gt 0 ]; then
    for t in "${targets[@]}"; do
      id="${t%%|*}"; kind="$(printf '%s' "$t" | cut -d'|' -f2)"; n="${t##*|}"
      f="$(issue_dir "$id")/$kind-$n"; st="$(call_state "$f")"
      case "$st" in RUNNING|QUEUED|WAITING|CHECKING) echo "== $id $kind#$n wait 超时事件尾（最近 20 条）"; python3 "$PY_SUMMARIZE" --tail "$f.jsonl" ;; esac
    done
  fi
  if [ "$report" -eq 1 ]; then
    for t in "${targets[@]}"; do
      id="${t%%|*}"; kind="$(printf '%s' "$t" | cut -d'|' -f2)"; n="${t##*|}"
      f="$(issue_dir "$id")/$kind-$n"
      case "$(call_state "$f")" in RUNNING|QUEUED|WAITING|CHECKING) continue ;; esac
      echo; echo "########## $id $kind#$n ##########"
      if [ "$kind" = review ]; then ( cmd_report_inner "$id" "review$n" ) || echo "$id review#${n}（无日志，跳过摘要）"
      else ( cmd_report_inner "$id" "$n" ) || echo "$id run#${n}（无日志，跳过摘要）"; fi
    done
  fi
  rm -rf "$progress_dir"
  [ "$waiting" -eq 0 ] || return 3
  [ "$still" -eq 0 ] || return 2
  return 0
}

cmd_list() {
  init_repo_context; require_project
  [ -d "$ISSUES_DIR" ] || { echo "（$REPO_SLUG 还没有任何 foreman 票）"; return 0; }
  python3 "$PY_SUMMARIZE" --list "$ISSUES_DIR"
  echo; echo "--- 票 → 线程（角色 / 引擎 / 轮次）---"
  python3 - "$ISSUES_DIR" <<'PY2'
import json, os, sys
root = sys.argv[1]
for tid in sorted(os.listdir(root)):
    p = os.path.join(root, tid, "meta.json")
    if not os.path.isfile(p): continue
    m = json.load(open(p)); th = m.get("threads") or {}
    prs=m.get("prs") or {}; default=m.get("default_pr"); pr=prs.get(default) if default else None
    if pr is None and len(prs)==1: pr=next(iter(prs.values()))
    branch=((pr or {}).get("branch") if prs else m.get("branch")) or "—"
    parts = []
    for name, t in th.items():
        runs = t.get("runs") or []
        parts.append(f"{name}[{t.get('role','?')}/{t.get('engine','?')}×{len(runs)}]")
    print(f"  {tid:16} 分支 {branch:40} 线程: {' '.join(parts) or '（无）'}")
PY2
}

# ---------- pr（只打印命令；--yes 才执行。远端动作归编排者且要用户确认） ----------

cmd_pr() {
  local issue="" title="" body_file="" base="" draft="" yes=0 prname=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --title) title="$2"; shift 2 ;;
      --body-file) body_file="$2"; shift 2 ;;
      --pr) prname="$2"; shift 2 ;;
      --base) base="$2"; shift 2 ;;
      --draft) draft=1; shift ;;
      --ready) draft=0; shift ;;
      --yes) yes=1; shift ;;
      -*) die "pr: 未知参数 $1" ;;
      *) [ -z "$issue" ] && issue="$1" || die "pr: 多余参数 $1"; shift ;;
    esac
  done
  [ -n "$issue" ] && [ -n "$title" ] && [ -n "$body_file" ] || die "用法: foreman pr <票 id> --title <t> --body-file <f> [--base <b>] [--draft|--ready] [--yes]"
  init_repo_context; require_git; require_project; require_issue "$issue"
  local wt branch gh; resolve_pr "$issue" "$prname"; wt="$PR_WT"; branch="$PR_BRANCH"; gh="$(cfg github.gh gh)"
  [ -n "$wt" ] || die "pr: 票 $issue 没有登记 PR / 工作目录"
  [ -n "$base" ] || base="$PR_BASE"
  if [ -z "$draft" ]; then [ "$(cfg github.pr_draft true)" = "true" ] && draft=1 || draft=0; fi
  local unpushed; unpushed="$(git -C "$wt" rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo all)"
  echo "# 分支 $branch  未推送提交: $unpushed  base: $base  draft: $draft"
  echo "git -C '$wt' push -u origin '$branch'"
  echo "(cd '$wt' && $gh pr create --base '$base' --head '$branch' --title \"$title\" --body-file '$body_file'$([ "$draft" -eq 1 ] && echo ' --draft'))"
  if [ "$yes" -eq 1 ]; then
    git -C "$wt" push -u origin "$branch"
    (cd "$wt" && "$gh" pr create --base "$base" --head "$branch" --title "$title" --body-file "$body_file" $([ "$draft" -eq 1 ] && echo --draft))
  else
    echo "# 以上未执行（预览）。加 --yes 执行。"
  fi
}

# ---------- cleanup ----------

cmd_cleanup() {
  local issue="" force=0 keep_branch=0 discard=0 prname=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1; shift ;;
      --pr) prname="$2"; shift 2 ;;
      --keep-branch) keep_branch=1; shift ;;
      --discard-unpushed) discard=1; shift ;;
      *) [ -z "$issue" ] && issue="$1" || die "cleanup: 多余参数 $1"; shift ;;
    esac
  done
  [ -n "$issue" ] || die "用法: foreman cleanup <票 id> --force [--pr <名>] [--keep-branch] [--discard-unpushed]（squash 合并仓库请用 --discard-unpushed）"
  init_repo_context; require_project; require_issue "$issue"
  local wt branch; resolve_pr "$issue" "$prname"; wt="$PR_WT"; branch="$PR_BRANCH"
  [ -n "$PR_NAME" ] || { echo "$issue 没有登记任何 PR / 工作目录，没有要清理的"; return 0; }
  if [ "$force" -ne 1 ]; then
    echo "将删除 worktree: $wt"; [ "$keep_branch" -eq 1 ] || echo "将删除分支: $branch"
    echo "日志保留在 $(issue_dir "$issue")"; die "加 --force 才会真的执行"
  fi
  if [ -z "$PR_HERE" ] && [ -d "$wt" ]; then
    [ -z "$(git -C "$wt" status --porcelain 2>/dev/null)" ] || die "worktree 有未提交改动，拒绝删除: $wt"
    # cleanup 只挡「未提交」挡不住「已 commit 未 push」——PR 已 MERGED 的分支最容易骗人，这里把它做成硬检查
    if [ "$discard" -ne 1 ]; then
      local unpushed
      git -C "$wt" fetch --prune origin "$PR_BASE" --quiet || die "cleanup: 无法 fetch origin ${PR_BASE}，未能可靠判断是否已推送"
      if git -C "$wt" merge-base --is-ancestor HEAD "origin/$PR_BASE"; then unpushed=0
      elif git -C "$wt" show-ref --verify --quiet "refs/remotes/origin/$branch"; then unpushed="$(git -C "$wt" rev-list --count "origin/$branch..HEAD")"
      else unpushed="$(git -C "$wt" rev-list --count "origin/${PR_BASE}..HEAD" 2>/dev/null || echo 0)"; fi
      [ "$unpushed" = "0" ] || die "分支 $branch 有 $unpushed 个未推送的提交（git -C '$wt' log --oneline -${unpushed}）。先 push，或确认丢弃后加 --discard-unpushed"
    fi
  fi
  local dir; dir="$(issue_dir "$issue")"; lock_runs "$dir"
  cleanup_require_pr_idle "$dir" "$PR_NAME"
  cleanup_release_idle_holds "$dir" "$PR_NAME"
  if [ -n "$PR_HERE" ]; then
    echo "$issue 的「${PR_NAME}」是 here 登记（工作目录就是编排者自己的检出 ${wt}），只删登记不动目录与分支"
    pr_del "$issue" "$PR_NAME" || die "cleanup: 删除 PR 登记失败"
    unlock_runs; echo "已删登记（线程与日志保留）"; return 0
  fi
  if [ -d "$wt" ]; then
    git -C "$MAIN_REPO" worktree remove "$wt" || die "cleanup: 删除 worktree 失败: $wt"
  fi
  if [ "$keep_branch" -ne 1 ]; then
    if [ "$discard" -eq 1 ]; then git -C "$MAIN_REPO" branch -D "$branch" || die "cleanup: 强制删除分支失败: $branch"
    else git -C "$MAIN_REPO" branch -d "$branch" || echo "分支未删除（本地看不到它已合并，squash 合并很常见）：需要时手动 git branch -D ${branch}，登记照常删"; fi
  fi
  pr_del "$issue" "$PR_NAME" || die "cleanup: 删除 PR 登记失败"
  unlock_runs
  echo "已清理 ${issue} 的 PR「${PR_NAME}」（票、线程与日志保留；剩余 PR: $(pr_names "$issue" | tr '\n' ' ')）"
}

# ---------- doctor ----------

doctor_claude() (
  local wt="${1:-${MAIN_REPO:-${PROJECT_ROOT:-$PWD}}}"
  echo; echo "--- claude ---"
  if command -v claude >/dev/null; then
    echo "claude:  $(command -v claude) → $(claude --version 2>&1)"
    local auth; auth="$(claude auth status 2>/dev/null || true)"
    printf '%s' "$auth" | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin); print("         login=" + str(bool(d.get("loggedIn"))).lower() + "  auth=" + str(d.get("authMethod") or "—") + "  account=" + str(d.get("subscriptionType") or d.get("apiProvider") or "—"))
except Exception: print("         登录状态无法解析（未打印原始输出）")'
  else
    echo "!! 找不到 claude（安装 Claude Code CLI 并先登录）"
  fi
  local missing="" role
  for role in research implement review accept mechanical; do
    [ -n "$(claude_role_cfg "$role" model)" ] && [ -n "$(claude_role_cfg "$role" effort)" ] || missing="${missing:+$missing,}$role"
  done
  [ -z "$missing" ] && echo "  [OK]  [roles.*.claude] 五个参考角色齐全" || echo "  [!!]  缺 [roles.<名>.claude]: $missing"
  echo "  并发池: $(active_claude_runs) / 上限 $(claude_concurrency_limit)"
  local tmp meta rc=0; tmp="$(mktemp -d "${TMPDIR:-/tmp}/foreman-doctor-claude.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  trap 'exit 143' INT TERM
  meta="$(python3 "$PY_CLAUDE" doctor-config --output-dir "$tmp" --work-dir "${wt:-$PROJECT_ROOT}" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ] && python3 - "$tmp/settings.json" "$tmp/mcp.json" <<'PY'
import json, sys
settings, mcp = (json.load(open(path)) for path in sys.argv[1:])
sandbox = settings["sandbox"]
assert all(key in sandbox for key in ("enabled", "failIfUnavailable", "autoAllowBashIfSandboxed", "allowUnsandboxedCommands"))
assert isinstance(settings["permissions"]["deny"], list) and all(isinstance(x, str) for x in settings["permissions"]["deny"])
assert isinstance(mcp.get("mcpServers"), dict)
PY
  then
    echo "  [OK]  settings / MCP 静态校验（sandbox 四键 + deny 形状 + JSON）"
    printf '%s' "$meta" | python3 -c 'import json,sys; d=json.load(sys.stdin); names=[x for x in d["mcp_servers"] if x!="foreman"]; print("  继承的用户 MCP: " + (", ".join(names) if names else "无"))'
  else
    echo "  [!!]  Claude settings / MCP 静态校验失败: $(printf '%s' "$meta" | tail -1)"
  fi
)

cmd_doctor() {
  local wt="${1:-}" codex_ready=1
  echo "--- 二进制 ---"
  command -v python3 >/dev/null && echo "python3: $(python3 --version 2>&1)" || echo "!! 缺 python3"
  python3 -c 'import tomllib' 2>/dev/null || echo "!! python3 需要 3.11+（tomllib）"
  command -v gh >/dev/null && echo "gh:      $(gh --version | head -1)" || echo "!! 缺 gh"
  command -v rg >/dev/null && echo "rg:      $(command -v rg) → $(rg --version | head -1)" || echo "rg:      未装（建议 brew install ripgrep：执行者常先敲 rg，缺它会多耗一轮）"
  if [ -n "$CODEX_BIN" ]; then
    echo "codex:   $CODEX_BIN → $("$CODEX_BIN" --version 2>&1)"
    "$CODEX_BIN" login status 2>&1 | sed 's/^/         /' || true
  else
    echo "!! 找不到 codex（装 ChatGPT 桌面端或设 FOREMAN_CODEX_BIN）"; codex_ready=0
  fi
  command -v pi >/dev/null && echo "pi:      $(pi --version 2>&1)（可选执行器）" || echo "pi:      未安装（可选，默认不用）"

  echo; echo "--- 仓库 ---"
  if resolve_main_repo >/dev/null 2>&1; then
    init_repo_context
    echo "项目:      $PROJECT_ROOT  （规则 = 它的 AGENTS.md + 仓库内 AGENTS.md）"
    echo "仓库:      $MAIN_REPO  slug=$REPO_SLUG  远端默认分支=$(repo_fact remote_default_branch)"
    if [ -f "$PROJECT_TOML" ]; then
      echo "配置:      $PROJECT_TOML"
      echo "  base=$(base_of_repo)  worktrees=$(expand_path_tpl "$(cfg repo.worktree_root '{repo}/.claude/worktrees')")  gh=$(cfg_opt github.gh)  copy_env=[$(cfg_opt repo.copy_env | tr '\n' ' ')] verify=[$(verify_of_repo | tr '\n' ';')]"
      echo "  角色: implement=$(role_cfg implement model)/$(role_cfg implement effort)  review=$(role_cfg review model)/$(role_cfg review effort)$(role_defined mechanical && echo "  mechanical=$(role_cfg mechanical model)/$(role_cfg mechanical effort)")  本项目派发上限=$(concurrency_limit)（本机默认 $(gcfg engines.concurrency 5)）"
      local ghbin; ghbin="$(cfg_opt github.gh)"
      if [ -n "$ghbin" ] && [ "$ghbin" != "gh" ]; then
        (cd "$MAIN_REPO" && "$ghbin" api rate_limit --jq .rate.limit >/dev/null 2>&1) && echo "  gh 入口可用: $ghbin" || echo "  !! gh 入口不可用: $ghbin"
      fi
    else
      echo "!! 项目 ${PROJECT_SLUG} 还没初始化 —— 先跑 foreman init"
    fi
    [ -n "$wt" ] || wt="$MAIN_REPO"
  else
    echo "（当前不在 git 仓库里：仍可用 here / run 派跟仓库无关的活；跳过仓库检查与沙箱自检）"
  fi

  echo; echo "--- codex home ---"
  if [ -z "${FOREMAN_CODEX_HOME:-}" ] && [ -z "$(gcfg codex.home "")" ]; then
    echo "!! $CODEX_HOME_HINT"; doctor_claude "$wt"; return 0
  fi
  if [ "$codex_ready" -eq 0 ]; then doctor_claude "$wt"; return 1; fi
  ensure_codex_home
  if [ "$CODEX_HOME_MODE" = "shared" ]; then echo "模式=shared  CODEX_HOME=$CODEX_HOME_DIR  （桌面端能看到 foreman 线程；执行者继承桌面端 config.toml 的 MCP / 插件 / notify / 全局 AGENTS.md）"
  else echo "模式=$CODEX_HOME_MODE  CODEX_HOME=$CODEX_HOME_DIR  auth.json → $(readlink "$CODEX_HOME_DIR/auth.json" 2>/dev/null)  （桌面端看不到线程，用 foreman tail / report）"; fi
  echo; echo "--- app-server 握手（不起模型，零 token）---"
  python3 "$PY_APPSERVER" probe --home "$CODEX_HOME_DIR" --codex "$CODEX_BIN" --request-user-input "$(cfg codex.request_user_input true)" || echo "!! app-server 握手失败：codex 执行器暂时不可用，把上面的原始报错告诉用户；不要自行排代理 / 换节点"

  if [ -z "$wt" ]; then doctor_claude; return 0; fi
  echo; echo "--- 沙箱边界自检（codex sandbox，不起模型，零 token）---"
  local gitdir probe="$wt/.fleet-doctor-probe"
  gitdir="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"
  local wr=(-c sandbox_mode=workspace-write -c "sandbox_workspace_write.writable_roots=[\"$gitdir\", \"$wt\"]" -c sandbox_workspace_write.network_access=true)
  sandbox_probe() {
    local label="$1" expect="$2" snippet="$3" out rc=0
    out="$( cd "$PROJECT_ROOT" && CODEX_HOME="$CODEX_HOME_DIR" "$CODEX_BIN" sandbox "${wr[@]}" bash -lc "$snippet" 2>&1 )" || rc=$?   # 线程 cwd = 项目根，探针也在这里跑
    if [ "$expect" = "OK" ]; then
      [ "$rc" -eq 0 ] && echo "  [OK]  $label" || echo "  [!!]  $label —— 失败: $(printf '%s' "$out" | tail -1)"
    else
      [ "$rc" -ne 0 ] && echo "  [OK]  ${label}（如期被挡）" || echo "  [!!]  $label —— 竟然放行了，隔离失效"
    fi
  }
  sandbox_probe "worktree 内可写" OK "touch '$probe'"; rm -f "$probe"
  sandbox_probe "git dir 可写(commit 能成)" OK "touch '$gitdir/.fleet-probe'"; rm -f "$gitdir/.fleet-probe"
  sandbox_probe "项目根之外不可写（HOME）" DENY "touch '$HOME/.fleet-doctor-probe'"; rm -f "$HOME/.fleet-doctor-probe"
  echo "  [i]   项目根整体可写（线程 cwd = 项目根）：改到工作目录之外靠「本轮位置」约束 + report 事后探针标出"
  sandbox_probe "沙箱内可出网" OK "curl --noproxy '*' -sS -m 15 -o /dev/null https://registry.npmjs.org/is-odd"
  sandbox_probe "gh api 读 GitHub" OK "gh api rate_limit --jq .rate.limit >/dev/null"
  local rc=0
  ( cd "$wt" && CODEX_HOME="$CODEX_HOME_DIR" "$CODEX_BIN" sandbox -c sandbox_mode=read-only bash -lc "touch '$probe'" ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] && echo "  [OK]  只读档真的写不了（复审就地跑）" || echo "  [!!]  只读档竟然可写 —— 复审隔离失效"
  rm -f "$probe"
  echo; echo "提示: 若 curl 报连 127.0.0.1 失败，那是没开 network_access 的表现（设了代理时「没网」长这样），不是代理问题。"
  doctor_claude "$wt"
}

# ---------- dispatch ----------

usage() {
  cat <<'EOF'
foreman <command>            执行器: codex（默认，app-server）| claude（Claude Code 非交互）| pi（可选）。

  setup [--codex-home shared|isolated] [--confirm]        本机一次：生成/查看跨项目的角色分工与并发上限（~/.foreman/config.toml）；（同时把五份角色文件样例拷到 ~/.foreman/roles/）
                           和用户确认后 --confirm 打标记，标记没打之前 run / review 拒绝派活
  init [--force]           为当前项目生成 foreman.toml 骨架（~/.foreman/projects/<项目>/，一个项目一份、兼容多仓库）
  config [show|path|get k] 看 / 定位仓库配置
  doctor [<worktree>]      二进制、登录、仓库配置、app-server 握手、沙箱边界（零 token）

  bootstrap <id> (--branch <b> | --slug <s> [--type feat]) [--pr <名>] [--base <br>] [--context <f>] [--gh-issue <n>] [--no-install]
                           建 worktree + 分支、拷 env、装依赖，登记为这张票的一个 PR（一票可多个 PR，--pr 起名）
                           调研票同样用它：--no-install 拿最新 origin/<base> 的检出，之后 run --role research --writable <交付目录>
  here <id> [--base <br>] [--context <f>] [--gh-issue <n>]
                           把编排者当前所在的 git 检出登记为这张票的工作目录（不建 worktree）
  硬规矩: 线程 cwd 永远 = 项目根（编排者的工作目录），worktree / 交付目录写进每轮 prompt 顶部的「本轮位置」；
          沙箱：复审 read-only（只看 diff）；其余角色（实现 / 轻活 / 调研 / 验收）workspace-write；审批默认「替我审批」(on-request + auto_review)。
          完全权限只有一个口子: run --full-access "<用户明确要求的原话>"（无沙箱无审批，原话进日志与摘要横幅；review 没有这个口子）
  run <id> --prompt <f> [--role <名>] [--title <线程名内容>] [--closeout] [--engine codex|pi|claude] [--model m] [--effort e]
           [--detach] [--timeout 1800] [--no-check] [--writable <dir>] [--context <f>] [--question-timeout s]
           [--max-turns n] [--max-budget-usd usd]
           [--full-access "<用户要求原话>"]
                           跑一轮（首轮建线程，之后自动续线程）。并发派活一律 --detach，再 status / wait 收敛
                           --role 取 ~/.foreman/config.toml 的 [roles.<名>]（跨项目，可自定；项目 foreman.toml 同名可覆盖），默认 implement
                           --role research = 只读调研线程（排查 / 核事实 / 找锚点，交事实清单）；--role accept = 验收线程（产品真跑起来对清单看，只报不修）
                           两者都配 --writable <交付目录> 放开交付目录，探针把该目录当作内部
                           --closeout = PR 收尾轮：默认续目标 PR 最近的 implement / mechanical 实现线程（显式 --role / --thread 优先），prompt 顶部自动加收尾阶段契约
                           写码角色 rc=0 后自动 detached 跑 check；--no-check 只跳过本轮
                           codex 与 claude 使用独立并发池；claude 档位来自 [roles.<名>.claude]，池上限来自 [engines.claude] concurrency（默认 3）
  review <id> [--prompt REVIEW.md] [--title <内容>] [--engine codex|claude|pi] [--model m] [--effort e] [--detach] [--timeout 1800]
                           对抗性复审：只读沙箱、新线程（ephemeral）、就地审，挑破坏项目 / 仓库约定与最佳实践的地方，只提意见编排者拍板；--prompt 给需求口径；pi 档一次性副本
  steer <id> [--thread <名>] (<文本> | --file <f> | --from-queue N)
                           口径变化默认立刻通知并用 tail 确认方向；已排队的 run 想立即生效用 --from-queue N
                           turn 已结束则转为新排队轮次，30 秒内等回执；默认线程 implement
  questions [<id>...]      执行者向编排者提的、还没回答的问题
  answer <id> [--qid q] <文本>|--file f
                           回答执行者的提问（超过 codex.question_timeout 没回会给兜底答复）
  status [<id>...]         最近一轮 run / review 的状态（RUNNING / WAITING / DONE / ENGINE_DOWN / DEAD）
  threads <id>             这张票下的全部线程（名字 / 引擎 / 角色 / 引擎内引用 / 轮次），与引擎无关
  wait [<id>...] [--timeout 300] [--progress 300|0] [--interval 20] [--no-report]   有进展才按周期打印；超时附事件尾；返回 2 = 还在跑，3 = 执行者在提问
  report <id> [N|reviewN] [--pr <名>]  重看某轮摘要      tail <id> [N]   最近 N 个 item 级事件（跑到一半也能看）
  diff <id> [-- path]      相对 base 的完整改动
  check <id> [cmd...]      在 worktree 里跑验收命令（默认 foreman.toml 的 verify.commands，空则取仓库 package.json 的 type-check / lint）
  pr <id> --title t --body-file f [--base b] [--draft|--ready] [--yes]   打印 push + gh pr create 命令；--yes 才执行
  list                     本仓库所有 issue 的状态与用量
  cleanup <id> --force [--keep-branch] [--discard-unpushed]   删 worktree 与分支（未提交 / 未推送都会拒绝）

环境变量: FOREMAN_HOME（默认 ~/.foreman） FOREMAN_CODEX_HOME（默认 $FOREMAN_HOME/codex-home） FOREMAN_CODEX_BIN
注意: codex 走 ChatGPT 订阅额度，和你自己开 Codex 抢同一份配额；并发上限：项目 foreman.toml 的 engines.concurrency，缺省本机 config.toml 的默认。
EOF
}

# 整段派发包在函数里：bash 先把函数体整个解析完再执行，脚本文件在长命令（wait）跑到一半时被改也不会读到错位内容
main() {
[ $# -gt 0 ] || { usage; exit 1; }
sub="$1"; shift
case "$sub" in
  setup)     cmd_setup "$@" ;;
  init)      cmd_init "$@" ;;
  config)    cmd_config "$@" ;;
  doctor)    cmd_doctor "$@" ;;
  selftest)  exec bash "$SKILL_DIR/scripts/selftest.sh" "$@" ;;
  bootstrap) cmd_bootstrap "$@" ;;
  here)      cmd_here "$@" ;;
  run)       cmd_run "$@" ;;
  review)    cmd_review "$@" ;;
  questions) cmd_questions "$@" ;;
  answer)    cmd_answer "$@" ;;
  steer)     cmd_steer "$@" ;;
  status)    cmd_status "$@" ;;
  threads)   cmd_threads "$@" ;;
  wait)      cmd_wait "$@" ;;
  report)    cmd_report "$@" ;;
  tail)      cmd_tail "$@" ;;
  diff)      cmd_diff "$@" ;;
  check)     cmd_check "$@" ;;
  pr)        cmd_pr "$@" ;;
  list)      cmd_list "$@" ;;
  cleanup)   cmd_cleanup "$@" ;;
  release)   cmd_release "$@" ;;
  # 内部：--detach 的执行体，由 launch_call 重入调用；参数: <main-repo> <dir> <kind> <n>
  __exec)    MAIN_REPO="$1"; shift; exec_call "$@" ;;
  __auto_check) auto_check_wait "$@" ;;
  __start_auto_check) [ "${FOREMAN_SELFTEST:-}" = 1 ] || die "内部自测命令"; start_auto_check "$@" ;;
  __cleanup_failed_dispatch) [ "${FOREMAN_SELFTEST:-}" = 1 ] || die "内部自测命令"; cleanup_failed_dispatch "$@" ;;
  __check_state) [ "${FOREMAN_SELFTEST:-}" = 1 ] || die "内部自测命令"; check_state "$@" ;;
  __call_state) [ "${FOREMAN_SELFTEST:-}" = 1 ] || die "内部自测命令"; call_state "$@" ;;
  __check_report) [ "${FOREMAN_SELFTEST:-}" = 1 ] || die "内部自测命令"; print_check_report "$@" ;;
  __check_result) [ "${FOREMAN_SELFTEST:-}" = 1 ] || die "内部自测命令"; check_result "$@" ;;
  __prepare_auto_check) [ "${FOREMAN_SELFTEST:-}" = 1 ] || die "内部自测命令"; init_repo_context; prepare_auto_check "$@" ;;
  __hold_active_run) [ "${FOREMAN_SELFTEST:-}" = 1 ] || die "内部自测命令"; hold_active_run "$@" ;;
  -h|--help|help) usage ;;
  *) die "未知命令 '$sub'（-h 看用法）" ;;
esac
}
main "$@"; exit $?
