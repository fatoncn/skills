# foreman.toml 字段说明（项目配置；项目规则在项目根 AGENTS.md，不在这里）

位置：`~/.foreman/projects/<项目目录名>/foreman.toml`，**一个项目一份、兼容多仓库**。项目 = Claude 的工作目录：从仓库上一级向上找第一个带 `AGENTS.md` / `CLAUDE.md` 的目录，找不到就是仓库本身；不在 git 仓库里时从当前目录向上找。
`foreman init` 只生成骨架（中性默认），项目特有字段由编排者按项目规则填；`foreman config show` 查看；改完直接生效。`init --force` 会覆盖手改，慎用。

## 三层怎么叠

| 层 | 在哪 | 例子 |
|---|---|---|
| 运行时事实 | 不写文件，每次从当前检出推导 | origin、slug、远端默认分支、lockfile → 装依赖命令、package.json → 验收命令 |
| 项目级默认 | 顶层各表 | worktree 落点、分支规范、gh 入口、review 轮次、规则文件 |
| 按仓库覆盖 | `[repos."<slug>"]`，键名与顶层同名 | `repo.default_base = "staging"`、`repo.copy_env = [".env.local"]` |

读取顺序：`[repos."<当前仓库 slug>"]` 同名键 > 顶层 > 运行时事实（仅 default_base / install_cmd / verify.commands 有回落）。派活时 `bootstrap --base` / `--copy-env` 可临时指定。仓库 slug = origin 的 `<owner>--<repo>`，`foreman doctor` 会打印。

## [project]

| 字段 | 含义 | 默认 |
|---|---|---|
| `root` | 项目根 | 探测 |

## [repo]（项目里每个仓库的默认）

| 字段 | 含义 | 默认 |
|---|---|---|
| `default_base` | 票与 PR 的基线分支 | 空 = 远端默认分支；按仓库写 `[repos]` 或 `--base` |
| `branch_template` / `branch_pattern` | 分支名模板与正则，`{type} {yy} {mm} {dd} {slug}` | `{type}/{yy}-{mm}-{dd}/{slug}` |
| `branch_check` | `strict` 不合规 bootstrap 直接拒；`warn` 只提示 | warn；仓库有校验脚本就改 strict |
| `worktree_root` / `worktree_prefix` | worktree 落点 `<root>/<prefix><issue-id>`；占位符 `{repo}` 仓库主 checkout、`{project}` 项目根、`{name}` 仓库目录名 | `{repo}/.claude/worktrees` + `foreman-`；按项目规则改 |
| `copy_env` | bootstrap 从主 checkout 拷进 worktree 的未跟踪文件 | 空；按仓库写 `[repos]` 或 `--copy-env` |
| `install_cmd` | bootstrap 装依赖命令（`--no-install` 跳过） | 空 = 按 lockfile 自动 |

## [verify]

`commands`：`foreman check <id>` 默认命令；空 = 取当前仓库 package.json 的 type-check / lint；票的完成定义可覆盖（`foreman check <id> "<cmd>" ...`）。

## [github]

| 字段 | 含义 | 默认 |
|---|---|---|
| `gh` | gh 入口，可以是包装脚本 | `gh`；项目要求包装脚本就填它 |
| `pr_draft` | 默认开 draft | true |

## [engines]

`concurrency`：codex 池从本项目派发时的并发上限，覆盖本机默认；`default`：角色没写 engine 时的默认执行器 `codex` / `claude` / `pi`。

`[engines.claude] concurrency`：Claude 独立池上限，默认 3；与 codex 一样按本机所有项目的活进程合计，两个池不混算。

## 全局配置 `~/.foreman/config.toml`（本机一份，跨项目）

| 字段 | 含义 | 默认 |
|---|---|---|
| `codex.home` | 执行者的 CODEX_HOME 模式，**初始化时必须显式选**，不设 `run` / `review` / `setup --confirm` 拒绝：`shared` 共用桌面端 `~/.codex`（桌面端能看到线程；执行者继承桌面端 MCP / 插件 / notify / 全局 AGENTS.md）；`isolated` 独立 `~/.foreman/codex-home`（只共用登录态）。`foreman setup --codex-home <模式>` 写入；环境变量 `FOREMAN_CODEX_HOME=<路径>` 可绕过 | 无默认 |
| `roles_confirmed` | 角色分工是否已由使用者过目确认；false 时 `run` / `review` 拒绝派活 | false |
| `codex.thread_name` | 线程命名模板，须含 `{ids}`（相关 issue / PR 号）与 `{title}`（工作内容） | `foreman {ids}: {title}` |
| `engines.concurrency` | 在跑 codex 线程上限的本机默认（run + review，计数是所有项目合计）；项目 foreman.toml 同名键覆盖 | 5 |
| `engines.claude.concurrency` | 在跑 Claude 轮次上限，独立计数 | 3 |
| `roles.<名>` | 角色 = `engine` / `model` / `effort` + 角色文件；implement / review / mechanical 三个都必需，再多的自定 | Codex 档位 |
| `roles.<名>.claude` | 该角色在 Claude 引擎下的 `model` / `effort`；缺失则 `--engine claude` 直接拒绝 | 参考角色见模板 |
| `roles.<名>.prompt` | 角色文件路径（契约：位置 / 沙箱事实 / 分工边界 / 提问 / 输出格式，不含干活纪律） | `~/.foreman/roles/<名>.md`，`setup` 从 `assets/roles/` 拷样例 |

项目 foreman.toml 里写同名 `[roles.<名>]` 可覆盖档位与角色文件。

## [codex]

| 字段 | 含义 | 默认 |
|---|---|---|
| `sandbox_network` | workspace-write 沙箱是否开 shell 网络 | true |
| `web_search` | 服务端联网搜索 | true |
| `approval_policy` / `approvals_reviewer` | `on-request` + `auto_review` = 「替我审批」 | on-request / auto_review |
| `approvals` | 自动审查不接、回到执行体时 `decline` / `accept` | decline |
| `request_user_input` | Default 模式是否开放提问工具；执行体用进程级功能位覆盖，修改后重起 hold 生效 | true |
| `question_timeout` | 执行者提问时等编排者回答的秒数；0 = 立即兜底 | 1800 |
| `hold_idle_minutes` | 常驻执行体占着线程（写锁）、空闲多久自动释放；`foreman release` / `cleanup` 之前桌面端打不开这条线程 | 360 |

## [claude]

| 字段 | 含义 | 默认 |
|---|---|---|
| `max_turns` | 每轮 Claude Code 最大 turn 数，可用 `run --max-turns` 覆盖 | 80 |
| `max_budget_usd` | 每轮 CLI 预算上限，可用 `run --max-budget-usd` 覆盖 | 5 |
| `question_timeout` | AskUserQuestion 等编排者回答的秒数；复审固定 0 | 1800 |

Claude 角色完整例子：

```toml
[roles.implement]
engine = "codex"
model = "gpt-6-sol"
effort = "medium"

[roles.implement.claude]
model = "sonnet"
effort = "high"
```
