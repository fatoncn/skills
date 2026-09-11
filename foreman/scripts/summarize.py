#!/usr/bin/env python3
"""把执行器的事件流压成编排者能直接读的摘要。

支持三种事件流，靠内容自动辨认:

  appserver  {"jsonrpc":"2.0","method":"thread/started",…}   codex app-server（默认执行器）
  codex-exec {"type":"thread.started"}                        旧 `codex exec --json`（兼容 pi-fleet 留下的日志）
  pi         {"type":"session"}                               pi（可选执行器）

三种流在非交互模式下都没有审批环节，失败会静静躺在流里——编排者不解析就会把失败当成功。
这个脚本负责把「没跑完」「命令报错」「碰了禁区命令」「向编排者提过问」四类信号顶到最前面。

越界探针 FORBIDDEN 是所有执行器共用的单一真源，不要复制一份出去。
"""
from __future__ import annotations

import json
import os
import re
import sys
import time

# 越界命令探针：执行器侧靠角色文件（契约）约束，这里做事后检测，双保险。命中只是「需要编排者判断」，项目规则允许的由编排者放行。
FORBIDDEN = [
    (re.compile(r"\bgit\s+push\b"), "git push"),
    (re.compile(r"\bgit\s+remote\s+(add|set-url|remove)\b"), "git remote 写操作"),
    # 只探 gh 的写子命令：只读的 view/list/diff 是任务书明确允许的，一并报会制造噪音
    (re.compile(r"\bgh\s+(issue|pr)\s+(create|edit|comment|close|merge|reopen|ready|review)\b"), "gh 写操作"),
    (re.compile(r"\bgh\s+(release|workflow|secret|repo)\b"), "gh 写操作"),
    (re.compile(r"\bgh\s+api\b.*(-X|--method)\s*(POST|PUT|PATCH|DELETE)"), "gh api 写"),
    (re.compile(r"\bgh\s+api\s+graphql\b"), "gh api graphql"),
    # vercel 只探写操作与 env：inspect / list / ls / logs / whoami / api GET 是任务书常允许的只读查询（#1606 验收线程 3 次误报）
    (re.compile(r"\bvercel\s+(deploy|promote|rollback|redeploy|alias|env|domains|dns|certs|rm|remove|link|project|teams|switch|login|logout|git)\b"), "vercel 写操作或 env"),
    (re.compile(r"\bvercel\s+api\b.*(-X|--method)\s*(POST|PUT|PATCH|DELETE)"), "vercel api 写"),
    (re.compile(r"\bsupabase\s+(link|db\s+push|db\s+remote)\b"), "supabase 远端"),
    (re.compile(r"\bnpx?\s+sst\b|\bsst\s+deploy\b"), "sst deploy"),
    (re.compile(r"eslint-disable"), "eslint-disable"),
    (re.compile(r"\.(skip|only)\s*\("), "测试 skip/only"),
    (re.compile(r"\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f|checkout\s+--\s|stash)\b"), "git 破坏性操作"),
    (re.compile(r"\bgit\s+push\b.*(--force|-f\b)"), "git push --force"),
    # 绕过索引 / 沙箱的底层提交手法：实测 luna 在沙箱拒绝后会用 GIT_INDEX_FILE + commit-tree + update-ref 硬造提交，
    # 结果把 README 从树里丢了。这是「被拒后绕路」的信号，必须人工看。
    (re.compile(r"GIT_INDEX_FILE=|\bgit\s+(update-ref|commit-tree|write-tree|symbolic-ref)\b|\bgit\s+--git-dir="), "git 底层改写（绕过索引/沙箱）"),
]

# 收尾轮（run --closeout，run-N.role 写 closeout 作阶段标记）被明确允许对自己的 PR 做这些远端动作，探针放行；仍然禁的留在 FORBIDDEN 里
CLOSEOUT_ALLOW = [
    re.compile(r"\bgit\s+push\b(?!.*(--force|-f\b))"),
    re.compile(r"\bgh\s+pr\s+(comment|ready|review)\b"),
    re.compile(r"\bgh\s+api\s+graphql\b"),
    re.compile(r"\bgh\s+api\b.*(-X|--method)\s*(POST|PATCH)\b.*(comments|reviews|pulls)"),
    re.compile(r"\bgh\s+pr\s+edit\b"),
]

# codex 用 item.type=="error" 报运行提示，不是任务失败，不能一律当红灯
BENIGN_ERROR = [
    re.compile(r"[Ss]kill descriptions? .*(shortened|removed)"),
    re.compile(r"Exceeded skills context budget"),
]

TRUNC = 4000


def text_of(message: dict) -> str:
    parts = []
    for chunk in message.get("content") or []:
        if chunk.get("type") == "text":
            parts.append(chunk.get("text", ""))
    return "\n".join(parts).strip()


def stringify(value, limit: int = 600) -> str:
    if isinstance(value, str):
        out = value
    else:
        try:
            out = json.dumps(value, ensure_ascii=False)
        except Exception:
            out = repr(value)
    out = out.strip()
    return out if len(out) <= limit else out[:limit] + f"…(+{len(out) - limit})"


def load(path: str):
    events = []
    with open(path, encoding="utf-8", errors="replace") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return events


def detect_engine(events) -> str:
    for event in events:
        if event.get("jsonrpc") == "2.0" or event.get("_fleet"):
            return "appserver"
        kind = event.get("type")
        if kind in ("thread.started", "turn.started", "turn.completed", "turn.failed", "item.completed"):
            return "codex"
        if kind in ("session", "agent_start", "message_end", "agent_settled", "tool_execution_start"):
            return "pi"
    return "appserver"


def blank_state() -> dict:
    return {
        "engine": "appserver",
        "id": None,
        "model": None,
        "effort": None,
        "settled": False,          # 这一轮是否正常收尾
        "status": None,            # appserver: completed / interrupted / failed
        "engine_down": None,
        "thread_busy": None,       # appserver: 线程被别的客户端占着（桌面端打开了它），rc=5       # appserver: 执行器不可用（404 / 5xx / 额度 / 登录），rc=4
        "cost": 0.0,               # 仅 pi：美元
        "tokens": 0,
        "in_tokens": 0,
        "out_tokens": 0,
        "cached_tokens": 0,
        "turns": 0,
        "errors": [],
        "tool_errors": [],
        "forbidden": [],
        "approvals": [],           # appserver: 回到执行体的审批请求及决定
        "auto_reviews": [],        # appserver: Codex 自动审查（替我审批）的决定
        "steers": [],
        "requeued_steers": [],
        "questions": [],           # appserver: 向编排者提的问题
        "tool_calls": 0,
        "web_searches": 0,
        "files": [],
        "work_dir": None,
        "notices": [],
        "final": "",
        "duration_ms": None,
    }


def _extra_writable_roots(log_path):
    """编排者用 run --writable 放开的目录（run-N.request.json 的 config_overrides）：调研线程的交付目录就靠它，探针把这些目录当作内部。"""
    import os, json
    if not log_path.endswith(".jsonl"):
        return []
    req = log_path[:-len(".jsonl")] + ".request.json"
    if not os.path.isfile(req):
        return []
    try:
        r = json.load(open(req, encoding="utf-8"))
        ov = dict(r.get("config_overrides") or [])
        roots = json.loads(ov.get("sandbox_workspace_write.writable_roots") or "[]")
        return [os.path.realpath(x) for x in roots if isinstance(x, str) and x]
    except Exception:
        return []


def _inside(real, root):
    return real == root or real.startswith(root + os.sep)


def _files_outside_work_dir(state):
    """线程 cwd = 项目根、整个项目可写，所以事后核：fileChange 的路径必须都在本轮工作目录（或 --writable 放开的目录）之内。"""
    wd = state.get("work_dir")
    if not wd:
        return []
    root = os.path.realpath(wd)
    extra = state.get("writable_extra") or []
    temp_roots = {os.path.realpath(p) for p in (os.environ.get("TMPDIR"), "/tmp", "/private/tmp") if p}
    out = []
    for kind, path in state.get("files") or []:
        if not isinstance(path, str) or not os.path.isabs(path):
            continue
        real = os.path.realpath(path)
        if (not _inside(real, root) and not any(_inside(real, e) for e in extra)
                and not any(_inside(real, t) for t in temp_roots)):
            out.append((kind, path))
    return out


def probe_forbidden(state, blob: str, shown, role: str | None = None):
    if role == "closeout" and any(p.search(blob) for p in CLOSEOUT_ALLOW):
        # 放行清单命中的命令仍要过「硬禁」那几条（force push / merge / close）
        for pattern, label in FORBIDDEN:
            if label in ("git push --force", "git 破坏性操作") and pattern.search(blob):
                state["forbidden"].append((label, shown))
        for pattern, label in [(re.compile(r"\bgh\s+pr\s+(merge|close)\b"), "gh pr merge/close")]:
            if pattern.search(blob):
                state["forbidden"].append((label, shown))
        return
    for pattern, label in FORBIDDEN:
        if pattern.search(blob):
            state["forbidden"].append((label, shown))


# ---------- pi ----------

def scan_pi(events, role=None):
    state = blank_state()
    state["engine"] = "pi"
    for event in events:
        kind = event.get("type")
        if kind == "session":
            state["id"] = event.get("id")
        elif kind == "agent_settled":
            state["settled"] = True
        elif kind == "turn_end":
            state["turns"] += 1
        elif kind == "tool_execution_start":
            state["tool_calls"] += 1
            args = event.get("args") or {}
            blob = " ".join(str(v) for v in (args.values() if isinstance(args, dict) else [args]))
            probe_forbidden(state, blob, stringify(args, 300), role)
        elif kind == "tool_execution_end":
            if event.get("isError"):
                state["tool_errors"].append((event.get("toolName", "?"), stringify(event.get("result"))))
        elif kind == "message_end":
            message = event.get("message") or {}
            if message.get("role") != "assistant":
                continue
            state["model"] = message.get("model") or state["model"]
            usage = message.get("usage") or {}
            state["cost"] += float((usage.get("cost") or {}).get("total") or 0)
            state["tokens"] += int(usage.get("totalTokens") or 0)
            if message.get("stopReason") == "error":
                state["errors"].append(message.get("errorMessage") or "(未提供 errorMessage)")
            body = text_of(message)
            if body:
                state["final"] = body
    return state


# ---------- codex exec（旧档，兼容） ----------

def scan_codex(events, role=None):
    state = blank_state()
    state["engine"] = "codex"
    started = 0
    for event in events:
        kind = event.get("type")
        if kind == "thread.started":
            state["id"] = event.get("thread_id")
        elif kind == "turn.started":
            started += 1
        elif kind == "turn.completed":
            state["turns"] += 1
            usage = event.get("usage") or {}
            state["in_tokens"] += int(usage.get("input_tokens") or 0)
            state["out_tokens"] += int(usage.get("output_tokens") or 0)
            state["cached_tokens"] += int(usage.get("cached_input_tokens") or 0)
        elif kind == "turn.failed":
            state["errors"].append(stringify(event.get("error") or event.get("message") or event, 800))
        elif kind == "item.completed":
            item = event.get("item") or {}
            itype = item.get("type")
            if itype == "command_execution":
                state["tool_calls"] += 1
                command = item.get("command") or ""
                exit_code = item.get("exit_code")
                if exit_code not in (0, None) or item.get("status") == "failed":
                    state["tool_errors"].append((f"exit {exit_code}", f"{stringify(command, 200)}\n      {stringify(item.get('aggregated_output'), 300)}"))
                probe_forbidden(state, command, stringify(command, 300), role)
            elif itype in ("file_change", "patch_apply"):
                for change in item.get("changes") or []:
                    state["files"].append((change.get("kind", "?"), change.get("path", "?")))
            elif itype == "agent_message":
                body = (item.get("text") or "").strip()
                if body:
                    state["final"] = body
            elif itype == "error":
                message = item.get("message") or ""
                if any(p.search(message) for p in BENIGN_ERROR):
                    state["notices"].append(stringify(message, 300))
                else:
                    state["errors"].append(stringify(message, 800))
    state["settled"] = started > 0 and state["turns"] >= started
    state["tokens"] = state["in_tokens"] + state["out_tokens"]
    return state


# ---------- codex app-server（默认） ----------

def _kind_of(change_kind) -> str:
    if isinstance(change_kind, dict):
        return str(change_kind.get("type") or "?")
    return str(change_kind or "?")


def _usage_int(usage: dict, *keys) -> int:
    for key in keys:
        if key in usage and usage[key] is not None:
            try:
                return int(usage[key])
            except (TypeError, ValueError):
                pass
    return 0


def scan_appserver(events, role=None):
    state = blank_state()
    state["engine"] = "appserver"
    final_phase = None
    for event in events:
        foreman = event.get("_fleet")
        if foreman == "out":
            continue
        if foreman == "thread":
            state["id"] = event.get("threadId") or state["id"]
            state["work_dir"] = event.get("workDir") or state["work_dir"]
            state["model"] = event.get("model") or state["model"]
            state["effort"] = event.get("reasoningEffort") or state["effort"]
            continue
        if foreman == "approval":
            state["approvals"].append((event.get("kind"), event.get("decision"), stringify(event.get("command") or event.get("reason") or "", 200)))
            continue
        if foreman == "question":
            for q in event.get("questions") or [{"question": "(无题目文本)"}]:
                state["questions"].append(stringify(q.get("question") or q, 300))
            continue
        if foreman == "answer":
            state["notices"].append("编排者" + ("已回答" if event.get("answered") else "未回答（用了兜底答复）") + "执行者的提问")
            continue
        if foreman == "steer":
            state["steers"].append(event)
            continue
        if foreman == "steer_requeued":
            state["requeued_steers"].append(event)
            continue
        if foreman == "steer_error":
            state["errors"].append("steer: " + stringify(event.get("error"), 800))
            continue
        if foreman == "protocol_error":
            state["errors"].append("协议错误: " + stringify(event.get("error"), 600))
            continue
        if foreman == "thread_name":
            state["notices"].append("线程名: " + stringify(event.get("name"), 120))
            continue
        if foreman == "thread_name_error":
            state["notices"].append("线程命名失败（不影响执行）: " + stringify(event.get("error"), 200))
            continue
        if foreman == "thread_busy":
            state["thread_busy"] = event.get("hint") or "线程被占用"
            state["notices"].insert(0, "⏸ THREAD_BUSY " + state["thread_busy"])
            continue
        if foreman == "engine_unavailable":
            state["engine_down"] = event.get("hint") or "codex 不可用"
            state["notices"].insert(0, "⛔ ENGINE_DOWN " + state["engine_down"] + "：告知用户该执行器暂时不可用，附下面「模型 / 协议错误」里的原始报错一行；不要自行排代理、换节点、反复重试")
            continue
        if foreman == "full_access":
            state["notices"].insert(0, "⚠ 本轮使用完全权限（无沙箱、无审批），用户要求原话: " + stringify(event.get("reason"), 300))
            continue
        if foreman == "interrupt":
            state["notices"].append("这一轮被编排者中断（turn/interrupt）")
            continue
        if foreman == "turn_summary":
            state["status"] = event.get("status") or state["status"]
            state["duration_ms"] = event.get("durationMs")
            usage = event.get("tokenUsage") or {}
            total = usage.get("total") or usage
            if isinstance(total, dict):
                state["in_tokens"] = _usage_int(total, "inputTokens", "input_tokens")
                state["out_tokens"] = _usage_int(total, "outputTokens", "output_tokens")
                state["cached_tokens"] = _usage_int(total, "cachedInputTokens", "cached_input_tokens")
                state["tokens"] = _usage_int(total, "totalTokens", "total_tokens") or (state["in_tokens"] + state["out_tokens"])
            if event.get("error"):
                state["errors"].append(stringify(event["error"], 800))
            continue
        if foreman:
            continue

        method = event.get("method")
        params = event.get("params") or {}
        if not method:
            continue
        if method == "thread/started":
            thread = params.get("thread") or {}
            state["id"] = thread.get("id") or state["id"]
            state["model"] = thread.get("model") or state["model"]
        elif method == "turn/started":
            state["turns"] += 1
        elif method == "turn/completed":
            turn = params.get("turn") or {}
            state["status"] = turn.get("status") or state["status"]
            if turn.get("status") == "completed":
                state["settled"] = True
            if turn.get("error"):
                state["errors"].append(stringify(turn["error"], 800))
        elif method == "error":
            err = params.get("error") or {}
            msg = stringify(err.get("message") or err, 600)
            if params.get("willRetry"):
                state["notices"].append("可重试错误: " + msg)
            else:
                state["errors"].append(msg)
        elif method == "item/completed":
            item = params.get("item") or {}
            itype = item.get("type")
            if itype == "commandExecution":
                state["tool_calls"] += 1
                command = item.get("command") or ""
                exit_code = item.get("exitCode")
                status = item.get("status")
                if status in ("failed", "declined") or exit_code not in (0, None):
                    state["tool_errors"].append((f"exit {exit_code} {status or ''}".strip(),
                                                 f"{stringify(command, 200)}\n      {stringify(item.get('aggregatedOutput'), 300)}"))
                probe_forbidden(state, command, stringify(command, 300), role)
            elif itype == "fileChange":
                for change in item.get("changes") or []:
                    state["files"].append((_kind_of(change.get("kind")), change.get("path", "?")))
                if item.get("status") in ("failed", "declined"):
                    state["tool_errors"].append((f"fileChange {item.get('status')}", stringify([c.get("path") for c in item.get("changes") or []], 300)))
            elif itype == "agentMessage":
                body = (item.get("text") or "").strip()
                phase = item.get("phase")
                if body and (phase == "final_answer" or final_phase != "final_answer"):
                    state["final"] = body
                    final_phase = phase
            elif itype == "webSearch":
                state["web_searches"] += 1
            elif itype == "mcpToolCall":
                state["tool_calls"] += 1
                if item.get("error") or item.get("status") == "failed":
                    state["tool_errors"].append((f"mcp {item.get('server')}/{item.get('tool')}", stringify(item.get("error"), 300)))
        elif method == "item/autoApprovalReview/completed":
            review = params.get("review") or {}
            action = params.get("action") or {}
            state["auto_reviews"].append((
                review.get("status") or "?", review.get("riskLevel") or "?", review.get("userAuthorization") or "?",
                stringify(action.get("command") or action.get("type") or action, 200),
                stringify(review.get("rationale") or "", 240),
            ))
        elif method == "warning":
            msg = stringify(params.get("message") or params, 300)
            if "Automatic approval review" not in msg:
                state["notices"].append("warning: " + msg)
        elif method == "thread/tokenUsage/updated":
            usage = (params.get("tokenUsage") or {}).get("total") or {}
            if isinstance(usage, dict) and usage:
                state["in_tokens"] = _usage_int(usage, "inputTokens", "input_tokens")
                state["out_tokens"] = _usage_int(usage, "outputTokens", "output_tokens")
                state["cached_tokens"] = _usage_int(usage, "cachedInputTokens", "cached_input_tokens")
                state["tokens"] = _usage_int(usage, "totalTokens", "total_tokens") or (state["in_tokens"] + state["out_tokens"])
        elif method == "item/commandExecution/requestApproval" and "id" in event:
            pass  # 决定在 _fleet.approval 里记
    return state


def scan(events, engine: str | None = None, role: str | None = None):
    engine = engine or detect_engine(events)
    if engine == "appserver":
        return scan_appserver(events, role)
    if engine == "codex":
        return scan_codex(events, role)
    return scan_pi(events, role)


def report(log_path: str, stderr_path: str | None, last_path: str | None = None,
           engine: str | None = None, role: str | None = None) -> int:
    events = load(log_path)
    if not events:
        print(f"!! 空日志: {log_path}")
        return 1
    state = scan(events, engine, role)
    state["writable_extra"] = _extra_writable_roots(log_path)
    eng = state["engine"]
    codex_like = eng in ("codex", "appserver")

    print(f"=== {eng} run 摘要 · {os.path.basename(log_path)}" + (f" · role={role}" if role else "") + " ===")
    for note in state["notices"]:
        if note.startswith("⚠ 本轮使用完全权限"):
            print(note)
    label = "thread" if codex_like else "session"
    extra = f"  effort={state['effort']}" if state.get("effort") else ""
    dur = f"  用时={state['duration_ms'] // 1000}s" if state.get("duration_ms") else ""
    print(f"{label}={state['id']}  model={state['model'] or '—'}{extra}  turns={state['turns']}  "
          f"tools={state['tool_calls']}" + (f"  files={len(state['files'])}" if codex_like else "")
          + (f"  web_search={state['web_searches']}" if state["web_searches"] else "") + dur)
    if codex_like:
        print(f"tokens: in={state['in_tokens']} (cached {state['cached_tokens']})  out={state['out_tokens']}"
              "   —— ChatGPT 订阅额度计费，无单次美元成本")
    else:
        print(f"cost=${state['cost']:.4f}  tokens={state['tokens']}")

    blockers = []
    # 复审 / 验收契约：只看不改（复审是只读沙箱，写不进去；验收跑在 workspace-write 要能起服务、用浏览器，所以靠这里事后核）
    if role in ("review", "accept") and state.get("files"):
        blockers.append(f"{role} 改了 {len(state['files'])} 个文件（该角色只看不改，改了这轮作废）")
    if state.get("thread_busy"):
        blockers.append("线程被占用：" + state["thread_busy"] + " —— 不是任务失败，这轮什么都没跑")
    if state.get("engine_down"):
        blockers.append("执行器不可用：" + state["engine_down"] + " —— 这不是任务失败，是 engine 暂时用不了；告知用户，等用户决定等 / 换 --engine / 改 spawn")
    if not state["settled"]:
        if eng == "appserver":
            blockers.append(f"turn 没有正常完成（status={state['status'] or '未知'}）：可能超时被杀、被中断、模型侧失败或协议错误")
        elif eng == "codex":
            blockers.append("有 turn 没有 turn.completed：可能超时被杀、崩溃或被中断")
        else:
            blockers.append("会话没有正常结束（无 agent_settled）：可能超时被杀、崩溃或被中断")
    if state["errors"]:
        blockers.append(f"模型侧 / 协议错误 {len(state['errors'])} 条")
    if state["tool_errors"]:
        blockers.append(f"命令非零退出或被拒 {len(state['tool_errors'])} 次（迭代中出现属正常，看下面清单判断）"
                        if codex_like else f"工具执行失败 {len(state['tool_errors'])} 次")
    if state["forbidden"]:
        blockers.append(f"命中越界命令探针 {len(state['forbidden'])} 次")
    outside = _files_outside_work_dir(state)
    if outside:
        blockers.append(f"改动了工作目录之外的 {len(outside)} 个文件（线程 cwd 是项目根，本轮位置块限定只改 {state['work_dir']}）")
    declined = [a for a in state["approvals"] if a[1] in ("decline", "denied", "unsupported")]
    if declined:
        blockers.append(f"执行者请求过 {len(declined)} 次沙箱外权限，已按策略拒绝（看它有没有绕路）")
    approved_auto = [r for r in state["auto_reviews"] if r[0] == "approved"]
    if approved_auto:
        blockers.append(f"自动审查（替我审批）放行了 {len(approved_auto)} 次沙箱外动作——逐条看清单，确认是任务需要的")
    elif state["auto_reviews"]:
        blockers.append(f"自动审查拒绝了 {len(state['auto_reviews'])} 次沙箱外动作（看它有没有绕路）")
    if state["questions"]:
        blockers.append(f"执行者向编排者提了 {len(state['questions'])} 个问题（看是否用了兜底答复）")

    if blockers:
        print("\n!!!! 需要人工/编排者判断 !!!!")
        for item in blockers:
            print(f"  - {item}")
    else:
        print("\n状态: 正常收尾，无工具错误，无越界探针命中，无审批请求，无提问")

    if state["errors"]:
        print("\n--- 模型 / 协议错误 ---")
        for message in state["errors"]:
            print(f"  {stringify(message, 800)}")

    if state["forbidden"]:
        print(f"\n--- 越界命令探针（{eng} 实际尝试过的调用）---")
        for label_, args in state["forbidden"]:
            print(f"  [{label_}] {args}")

    if state["auto_reviews"]:
        print("\n--- 自动审查（替我审批）的决定 ---")
        for status, risk, auth, what, why in state["auto_reviews"]:
            print(f"  [{status} · risk={risk} · userAuth={auth}] {what}")
            if why:
                print(f"      理由: {why}")
    if state["approvals"]:
        print("\n--- 审批请求（回到执行体的）---")
        for kind, decision, what in state["approvals"]:
            print(f"  [{kind} → {decision}] {what}")

    for key, title in (("steers", "本轮收到的引导消息"), ("requeued_steers", "引导转排队（steer_requeued）")):
        if state[key]:
            print(f"\n--- {title} ---")
            for entry in state[key]:
                at = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(entry.get("at", 0) / 1000))
                source = f"fromRun={entry.get('fromRun')}"
                target = f" → run #{entry['run']}" if key == "requeued_steers" else ""
                preview = (entry.get("text") or "")[:120].replace("\n", " ")
                print(f"  {at}  {source}{target}  {preview}")

    if state["questions"]:
        print("\n--- 执行者的提问 ---")
        for q in state["questions"]:
            print(f"  ? {q}")

    if state["tool_errors"]:
        print("\n--- 工具/命令失败（最多 10 条）---")
        for name, result in state["tool_errors"][:10]:
            print(f"  [{name}] {result}")
        if codex_like and any("xcrun_db" in r for _, r in state["tool_errors"]):
            print("  （提示：xcrun_db 缓存报错是沙箱下 macOS git 的固有噪音，按 stdout 判断）")

    outside = _files_outside_work_dir(state)
    if outside:
        print(f"\n--- 工作目录之外的改动（{len(outside)} 个，需要编排者判断：项目根整体可写，但本轮只该改 {state['work_dir']}）---")
        for kind, path in outside[:40]:
            print(f"  {kind:<8} {path}")
    if state["files"]:
        print("\n--- 模型直接改动的文件（不含它经 shell 改的）---")
        for kind, path in state["files"][:40]:
            print(f"  {kind:>6}  {path}")
        if len(state["files"]) > 40:
            print(f"  …(+{len(state['files']) - 40})")

    print(f"\n--- {eng} 的交付报告（最后一条消息）---")
    final = state["final"]
    if not final and last_path and os.path.exists(last_path):
        with open(last_path, encoding="utf-8", errors="replace") as handle:
            final = handle.read().strip()
    final = final or f"（{eng} 没有输出任何文本 —— 视为失败）"
    print(final[:TRUNC] + ("…(截断)" if len(final) > TRUNC else ""))

    if state["notices"]:
        print("\n--- 运行提示 ---")
        for message in state["notices"]:
            print(f"  {message}")

    if stderr_path and os.path.exists(stderr_path) and os.path.getsize(stderr_path) > 0:
        with open(stderr_path, encoding="utf-8", errors="replace") as handle:
            tail = handle.read()[-800:].strip()
        noisy = [line for line in tail.splitlines()
                 if line.strip() and "Shell cwd was reset" not in line
                 and "Reading additional input from stdin" not in line]
        if noisy:
            print("\n--- stderr ---")
            print("\n".join(noisy))
    return 0


def tail(log_path: str, count: int = 20) -> int:
    """人读的进度视图：最近 N 个 item 级事件。跑到一半随时可看。"""
    events = load(log_path)
    rows = []
    for event in events:
        foreman = event.get("_fleet")
        if foreman in ("question", "approval", "interrupt", "protocol_error", "steer", "steer_error", "steer_requeued"):
            rows.append(f"[{foreman}] {stringify({k: v for k, v in event.items() if k != '_fleet'}, 200)}")
            continue
        if foreman or not event.get("method"):
            continue
        method = event["method"]
        params = event.get("params") or {}
        if method == "item/completed":
            item = params.get("item") or {}
            itype = item.get("type")
            if itype == "commandExecution":
                rows.append(f"$ {stringify(item.get('command'), 160)}  → exit {item.get('exitCode')} {item.get('status', '')}")
            elif itype == "fileChange":
                rows.append("✎ " + ", ".join(f"{_kind_of(c.get('kind'))} {c.get('path')}" for c in (item.get("changes") or [])[:6]))
            elif itype == "agentMessage":
                rows.append(f"💬 {stringify(item.get('text'), 240)}")
            elif itype == "reasoning":
                summary = " ".join(item.get("summary") or [])
                if summary:
                    rows.append(f"… {stringify(summary, 160)}")
            elif itype == "webSearch":
                rows.append(f"🔎 {stringify(item.get('query'), 120)}")
            else:
                rows.append(f"[{itype}]")
        elif method == "item/autoApprovalReview/completed":
            r = params.get("review") or {}; a = params.get("action") or {}
            rows.append(f"[自动审查 {r.get('status')} risk={r.get('riskLevel')}] {stringify(a.get('command') or a.get('type'), 140)}")
        elif method in ("turn/started", "turn/completed", "thread/status/changed", "error"):
            rows.append(f"[{method}] {stringify(params.get('turn', {}).get('status') if method == 'turn/completed' else params, 160)}")
    for row in rows[-count:]:
        print(row)
    if not rows:
        print("（还没有 item 级事件）")
    return 0


def listing(issues_home: str) -> int:
    rows = []
    for name in sorted(os.listdir(issues_home)):
        issue_dir = os.path.join(issues_home, name)
        meta_path = os.path.join(issue_dir, "meta.json")
        if not os.path.isfile(meta_path):
            continue
        meta = json.load(open(meta_path, encoding="utf-8"))
        runs = sorted(f for f in os.listdir(issue_dir) if re.fullmatch(r"run-\d+\.jsonl", f))
        cost = 0.0
        cx_tokens = 0
        engines = []
        last = "—"
        for run in runs:
            events = load(os.path.join(issue_dir, run))
            if not events:
                engines.append("?")
                last = "RUNNING?"
                continue
            state = scan(events)
            if state["engine"] in ("codex", "appserver"):
                cx_tokens += state["tokens"]
            else:
                cost += state["cost"]
            engines.append({"codex": "c", "appserver": "a", "pi": "p"}.get(state["engine"], "?"))
            last = "ok" if state["settled"] and not state["errors"] else "CHECK"
        spend = f"${cost:.3f}" if cost else ""
        if cx_tokens:
            spend += (" +" if spend else "") + f"{cx_tokens // 1000}k tok"
        rows.append((name, meta.get("branch", "?"), meta.get("gh_issue", "—"), "".join(engines) or "—",
                     spend or "—", last, "有" if os.path.isdir(meta.get("worktree", "")) else "已清理"))
    if not rows:
        print("（没有登记的 issue）")
        return 0
    header = ("issue", "branch", "gh", "runs(a/c/p)", "spend", "last", "worktree")
    widths = [max(len(str(r[i])) for r in ([header] + rows)) for i in range(len(header))]
    line = lambda r: "  ".join(str(r[i]).ljust(widths[i]) for i in range(len(header)))
    print(line(header))
    print("  ".join("-" * w for w in widths))
    for row in rows:
        print(line(row))
    print("\nruns 列: a=codex app-server, c=codex exec(旧), p=pi（按轮次顺序）")
    print("codex 走 ChatGPT 订阅额度，没有美元成本，只计 token。")
    return 0


if __name__ == "__main__":
    argv = sys.argv[1:]
    engine = None
    role = None
    for flag in ("--engine", "--role"):
        if flag in argv:
            i = argv.index(flag)
            value = argv[i + 1]
            del argv[i:i + 2]
            if flag == "--engine":
                engine = value
            else:
                role = value
    if len(argv) >= 2 and argv[0] == "--list":
        sys.exit(listing(argv[1]))
    if len(argv) >= 2 and argv[0] == "--thread":
        print(scan(load(argv[1]), engine)["id"] or "")
        sys.exit(0)
    if len(argv) >= 2 and argv[0] == "--final":
        print(scan(load(argv[1]), engine)["final"])
        sys.exit(0)
    if len(argv) >= 2 and argv[0] == "--tail":
        sys.exit(tail(argv[1], int(argv[2]) if len(argv) > 2 else 20))
    if not argv:
        print(
            "用法: summarize.py [--engine appserver|codex|pi] [--role closeout] <run.jsonl> [run.stderr] [run.last.md]\n"
            "      summarize.py --list <issues-dir>\n"
            "      summarize.py --thread <run.jsonl>   # 取 thread_id\n"
            "      summarize.py --final <run.jsonl>    # 只吐交付报告\n"
            "      summarize.py --tail <run.jsonl> [N] # 最近 N 个 item 级事件",
            file=sys.stderr,
        )
        sys.exit(2)
    sys.exit(report(argv[0], argv[1] if len(argv) > 1 else None, argv[2] if len(argv) > 2 else None, engine, role))
