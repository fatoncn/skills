> **foreman 说明**：本文原样继承自 pi-fleet（实测于 codex 0.149.0），现在对应 `foreman run --engine codex-exec` 备用引擎；
> 「沙箱四坑」对默认的 app-server 引擎同样成立。0.153.4 新增一坑：`codex` 若经 `~/.local/bin` 软链调用，
> 同目录必须也有 `codex-code-mode-host`（shell 工具靠它起），否则模型一条命令都跑不了。foreman 已把二进制解析成真实路径。

# codex CLI 实测笔记

对 `@openai/codex` v0.149.0 的实测结论（26-08-26）。改 `pi-foreman.sh` 的 codex 档之前先读这里，
不要凭 `--help` 猜行为。pi 档看 [`pi-cli.md`](./pi-cli.md)。

## 核心调用

```bash
# 首轮:建会话
CODEX_HOME=<隔离 home> codex exec --json \
  -C <worktree> -s workspace-write \
  -c 'sandbox_workspace_write.writable_roots=["<main>/.git"]' \
  -c sandbox_workspace_write.network_access=true \
  -o <last.md> "<prompt>"

# 之后:续会话(返工)
CODEX_HOME=<同一个 home> codex exec resume <thread_id> --json \
  -c sandbox_mode=workspace-write -c '…同上两条…' -o <last.md> "<prompt>"
```

- `exec` 非交互，处理完即退出；**没有审批环节**（同 pi），但**有沙箱**（pi 没有）。
- `--json` 输出 JSONL 事件流到 stdout。
- `-o <file>` 直接把最后一条消息落盘 —— 不用解析事件流也能拿到交付报告。
- `</dev/null` 是必须的：不给 stdin 它会停下来等「追加输入」。
- 自动加载仓库 `AGENTS.md`（与 pi 同）。

## 已验证的行为

| 项 | 结论 |
|---|---|
| 工具审批 | **没有**。`exec` 模式下全部自动执行 |
| 沙箱 | **有**。`workspace-write` 下主仓库根写不进去；`read-only` 下 `touch` 直接被拒 |
| 续会话 | `codex exec resume <thread_id>`，实测跨轮记得上一轮产出与自己报告过的 sha |
| 会话存储 | `$CODEX_HOME/sessions/`（所以 CODEX_HOME 不能整目录重建，见下） |
| 成本 | ChatGPT 订阅计费，`turn.completed.usage` **只有 token、没有美元** |
| 退出码 | 模型报错时进程仍可能 exit 0，**必须解析事件流判断成败** |

## 事件流要点

```
{"type":"thread.started","thread_id":…}      首行,thread_id 用于 resume
{"type":"turn.started"}
{"type":"item.started"/"item.completed","item":{"type":…}}
{"type":"turn.completed","usage":{input_tokens,cached_input_tokens,output_tokens,…}}
{"type":"turn.failed", …}
```

`item.type` ∈ `agent_message` `reasoning` `command_execution` `file_change` `patch_apply`
`mcp_tool_call` `web_search` `todo_list` `error`。

判定成败：
1. **「这一轮结束了」= 每个 `turn.started` 都有对应的 `turn.completed`**（不是进程 rc=0）
2. 有没有 `turn.failed`
3. `command_execution` 的 `exit_code`

两处比 pi 好：`command_execution` 直接给**完整 shell 命令原文**（越界探针不用猜 args），
`file_change` 直接给改了哪些文件。

**一个必须过滤的假阳性**：`item.type == "error"` 会被用来报「skill 描述被截断」这类
无害提示，不能一律当失败。`summarize.py` 的 `BENIGN_ERROR` 负责这件事。

## 四个坑

1. **workspace-write 默认挡掉 worktree 的 git 提交。**
   worktree 的 git common dir 在主仓库 `.git`，属 workspace 之外，
   实测 `touch <main>/.git/x` → `Operation not permitted`，`git commit` 因此失败。
   必须 `-c sandbox_workspace_write.writable_roots=["<main>/.git"]`；
   放行后**仓库根依然写不进去**，隔离还在。
   ⚠️ 在 `/private/tmp` 下建的临时仓库**测不出这条**（TMPDIR 本来就可写），必须拿真仓库验。

2. **默认无网络**（DNS 直接解析失败）。本仓库测试要连远端库，必须
   `-c sandbox_workspace_write.network_access=true`。
   `HTTP(S)_PROXY` 会被继承，开了 network_access 之后**连本机代理是通的**；
   见到 `curl:(7) 连 127.0.0.1 失败`，那是**没开 network_access** 的表现
   （设了代理时「没网」就长这样，而不是 DNS 失败）。

3. **codex 没有 `--append-system-prompt`。**
   唯一稳定的注入点是 `$CODEX_HOME/AGENTS.md`，所以每个 issue 一份专属 CODEX_HOME：
   `auth.json` 软链真身 + `AGENTS.md` 放角色文件（+ 批次背景文档）+
   精简 `config.toml`（不继承 MCP / plugins / notify / 个人偏好）。
   ⚠️ **只能增量刷新，绝不能整目录重建** —— 会话 rollout 住在 `$CODEX_HOME/sessions/`，
   删掉它下一轮 resume 报 `no rollout found for thread id`。

4. **`codex exec resume` 的参数表比 `codex exec` 窄**：没有 `-s` / `-C` / `--add-dir` /
   `--approve-for-me`。沙箱只能走 `-c sandbox_mode=…`，工作目录靠进程自身 cwd。

## 联网：三条路，别用错

| 路径 | run 档（workspace-write） | review 档（read-only） |
|---|---|---|
| shell 出网（curl / git clone / gh / npm registry） | ✅ 需 `network_access=true` | ❌ **完全没有**，DNS 直接失败 |
| 服务端联网搜索 `web_search` | ✅ | ✅ **有** —— 它不走沙箱网络 |
| MCP 工具 | ❌ 隔离 CODEX_HOME 已剥掉 | ❌ 同左 |

- `sandbox_read_only.*` 这个配置键**不存在**；`network_access` 只属于 `workspace_write`，
  往 read-only 上加没用（实测仍 DNS 失败）。
- workspace-write + network_access 实测可用：`gh api`（含 `search/code`，认证读 `~/.config/gh`）、
  `git clone --depth 1`、`raw.githubusercontent`、npm registry、任意 HTTPS 文档站。
- **`web_search` 默认就开**（不写 `[tools]` 也会触发）。别只信模型自称「我有搜索工具」，
  要看事件流里有没有真的出现 `item.type=web_search`。
- **egress gate 不适用于这套工具**（Derek 26-08-26 定）：`contracts/.../egress.ts` 管的是
  产品运行时把用户内容发第三方，不管开发侧编码 agent 的调研。搜什么不设限。

## 只读档的固有噪音

macOS 自带 `/usr/bin/git` 是 xcrun 壳，只读沙箱下写不了缓存，会往 stderr 喷
`couldn't create cache file '/tmp/xcrun_db-…' (errno=Operation not permitted)`。
**命令本身仍然成功**。复审 prompt 里已写明，`summarize.py` 也会加一行提示。

## 用户当前配置

`~/.codex/config.toml` 是 `gpt-5.6-terra` + `model_reasoning_effort = high` +
`service_tier = "priority"`，还挂了一堆 MCP / plugins（浏览器、computer-use 等）。
**编队不继承这些**：隔离 CODEX_HOME 只写模型、推理档、`web_search`。

隔离还顺手解决一个真问题：全局 `~/.codex/AGENTS.md` 里有
*"When you create a pull request, automatically monitors it for CI failures … post comments on your behalf"*，
和编队「远端动作全归编排者」的硬边界正面冲突。

## 零成本自检

`codex sandbox <-c …> bash -lc '<probe>'` **不起模型会话**，可以随便验沙箱边界。
`pi-fleet doctor` 就是这么做的：worktree 内可写 / git dir 可写 / 主仓库根不可写 /
可出网 / gh api / git clone / 只读档写不了，七条断言，零 token。

`codex debug prompt-input` 打印模型可见的完整 prompt（也不花钱），
用来确认 AGENTS.md 注入是否生效、个人偏好是否已剥掉。

## 还没验到的（别当成已知）

- **`turn.failed` 的实际载荷没见过** —— 26-08-26 的全部实测里一次都没触发（没撞限流、
  没遇模型报错）。`summarize.py` 对它的解析是**防御性写的**，真出现时先核对字段名。
- **长任务下 codex 自动压缩上下文之后，`$CODEX_HOME/AGENTS.md` 注入的边界是否仍在场**——
  没验过。派长活时值得在返工轮抽查一次它还记不记得角色文件的边界。
- **并发上限**：只实测到 **2 路同时跑不限流**（两条 PR 复审，各 2m21s，同起同收）。
  更高并发下 ChatGPT 订阅额度的表现未知，所以口径仍是 1–2 路。

## 写 prompt 时的一个语言陷阱

脚本里 codex 的 prompt 是 bash 双引号字符串，**反引号会触发命令替换**。
想在 prompt 里写代码标记必须转义成 `` \` ``。写错的表现是 bash 打
`unexpected EOF while looking for matching \`'` 而**进程照样启动**，
那一段被替换成空 —— 静默丢内容，`bash -n` 也查不出来（反引号成对时语法合法）。
