# Foreman 外派操作手册

仅在已选定 Foreman 外派通道、配置或操作其执行器时读取相关章节。使用宿主子 agent 不需要初始化 Foreman，也不需要预读本手册。

分工、角色档位、任务书与验收判据统一见 [通用编排指导](orchestration-guide.md)，不要在本手册重复维护。

按任务定位：首次使用读“第一次用”和对象模型；派发与续跑读“阶段 3”；验收与收尾读对应命令；排障再读“已知降级”及执行器参考。脚本入口中的路径相对安装位置不变。

框架主线使用 Codex app-server 常驻线程；Claude Code CLI 引擎处于 beta，pi 为可选引擎。源仓库为 github.com/fatoncn/skills 的 foreman/ 目录，本机源目录为 ~/skills/foreman；客户端通过安装目录或符号链接使用。

脚本入口（下文统一用 `$FOREMAN`）：

```bash
FOREMAN=~/.claude/skills/foreman/scripts/foreman.sh
```

## 两条硬规矩（使用者在本机定的红线，脚本层强制，项目规则不能放宽）

1. **线程的工作目录永远等于编排者的项目目录。** 每条线程的 cwd 就是项目根（Claude 的工作目录），和你一模一样，脚本写死、不用 `cd`；票下的 PR（worktree、分支、基线）只是框架对你的约束，线程感觉不到框架，在它看来就是在项目目录下干一件 prompt 顶部「本轮位置」说明的活（工作目录、分支、基线由脚本每轮生成写进去）。理由：两边目录一样，环境、规则就一样；桌面端也按 cwd 把线程归到项目下。守卫只有一条：PR 的目录必须在项目根之内。
2. **审批默认「替我审批」，完全权限只留一个显式口子。** 沙箱：复审 `read-only`（它只看 diff，不需要环境）；其余角色（实现、轻活、调研、验收）`workspace-write`；`approval_policy=on-request` + `approvals_reviewer=auto_review`，即执行者可以请求沙箱外动作，由 Codex 自动审查决定，自动审查不接的按 `approvals`（默认 decline）兜底。这个默认对 review 之外的角色一样，也是权限的**下限**：执行者能用的都能用——本机 MCP（shared home 继承桌面端的）、凭证索引 + Keychain、本机 CLI、连库、写排查脚本；角色文件不额外收紧，任务书只在确需时写边界。用户没有明确要求时，**禁止**任何 `danger-full-access` / `--dangerously-bypass-*` / pi、claude 的「跳过权限」。用户在本会话明确要求时才用 `run --full-access "<用户原话>"`：无沙箱无审批，原话记进 `run-N.full-access`、事件流与摘要横幅，`status` 标 `!FULL`；复审没有这个口子。
   连带纪律：自动审查把任务书、角色文件、注入的项目规则都当「用户授权」看（实测放行理由："The user explicitly authorized this exact command"）。所以「替我审批」是**有意提权的口子**：这项活确实要出沙箱（读 Keychain 某条目、连某库只读、跑本机某个 CLI）就在任务书里**点名写出是哪个动作、只读还是可写**，让自动审查有据可判；活不需要的动作一个字都别写，免得被拿去当授权。`report` 会把每次放行 / 拒绝列成一节，逐条对照任务书确认是它该做的。

## 项目规则优先于本 skill

项目、仓库的定义见下节；**项目规则** = 项目根 `AGENTS.md` + 仓库内 `AGENTS.md`。本 skill 是跨项目的**默认**：流程、模板、目录落点、review 轮次、PR 粒度等与项目规则冲突时**以项目规则为准**，并在任务书或汇报里说一句按的是哪条。唯一例外是上面两条硬规矩。

执行者那边不用你替它指定规则文件：线程 cwd 就是项目根，codex 自动读入项目根的 `AGENTS.md`（实测 instructionSources 含它）；仓库内的 `AGENTS.md` 在它碰到那个子树的文件时按范围生效。不另造摘要，真源只有那一份。

## 对象模型：项目 · 仓库 · 票 · 线程 · 角色 · 引擎

skill 以**仓库内的票**为工作单位；票下挂若干线程；每条线程建立时绑定一个角色和一个引擎。这层由脚本强制，不靠 prompt 约束：

| 对象 | 是什么 | 谁定 / 在哪 |
|---|---|---|
| **项目** | Claude 的工作目录（工作区根，可含多个仓库）。推导：从仓库主检出的上一级往上找，第一个带 `AGENTS.md` / `CLAUDE.md` 的目录；找不到就是仓库本身 | `init` 一个项目一份 `foreman.toml`，按仓库可覆盖 |
| **仓库** | 一个 git 检出，票的工作主仓库；票在仓库内（跟仓库无关的活也能在普通目录里立票）。跨仓库的活一仓一票，先后与同批合并由你按项目规则安排 | 运行时从当前目录推导 |
| **票** | 一份工作，主键。一个 id（issue 号或任意标识符），下面挂线程和 PR。调研票也是票：同样 `bootstrap`，只是检出只读、线程走 `research` 角色、交付物写到 `--writable` 放开的目录，不开 PR | 第一次 `bootstrap` / `here` 立票 |
| **PR** | 票下若干个，每个 = 一个 worktree + 一条分支 + 一个基线（`here` 登记的检出也算一个）。是框架对编排者的约束，线程感觉不到它 | `bootstrap <id> --pr <名>` 建，`cleanup <id> --pr <名>` 删；只有一个时各命令不用 `--pr` |
| **线程** | 票下若干条。建立时绑定角色 + 引擎，记引擎内引用和轮次；cwd 永远是项目根，每轮针对票下的一个 PR 干活（`--pr`）；默认按角色命名，`--thread <名>` 另起，同角色可多条 | `run` 开或续，`review` 开复审线程，`threads <id>` 查 |
| **角色** | 线程干什么活、用什么档位：implement / review / mechanical 必需，再多的自定；每个角色一份角色文件（契约） | 本机 `~/.foreman/config.toml`，项目可覆盖 |
| **引擎** | 线程属于且只属于一个：codex（app-server）/ claude（Claude Code CLI，beta）/ pi | 角色默认引擎，`--engine` 只在新开线程时可指定；codex / claude 各用独立并发池 |

脚本强制的几条：**跨引擎绝不共用一条线程**；**线程角色不中途换**（续线程时角色、引擎自动取记录，显式给的不一致直接拒绝，要换就 `--thread` 另起）；实现与收尾续同一条线程；复审永远新线程；PR 之间不共用目录；**同一 PR 同时只跑一条线程**（另一条还在跑就拒绝派发）。**真源是另一回事**：真源是需求从哪来（issue、文档、用户口径），写在任务书首段和 PR 描述里；票只把一份活和它的目录、分支、线程绑在一起。

脚本分四类，前三类是本体：① 执行器桥（起线程、续线程、后台跑、接提问与审批、解析事件流）；② 硬规矩与对象模型的机械执行；③ 票与线程的账本；④ 围绕账本的便利包装（`diff` / `pr`，等价于你自己敲 git / gh，只是从账本取 base 和分支）。

## 第一次用

**本机一次（跨项目）**：

```bash
$FOREMAN doctor                              # 二进制 / 登录 / app-server 握手 / 沙箱边界，零 token
$FOREMAN setup --codex-home shared|isolated  # 必须显式二选一，不设不能派活
$FOREMAN setup                               # 生成角色表 + 拷五份角色文件样例 → 表和文件都念给用户过目
$FOREMAN setup --confirm                     # 用户确认后打标记；没确认之前 run / review 一律拒绝
ln -sfn ~/skills/foreman ~/.codex/skills/foreman  # 装到 Codex；Codex 新会话生效
```

建议先安装 ripgrep（`brew install ripgrep`）：执行者搜索更快、更省轮次，`foreman doctor` 会在未安装时提示，但不阻塞使用。

这一节只在要把活外派给 spawn 之外的 Agent（codex / claude / pi 执行器）时才需要做。没做完，受影响的只有 `$FOREMAN` 命令（`run` / `review` 拒绝派发）：分工判断、任务书、验收纪律照用；告知用户 foreman 尚未初始化，让用户选：现在初始化，还是本会话改用 spawn；不替用户跑 `setup --confirm`。

codex home：`shared` = 共用桌面端的 `~/.codex`，桌面端能看到 foreman 线程，但执行者继承桌面端 config.toml 里的 MCP、插件、notify 和全局 AGENTS.md，**foreman 占着的线程桌面端打不开（这是有意的：线程由常驻执行体持锁，直到 `release` / `cleanup`）；反过来桌面端先打开了某条线程时 foreman 续不上，`status` 显示 `THREAD_BUSY`，关掉它再续**。把差别念给用户选。切换后旧线程仍按创建时的 home 续；复审线程是 ephemeral，两种模式都不留。

角色 = 执行器 + 模型 + 推理档 + 角色文件：档位放 `~/.foreman/config.toml`，角色文件放 `~/.foreman/roles/<名>.md`（`setup` 从 `../assets/roles/` 拷五份样例，可改可加，或 `[roles.<名>].prompt` 指到别处）。implement / review / mechanical 三个参考角色必需，research / accept 建议保留；缺角色或缺文件拒绝派活；再多的自定，`run --role <名>` 取用。派发沿用已配置档位；首次配置或用户要求重新选型时，按 [通用编排指导](orchestration-guide.md#角色与模型档位) 选择。

**角色文件只写契约**：位置、沙箱事实、分工边界（探针会查什么）、提问方式、输出格式。怎么干活不写在里面，每轮由你写进任务书（模板有可选「工作纪律」段）、复审关注点用 `review --prompt`、收尾规则写在收尾任务书里；角色文件与项目规则或任务书冲突时以后者为准。**收尾不是角色**：由实现者带着原口径续同一线程做（`run --closeout`）。并发上限：本机 `engines.concurrency` 是默认（5），项目 `foreman.toml` 同名键可覆盖；计数是本机所有项目合计在跑的 codex 线程（run 与 review 都算），因为执行者和用户自己的 Codex 抢同一份订阅额度。claude 走独立池，上限 `[engines.claude] concurrency`（默认 3）。

**每个项目一次**（在项目内任一仓库里跑）：

```bash
$FOREMAN init              # 生成 ~/.foreman/projects/<项目>/foreman.toml 骨架
```

`init` 只生成中性骨架并打印要填的清单（gh 入口、worktree 落点与前缀、分支规范与是否严格）；仓库事实（origin、远端默认分支、装依赖命令、验收命令）运行时推导，不写文件。**你读项目规则**填项目特有字段，按仓库不同的（基线分支、要拷的 env、验收命令）写进 `[repos."<slug>"]`，填完**念给用户过一遍再开工**。它是配置不是规则；字段说明见 `project-config.md`。协作流程规则只放本 skill 与项目规则，不写进代码仓库。


## 阶段 3 · 派活

### 汇总分支

默认口径（项目规则另有规定按项目的）：同批 ≥2 张票 → 从 base 建 `<type>/<YY-MM-DD>/<批次>-batch`，所有票的 `--base` 与 PR base 指向它，全批完成后由它开一个 PR 进 base（省 base 那条慢 CI）。单张独立改动直接进 base。**动汇总分支永远从 `origin/` 起，别碰同名本地分支**——本地同名分支自创建后就没更新过，在它上面 merge 会得到一棵「只有 base、没有任何票」却全绿的树。

### 每张票若干 PR、若干线程

```bash
$FOREMAN bootstrap <id> --slug <slug> [--pr <名>] [--type feat] --base <汇总分支或base> --context <BACKGROUND.md> --gh-issue <n>   # 给票建一个 PR（worktree + 分支）
$FOREMAN run <id> --prompt <brief.md> --title "…" --detach --timeout 1800   # 首轮建线程；票有多个 PR 时加 --pr <名>
$FOREMAN run <id> --prompt <rework.md> --title "…" --detach               # 返工自动续同一线程，它记得上一轮
```

实现轮需要把工作树之外的交付物写到指定目录时，用 `run --writable <目录>` 显式放开并登记该目录。

线程 cwd 永远是项目根，不用 `cd`；这轮针对哪个 PR、它的 worktree / 分支 / 基线由脚本写进 prompt 顶部的「本轮位置」。一票多 PR 时每条命令用 `--pr` 指定，只有一个时省略。

**调研线程**（排查、核事实、找锚点、复现，交付物给你拆票、下判断）用同一套命令，只是没有 PR：

```bash
$FOREMAN bootstrap <id> --slug research-<slug> --no-install [--gh-issue <n>]                     # 最新 origin/<base> 的检出；只读是角色契约，不装依赖；有背景 issue 就挂上
$FOREMAN run <id> --role research --prompt <research-id.md> --title "…" --writable <交付目录> --detach
```

调研不必先建 issue，票 id 用一个词就行；但**有背景 issue 就 `--gh-issue` 挂上**，线程名的 `{ids}` 才带号，桌面端一眼能认出它归哪张票。交付目录放项目约定的中间产物目录（项目没规定就 `~/.foreman/projects/<项目>/batches/<批次>/`）；`--writable` 把它放开，`report` 的越界探针把它当作内部，改到检出里的文件照样标出。调研票不走 `check` / `diff` / `pr`，验收就是你逐条核交付物（阶段 4）。追问续同一线程（`run` 不带 `--role` 自动取记录）；用完 `cleanup <id> --force`（分支没有提交，直接删）。任务书模板 `research-<id>.md` 见 `issue-pr-flow.md`：问事实不问方案。

- **线程按对象模型走**：`run` 默认开或续 `implement` 线程；一票多 PR 时，非默认 PR 的 `run --pr <名>` 会自动用 `<角色>@<pr>`（如 `implement@b`）并行，仍可显式 `--thread` 覆盖。`--role mechanical` 走 `mechanical` 线程，`--role research` 走 `research` 线程（调研，见上），`--role accept` 走 `accept` 线程（验收，见阶段 4）。`--closeout` 默认续目标 PR 最近的 `implement` / `mechanical` 实现线程，显式 `--role` / `--thread` 优先，并把 `../assets/CLOSEOUT.md`「收尾阶段契约」放在 prompt 顶部、探针按收尾白名单判；`--thread <名>` 另起；续线程不用再给角色和引擎。同名线程不覆盖，要重开就 `release` 旧的再 `--thread <新名>` 另起（旧线程的账本保留）；换引擎只能另起线程，它不记得旧线程干过什么，返工上下文要在 prompt 里补。复审每次新开 `review-N`。`threads <id>` 看全表；没有这本账，隔几个小时或换个会话回来就找不到之前的线程。
- **档位**来自全局 `[roles.*]`（项目同名可覆盖），单次 `--model` / `--effort` 可覆盖；派活后看 `report` 首行的 `model= effort=` 确认，不要等验收才发现。到并发上限脚本拒绝派发，`status` 尾行显示当前在跑数。
- **线程由常驻执行体占着（写锁）**：第一次 `run` 起一个常驻执行体载入线程并一直持有它的写锁，之后每轮只是往它的队列丢请求（同一线程的轮次排队，`status` 里 `QUEUED`）；桌面端在此期间打不开这条线程，也就不会再出现「already has an active writer」。**编排者明确结束这轮工作时 `release <id>` 释放**，`cleanup` 也会释放；空闲超过 `codex.hold_idle_minutes`（默认 360）自动释放，免得编排者会话没了还永久占着。
- **并发派活一律 `--detach`**：宿主 shell 有 10 分钟上限，一轮 20～40 分钟正常。前台档只适合几分钟的小活。
- 收敛用 `status` / `wait [<id>...] --timeout <秒> [--progress <秒>]` / `tail <id>`。**推荐在 Monitor 下跑 `wait`**：每行进展就是一次通知，`--timeout` 设为本轮预期总时长（与 `run --timeout` 同量级）或更长；靠进展行看进度、异常提示看卡住、rc 3 接执行者提问。宿主后台一次性 Bash 拿不到中途通知时，`--timeout` 设为自己想看一眼的间隔，rc 2 的进展与事件尾就是这段摘要，看完再续；前台仍只适合几分钟的小活，timeout 不超过自己愿意被挂住的时间。`--progress` 是唤醒频率，长活调大、短活可调小，异常提示不受它限制，`0` 关闭周期进展。
- `run --timeout` 按任务书估的人类工作量给足，实现类常见 30～60 分钟，抽样、长测试、收尾等外部结果给更长。进展行的「距时限」供你判断是否提前 `steer` 收尾或接受硬超时，脚本不代劳。`wait` 返回 2 = 仍在跑，3 = 正在提问；`DEAD` 按失败处理，`THREAD_BUSY` 让用户关桌面端再续，急则 release 后换线程补上下文。
- **执行者会向你提问**：阻塞问题用 `request_user_input` 问编排者并等答复；`status` 显示 `WAITING` 时，用 `questions <id>` 看问题、`answer <id> --qid <问题 id> "回答"` 回复，执行体通常 2 秒内读取并继续。`wait` 遇到 WAITING 返回 3，回答后再等；超过 `codex.question_timeout` 才给兜底答复。这靠执行体探测可用后默认带的功能位 `default_mode_request_user_input`（缺失时不传，只记 `feature_missing`，用 doctor 检查），不开它 codex 默认模式不会调用这个工具；项目可设 `codex.request_user_input = false` 关闭（重起 hold 生效）。只有红线和真正定不了的口径才问，其它按合理理解做完列进报告的「需要澄清」。派出后要盯 WAITING，别把 wait 丢后台就走。
- **中途变化默认立刻 `steer`**：纠偏、撤回及下一轮预告都直接通知正在跑的线程，再用 `tail` 确认方向。只有追加内容与本轮无关、留到下一轮也不会造成两轮改同一处，才用 `run` 排队。已排队的轮次用 `steer --from-queue N` 转成立即引导；若已经被拿起则拒绝，因为它已经在跑。steer 时 turn 已结束会自动转回完整新排队轮，`report` 可看 `steer_requeued`。默认线程 implement，其它线程显式带 `--thread`。
- **线程命名自动化**：每次 `run` / `review` 都按本机 `config.toml` 的 `codex.thread_name` 模板给 codex 线程命名，模板由使用者定，skill 只约束它必须含 `{ids}`（这张票相关的全部 issue / PR 号，`+` 连接）和 `{title}`（具体工作内容）。**每次 `run` / `review` 都给 `--title`，写这一轮真实做的事**（返工写返的是什么、复审写审的是什么），不给才回落到任务书首个标题、再回落到阶段词「实现 / 返工 第 N 轮 / 收尾 / 复审」并打警告。shared 模式下桌面端按这个名字找线程。
- **执行器不可用就告知用户，不自己排障**：`status` / `wait` 出现 `ENGINE_DOWN`、`report` 顶部有 ⛔ 横幅、或 `doctor` 握手失败（404 / 5xx / 连接失败 / 额度用尽 / 登录失效）→ 一句话告诉用户 codex 暂时无法使用并附原始报错，让用户决定等、换 `--engine`、还是改 spawn；不要自己排代理、换节点、反复重试刷额度。


## 验收与收尾命令

审核判据、复审风险档、返工及交付纪律见 [通用编排指导](orchestration-guide.md#阶段-4--验收你的核心工作)。本节只列 Foreman 操作。

```bash
$FOREMAN report <id>     # 摘要：模型档位、token、命令失败、越界探针、审批请求、提问、交付报告
$FOREMAN check  <id>     # 真跑 verify.commands（或票里的完成定义命令）
$FOREMAN diff   <id>     # 完整改动
```

```bash
$FOREMAN review <id> --prompt <REVIEW-id.md>   # codex：只读沙箱、新线程、就地审；档位取 roles.review；REVIEW-id.md 首段是你写的需求口径
$FOREMAN review <id> --engine pi     # pi：一次性副本 worktree，审完丢弃
```

```bash
$FOREMAN run <id> --role accept --prompt <accept-id.md> --title "…" --writable <证据目录> --detach   # 位置是这张 PR 的 worktree（只读用，可起本地服务）；实现者线程已停手
```

```bash
git -C <wt> log --oneline origin/<base>..HEAD          # 提交历史干净
$FOREMAN pr <id> --title "..." --body-file <body.md> --yes   # 不带 --yes 只打印命令（预览）
```

`report` 里这些信号出现就是**没通过**：turn 没正常完成；模型 / 协议错误；命中越界探针（push / gh 写 / 部署 / 关掉 lint 规则 / skip 测试 / 破坏性 git）；请求过沙箱外权限（看它有没有绕路）；报告贴不出真实命令输出。

## 已知降级

- claude 引擎整体 beta：只跑过一张真实票。其沙箱内跑 `pnpm` 脚本会触发依赖校验重装并损坏 `node_modules`（仓库 issue #26 待修；根子是 Claude Code 沙箱把 pnpm store 指到临时目录、且禁写 `.idea` / `.vscode`），修好前 claude 线程只派不跑包管理器脚本的活。
- Claude 的 `steer` 只排到下一轮 `run`，不中断或谎报已注入当前进程。
- Claude 复审只读是 Read / Glob / Grep 工具级，不是 OS 级只读。
- 用户 MCP 的远程写不在本地 Bash / 文件事件探针观测面。
- `listing` 图例含 `l = claude`，因新引擎字符增加而与旧版表头不同。

## 边界与成本

- 执行者没有人工审批环节，约束靠四层：OS 沙箱（线程 cwd = 项目根，整个项目可写）、自动审查、「本轮位置」+ 角色文件里的分工边界、`report` 的事后探针（越界命令、工作目录之外的改动）。
- worktree 里有真实 `.env`。不要在 prompt 里让执行者打印、外发或提交任何凭证。要用凭证的活让执行者**内联取用**（如 `psql "$(security find-generic-password … -w)"`），不落文件、不 echo，事件流里留下的只是命令原文。
- codex 无美元成本、只计 token；`list` 看全批用量，`doctor` 看订阅额度百分比。单票用量明显异常就停下来问。

## 命令速查

| 命令 | 用途 |
|---|---|
| `$FOREMAN setup [--codex-home shared\|isolated] [--confirm]` | 本机一次：codex home 模式（必须显式选）+ 角色分工 + 角色文件样例，确认后才能派活 |
| `$FOREMAN init [--force]` / `config` | 项目配置（一个项目一份，按仓库覆盖） |
| `$FOREMAN doctor [<wt>]` | 前置 + app-server 握手 + 沙箱自检（零 token） |
| `$FOREMAN selftest [--keep]` | 零 token 自测：隔离目录 + 假 codex，把 setup / init / here / bootstrap / run / review / check / diff / pr / cleanup 和各条守卫走一遍。**改过 skill 的脚本就跑它**，全绿再用 |
| `$FOREMAN bootstrap <id> (--branch b \| --slug s) [--pr 名] [--base] [--copy-env f] [--context] [--gh-issue]` | 给票建一个 PR：worktree + 分支 + 环境（需要在 git 仓库里）；再跑一次加 `--pr` 就是第二个 PR；id 任意。调研票加 `--no-install`，只要检出 |
| `$FOREMAN here <id> [--base] [--context] [--gh-issue]` | 不建 worktree，把当前检出登记为票的一个 PR「here」（不在 git 仓库里也行） |
| `$FOREMAN run <id> --prompt f --title 内容 [--pr 名] [--role 名] [--thread 名] [--closeout] [--writable dir] [--engine codex\|claude\|pi] [--model] [--effort] [--detach] [--timeout] [--full-access "<原话>"]` | 跑一轮；并发一律 `--detach`；claude 一轮一进程并用 session resume |
| `$FOREMAN review <id> [--pr 名] [--prompt f] --title 内容 [--engine] [--model] [--effort] [--detach]` | 对抗性复审（只读、新线程）；`--prompt` 给需求口径与关注点，只提意见你拍板 |
| `$FOREMAN steer <id> [--thread <名>] <文本> / --file <f> / --from-queue N` | 口径变化默认立刻通知；`tail` 确认方向已改；刚排队的任务用 `--from-queue` 立刻生效 |
| `$FOREMAN questions [<id>]` / `answer <id> <文本>` | 执行者提问 / 你回答 |
| `$FOREMAN status` / `wait [<id>...] [--timeout 秒] [--progress 秒]` / `tail <id>` | 收敛与进度；推荐在 Monitor 下等，timeout 按跑法与预期总时长定；进展周期就是通知频率，`0` 可关闭；WAITING 返回 3，仍在跑返回 2 并附事件尾 |
| `$FOREMAN threads <id>` | 这张票下的全部线程（名字 / 引擎 / 角色 / 引擎内引用 / 轮次） |
| `$FOREMAN report <id> [N\|reviewN] [--pr 名]` / `check <id> [--pr 名] [cmd...]` / `diff <id> [--pr 名]` | 验收三件；多 PR 时都可用 `--pr` 定位 |
| `$FOREMAN pr <id> [--pr 名] --title --body-file [--yes]` | push + 建 GitHub PR（`--yes` 执行；不带只打印预览） |
| `$FOREMAN release <id> [--thread 名]` | 释放常驻执行体占着的线程（编排者明确结束这轮工作时；cleanup 也会做） |
| `$FOREMAN list` / `cleanup <id> [--pr 名] --force` | 全批状态（票 → 线程）；删一个 PR 的 worktree；目标 PR 有在跑 / 排队轮次时拒绝，先 `release`；未提交 / 未推送也会拒绝，票、线程与日志保留 |

## 参考

- `codex-app-server.md` —— app-server 协议实测、request.json 字段、审批 / 提问机制、未验证项（改执行体前先读）
- `claude-code-cli.md` —— Claude Code CLI argv、settings / MCP、事件与升级复验清单
- `pi-cli.md` —— pi 实测（可选执行器）
- `issue-pr-flow.md` —— 背景文档 / 任务书 / 返工 / PR 描述 / 收尾任务书 / 复审关注点 / 验收包模板
- `project-config.md` —— foreman.toml 字段说明
- `orchestrator-codex.md` —— 副线：Codex 当编排者、Claude 当执行器要补什么
- `../assets/roles/{implement,mechanical,review}.md` —— 三个参考角色的角色文件**样例**（`setup` 拷到 `~/.foreman/roles/`，运行时读的是那边）
- `../assets/CLOSEOUT.md` —— 收尾阶段契约，只给实现角色，`run --closeout` 自动放在那一轮 prompt 顶部
