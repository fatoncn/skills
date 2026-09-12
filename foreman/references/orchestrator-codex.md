# Codex 当编排者

foreman 的命令行与账本不依赖宿主：Codex 可以当编排者，并用 `--engine codex|claude|pi` 派执行者。Claude 引擎的 argv、权限、事件与降级口径见 `claude-code-cli.md`。

## 安装

Codex 会在新会话扫描 `~/.codex/skills/`：

```bash
ln -sfn ~/skills/foreman ~/.codex/skills/foreman
```

Claude Code 另从 `~/.claude/skills/foreman` 读取同一份真源。

## 宿主差异

- 在项目根或仓库内运行 `$FOREMAN`；票的执行线程 cwd 仍由 foreman 固定为项目根。
- Codex 宿主的 spawn 能力按当前产品提供的子 agent 工具使用；不改变 foreman 引擎选择。
- 浏览器、MCP 与凭证边界按宿主会话和项目 `AGENTS.md` 执行；合并仍由人按键。
