# pi CLI 实测笔记

对 `@earendil-works/pi-coding-agent` v0.84.2 的实测结论。改 `pi-foreman.sh` 之前先读这里，
不要凭 `--help` 猜行为。

## 核心调用

```bash
pi -p --mode json \
   --session-id <id> \
   --append-system-prompt <file> \
   "<prompt>"
```

- `-p` 非交互，处理完即退出。
- `--mode json` 输出 JSONL 事件流到 stdout；stderr 放警告。
- `--session-id <id>` **不存在则建、存在则续**，会话按 cwd 分项目命名空间。
  这是「和同一个 pi 反复沟通」的全部机制——不需要别的状态管理。
  首次会往 stderr 打 `Warning: No project session found ...`，是正常的。
- `--append-system-prompt` 接**文件路径或文本**，可重复多次，实测文件注入生效。
- 会话文件落在 `~/.pi/agent/sessions/<cwd-slug>/`。

## 已验证的行为

| 项 | 结论 |
|---|---|
| 工具审批 | **没有**。`-p` 模式下 write / edit / bash 全部自动执行，不询问 |
| 沙箱 | **没有**。官方 `docs/security.md` 明说，隔离要靠 OS/容器 |
| 工作目录 | bash 工具的 cwd = 启动 pi 的目录，worktree 隔离可行 |
| 上下文文件 | 自动加载 `AGENTS.md` / `CLAUDE.md`（除非 `-nc`），不用手喂仓库规范 |
| 成本 | 每条 assistant `message_end` 的 `usage.cost.total`，累加即为总成本 |
| 退出码 | 模型报错时进程仍可能 exit 0，**必须解析事件流判断成败** |

## 事件流要点

```
{"type":"session","id":...,"cwd":...}     首行
{"type":"agent_start"} / {"type":"turn_start"}
{"type":"message_update", ...}            增量，只有 delta，无累积快照
{"type":"message_end","message":{...}}    权威消息体
{"type":"tool_execution_start","toolName":...,"args":{...}}
{"type":"tool_execution_end","isError":bool,"result":...}
{"type":"turn_end"} / {"type":"agent_end"}
{"type":"agent_settled"}                  正常收尾标志
```

判定成败必须看三处，缺一会误判：
1. 有没有 `agent_settled`（没有 = 被杀/崩溃/超时）
2. 有没有 assistant `message_end` 的 `stopReason == "error"`（带 `errorMessage`）
3. 有没有 `tool_execution_end` 的 `isError == true`

**最后一条 assistant 文本消息 = pi 的交付报告**，这是编排者唯一读到的东西，
所以角色文件强制它用固定格式收尾。

## 后台执行（`run --detach` / `review --detach`）

宿主 agent 的 shell 工具都有超时上限，而且命令返回后可能把整个进程组一并收掉，
所以后台档不能只靠 `&`：`launch_call` 借 python3 做 `os.setsid()`（macOS 没有 `setsid(1)`）
再 exec 回本脚本的隐藏子命令 `__exec`，pi 因此活在一个和宿主无关的会话里。

一次调用的全部输入都先落盘，前台与后台跑的是同一段代码（`exec_call`）：

| 文件 | 内容 |
|---|---|
| `<kind>-N.argv` | pi 的完整 argv，NUL 分隔（含 prompt 正文）|
| `<kind>-N.cwd` / `.timeout` / `.rmwt` | 工作目录、看门狗上限、跑完要销毁的一次性副本（复审档）|
| `<kind>-N.started` / `.pid` | 起始时间戳、活着的进程 pid（结束后删除）|
| `<kind>-N.rc` | 退出码，**它的存在 = 这一轮结束了**；`143` = 看门狗超时 SIGTERM |
| `<kind>-N.jsonl` / `.stderr` | 事件流与警告 |

`status` 就是读这几个文件：有 `.rc` = DONE；`.pid` 还活着 = RUNNING；
两者皆无但有 `.argv` = DEAD（被外力杀掉，按失败处理）。
`kind` 取 `run` 或 `review`，两类会话共用这套机制。

## 坑

- **`--thinking off` 对某些模型直接 400**。实测 `qwen/qwen3.8-max` 报
  `Reasoning is mandatory for this endpoint and cannot be disabled.`——不要为省钱关思考。
- **macOS 没有 `timeout` / `gtimeout`**，脚本里用 `sleep + kill` 自己做看门狗；
  超时被 SIGTERM 杀掉表现为 `rc=143` 且流里没有 `agent_settled`。
- stderr 常有一行 `Shell cwd was reset to ...`，无害，摘要里已过滤。
- `message_update` 是 delta-only，不要拿它拼状态；只用 `message_end`。

## 用户当前配置（`~/.pi/agent/settings.json`）

`openrouter` + `qwen/qwen3.8-max` + thinking `high`。只认证了 openrouter 一家。
`~/.pi/agent/trust.json` 里 `/Users/<you>/workspace` 已信任。
换模型用 `$PF run --model <pattern>`，不要去改用户的全局 settings。

## 模型实测（26-08-17）

| 模型 | 实测 |
|---|---|
| `qwen/qwen3.8-max` | 默认。1M context / 131K max-out。契约+纯函数+测试这类中等任务约 $0.40、60–70 万 token |
| `deepseek/deepseek-v4-flash-latest` | 简单任务档。1M context。同类小任务约 $0.002 —— 便宜两个数量级 |

`--list-models` 给 `deepseek/deepseek-v4-flash-latest` 报的 max-out 是 **4.1K**，
而同系列 `deepseek/deepseek-v4-flash` 报 393.2K —— 这是 catalog 对 `-latest` 别名的
元数据缺口，不是真限制：实测一次性写 61 行 TS 文件完整落盘、无截断、无报错。
但没有验证过更大的单次写入；**若某个任务需要一次生成很大的单文件，用 qwen 或
钉住 `deepseek/deepseek-v4-flash`**，别赌那个别名。

## 这个仓库特有的

- worktree **不自带 `.env` / `.env.local` / `node_modules`**，不 bootstrap 的话 pi 会把
  环境问题误报成代码 bug。`$PF bootstrap` 已处理。
- 根 `pnpm lint` 会先跑 `check-branch-name.mjs`，分支名不合
  `<type>/<YY-MM-DD>/<slug>` 直接失败。`$PF bootstrap` 会提前拦。
- 迭代期用 `pnpm affected:check`（lint + type-check 的受影响子集）比根 `pnpm lint` 快得多；
  收口前再跑完整的。
