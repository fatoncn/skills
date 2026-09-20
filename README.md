# skills

个人维护的 Claude Code / Codex skill 集合：

| skill | 一句话 |
| --- | --- |
| [`foreman`](foreman/SKILL.md) | 编排层统筹、执行层干活。一份**分工指导**（统筹 / 执行怎么切、外派 foreman / spawn 两条通道怎么选、任务书与验收纪律，任何编排会话都适用）加一套**外派框架**（只在要把活外派给 spawn 之外的 Agent 时启用）：Claude Code 当编排者，指挥本地 codex（`codex app-server` 协议；claude 引擎 beta）在独立 git worktree 里调研、实现、交叉复审、验收、收尾成 PR，票 / 线程 / 角色由脚本强制，验收靠机械检查 + 事后越界探针。 |
| [`public-access`](public-access/SKILL.md) | 让本地 HTTP / SSE / WebSocket 项目通过已有公网中转机、reverse SSH 与 Nginx TLS 获得稳定域名入口；提供严格 manifest、本地配置生成、独立隧道常驻和分层排障方法。 |

## 安装

```bash
git clone https://github.com/fatoncn/skills.git ~/skills
ln -s ~/skills/foreman ~/.claude/skills/foreman   # 或 cp -r 一份
ln -s ~/skills/public-access ~/.codex/skills/public-access   # Codex；Claude Code 可改为 ~/.claude/skills/
```

`foreman` 依赖 `codex` CLI（已登录）、`python3`、`git`。第一次用先跑 `scripts/foreman.sh doctor` 和 `setup`，步骤见 [foreman/SKILL.md](foreman/SKILL.md)「第一次用」一节；变更记录在 [foreman/CHANGELOG.md](foreman/CHANGELOG.md)。

`public-access` 的本地生成与隧道运行依赖 Node.js 和 OpenSSH client；公网中转机需已有 OpenSSH server、Nginx 与可用的 ACME 客户端。
