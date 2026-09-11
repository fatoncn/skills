# 副线：Codex 当编排者、Claude 当执行器（未实现，只留接口与说明）

主线是 Claude Code 编排、codex 执行。用户 2026-09-11 拍板：这条副线**将来可能用、现在不做**。本文记下要补什么，免得重查。

## pi-fleet 已经有的

- **宿主无关**：SKILL.md 与脚本两边都能读，Codex 也能当编排者跑 `$FOREMAN …`。
- 但执行器只有 pi 和 codex，**Claude 从未作为执行器出现**。「Codex 指挥 Claude」= Codex 当编排者 + 新增一个 claude 执行器。

## 让 Codex 看到这个 skill

Codex 会扫 `~/.codex/skills/` 和 `~/.agents/skills/`（2026-09-11 实测：放在后者会被桌面端直接用上）。本 skill 现在只装 `~/.claude/skills/foreman`；要给 Codex 用时再软链：

```bash
ln -s ~/.claude/skills/foreman ~/.codex/skills/foreman
```

注意 Codex 有 skills context budget（`Exceeded skills context budget` 会截断描述），SKILL.md 的 description 已尽量短。

## claude 执行器要做的（`foreman run --engine claude`）

本机 `claude` 2.1.267 具备所需参数：

```bash
claude -p --output-format stream-json --verbose \
  --model <opus|sonnet> [--effort <level>] \
  --append-system-prompt-file <角色文件拼好的 dev 指令> \
  --permission-mode <bypassPermissions|acceptEdits> \
  --add-dir <git common dir> \
  [--resume <session-id>] \
  "<prompt>"
```

要点：
1. **没有 OS 级沙箱**（与 pi 同）：隔离只靠 worktree + `--add-dir` 的目录白名单 + 事后越界探针。**硬规矩同样适用**：默认不许 `--permission-mode bypassPermissions` / `--dangerously-skip-permissions`，先用 `acceptEdits` + `--allowedTools` 白名单跑，权限不足就让它报 BLOCKED；只有用户明确要求时才走 `--full-access` 同款口子（原话进日志）。派活目录同样必须等于编排者当前所在的检出目录。
2. **续会话**：首轮从 stream-json 的 `system.init.session_id` 捞 session id 存 meta（`claude_session`），后续 `--resume`。
3. **事件流词汇**：stream-json 的 `type` ∈ `system` / `assistant` / `user` / `result`；工具调用在 `assistant.message.content[].type == "tool_use"`（`name`=Bash 时 `input.command` 是命令原文，探针用它）；结束看 `result.subtype`（`success` / `error_max_turns` / …）与 `result.result` 文本 = 交付报告；`result.total_cost_usd` 是美元成本。`summarize.py` 需加 `scan_claude`。
4. **模型**：届时在全局 `~/.foreman/config.toml` 加 `[claude]` 段配 implement/review 的模型名（现在没有这一段，脚本不读）。
5. `exec_call` 里 claude 与 pi 一样：stdout 直接落 `run-N.jsonl`。
6. 复审：`--permission-mode plan` 或 `--disallowedTools Edit,Write,Bash(git commit*)` 都挡不住 bash 写文件，所以复审要像 pi 档一样用**一次性副本 worktree**。

## Codex 当编排者时的差异

- 编排者读 `references/*` 与 `assets/*` 的方式相同；`$FOREMAN` 命令行相同。
- Codex 桌面端会话的 cwd 通常是工作区根而不是仓库，`foreman` 要求在 git 仓库内运行——先 `cd` 进仓库。
- 宿主子 agent 那一栏（只读调研）换成 Codex 自己的子代理机制。
- 浏览器验收按项目自己的 skill；Codex 侧同样不派给执行器。
