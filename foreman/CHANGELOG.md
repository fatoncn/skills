# foreman 版本记录

## 1.5.8 — 2026-09-15

- 每轮「本轮位置」补充实际时限；Claude 轮同时写明工具调用轮数与美元预算。
- 五份角色文件改为引擎无关的沙箱、MCP 与提问措辞，并明确 turn 结束前缺交付报告即失败。
- Claude 引擎事实补齐一轮一进程、禁止后台等待与改写依赖、IDE 目录不可写及环境失败如实阻塞的边界。
- Codex / Claude 桥按角色或收尾契约传入的报告标记校验最后消息；正常结束但缺标记时返回 rc 6、subtype `no_report`，且不触发自动 check。
- `review` 角色 Codex 档位由 gpt-6-astra / high 降为 gpt-6-astra / medium（cookie 09-15）；Claude 档位不变。

## 1.5.7 — 2026-09-15

- 任务书改为四条戒律：固定拼接层已有的内容不再在任务书、复审关注点或收尾任务书中赘述。
- 复审需求口径强调越全越好，并说明复审者自动有角色文件、上一轮任务书、交付报告和完整 diff；不会自动有批次背景、会话里的用户口径与拍板、相关 issue / 文档。
- 复审者新增「与原口径的对齐风险」一节（看什么第 5 条 + 输出格式）：不判需求，只列确实对不齐的风险交编排者核，要求客观、不夸大。

## 1.5.6 — 2026-09-15

- `research` 角色的 codex 档位由 gpt-6-astra / high 降为 gpt-5.6-sol / high（cookie 09-15：调研用旗舰太奢侈，与实现者同级即可）；claude 档位不变。

## 1.5.5 — 2026-09-14

- claude 引擎五个角色默认档位调整（cookie 09-14）：`review` fable/high → opus/xhigh，`research` sonnet/xhigh → opus/high，`implement` sonnet/medium → sonnet/high，`accept` sonnet/high → sonnet/xhigh，`mechanical` 不变（sonnet/low）。依据两天四张真实票的表现：implement 用 sonnet/medium 修脚本两轮没到根因；review 用 fable/high 意见全部成立但贵。

## 1.5.4 — 2026-09-14

- 分工第二级回到最初版本（cookie 09-14，参照 foreman 之前工作区规则「开工前先对齐模式」）：派 spawn 还是 foreman 开工前由用户定，会话开头、派出第一项执行工作之前必须让用户二选一，不再预设「优先外派 foreman」；「各自擅长」表只作用户定通道的参考、不是路由判据；核心口径、第一次用、互斥、阶段 1 调研票、阶段 4 验收派谁的散见说法同步对齐。

## 1.5.3 — 2026-09-13

- 修 #25：codex 桥写第一条 initialize 时子进程已经退出的话，stdin 拿到的 EPIPE 会作为未捕获异常把执行体打挂——前台 run 落不下 rc、常驻执行体也不给排队轮次判失败，shell 侧只能按「没跑起来」补 rc 3；改成把写失败转成带 `engine_exit` 标记的协议错误，和 stdout 读到 EOF 走同一条「只看子进程 stderr 尾部」的不可用分类（先等进程真正退出，再在 1s 判定窗口里轮询重读，免得读得比子进程写得早），起不来的 codex 在前台 run、常驻执行体、review、research / accept 各条派发路径上都稳定判 rc 4。新增三条回放用例：`immediate_exit_before_first_write_is_engine_down` 钉住前台 run 的 EPIPE 路径、`holder_boot_failure_marks_queued_runs_engine_down` 钉住常驻执行体把 boot 失败落成排队轮次的 rc 4、`immediate_exit_slow_stderr_still_classifies_unavailable` 钉住 stderr 迟到时仍按判定窗口轮询重读（孙进程的 stdout 重定向到 /dev/null，桥读到 EOF 时 stderr 还是空的，只读一次必然误判 rc 3）。
- 修 #27：claude 桥在坏 JSON 触发 protocol_error 之后，把子进程 stdout 显式排空到 EOF 再落 `.jsonl`（带硬超时 `STDOUT_DRAIN_TIMEOUT`，防子进程真挂住不退出）；同时把 `claude_replay.py --selftest` 的每个用例都套进独立的 `case()` 上下文，单个用例断言失败只标那一条 FAIL，不再让整个进程崩溃、拖累其余二十多条「Claude 回放」用例一起显示 FAIL。也修了假 claude 夹具里 `bad_json` 场景的信号竞态（先装 SIGTERM 忽略再吐坏行）。

## 1.5.2 — 2026-09-13

- 通道收为两条：删掉「外部会话转发」通道的章节、表格行与散见说法，只留外派 foreman 与宿主 spawn 子 agent；用户点名「外包」不再是一条通道。来源：cookie 09-13「只留 spawn 和外派两种，不然口径容易混淆」。

## 1.5.1 — 2026-09-13

- 文档口径：SKILL 描述与开头把 skill 定为「一份分工指导 + 一套外派框架」。分工指导（统筹 / 执行怎么切、三条通道怎么选、任务书与验收纪律）任何编排会话都适用，走 spawn 或外部会话时同样按它；外派框架只在要把活外派给 spawn 之外的 Agent 时才启用，也只在那时才需要初始化，未初始化只是 foreman 通道暂不可用、通道退到 spawn。来源：Codex 侧会话把「脚本没初始化」当成「整份 skill 不用」而绕开分工指导，cookie 09-13 拍板补上。
- claude 引擎标注 beta：只跑过一张真实票；沙箱内跑 `pnpm` 脚本会损坏 `node_modules`（issue #26 待修），修好前只派不跑包管理器脚本的活。
- spawn 通道说明补上 Codex 宿主的子 agent，不再只写 Claude Code 的 `Agent` 工具。
- 验收口径收紧（cookie 09-13）：真实浏览器 / 真机验收默认不做，只有用户明确要求、破坏性重构、大型功能开发、较大的产品口径调整四种情况才上；返工增量 Preview 冒烟与批次合测是否上浏览器随之按这四种情况判；低风险 PR 靠逐行审加测试 / CI。

## 1.5.0 — 2026-09-12

- C1：新增 Claude Code CLI 一轮一进程桥、session resume、原生 `auto` + 权限 MCP、独立并发池、严格 full-access 双层授权与 Codex 分发快照门。
- C2：新增 Claude stream-json 事件解析、report / progress / listing 集成、权限拒绝与目录外改动探针，并保留旧 Codex / pi 黄金输出。
- C3：新增 Claude 只读工具级复审、下一轮 steer 队列、零 token doctor 自检、`review_readonly=tools_only` 横幅与完整配置 / CLI 文档。
- 允许例外：`listing` 为新引擎增加 `l = claude` 图例而变更表头 / 列宽；report、event rows 与 progress 的旧引擎输出仍逐字节不变。
- 凭证落盘：用户 MCP 配置只写入 0600 的本轮临时 `mcp.json`，成功、失败或中断都在统一收尾删除；持久 `claude.json` 只留 server 名字。

## 1.4.1 — 2026-09-12

- 收口阶段新增「返工复测按改动性质分两档」：用户可见的返工项在报可合前补一次增量 Preview 冒烟（只点被改路径，可攒到最后一轮），纯 API / 内部行为返工靠单测 + CI。来源：#1808 返工四轮均未回浏览器、用户可见修复只有单测钉住，cookie 拍板补上这层。

## 1.4.0 — 2026-09-12

- 退役 `codex-exec` 引擎，删除脚本执行入口、旧事件摘要和配置 / 帮助枚举；旧线程改用 codex 新线程继续，旧 `codex exec` 事件日志不再解析。
- 把仍适用于 app-server 的 common gitdir、网络、只读缓存噪音、二进制宿主与会话 home 经验合并到 app-server 文档，删除独立 CLI 文档。
- 纠正文档中旧执行器对比、CODEX_HOME 固定隔离、项目根不可写和已删除规则文件配置等与当前实现冲突的说明。
- doctor 增加 ripgrep 检测与安装建议，减少执行者因搜索工具缺失浪费的轮次。

## 1.3.2 — 2026-09-12

- issue #22：新增隔离 CODEX_HOME / 插件环境的可编排 app-server stdio 回放夹具，固定协议基线并纳入 selftest。
- issue #20：app-server 响应按请求 id 与 deadline 分发到独立槽，嵌套等待、超时、EOF、重复和迟到响应均有界收尾；仅在 stdout EOF 时读取 stderr 末尾 8 KB 辅助判定执行器不可用。
- issue #21：实时桥与摘要共用根 thread/turn 身份判定，启动前通知缓冲回放，协作子线程跨轮跟踪，token 按根/子分列并计合计。
- issue #18：写码轮 rc=0 后自动 detached 跑 check；worker 不继承运行锁，派发失败会撤回未领取请求并写取消终态，Holder 跨重启等待且 release 可打断，状态判定由桥、shell 与 list 统一，支持单轮 `--no-check`。

## 1.3.1 — 2026-09-12

- issue #14：run 到时仍按原语义硬中断并记 rc=143；report 自动从事件流与 worktree 合成 commit、未提交文件、末尾事件及被打断命令，不主动向 turn 注入 prompt。
- issue #15：收尾执行者 push 并回复 / resolve 本轮线程后立即交报告；CI 与下一轮 review 改由编排者在宿主后台等待，红了或有新 finding 再派下一轮。
- issue #16：list 直接从新版 `prs` 账本取默认（或唯一）PR 的分支 / 基线，缺失统一显示 `—`；引擎列保持每字符代表一轮并补清晰图例。
- issue #17：wait 支持有变化才按 `--progress` 周期输出单行进展，长时间无事件 / 长命令各单次提示，rc=2 超时附事件尾；tail 也会列出 started 的命令 / 工具事件；文档按 Monitor、后台一次性 Bash、前台三种跑法说明 timeout。

## 1.3.0 — 2026-09-12

- issue #1-1：多 PR 默认用 `<角色>@<pr>` 线程并行，已有角色线程稳定复用。
- issue #1-2：`release` 先取消排队轮，TERM 宽限后 KILL；RUNNING 以执行体存活为准。
- issue #1-3：`cleanup --discard-unpushed` 直接强制删分支；普通 cleanup 识别已合入 base 的分支。
- issue #1-4：`report` 支持指定 run / review 轮次与 `--pr`，在跑时提示上一轮交付。
- issue #1-5：`wait <id...>` 等给定票的全部线程并逐线程打印状态。
- issue #1-6：越界探针忽略系统临时目录。
- issue #1-7：文档补充实现轮工作树外交付物的 `--writable`。
- issue #1-8：RUNNING 主用时从 request 派发起算，QUEUED 交接不归零。
- issue #1-noise-a：探针 stderr 不直通，报告过滤 skill descriptions 良性告警。
- issue #1-noise-b：`review` 命令表补齐 `--title`。
- issue #1-noise-c：派发位置块按环境标注 `rg` 可用性。
- issue #2-1：无 id 的 `wait` 遇 WAITING 先打问题摘要再打全表；指定 id 不受无关票影响。
- issue #2-2：沿用 issue #1-8 的派发起算用时口径。
- issue #2-3：只看不改以 porcelain 前后对比判定，fileChange 排除 writable roots 后只列事实。
- issue #2-4：`--closeout` 默认续目标 PR 最近的 implement / mechanical 实现线程。
- issue #2-5：升级前执行体的 steer 提示保持过渡期行为，未新增兼容层。
- issue #2-6：沿用 issue #1-noise-c 的 `rg` 环境事实。
- issue #2-7：命令失败按完整命令 + cwd 去重，末次成功不再列为最终失败。
- issue #2-8：accept 把 PR 触碰面外的失败统一归为范围外观察。
- issue #2-9：收尾等 CI 改为最多 5 分钟的轮询 + sleep，不用前台 `--watch`。
- issue #2-10：未增加 ci-baseline 命令。
- issue #2-11：沿用既有的 wait 后台运行指引。

## 1.2.3 — 2026-09-11

- 档位调整（cookie 09-12）：描述定为 research / review 用旗舰，implement / accept 用旗舰或次旗舰（accept 比 implement 高一档）。今天的对应：`implement` = gpt-5.6-sol / medium，`accept` = gpt-5.6-sol / high（多是浏览器脏活，gpt-6 太奢侈），review / research 仍 gpt-6-astra / high，mechanical 仍 gpt-5.6-terra / medium。配置模板同步。
- **先发消息，再改引导**（cookie 09-11 晚口径）：编排者追加内容默认 `run`，turn 在跑就安全排队，结束了就起下一轮。排队输出明确指出当前 run 和新 run，并给出 `foreman steer <id> --from-queue N --thread <名>`；要立刻纠偏才转换。直接 `steer <id> [--thread <名>] "文本"` / `--file <f>` 也保留。
- 引导走 `turn/steer`，以提交时的活动 turn 为前置条件；处理中 turn 已结束或 ID 不匹配就建齐新轮次（标题「引导转排队」），记 `steer_requeued`，不丢消息、不误投下一轮。已被拿起的 queue 轮次不再撤回。成功 / 失败回执最多等待 30 秒，失败保留消息。
- `--from-queue` 清理原轮次全部账本及线程 runs；`prompt_source` 保存原任务书绝对路径，旧请求回退到去掉位置块的 prompt 正文。轮次定位扫描现存最大编号，允许撤回产生空号；队列取出、撤回和分配在短文件锁内完成。report 增加引导列表（时间、fromRun、前 120 字）和转排队记录。
- **Default 模式提问由执行体开启**：先探测并缓存 `codex features list`；功能位存在时 app-server 进程默认覆盖 `features.default_mode_request_user_input=true` 和 `suppress_unstable_features_warning=true`，不改用户级配置；功能位缺失或探测失败不传该位，仅记 `feature_missing`，doctor 展示名称、阶段、生效值与是否携带；项目 `codex.request_user_input=false` 可关闭。编排者 probe-ask run #2 已验证 request_user_input → WAITING → answer → 复述回答全链路，44 秒完成。五份角色样例与 SKILL 恢复工具提问：只有红线和真正定不了的口径才问，其它合理完成后列「需要澄清」。
- 脚本以同一行 `main "$@"; exit $?` 收尾，避免运行中改文件后 bash 从旧偏移继续解析，污染 wait 返回码。

## 1.2.2 — 2026-09-11

- 调研配方加一句：有背景 issue 就 `bootstrap --gh-issue` 挂上，线程名 `{ids}` 才带号（cookie 09-11 在桌面端看到三条只有词没有号的调研线程）。调研不必先建 issue，这点不变。
- 用法文案里的 `<issue-id>` 全改成 `<票 id>`（cookie 09-11 看到调研票的线程名没有 issue 号，追问「框架是不是定死了有 issue」）：1.1 起票的 id 是任意标识符、issue 可选，但脚本用词没跟着改；目录名 `issues/` 与 meta 键 `gh_issue` 不动，改了现有票就认不出来。
- `wait` 遇到执行者提问（WAITING）立即打出问题并以 rc=3 返回（cookie 09-11 同意）：后台挂一个 `wait` 就同时覆盖「做完了」和「它在问你」两种叫醒，不用再另写轮询 status 的循环。selftest 加两项。
- `question_timeout` 默认 600 → 1800（cookie 09-11「不要卡太紧」）：执行者用 `request_user_input` 提问时等编排者 30 分钟再兜底。
- 验收任务书改名 `accept-brief-<id>.md`：原来叫 `accept-<id>.md`，与交付物 `ACCEPT-<PR>.md` 只差大小写，macOS 默认文件系统不区分大小写，验收者一落盘就把任务书覆盖了（#1606 实测）。
- `vercel` 探针收窄到写操作子命令与 `env`，`inspect` / `list` / `logs` 这类只读查询不再误报。
- `foreman.sh` 的命令派发段包进 `main()`：bash 逐段读脚本，`wait` 跑到一半时脚本被改会读到错位内容报 unexpected EOF；包进函数后整段先解析完再执行。
- SKILL.md 阶段 3 补一句：调研 / 验收线程最容易提问，派出后要盯 WAITING，别把 `wait` 丢后台就走（问题超时兜底等于白跑一轮）。
- 修 `wait` 竞态：只把 RUNNING / WAITING 当在跑，`run --detach` 刚把轮次放进常驻执行体的线程队列（QUEUED，几秒的交接窗口；与并发上限无关）时立刻 `wait` 会误报「没有正在运行的会话」直接返回（#1606 验收线程派发后实测）。现在 QUEUED 也算在跑；selftest 加一项。

## 1.2.1 — 2026-09-11

- **发布到 github.com/fatoncn/skills，仓库为真源**（cookie 09-11）：skill 以 `foreman/` 子目录放在个人公开仓库里，本机 `~/.claude/skills/foreman` 是指向克隆的符号链接；此前的本地仓库连历史归档到 `~/.foreman/archive/`，不再维护。
- **常规对外动作不再「先跟用户确认」**（cookie 09-11「对外动作并不是都需要我拍板，每个任务都要执行、没有破坏性的完全你自己拍板」）：首次 push、建 draft PR、建 issue 由编排者直接做；仍要人按的只有项目规则点名的合并由人、生产 / 动钱 / 部署平台写操作、改写共享历史、删远端分支。SKILL.md 阶段 2 / 阶段 5 / 命令速查与 `pr` 的提示语一起改；`--yes` 语义不变（不带只打印预览）。反例：#1606 验收通过后编排者停下来问「要不要 push」，多耗一个来回。

## 1.2.0 — 2026-09-11（晚，核心口径收口）

- **核心口径改写（cookie 09-11 晚）：编排层统筹，执行层干活。** 编排层只做需求分析、规划、推进、审核（增量代码逐行）；用户确认通道后，所有能独立切分的执行工作都交给执行层（排查、调研、实现、复审、验收冒烟、收尾）；拿 bug 举例：排查交给执行，下判断交给编排；留给自己的只有三类（要本会话独有的上下文 / MCP、要来回确认口径、一两步的小事）；已有口径能覆盖的小风险决定直接拍板并注明按的哪条，拿不准的问用户。取代 1.1.0 的「按工作量判」。
- **改掉四处自相矛盾**（编排者自己没照文档做，追根是文档打架）：① 开头前提「验收必须机械可判定，写不出的不派、自己做」把调研排除在外，改为两类票各有完成定义（实现票 = 退出码；调研票 = 交付物清单）；② 阶段 1「什么能派」只承认实现类任务，改为「先核事实：够量就派调研线程」；③ 阶段 1 规则 8 / 9 把「看 origin/<base>」「读在途 PR 的 diff」写成编排者亲自做的步骤，改为「核现状的人（多半是调研线程）」；④ 对象模型里只有实现票的形状，票的定义加上调研票（同样 bootstrap、检出只读、线程走 research 角色、交付物写到 --writable 目录、不开 PR）。判断的触发点改为「每一段活」而不是整个任务判一次。适合 / 不适合派出去的清单从旧版工作区 AGENTS.md 收回。
- **第四个参考角色 `research`**（只读调研；档位与实现者同级 + high 及以上，cookie 09-11）：`assets/roles/research.md` 契约 = 代码只读、交付物只写交付目录、排查归它判断归编排者、每条事实带出处、判断题给候选项不替编排者选；`setup` 一并拷、配置模板一并生成；三个必需角色不变，research 建议保留。不加新票种、不加新参数：调研线程 = `bootstrap --no-install` + `run --role research --writable <交付目录>`。
- **权限下限：review 之外的角色一律 workspace-write + 替我审批**（cookie 09-11：research 要 MCP、凭证库 + Keychain、写脚本、连库；验收要操作浏览器 / computer-use）。review 保持 read-only（它只看 diff，不需要环境）。角色文件写明能用的都能用、凭证内联取用；探针对 review / accept 挂「改了文件即阻塞」（`review-N.role` 落盘）。
- **review 定位改为对抗性视角**（cookie 09-11：子 agent 没有完整上下文，判不了需求做对没有）：只看 diff，挑破坏项目约定 / 仓库约定 / 最佳实践的地方，给意见 + 依据，采不采纳编排者逐条拍板；它最需要的上下文是编排者写的需求口径（前因后果、做到什么程度、有意不做的），`REVIEW-<id>.md` 模板首段改为需求口径；输出从 BLOCK / CONCERNS / LGTM 判决改为按严重度排的意见列表 + 一行总体印象 + 口径之外的观察；需求符合度由编排者自己审。
- **第五个参考角色 `accept`（验收）**：把产品真跑起来对清单看（浏览器 / 预览 / 查库），证据落交付目录，发现问题只报不修，逐项通过 / 不通过 / 未能验证；档位与实现者同级 + low～medium；走法 `run --role accept --writable <证据目录>`（位置是那张 PR 的 worktree，实现者已停手）；模板 `accept-<id>.md`；`ACCEPT-<PR>.md` 由它填好、编排者核过再给用户。
- **交叉复审按风险档跑**（cookie 09-11）：低风险跳过（编排者逐行审 + accept 冒烟够了），中高必跑；复审输出多一张「要求 → diff 位置」对照表，是给编排者逐行审的索引，不是判决。
- **同一 PR 同时只准一条线程在跑，脚本强制**（cookie 09-11「更多是框架层约束」）：`run` / `review` 前查同一 PR 上其它线程的轮次，RUNNING / QUEUED / WAITING 即拒绝（同一线程自己排队不在此限）；`review-N.pr` 随之落盘。selftest 加两项。
- accept 档位定为与实现者同级 + medium（比实现者高一档，假「通过」最贵）；research 交付物要求每个锚点附最小代码摘录，编排者不用再打开文件。
- 「本轮位置」块瘦成纯事实（cookie 09-11：和角色文件重复）：只写 cwd / 工作目录 / 分支 / 基线 / 交付目录，规矩只在角色文件说一遍；去掉与角色文件打架的「沙箱可写范围以这个目录及其 git 目录为准」（项目整体可写才是事实）。
- 探针补一道 git 事实：事件流里的 fileChange 只有 apply_patch 才有，执行者用 heredoc / 脚本写文件时 `files=0`（#1606 首轮实测：32 个文件改动、探针计数 0）。review / accept / research 起跑前记一份 worktree 的 `git status --porcelain`，`report` 时不一样就标「只看不改的角色改动了 worktree」并阻塞。
- 探针：`report` 把 `run --writable` 放开的目录当作内部（从 `run-N.request.json` 的 writable_roots 读），调研线程的交付物不再被标成「工作目录之外的改动」；改到检出里的照样标。selftest 加两项。
- 模板：`references/issue-pr-flow.md` 加 `research-<id>.md`（问事实不问方案）；阶段 4 加「调研票的验收」；命令速查 / usage 补 `--writable`、调研走法；usage 里过期的硬规矩 1 措辞（「派活前要 cd 进去」「目录必须等于编排者所在检出」）改为线程 cwd = 项目根。描述加「排查一下」「调研一下」触发词。工作区 AGENTS.md 分工节按同一口径重写。

## 1.1.2 — 2026-09-11（晚，18:5x～19:1x：线程 cwd = 项目根、票下多 PR、线程加锁；在 1.1.1 之后）

- **分工改成两级决定**（cookie 09-11 晚）：亲自做还是派出去由编排者按情况判——执行者读同一份项目规则、走同一条审批链，同样可信，差别只在模型弱一档、上下文窄一些；必须亲自的只有要会话上下文 / MCP、要来回确认、小改强依赖上下文三类，派不派主要看工作量值不值得付固定成本，查生产 / 动数据同样按量判（任务书写死边界 + 逐条核产出），「高危一律亲自」不作硬约束；阶段 1「不能派」改为「先拍板再派」+「视情况派」；验收行改为不派回同一执行者、派谁由用户定；描述改「三条通道各自擅长什么、由谁定」；派 spawn 还是 foreman 由用户定，两条通道地位相同，编排者不按判据自动路由，只提建议；判据表改为「各自擅长」参考表。工作区 AGENTS.md 同步。
- **线程加锁（cookie 09-11 晚「foreman 管理的线程要由编排脚本加锁，解锁由编排者明确结束工作再做」）**：codex 线程改由常驻执行体（`serve` 模式）占着写锁，每轮往队列丢请求；`release <id>` / `cleanup` 释放，`codex.hold_idle_minutes` 空闲自动释放；`status` 列 HOLD 与 QUEUED；`--new-thread` 先放掉旧的。「本轮位置」随之从开发者指令挪到 prompt 顶部。
- `--new-thread` 取消（cookie 09-11：同名线程不该被顶掉）：重开 = `release` 旧的 + `--thread <新名>` 另起，账本只增不改。
- `selftest` 零 token 自测（隔离目录 + 假 codex + 本地 bare 远端）；skill 目录纳入 git。另一会话 1.1.1 的五处修正全部保留。
- **硬规矩 1 纠偏（cookie 09-11 晚）**：线程 cwd 永远 = 编排者的项目根（`thread/start` cwd=PROJECT_ROOT），不再是 worktree、编排者不用 cd；桌面端按 cwd 与项目 rootPaths 精确相等归类，新线程自动落到项目下（已跑的线程 cwd 不可改，留在 Tasks）。**票下可挂多个 PR**（`meta.prs.<名>` = worktree / 分支 / 基线；`bootstrap --pr`、`run/review/check/diff/pr/cleanup --pr`，只有一个时省略；`here` 登记为 PR「here」；旧格式按 default 读）。每轮开发者指令顶部生成「本轮位置」（cwd、工作目录、分支、基线）。`rules.executor_rules_file` 删除：cwd = 项目根后 codex 自己读项目根 AGENTS.md（instructionSources 实测）。摘要器新增「工作目录之外的改动」探针（`work_dir` → `_fleet thread.workDir`），doctor 探针改在项目根跑、验「$HOME 不可写」。角色文件位置段同步（样例 + 本机）。撤销临时加过的桌面项目 root。
- 通道判据放宽（cookie 09-11「替我审批就是可以提权，查库 / 绕出沙盒也可以派 foreman」）：本机凭证、CLI、网络不再是改走 spawn 的理由，只读调研按开销选，spawn 只在「要接着编排者会话上下文 / 会话 MCP / 要来回确认」时必选；硬规矩 2 连带纪律改为「确需出沙箱就在任务书点名动作，不需要的一个字别写」；边界一节加凭证内联取用。工作区 AGENTS.md 同步。

## 1.1.1 — 2026-09-11（首张真票 #1626 实跑修正）

- **修复：`review` 起不来**。`foreman.sh` 复审分支 `write_request` 的参数列表里有一行多余的 `\ \` 续行、下一行又缺 `\`，导致 `"out_jsonl=…"` 起被当成独立命令执行（`line 1075: out_jsonl=…: No such file or directory`），复审线程根本没启动；顺手删掉同一列表里重复的空 `"meta_path="`（它会把前一行写的 `meta_path` 覆盖成空，复审线程的引用就记不进 meta.json）。1.1.0 的 review 路径在真仓库上从没跑通过，scratch 仓库闭环测的是改这段之前的版本。
- 复审（ephemeral）线程不再调 `thread/name/set`：app-server 对 ephemeral 线程回 -32600「不支持 metadata 更新」，1.1.0 每次复审都留一条「线程命名失败（不影响执行）」；桌面端本来也看不到 ephemeral 线程，命名没有意义。
- 参考文档记下 shared home 的一个实测坑：桌面端打开了 foreman 线程时 `thread/resume` 被拒（active writer），run rc=3；处置是 `--new-thread` 补上下文或 isolated home。SKILL.md「第一次用」的 shared / isolated 说明加上这一句代价。
- **修复：`foreman pr --yes` 推完分支就中止**。`gh pr create` 没带 `--head`，在包装脚本注入 token 的环境下 gh 认不出刚 `push -u` 的上游，报「you must first push the current branch to a remote, or use the --head flag」；现在显式传 `--head <票的分支>`。
- 任务书模板「工作纪律」加一条示例：验证日志写到工作树之外 —— 首张真票的执行者把日志写进了仓库目录 `data/<id>/`（未跟踪），收尾时容易被 `git add -A` 扫进去。

## 1.1.0 — 2026-09-11（下午～傍晚，1.1.1 之前）

- 线程命名模板归使用者（cookie 09-11）：本机 config.toml `codex.thread_name`，skill 只约束须含 `{ids}` 与 `{title}`，缺一拒绝；中性默认 `foreman {ids}: {title}`，本机设为 `【Foreman】{ids}：{title}`。
- 三个守卫：项目 foreman.toml 语法错误直接拦（以前 cfg 静默回落默认值）；`review` 先验 `origin/<base>` 在本地存在（以前是 git fatal）；前台 `run` 把执行体退出码透传（以前恒 0）。doctor 去掉 closeout 角色残留。
- 并发上限支持项目覆盖（cookie 09-11「当前项目允许 10 并发」）：项目 foreman.toml `[engines] concurrency` > 本机 config.toml 默认；计数仍是本机所有项目合计。
- 再收三个「读了但没决策」的键（cookie 09-11「不光读取，确实都有用」）：`codex.sandbox`（实现只能 workspace-write、复审固定 read-only，是常量不是开关，改为写死）；`engines.review_default`（与 roles.review.engine + engines.default 重复）；`codex.service_tier`（pi-fleet 环境变量的透传，app-server 下从未验证；shared 模式本就继承桌面端配置）。
- 配置层按「脚本读什么」收（cookie 09-11）：删 `project.rules_file`、`github.pr_base` / `batch_branch` / `close_issue_manually` / `issue_first_line`、`engines.pi_enabled`、全局 `[claude]` 段——都是 1.0.0 按文档口径造的开关，脚本从不读；生成器、样例、字段说明、SKILL.md 引用、doctor 的 claude 行一起删。`project.root` 改成真守卫：项目目录名撞车时 require_project 拒绝串用。
- SKILL.md 精简 312→277 行（cookie 09-11）：项目 / 仓库 / 项目规则只在对象模型定义一次；角色表、复审新线程、收尾续线程、并发上限、单执行者各只说一处；配置字段表整块移到 references/project-config.md；「审核逐文件读完」并入阶段 4；边界一节删掉与判据表、codex home 重复的两条。修正两处不自洽：`--new-thread` 语义（同名线程重开、角色引擎不变）；「永远不要把执行者指向主仓库」与 `here` 冲突，改为「主检出只在用户点名 here 时才是票目录」。
- `[rules]` 收成只剩 `executor_rules_file`（cookie 09-11：review 轮次、merge_by 是规则不是配置，且脚本从不读；`extra_rules_file` 与 `project.rules_file` 重复）。SKILL.md 阶段 5 改为「项目规则有规定按项目的，没有按默认」。
- 修复：`init` 尾行 `$PROJECT_TOML，` 未加花括号导致 unbound variable（全文件再扫一遍，已无同类写法）。
- SKILL.md：去掉项目专有词（治理 PR / promote / 规则激活迁移 / data/<批次>），改成「走项目自己的流程」；`foreman.toml` 措辞改为按项目生成、按仓库覆盖；安装说明去掉用户/日期专属口径；角色表只留「第一次用」一份，阶段 3 指回。
- 「分工模式」整节重写为**三条通道（foreman 派 codex / 宿主 spawn 子 agent / 外部会话转发）对同一项活互斥**：会话开头对齐默认通道，每项活按判据表选（进 PR 且机械可判 → foreman；只读调研 / 要宿主工具 → spawn；≤50 行强依赖上下文 → 自己做；验收永不派回 codex；额度告急改 spawn 不降沙箱）。spawn 通道的具体规则（次旗舰模型、同消息并发派、SendMessage 续同一 agent、不单独放宽权限）并入。来源：工作区 AGENTS.md「分工协作模式」+ cookie 09-11 晚的补充。
- **角色文件归使用者**：每个角色一份角色文件（契约），运行时读 `~/.foreman/roles/<名>.md`（或 `[roles.<名>].prompt`）。pi-fleet 的 implement / mechanical / review 作为 skill 的**参考角色**放 `assets/roles/`，`setup` 拷过去；**implement / review / mechanical 三个参考角色都必需**（cookie 09-11 晚），角色档位按**描述**定义、不绑死模型名（实现者 = 旗舰或次旗舰 + low～medium；复审 = 旗舰 + high；轻活 = 次旗舰 + low～medium、便宜但精准），模型名只作当日对应；再多的可选、使用者自定。缺必需角色或缺文件，`run` / `review` / `setup --confirm` 拒绝。
- **closeout 角色取消**（cookie 09-11 晚：实现者带着初始口径收尾更合理）：`run --closeout` 改为实现者续同一 `codex_thread`，把 `assets/CLOSEOUT.md`「收尾阶段契约」（放行对自己 PR 的 push / gh 写 + 本轮输出格式）放在那一轮 prompt 顶部；契约 skill 持有、只给实现角色；`codex_closeout_thread` 线程键与 `[roles.closeout]` 示例删除。
- **角色文件只写契约，干活纪律出注入文件**（cookie 09-11 晚：skill 管「如何分工」，「如何干活」由编排者写进 prompt）：ROLE / REVIEWER / CLOSEOUT 瘦身到位置、沙箱事实、分工边界（探针会查什么；与项目规则冲突以项目规则为准）、提问、输出格式。拿出来的内容进模板：任务书加可选「工作纪律」段、新增 `REVIEW-<id>.md` 复审关注点模板（`foreman review --prompt` 传入）、收尾任务书模板并入工作循环与轮次规则。
- 顶部新增「项目规则优先于本 skill」；`executor_rules_file` 明确只放仓库外规则（实测 codex 只注入仓库根到 cwd 链上的 AGENTS.md）。
- 阶段 1 加「在最新 base 上拆票」「追加范围前先看在途 PR 的 diff」；阶段 2 加写任务书三戒律（不自造数值约束 / UI 判据写成产品口径 / 写日期先 `date`）；阶段 4 加审核范围（第 N 轮只审增量、整文件删除按文件名核）。触发词加「处理 review 反馈」「报可合」。
- 工作区 AGENTS.md 的「分工协作模式」「review 反馈闭环」两节同日收成指向本 skill 的短段（cookie 拍板）。
- 收尾最佳实践加「没有 CI run 先查冲突」（阶段 5 + 收尾任务书模板；项目规则优先）。
- **去工作区烙印**（cookie 09-11：skill 只留分工机制与通用最佳实践）：分工判据里的工具名改成泛称、「报可合」不再默认预览 URL、模板里的项目特定例子（真实模型抽样、哪门课 / 哪个空间、vitest）改成泛例、示例配置改中性值。
- **对象模型定稿**（cookie 09-11 晚：skill 以仓库内的票为单位，票下挂线程，线程有角色、属于一个引擎；靠框架 + prompt 自洽而不是靠 prompt 约束）：线程建立时绑定角色与引擎，续线程自动取记录、显式不一致拒绝；SKILL.md 从对象模型讲起；`list` 显示票 → 线程。
- **票下若干线程、引擎无关的账本**（cookie 09-11：一份工作必须由一张票立起来，票下可以有若干线程，规划者才找得到之前的线程）：meta.threads.<名> = {engine, ref, role, kind, home, runs}；`run --thread <名>`，默认按角色命名，`--closeout` 续 implement，复审入账为 review-N；换引擎不能续同一条；新命令 `foreman threads <id>`；status 显示 `角色@线程`。继承自 pi-fleet 的「每票一条隐式线程」模型，改成显式多线程。
- **配置改按项目、兼容多仓库、非 git 也能派**（cookie 09-11：仓库配置要留但不能一个项目只有一个仓库；skill 也可能派跟仓库无关的活）：`~/.foreman/projects/<项目>/foreman.toml` 顶层 = 项目级默认，`[repos."<slug>"]` = 按仓库覆盖，origin / 远端默认分支 / 装依赖 / 验收命令运行时推导；`bootstrap --base / --copy-env` 可临时指定；worktree 落点支持 `{repo}` `{project}` `{name}` 占位符；不在 git 仓库里 `here` / `run` / `status` / `report` / `check` / `cleanup` 照用，bootstrap / diff / review / pr 明确拒绝。
- **init 瘦身**（cookie 09-11：过头了，每个项目结构不同）：只生成骨架（git 事实 + 中性默认 + lockfile / package.json 通用探测），删掉工作区特有的探测（gh 包装脚本、data/worktrees、需求首行契约、分支校验脚本、staging 偏好）；项目特有字段由编排者读项目规则填，`init` 打印清单。
- **术语改口径**（cookie 09-11）：项目 = Claude 工作目录（工作区根）、项目规则 = 根目录 AGENTS.md + 仓库内 AGENTS.md；skill 按仓库生成的配置改叫**仓库配置** `~/.foreman/repos/<owner--repo>/repo.toml`（原 projects/project.toml）；`executor_rules_file` 默认指向根目录 AGENTS.md 整份注入，不再另造规则文件。
- **线程命名**（cookie 09-11）：`run` / `review` 自动 `thread/name/set` 为 `【Foreman】<issue/PR 号，+ 连接>：<工作内容>`（`--title` > 任务书首标题 > 阶段默认）；探针实测 `thread/name/set {threadId,name}` 返回 `{}`、`thread/read` 回读、通知 `thread/name/updated`。
- **改名 foreman、只装 Claude**（cookie 09-11）：skill 真身 `~/.claude/skills/foreman`，数据目录 `~/.foreman`，环境变量前缀 `FOREMAN_`；不放 `~/.agents/skills`（Codex 扫该目录，桌面端会话曾因此直接用上）。
- **codex home 模式必须显式选**（cookie 09-11：不默认隔离也不默认共用）：`foreman setup --codex-home shared|isolated` 写入全局 `[codex] home`，不设则 doctor 只提示、run / review / setup --confirm 拒绝；shared 共用桌面端 `~/.codex`（脚本不再往里写 auth 软链和 config.toml）、isolated 独立 home；续线程按创建时的 home（meta.codex_home，或在两个 home 的 sessions/ 里找 rollout），切换模式不丢旧线程。
- **执行器不可用只告知用户**（cookie 09-11：404 这类宕机不排障）：执行体把 404 / 5xx / 连接失败 / 429 / 401 判成 `ENGINE_DOWN`（rc=4、`_fleet: engine_unavailable`），`status` / `wait` 标出、`report` 顶部横幅、`doctor` 握手失败同样提示；SKILL.md 写明只告知用户等其决定。
- 阶段 5 并入工作区 AGENTS.md 的「小修轻量收尾」与「批次合测只做集成态冒烟」两条。
- 修正：项目规则表里 `codex` 行的默认值写成了 `approval_policy=never`，与硬规矩 2 矛盾，改为 on-request + auto_review；命令速查补 `foreman here`。
- 真源口径（同日下午）：任务书首段写真源、每个 PR 注明实现真源；建 issue 降为建议。

## 1.0.0 — 2026-09-11

从 Derek 团队的 `pi-fleet`（2026-08-26 版）改造而来，面向「Claude Code 当编排者、codex 当执行器」的跨项目通用版。

继承（实测过，原样或近原样）：worktree 生命周期、detach / watchdog / 状态机、summarize 的探针与 pi / codex-exec 解析、review 三件输入与一次性副本、check / diff / cleanup / list、doctor 沙箱断言、ROLE / REVIEWER、codex-cli.md / pi-cli.md、阶段 0～5 方法论。

新增：
- 默认执行器换成 `codex app-server` 协议（`scripts/codex_appserver.py`）：线程级 developerInstructions、轮级 model / effort、审批策略、执行者向编排者提问（`foreman questions` / `answer`）、`turn/interrupt` 优雅中断。
- `codex exec` 路径保留为 `--engine codex-exec` 备用引擎。
- 全 skill 一份隔离 CODEX_HOME（`~/.foreman/codex-home`），不再每票一份。
- 仓库配置 `repo.toml`（`foreman init` 探测生成）：角色 → 模型 / 推理档默认表、基线、验收命令、gh 入口、汇总分支开关、review 轮次、合并归人。
- 收尾角色 `CLOSEOUT.md` + `run --role closeout`；`tail`、`pr`（打印命令，--yes 才执行）、`cleanup` 拒绝未推送提交。
- 把工作区 AGENTS.md 的协作纪律（任务书自包含、审核逐文件读完、PR 粒度按用户面、review 轮次按风险、报可合三件、合并归人、外部会话转发格式）通用化后并入 SKILL.md。
- 副线说明 `references/orchestrator-codex.md`（Codex 编排 / Claude 执行器，未实现）。

未实现 / 未验证：claude 执行器；app-server 首跑前的 8 条未验证项见 `references/codex-app-server.md`。

### 1.0.0 当日补充（2026-09-11 下午，用户两条硬规矩）
- 派活目录必须等于编排者当前所在的检出目录：`run` / `review` 前比对，不一致直接拒绝；新增 `foreman here <id>` 把当前检出登记为执行目录。
- 审批默认「替我审批」：`approval_policy=on-request` + `approvals_reviewer=auto_review`；`codex-exec` 加 `--approve-for-me`。沙箱只允许 workspace-write / read-only。
- 完全权限只留一个口子 `run --full-access "<用户原话>"`：无沙箱无审批，原话进 `run-N.full-access` / 事件流 / 摘要横幅 / `status !FULL`；执行体拒绝没有用户标记的 danger-full-access；复审无此口子。
- 修复：turn 级 sandboxPolicy 导致 git 写 gitdir EPERM（已不传）；`codex` 软链需同目录 `codex-code-mode-host`；`exec_call` 同行 local 引用；`$var` 后紧跟全角标点被吃成变量名。
- 角色收成两个（用户拍板）：implement = gpt-6-astra/low（实现+测试等一切写码活，收尾也用它）、review = gpt-6-astra/high；`--role` 改为 `--closeout` 开关只换提示词；去掉「复审必须换模型」警告。只保留两个角色。
- 角色分工跨项目：角色表挪到 `~/.foreman/config.toml`（`foreman setup` 生成 / 查看，`--confirm` 确认后才能派活；项目同名 `[roles.<名>]` 可覆盖）；名字自定，pi-fleet 的 mechanical / closeout 留作注释示例。本机并发上限 5 也在全局并强制。复审永远新线程，`--closeout` 走独立线程键。
