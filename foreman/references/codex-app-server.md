# codex app-server 实测笔记（foreman 默认执行器）

对 codex-cli **0.153.4**（ChatGPT 桌面端内置二进制）的实测与设计决定，2026-09-11。
改 `scripts/codex_appserver.py` 之前先读这里。`codex exec` 那条路的笔记在 [`codex-cli.md`](./codex-cli.md)，
其中「沙箱四坑」对 app-server 同样成立（同一套 core）。

## 为什么从 `codex exec` 换到 app-server

| 能力 | `codex exec --json` | `codex app-server` |
|---|---|---|
| 角色注入 | 只能 `$CODEX_HOME/AGENTS.md`，所以每票一份 CODEX_HOME | `thread/start.developerInstructions`，全 skill 一份 home |
| 模型 / 推理档 | 进程级 `-c`，run 与 review 共用一个 effort | `thread/start.model` + `turn/start.effort`，每轮可换 |
| 续会话 | `exec resume` 参数表更窄（无 `-s` / `-C`） | `thread/resume` 参数与 start 一致 |
| 审批 / 提问 | 非交互，模型没法问人 | `item/tool/requestUserInput` 等作为**服务端请求**回给客户端，编排者能当场答 |
| 中断 | 只能杀进程 | `turn/interrupt` 优雅收尾（status=interrupted） |
| 成败判定 | 缺 `turn.completed` 就当失败 | `turn/completed.turn.status` ∈ completed / interrupted / failed，带 `error` |
| 状态 | `mcp-server` 在 0.153.4 已标 **deprecated** | app-server 标 experimental，但桌面端与 IDE 扩展就是它的客户端 |

## 核心调用

```
CODEX_HOME=<foreman home> codex app-server --listen stdio:// [-c key=value ...]
→ initialize {clientInfo, capabilities:{experimentalApi:true, optOutNotificationMethods:[…]}}
→ initialized（通知）
→ thread/start {cwd, sandbox:"workspace-write"|"read-only", approvalPolicy:"never", developerInstructions, model, ephemeral, serviceTier?}
   或 thread/resume {threadId, excludeTurns:true, cwd, sandbox, developerInstructions, model}
→ turn/start {threadId, input:[{type:"text", text}], effort?, sandboxPolicy?}
← 通知流 … item/started / item/completed / thread/tokenUsage/updated / error
← 服务端请求（有 id 有 method）：item/commandExecution/requestApproval / item/fileChange/requestApproval / item/tool/requestUserInput / …
← turn/completed {turn:{id, status, error?}}
```

- 所有消息都是 JSON-RPC 2.0 一行一条。服务端请求**必须回响应**，否则那个工具调用挂着。
- `initialize` 已实测成功（隔离 home、零 token）：`model/list` 返回 6 个模型及各自 `supportedReasoningEfforts`，
  `account/rateLimits/read` 返回订阅额度百分比与重置时间，`account/read` 返回 plan。
- `thread/start` / `turn/start` / 服务端请求处理**首跑前未实测**，见文末「未验证」。

## 沙箱与网络（继承 codex-cli.md 的结论 + 本次实测）

- `workspace-write` 默认挡掉 worktree 的 git 提交（common dir 在主仓库 `.git`），必须放行：
  进程级 `-c 'sandbox_workspace_write.writable_roots=["<main>/.git"]'` + `thread/start.sandbox="workspace-write"`。
  这就是 codex exec 的口径，实测 `git add && git commit` 在 worktree 里成功（探针 D）。
- **不要往 `turn/start.sandboxPolicy` 传结构化策略**（2026-09-11 实测，0.153.4）：带上同样内容的
  `{"type":"workspaceWrite","writableRoots":[<common .git>],…}` 后，`git add` 写 `.git/worktrees/<wt>/index.lock`、
  `update-ref` 写 `HEAD.lock` 一律 `Operation not permitted`（探针 H / I，两个 worktree 都复现），而同目录 `touch` 反而能过；
  更糟的是这些命令**不产生 `item/completed(commandExecution)` 事件**，编排者在摘要里看不到它失败过。
  执行体已改为默认不传（`force_turn_sandbox_policy` 才传），summarize 加了「git 底层改写」探针抓绕路。
- 实测的连带现象：luna/low 被拒后会用 `GIT_INDEX_FILE=/tmp/x git add` + `commit-tree` + `update-ref` 硬造提交，
  结果树里少了 README（临时索引是空的）。`foreman check` 的 `git status --porcelain` 为空这一条抓住了它。
- 默认无网络（DNS 直接失败）；`sandbox_workspace_write.network_access=true` 才有 shell 出网。开了之后连本机代理是通的。
- `read-only`（复审）**完全没有 shell 网络**，但有服务端 `web_search`（不走沙箱）。`sandbox_read_only.*` 这个键不存在。
- `codex sandbox <-c …> bash -lc '<probe>'` 不起模型，`foreman doctor` 用它做七条边界断言。

## 审批：默认「替我审批」，完全权限只留一个口子（用户 2026-09-11 硬规矩）

线程级三件：`sandbox`（默认 `workspace-write`，复审 `read-only`）+ `approvalPolicy="on-request"` + `approvalsReviewer="auto_review"`。
`auto_review` 就是 Codex 的「替我审批」（CLI 的 `--approve-for-me`）：执行者请求沙箱外动作时，由 Codex 自动审查决定放不放，
不回到人。自动审查不接的请求才会以服务端请求回到执行体，按下表处理：

| 服务端请求 | 执行体的回应 | 配置 |
|---|---|---|
| `item/commandExecution/requestApproval` | `{"decision":"decline"}`（默认）或 `accept` | `codex.approvals` |
| `item/fileChange/requestApproval` | 同上 | 同上 |
| `execCommandApproval` / `applyPatchApproval`（v1 旧名） | `denied` / `approved` | 同上 |
| `item/tool/requestUserInput` | 落 `run-N.questions.json` → 轮询 `run-N.answer.json` 最多 `question_timeout` 秒 → 有答复原样转；没有则每题回兜底答复 | `codex.question_timeout`（0 = 立即兜底） |
| `mcpServer/elicitation/request` | `{"action":"decline"}` | — |
| 其它（permissions、dynamic tool、attestation…） | JSON-RPC error（-32601），模型把它当失败的工具调用继续 | — |

**完全权限**（`danger-full-access` + `approvalPolicy=never`，等价于 CLI 的 `--dangerously-bypass-approvals-and-sandbox`）：
只有用户在本会话明确要求时才用，入口只有 `foreman run --full-access "<用户原话>"`。foreman 把原话写进 `run-N.full-access` 与 request 的
`full_access_reason`，并置 `user_explicitly_approved_full_access=true`；执行体收到 `danger-full-access` 而没有这个标记就直接拒绝（rc=3）。
事件流里有 `{"_fleet":"full_access","reason":…}`，摘要第一行打横幅，`status` 的 role 列带 `!FULL`。复审没有这个口子。
所有审批决定都以 `{"_fleet":"approval",…}` 落进 jsonl，`report` 里单列一节。

回答格式（`foreman answer` 会写）：`{"all":"文本"}` 对所有问题同一答复，或 `{"answers":{"<qid>":["文本"]}}`。执行体消费后把文件改名为 `.consumed`，questions 文件改名为 `.questions.answered.json`。

## 事件流（落盘的 jsonl）

- 服务端来的消息原样一行一条；执行体发出的带 `"_fleet":"out"`。
- 执行体自己的记录：`_fleet` ∈ `thread`（线程 id / 模型 / 实际推理档 / instructionSources）、`approval`、`question`、`answer`、`interrupt`、`protocol_error`、`turn_summary`（rc / status / tokenUsage / 拒绝次数 / 提问次数 / 用时）。
- 已 opt-out 的增量通知：agentMessage / reasoning / plan / commandExecution / fileChange 的 delta、`turn/diff/updated`、`account/rateLimits/updated`、realtime 音频类。`item/completed` 不受影响。
- `item/completed.item.type` 关心的几种：`agentMessage{text, phase: commentary|final_answer}`、`commandExecution{command, exitCode, status: completed|failed|declined, aggregatedOutput}`、`fileChange{changes:[{path, kind:{type:add|delete|update}}], status}`、`webSearch{query}`、`mcpToolCall`、`reasoning{summary[]}`。
- 成败：`turn/completed.turn.status`。`error` 通知带 `willRetry`，为 true 的不算失败。`turn.error.codexErrorInfo` 里有 `usageLimitExceeded` / `rateLimitExceeded` / `contextWindowExceeded` / `sandboxError` 等可读枚举。
- token：`thread/tokenUsage/updated.tokenUsage.total`（字段名以 camelCase 读，summarize 兼容 snake_case）。

## request.json 字段（foreman.sh → codex_appserver.py）

| 字段 | 说明 |
|---|---|
| `codex_bin`, `home`, `cwd` | 二进制、CODEX_HOME、工作目录（worktree） |
| `sandbox` | `workspace-write` / `read-only`（thread 级） |
| `sandbox_policy` | turn 级结构化策略（见上） |
| `config_overrides` | `[[key, tomlValue], …]` 进程级 `-c` |
| `approval_policy`, `approvals_reviewer`, `approvals` | `on-request`（默认）/`never`；`auto_review`（默认）/`user`/`guardian_subagent`；兜底 `decline`/`accept` |
| `user_explicitly_approved_full_access`, `full_access_reason` | 完全权限口子：仅 `foreman run --full-access "<原话>"` 生成；没有标记的 `danger-full-access` 被拒 |
| `model`, `effort` | 模型；推理档（turn 级） |
| `developer_instructions` | 角色提示词 + 项目执行者规则 + 批次背景（foreman 组装成 `run-N.dev.md` 后读入） |
| `prompt` | 本轮 user 输入（任务书 / 返工 prompt） |
| `thread_id` | 空 = 新线程；非空 = `thread/resume` |
| `ephemeral` | 复审用 true：不落盘 |
| `out_jsonl`, `out_stderr`, `out_last` | 事件流、app-server 的 stderr、最后一条 agent 消息 |
| `meta_path`, `meta_thread_key` | 拿到 thread id 立刻写进 meta.json（默认键 `codex_thread`） |
| `questions_path`, `answer_path`, `question_timeout`, `canned_answer` | 提问机制 |

退出码：0 完成 / 1 failed / 2 被中断 / 3 没跑起来 / 143 SIGTERM 且未能优雅中断。看门狗超时会 SIGTERM 执行体，执行体先发 `turn/interrupt` 再退。；**4 = 执行器不可用**（turn 失败或协议错误里匹配到 404 / 5xx / 连接失败 / 429 / 401，事件流写 `_fleet: engine_unavailable`，`status` 显示 `ENGINE_DOWN`）——编排者只告知用户，不排障

## CODEX_HOME：全 skill 一份，与用户的 `~/.codex` 隔离

`~/.foreman/codex-home/`：`auth.json` 软链到 `~/.codex/auth.json`（认证仍走用户已登录的 ChatGPT）+ 极简 `config.toml`。
有意**不继承** `~/.codex` 的 MCP servers、插件、`notify` 钩子、全局 `AGENTS.md`（用户全局指令里的「有不确定先问用户」在非交互场景会卡住；现在换成执行体处理提问）。
代价：这些线程**不会出现在 Codex 桌面端**。要看：`foreman report/tail`，或终端 `CODEX_HOME=~/.foreman/codex-home codex resume <thread_id>`。
不要为了在桌面端看见而把 home 指回 `~/.codex`。
**不要整目录重建这个 home**：sessions/ 里是所有线程的 rollout，删了 `thread/resume` 找不到历史。

## 与 codex-exec 备用引擎的关系

`foreman run --engine codex-exec` 走 pi-fleet 原样的 `codex exec --json` 路径（每票一份 `codex-home-run/`，AGENTS.md 注入），实测过、可退回。
两条路的 thread id 分开存（`codex_thread` vs `codex_exec_thread`），互不能 resume；换引擎 = 换会话，返工上下文要在 prompt 里补。

## 已验证（2026-09-11 首跑，scratch 仓库 + luna/low）

- 隔离 home 下 `thread/start` 直接成功，没有「目录未信任」的请求；`instructionSources` 为空（隔离 home 没有 AGENTS.md，角色全靠 developerInstructions）。共用 `~/.codex`（shared 模式）时会多出桌面端的全局 `~/.codex/AGENTS.md` 与 MCP / 插件，未单独实测。
- `turn/start.effort="low"` 被接受，`thread/start` 响应里 `reasoningEffort` 回显一致；`model` 回显一致。
- `thread/resume` + `excludeTurns:true` 正常，续线程后模型记得上一轮。
- **hold 模式（1.1.2）**：`codex_appserver.py serve <hold-dir>` 一条线程一个常驻进程，boot 一次（`thread/start|resume`）后持有写锁，队列 `<hold-dir>/queue/run-N.request.json` 来一轮跑一轮（请求多 `out_rc` / `timeout`，超时由执行体自己 `turn/interrupt` → rc 143），`release` 文件出现或空闲超 `idle_seconds` 才退；启动失败给队列里每轮写 rc 并抄失败事件。轮间的服务端通知落 `hold.jsonl`，每轮切到那轮的 jsonl（`_fleet: thread` 事件带 `held: true`）。开发者指令在载入时定死，所以「本轮位置」放 prompt 顶部。
- **shared home 下 `thread/resume` 可能被桌面端抢锁**（2026-09-11 首张真票实测）：桌面端 ChatGPT 自带的 app-server 一旦打开同一条线程，resume 回 -32600「already has an active writer」，run 立即失败（rc=3）；本机并没有 foreman 自己的进程残留。处置：关掉桌面端那条线程再续，或 `release` 后 `run --thread <新名>` 另起并在 prompt 里补上下文（1.1.2 起 foreman 自己持锁，桌面端反而打不开它）；桌面端只看不开就不会占锁。
- `item/completed` 的 `fileChange`（apply_patch）与 `commandExecution` 事件形状与 schema 一致；apply_patch 的工具返回是 `{}`。
- `thread/tokenUsage/updated.tokenUsage.total` 字段是 camelCase（`inputTokens` / `cachedInputTokens` / `outputTokens`）。
- 后台 detach（setsid）+ `wait` + `tail` 全链路可用；`status` 在 3 秒内即显示 RUNNING。
- **shell 工具依赖同目录的 `codex-code-mode-host`**（`features.code_mode_host` 稳定开启，关掉就没有 shell）。`codex` 若经软链调用，argv[0] 所在目录必须也有这个兄弟程序，否则 `Code Mode … fail closed`、模型一条命令都跑不了。执行体已把二进制解析成真实路径；`~/.local/bin` 也补了软链。
- `approval_policy=never` 下守卫（`guardian_approval`）会直接拒绝 `rm -f` 这类命令（stderr 出现 `Rejected(... rm -f style commands are not permitted)`），不是沙箱、不产生事件；模型会收到拒绝文本。
- **「替我审批」实测**（`on-request` + `auto_review`，探针 t3）：`thread/start` 响应回显 `approvalsReviewer=auto_review`；模型要写工作区外文件时，事件流出现 `item/autoApprovalReview/started` → `guardianWarning`（"Automatic approval review approved (risk: low, authorization: high): …"）→ `item/autoApprovalReview/completed`（`review.status/riskLevel/userAuthorization/rationale` + `action.command`），**不会**以 `requestApproval` 回到执行体；命令随后作为普通 `commandExecution` 执行成功。summarize 已把每次自动审查决定列成一节并计入「需要编排者判断」。
- **自动审查把任务书当「用户授权」**：那次放行的 rationale 是 "The user explicitly authorized this exact touch command"。所以任务书 / 返工 prompt 里**不要写授权沙箱外动作的话**（"可以写到 ~ 下""需要审批就请求一次"之类），否则等于替用户批了。
- **账本里的线程记录**：request.json 的 `meta_thread_key` 支持点路径（`threads.<名>.ref`），执行体拿到 thread id 后写进票的 meta.json；票下多条线程各一条记录，引擎无关。
- **线程命名**：`thread/name/set {threadId, name}` → `{}`，`thread/read` 的 `thread.name` 回读一致，并推 `thread/name/updated` 通知（2026-09-11 探针，thread/start 不花 token）。执行体在 thread/start / resume 后按 request.json 的 `thread_name` 设置，失败只记事件不阻塞。
- **线程 cwd = 项目根（2026-09-11 晚定稿）**：`thread/start` 的 `cwd` 一律是编排者的项目目录，不是 worktree；实测 `instructionSources` = `~/.codex/AGENTS.md` + `<项目根>/AGENTS.md`，所以项目规则不用再由 foreman 注入。桌面端把线程归到项目的规则是 cwd 与项目 rootPaths **精确相等**（app.asar 里 `path.relative(root, cwd) === ''`），cwd 是 worktree 就落到 Tasks；app-server 有未公开的 `project/list` / `project/update`（roots 可多个），但不需要用。工作目录（PR 的 worktree）走请求的 `work_dir`，进 `_fleet: thread` 事件的 `workDir`，摘要器据此标出工作目录之外的改动。
- **`AGENTS.md` 自动注入范围**（探针 2026-09-11 晚，worktree + 三层暗号）：codex 只注入「仓库根到 cwd」链上的 `AGENTS.md`；worktree 里的 `.git` **文件**就算仓库根，仓库根之上的父目录（工作区级 AGENTS.md）**一个字都不读**；子目录的 `AGENTS.md` 在 cwd 为根时不注入（按二进制里的说明，模型碰到该子树文件时才按范围适用）。`developerInstructions` 与 `AGENTS.md` 并存，模型自己能分清（它把 AGENTS.md 归为"用户消息提供"），直接指令优先。二进制里另有两条：`project_doc_max_bytes` 默认 32 KiB（超出截断；工作区 AGENTS.md 已 39 KiB）；`AGENTS.md` 与开发者消息都是「可信内容、可建立 user_authorization」，即它们能替自动审查放行沙箱外动作。结论：仓库内规则不用替执行者指定；仓库外规则才走 `rules.executor_rules_file`，且不写放行的话。
- 续线程时若模型与首轮不同，会来一条 `warning`（"session was recorded with model X but is resuming with Y"），无害，summarize 列在运行提示里。

## 未验证（下次要盯的）

1. **已验**：打开 `features.default_mode_request_user_input` 后 Default 模式真实触发 `item/tool/requestUserInput`，见文末提问实测。
2. `turn/interrupt` 后 `turn/completed.status=interrupted` 是否可靠到达（否则执行体 20 秒后强杀，rc=143）。
3. 长任务自动压缩上下文后 developerInstructions 是否仍在场（`thread/compacted` 通知可观察）。
4. 并发 2 路以上的订阅额度表现；terra/high 档一轮真实票的 token 与用时。
5. ~~真仓库（非 /private/tmp 下）的沙箱行为与 scratch 一致~~ **已验**（2026-09-11 晚，一个真实 monorepo 的布局 `data/worktrees/<repo>-<id>` + `.git` 文件指回主仓库）：doctor 六项全 OK，含「主仓库根不可写（如期被挡）」与「git dir 可写」。

## 零成本工具

- `foreman doctor`：握手 + `model/list` + 额度 + 沙箱断言，全程不起模型。
- `CODEX_HOME=~/.foreman/codex-home codex debug prompt-input`：打印模型可见的完整 prompt（不花钱）。
- `codex app-server generate-json-schema --out <dir>`：导出协议 schema（本笔记的字段名全部来自它）。


## turn/steer 与排队转引导（2026-09-11）

cookie 的最终口径是「先发消息，再改引导」：编排者默认用 `foreman run` 追加任务，正在跑就排队，结束了就起下一轮；看到排队提示后，需要立即纠偏才用 `foreman steer <id> --from-queue N --thread <名>`。直接 `steer <id> --thread <名> "文本"` / `--file <f>` 保留。

0.153.4 本机 `codex app-server generate-json-schema --out <目录>` 的 v2 schema：

```json
{"method":"turn/steer","params":{"threadId":"<thread id>","expectedTurnId":"<活动 turn id>","input":[{"type":"text","text":"引导正文"}]}}
```

`threadId`、`expectedTurnId`、`input` 必填；可选 `clientUserMessageId`。`input` 与 `turn/start` 同形，响应 `TurnSteerResponse` 为 `{"turnId":"<turn id>"}`。

独立只读协议探针实测（thread `01a0911b-0d58-71b0-aee5-cc7a9a0d8968`，只回复 OK，正常 completed），故意传错误 expectedTurnId，JSON-RPC 错误原文：

```json
{"code":-32600,"message":"expected active turn id `foreman-intentionally-wrong-turn` but found `01a0911b-0dc7-7b30-baa6-0efcf8159941`"}
```

执行体将此类前置条件失败、已 completed、当前无活动 turn 转为完整新排队轮次，标题「引导转排队」，记录 `_fleet: steer_requeued`；其它错误记录 `steer_error` 并保留原消息。提交时固定目标 turn，不能把原 turn 的纠偏误投到下一轮。RUNNING 的主循环和 WAITING 的 answer 轮询都消费 `hold-<线程>/steer/*.json`；成功回执放 `sent/`，失败放 `failed/`，CLI 最多等 30 秒，超时只表示尚无回执，不应重复发送。

`--from-queue` 只撤回尚在 queue 的轮次；取队列与撤回共用票目录 `.runs.lock`。撤回清理 `run-N.*` 和 meta 的线程 runs，允许编号有空洞。`run-N.argv` 实际是 NUL 分隔的执行器 argv，没有原 `--prompt`；新请求的 `prompt_source` 存原任务书绝对路径，旧请求退回 `run-N.prompt.md` 并去掉完整生成位置块。转排队沿用原请求的模型、权限、工作目录等配置，重新建立全部轮次路径和账本。已有 hold 进程不会热加载新代码；CLI 用与 bridge.pid 匹配的 steer.pid 标记识别支持此通道的执行体，旧进程会明确拒绝且不改队列。结束并 release 后新起的进程才支持此通道。

## Default 协作模式下的提问实测（2026-09-11）

编排者在项目 `probe-ask` 的 run #2 实测：codex-cli 0.153.4 的 `default_mode_request_user_input` 为 under development 功能位，出厂默认 false。不开时模型按系统提示自我禁用，通常用纯文本提问结束 turn；打开后模型真实调用 `request_user_input`，桥收到 `item/tool/requestUserInput` → questions 文件 → WAITING → `foreman answer --qid <id> "B"` → 约 2 秒内继续，最后一条消息原文复述回答。全链路 44 秒。此证据由编排者提供，本票执行者线程的下一轮验证另计。

执行体先用 `codex features list` 探测，并在同一进程内缓存一次。只有输出包含 `default_mode_request_user_input` 才默认传这两个进程级覆盖，不修改 `~/.codex/config.toml`：

```text
-c features.default_mode_request_user_input=true
-c suppress_unstable_features_warning=true
```

功能位缺失或探测失败时不传该位（包括请求里已有的覆盖），不报错，只在执行体 jsonl 写一条 `_fleet: feature_missing`，带功能位名与缺失原因。`doctor` 显示名称、阶段、当前 CLI 配置的生效值、执行体是否会携带以及进程覆盖值；它与启动共用探测缓存，不重复调用。

项目 `foreman.toml` 的 `[codex] request_user_input = false` 可关闭；该值经 request 的 config_overrides 传给执行体，覆盖其默认 true。hold 启动时生效，现有进程不会热加载。

服务端请求形状（字段以 0.153.4 v2 schema 为准）：

```json
{"jsonrpc":"2.0","id":17,"method":"item/tool/requestUserInput","params":{"threadId":"<thread>","turnId":"<turn>","itemId":"<item>","isBlocking":true,"questions":[{"id":"choice","header":"联调","question":"随机词选 A 还是 B？","options":[{"label":"A","description":"使用 A"},{"label":"B","description":"使用 B"}]}]}}
```

`foreman answer <id> --qid choice "B"` 写入本地 answer 文件的 answers 是 `{ "choice": ["B"] }`，完整文件为 `{"answers":{"choice":["B"]}}`。桥读取后返回协议要求的嵌套结构：

```json
{"jsonrpc":"2.0","id":17,"result":{"answers":{"choice":{"answers":["B"]}}}}
```

阻塞问题用工具问并等待；超过 `question_timeout` 才兜底。只有红线和真正定不了的口径才问，其它合理完成后列进报告的「需要澄清」。五份角色样例同步；用户级运行时角色副本仍由编排者同步。
