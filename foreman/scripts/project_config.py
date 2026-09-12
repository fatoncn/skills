#!/usr/bin/env python3
"""foreman 项目配置：一个项目（Claude 的工作目录）一份 foreman.toml，兼容多仓库。

用法:
  project_config.py init  --project-dir <dir> --project-root <root> --main-repo <repo> [--force]
  project_config.py get   --path <toml> [--repo <slug>] <key> [--default <v>]   # repos.<slug>.<key> 优先于顶层 <key>
  project_config.py facts --main-repo <repo>                                   # 当前仓库的运行时事实（JSON）
  project_config.py dump  --path <toml>

分层：
  顶层            项目级默认（worktree 落点、分支规范、gh 入口、review 轮次……），对项目里所有仓库生效
  [repos."<slug>"] 某个仓库不同的地方（基线分支、要拷的 env、验收命令……），同名键覆盖顶层
  运行时事实      origin / 远端默认分支 / lockfile 装依赖命令 / package.json 验收命令，不写进文件，每次从当前检出推导
"""
from __future__ import annotations
import json, os, re, subprocess, sys, tomllib

SCHEMA = 2


def sh(args, cwd=None) -> str:
    try:
        return subprocess.run(args, cwd=cwd, capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return ""


def slug_from_origin(origin: str) -> str:
    s = origin.strip()
    s = re.sub(r"\.git$", "", s)
    s = re.sub(r"^[a-z]+://", "", s)
    s = re.sub(r"^[^@]+@", "", s)
    s = s.replace(":", "/")
    parts = [p for p in s.split("/") if p]
    tail = parts[-2:] if len(parts) >= 2 else parts
    return "--".join(tail) or "local"


# ---------- 运行时事实（不进配置文件） ----------

def repo_facts(main_repo: str) -> dict:
    origin = sh(["git", "-C", main_repo, "remote", "get-url", "origin"])
    head = sh(["git", "-C", main_repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"])
    head = head.split("/", 1)[1] if "/" in head else (head or "main")
    pm = "pnpm" if os.path.isfile(os.path.join(main_repo, "pnpm-lock.yaml")) else \
         "yarn" if os.path.isfile(os.path.join(main_repo, "yarn.lock")) else \
         "npm" if os.path.isfile(os.path.join(main_repo, "package-lock.json")) else ""
    install_cmd = {"pnpm": "pnpm install --frozen-lockfile", "yarn": "yarn install --immutable", "npm": "npm ci"}.get(pm, "")
    verify = []
    pkg = os.path.join(main_repo, "package.json")
    if pm and os.path.isfile(pkg):
        try:
            scripts = json.load(open(pkg, encoding="utf-8")).get("scripts") or {}
        except Exception:
            scripts = {}
        for name in ("type-check", "typecheck", "lint"):
            if name in scripts:
                verify.append(f"{pm} {name}" if pm != "npm" else f"npm run {name}")
    refs = sh(["git", "-C", main_repo, "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/"]).split()
    names = [r.split("/", 1)[1] for r in refs if "/" in r and not r.endswith("/HEAD")]
    likely = [n for n in names if n in ("main", "master", "staging", "development", "develop", "dev", "next", "trunk") or n.startswith("release")]
    return {
        "origin": origin,
        "slug": slug_from_origin(origin) if origin else os.path.basename(main_repo),
        "name": os.path.basename(main_repo),
        "main_checkout": main_repo,
        "remote_default_branch": head,
        "likely_bases": likely,
        "install_cmd": install_cmd,
        "verify_commands": verify,
    }


# ---------- 项目配置骨架 ----------

def detect_project(project_root: str, main_repo: str) -> dict:
    project_is_repo = os.path.realpath(project_root) == os.path.realpath(main_repo)
    # 项目目录本身就是仓库时两者留空：codex 会自动读仓库内 AGENTS.md，不要重复注入。
    return {
        "schema": SCHEMA,
        "project": {"root": project_root},
        "repo": {
            "default_base": "",
            "branch_template": "{type}/{yy}-{mm}-{dd}/{slug}",
            "branch_pattern": r"^[a-z][a-z0-9-]*/[0-9]{2}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])/[a-z0-9]+(-[a-z0-9]+)*$",
            "branch_check": "warn",
            "worktree_root": "{repo}/.claude/worktrees",
            "worktree_prefix": "foreman-",
            "copy_env": [],
            "install_cmd": "",
        },
        "verify": {"commands": []},
        "github": {"gh": "gh", "pr_draft": True},
        "engines": {"default": "codex", "concurrency": 5},
        "codex": {"sandbox_network": True, "web_search": True,
                  "approval_policy": "on-request", "approvals_reviewer": "auto_review", "approvals": "decline", "question_timeout": 600, "hold_idle_minutes": 360},
        "claude": {"max_turns": 80, "max_budget_usd": 5, "question_timeout": 1800},
    }


COMMENTS = {
    "project": "项目 = Claude 的工作目录（可含多个仓库）。root 是这份配置属于哪个目录：项目目录名撞车时脚本靠它拒绝串用。",
    "repo": "对项目里每个仓库都适用的默认。default_base 空 = 远端默认分支（按仓库不同的写到下面 [repos.\"<slug>\"]，或派活时 bootstrap --base）。"
            "worktree_root / worktree_prefix 支持占位符 {repo}=仓库主 checkout、{project}=项目根、{name}=仓库目录名。"
            "copy_env = bootstrap 从主 checkout 拷进 worktree 的未跟踪文件。install_cmd 空 = 按 lockfile 自动。branch_check=strict 时不合规直接拒 bootstrap。",
    "verify": "机械验收默认命令（foreman check）。空 = 从当前仓库 package.json 自动取 type-check / lint；每张票的完成定义可覆盖（foreman check <id> <cmd...>）。",
    "github": "gh 可以是包装脚本（foreman pr / doctor 用）。pr_draft = 建 PR 默认 draft。汇总分支、关票、issue 首行契约这些是编排者按项目规则做的事，不在这里配。",
    "engines": "角色没写 engine 时的默认执行器（codex / claude / pi）。concurrency 是 codex 独立池上限；Claude 独立池用 [engines.claude] concurrency（默认 3），两者都按本机所有项目合计。",
    "roles": "本项目要覆盖的角色档位（同名覆盖 ~/.foreman/config.toml 的 implement / review / mechanical）。单次 --model / --effort 可覆盖。",
    "codex": "codex 执行器细节。沙箱不在这里配：实现固定 workspace-write、复审固定 read-only，完全权限只有用户明确要求时 foreman run --full-access 「用户原话」。sandbox_network / web_search 是给执行者的能力开关。"
             "审批默认『替我审批』= approval_policy=on-request + approvals_reviewer=auto_review；approvals 是自动审查仍回给编排者时的兜底（decline/accept）。question_timeout 是执行者提问时等编排者的秒数，0=立即兜底答复。hold_idle_minutes：常驻执行体占着线程、空闲多久自动释放（编排者 release / cleanup 之前桌面端打不开该线程）。",
    "claude": "Claude Code 一轮一进程的上限：max_turns、max_budget_usd，以及 AskUserQuestion 等待 answer 文件的 question_timeout。",
}

REPOS_EXAMPLE = '''
# 按仓库覆盖：某个仓库和项目默认不一样的地方写在这里，键名与顶层同名（repo.* / verify.* / github.* 都可以）。
# 仓库 slug = origin 的 <owner>--<repo>，foreman doctor 会打印当前仓库的 slug。例如：
# [repos."owner--repo"]
# repo.default_base = "staging"
# repo.copy_env = [".env.local"]
# verify.commands = ["pnpm type-check", "pnpm lint", "pnpm test:unit"]
'''


# ---------- TOML 输出（够用即可：标量、字符串列表、两层表） ----------

def toml_scalar(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(toml_scalar(v) for v in value) + "]"
    return json.dumps(str(value), ensure_ascii=False)


def render(cfg: dict) -> str:
    out = ["# foreman 项目配置：一个项目（Claude 的工作目录）一份，兼容多仓库。init 只生成骨架（中性默认），项目特有字段由编排者按项目规则填。",
           "# 顶层 = 项目级默认；[repos.\"<slug>\"] = 某个仓库的覆盖；origin / 远端默认分支 / 装依赖 / 验收命令这类仓库事实运行时推导，不写在这里。",
           "# 字段说明: ~/.claude/skills/foreman/references/project-config.md",
           "# 角色分工与本机并发上限是跨项目的，在 ~/.foreman/config.toml；本项目要不同档位时在这里加同名 [roles.<名>] 覆盖。", ""]
    out.append(f"schema = {cfg['schema']}")
    for table, body in cfg.items():
        if table == "schema" or not isinstance(body, dict):
            continue
        out.append("")
        if table in COMMENTS:
            out.append(f"# {COMMENTS[table]}")
        out.append(f"[{table}]")
        for key, value in body.items():
            out.append(f"{key} = {toml_scalar(value)}")
    out.append(REPOS_EXAMPLE)
    return "\n".join(out)


# ---------- 子命令 ----------

def cmd_init(argv: list[str]) -> int:
    project_dir = project_root = main_repo = None
    force = False
    i = 0
    while i < len(argv):
        if argv[i] == "--project-dir":
            project_dir = argv[i + 1]; i += 2
        elif argv[i] == "--project-root":
            project_root = argv[i + 1]; i += 2
        elif argv[i] == "--main-repo":
            main_repo = argv[i + 1]; i += 2
        elif argv[i] == "--force":
            force = True; i += 1
        else:
            print(f"init: 未知参数 {argv[i]}", file=sys.stderr); return 2
    if not (project_dir and project_root and main_repo):
        print("init: 需要 --project-dir、--project-root 与 --main-repo", file=sys.stderr); return 2
    path = os.path.join(project_dir, "foreman.toml")
    if os.path.exists(path) and not force:
        print(f"已存在，不覆盖: {path}（加 --force 重新生成骨架，会丢手改）")
        return 0
    os.makedirs(project_dir, exist_ok=True)
    cfg = detect_project(project_root, main_repo)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(render(cfg))
    with open(path, "rb") as fh:
        tomllib.load(fh)   # 回读校验
    facts = repo_facts(main_repo)
    print(path)
    print("骨架已生成（中性默认）。项目特有的字段先读项目规则再填，不要猜：")
    print(f"  项目根: {project_root}{'（项目就是仓库本身）' if os.path.realpath(project_root) == os.path.realpath(main_repo) else '  → 规则: ' + os.path.join(project_root, 'AGENTS.md')}")
    print("  github.gh                             项目要求用包装脚本就填它的路径")
    print("  repo.worktree_root / worktree_prefix  项目约定的 worktree 落点（默认 {repo}/.claude/worktrees）")
    print("  repo.branch_pattern / branch_check    分支名规范；仓库有校验脚本就改 strict")
    print(f"  按仓库不同的（基线分支、要拷的 env、验收命令）写 [repos.\"<slug>\"]，当前仓库 slug = {facts['slug']}，远端有: {', '.join(facts['likely_bases']) or '?'}；派活时也可 bootstrap --base / --copy-env 临时指定")
    return 0


def lookup(node, key: str):
    for part in key.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node


def emit(value) -> None:
    if isinstance(value, bool):
        print("true" if value else "false")
    elif isinstance(value, list):
        for item in value:
            print(item)
    else:
        print(value)


def cmd_get(argv: list[str]) -> int:
    path = default = key = repo = None
    i = 0
    while i < len(argv):
        if argv[i] == "--path":
            path = argv[i + 1]; i += 2
        elif argv[i] == "--default":
            default = argv[i + 1]; i += 2
        elif argv[i] == "--repo":
            repo = argv[i + 1]; i += 2
        else:
            key = argv[i]; i += 1
    if not path or not key:
        print("get: 需要 --path 与 key", file=sys.stderr); return 2
    with open(path, "rb") as fh:
        cfg = tomllib.load(fh)
    value = None
    if repo:
        value = lookup((cfg.get("repos") or {}).get(repo) or {}, key)
    if value is None:
        value = lookup(cfg, key)
    if value is None:
        if default is None:
            return 1
        print(default)
        return 0
    emit(value)
    return 0


def cmd_facts(argv: list[str]) -> int:
    main_repo = argv[argv.index("--main-repo") + 1] if "--main-repo" in argv else None
    if not main_repo:
        print("facts: 需要 --main-repo", file=sys.stderr); return 2
    print(json.dumps(repo_facts(main_repo), ensure_ascii=False))
    return 0


def cmd_dump(argv: list[str]) -> int:
    path = argv[argv.index("--path") + 1] if "--path" in argv else None
    if not path:
        print("dump: 需要 --path", file=sys.stderr); return 2
    print(open(path, encoding="utf-8").read())
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print(__doc__, file=sys.stderr); sys.exit(2)
    sub, rest = args[0], args[1:]
    sys.exit({"init": cmd_init, "get": cmd_get, "facts": cmd_facts, "dump": cmd_dump}.get(sub, lambda _: (print(__doc__, file=sys.stderr), 2)[1])(rest))
