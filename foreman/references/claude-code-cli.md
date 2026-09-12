# Claude Code CLI 执行桥

版本锚定：Claude Code 2.1.268（2026-09-12 实测）。升级 CLI 后必须重跑本文末尾的复验清单。

## 一轮一进程

每轮启动一个 `claude -p`，首轮从 `system.init.session_id` 建账，后续轮次用 `--resume <session_id>`：

```text
claude -p --output-format stream-json --verbose --input-format text
  --model <model> --effort <low|medium|high|xhigh|max>
  --permission-mode <auto|bypassPermissions>
  --setting-sources '' --settings <run-N.settings.json>
  --strict-mcp-config --mcp-config <run-N.mcp.json>
  [--permission-prompt-tool mcp__foreman__approve]
  --append-system-prompt-file <run-N.system.md>
  --max-turns <n> --max-budget-usd <usd>
  [--resume <session_id>] [--no-session-persistence]
```

prompt 通过 stdin 传入。默认 `max_turns = 80`、`max_budget_usd = 5`；项目可在 `[claude]` 覆盖。普通轮使用 `auto`；只有同时带用户授权布尔标记与用户原话的 `--full-access` 轮使用 `bypassPermissions`，并关闭 sandbox、移除权限 MCP。

## settings 与 MCP

`run-N.settings.json` 固定隔离用户 settings：sandbox 开启并 `failIfUnavailable`，不自动放行 Bash，不允许未沙箱命令；`allowWrite` 包含 worktree、显式 `--writable` 根和 common gitdir。`permissions.deny` 映射共享 `summarize.FORBIDDEN` 禁止项，`permissions.ask = ["AskUserQuestion"]`。收尾轮只移除 `CLOSEOUT_ALLOW` 对应的 push / gh PR 放行项。

`run-N.mcp.json` 显式包含 foreman stdio 权限 server，以及从 `~/.claude.json` 内存读取的 `mcpServers`。用户 settings、hooks、插件不参与。权限 server 在启动模型前做 `initialize` 与 `tools/list` 自检，失败按 `ENGINE_DOWN` 退出。

权限 MCP 最小协议为逐行 JSON-RPC：`initialize`、`tools/list`、`tools/call`。`approve` 返回的文本内容是 JSON 串：放行为 `{"behavior":"allow","updatedInput":{...}}`，拒绝为 `{"behavior":"deny","message":"..."}`。`AskUserQuestion` 写现有 questions / answer 文件族；答案按问题文本写入 `updatedInput.answers`。其它升级到 MCP 的动作默认拒绝，权限决定不会超时放行。

## 事件与文件族

`run-N.jsonl` 首行是 `_foreman` 引擎标记（engine、cli_version、session_id、role、model、effort、permission_mode、cwd、work_dir、writable_roots、started_at）；其中 `work_dir` 无 worktree 时为 null，`writable_roots` 与本轮 settings 的 `sandbox.allowWrite` 复用同一数组。中间逐行原样保留 Claude stream-json，并穿插 permission / question 决策标记；末行是 `turn_summary`（rc、raw_rc、subtype、terminal_reason、session_id、usage、total_cost_usd、cost_basis、ended_at）。

每轮沿用 `argv / cwd / timeout / engine / jsonl / pid / rc / full-access` 文件族，新增 `claude.json`、`settings.json`、`mcp.json`、`system.md`。`argv` 是 NUL 分隔的真实 Claude argv。

| rc | 含义 |
|---:|---|
| 0 | `result.subtype == success` |
| 1 | Claude result 错误（轮次、预算或模型侧失败） |
| 3 | 启动、参数或 stream-json 协议失败 |
| 4 | 认证、模型、服务端或权限审查器不可用（ENGINE_DOWN） |
| 143 | foreman 超时或信号中断；session 可续 |

## 已知降级

- steer 只排到下一轮，不宣称已注入当前 Claude 进程。
- Claude 复审只读是工具集级只读，不是 OS 级只读。
- 用户 MCP 的远端写不在本地 Bash / 文件事件探针观测面。

## 升级复验清单

1. 核对上述所有 argv 开关、`auto` / `bypassPermissions` 与 effort 五档。
2. 用真实 CLI 验证 stream-json 的 `system.init`、`result`、session_id、usage 与 cost 字段。
3. 真走一次权限 MCP initialize / list / call，覆盖 allow、deny、AskUserQuestion 回答与超时。
4. 验证 settings sandbox 四键、allowWrite、deny / ask 规则仍被 CLI 接受。
5. 覆盖正常结束、坏 JSON、EOF、预算 / max turns、认证失败与 SIGTERM 的 rc 归一化。
6. 跑 `claude_replay.py --selftest`、完整 `selftest.sh`、Codex 分发快照和真实两轮 resume 冒烟。
