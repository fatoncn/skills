#!/usr/bin/env python3
"""Claude Code 非交互桥与 foreman 权限 MCP。

每轮运行一个 ``claude -p`` 进程；事件原样写入 jsonl，并在首尾补 foreman
账本事件。权限 MCP 既是 Claude ``auto`` 权限模式的回调，也是 AskUserQuestion
与 ``foreman questions / answer`` 文件族之间的桥。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone

SCRIPT = pathlib.Path(__file__).resolve()
sys.path.insert(0, str(SCRIPT.parent))
from summarize import FORBIDDEN  # noqa: E402

STDOUT_DRAIN_TIMEOUT = 5.0  # protocol_error 后仍要把 stdout 读到 EOF 才落盘；这个硬超时只防子进程真挂住不退出

DEFAULT_CANNED_ANSWER = (
    "编排者当前不在线，无法实时回答。请按你最合理的理解把能做的部分做完，"
    "不要在关键取舍上猜着做；把这个问题原文写进交付报告的「需要澄清」一节，"
    "STATUS 按实际情况用 PARTIAL 或 BLOCKED。"
)
INTERRUPT_GRACE = 20
QUESTION_POLL = 0.2
MODEL_ALIASES = {"sonnet", "fable", "opus", "best", "haiku"}
EFFORTS = {"low", "medium", "high", "xhigh", "max"}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def write_json(path: pathlib.Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(value, fh, ensure_ascii=False, indent=2)
            fh.write("\n")
        os.replace(tmp, path)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def write_private_json(path: pathlib.Path, value: object) -> None:
    """写可能含凭证的本轮文件；即使目标原先存在也收紧为 0600。"""
    write_json(path, value)
    os.chmod(path, 0o600)


def append_event(path: pathlib.Path, event: dict) -> None:
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n")


def append_raw(path: pathlib.Path, raw: bytes) -> None:
    """不重新序列化 JSON，原样追加一条 Claude stdout 记录。"""
    with path.open("ab") as fh:
        fh.write(raw)


def foreman_event(path: pathlib.Path, payload: dict) -> None:
    append_event(path, {"_foreman": payload})


def load_request(stem: pathlib.Path) -> dict:
    path = pathlib.Path(str(stem) + ".request.json")
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def question_id(question: dict) -> str:
    payload = {"question": question.get("question") or question.get("text") or "", "options": question.get("options") or []}
    raw = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha1(raw.encode()).hexdigest()[:12]


def input_digest(tool_input: object) -> str:
    raw = json.dumps(tool_input, ensure_ascii=False, sort_keys=True, separators=(",", ":"), default=str)
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def command_for(tool: str, tool_input: dict) -> str:
    if tool == "Bash":
        return str(tool_input.get("command") or "")
    return ""


def command_segments(command: str) -> list[str]:
    """按 shell 控制操作符分段，并在权限检查前丢弃重定向目标。"""
    segments: list[str] = []
    current: list[str] = []
    quote = ""
    index = 0

    def finish() -> None:
        segment = "".join(current).strip()
        if segment:
            segments.append(segment)
        current.clear()

    while index < len(command):
        char = command[index]
        if quote:
            current.append(char)
            if char == "\\" and quote == '"' and index + 1 < len(command):
                index += 1
                current.append(command[index])
            elif char == quote:
                quote = ""
            index += 1
            continue
        if char in "'\"":
            quote = char
            current.append(char)
            index += 1
            continue
        if char == "\\" and index + 1 < len(command):
            current.extend((char, command[index + 1]))
            index += 2
            continue

        fd_redirect = re.match(r"\d*>&\d+", command[index:])
        file_redirect = re.match(r"(?:&>>?|\d*(?:>>|>|<<|<))", command[index:])
        redirect = fd_redirect or file_redirect
        if redirect:
            index += len(redirect.group(0))
            if fd_redirect:
                continue
            while index < len(command) and command[index] in " \t":
                index += 1
            target_quote = ""
            while index < len(command):
                target = command[index]
                if target_quote:
                    if target == "\\" and target_quote == '"' and index + 1 < len(command):
                        index += 2
                        continue
                    if target == target_quote:
                        target_quote = ""
                    index += 1
                    continue
                if target in "'\"":
                    target_quote = target
                    index += 1
                    continue
                if target == "\\" and index + 1 < len(command):
                    index += 2
                    continue
                if target.isspace() or target in ";|&":
                    break
                index += 1
            continue

        operator = next((item for item in ("&&", "||", "|&", ";", "|", "&", "\n")
                         if command.startswith(item, index)), None)
        if operator:
            finish()
            index += len(operator)
            continue
        current.append(char)
        index += 1
    finish()
    return segments


def closeout_segment_allowed(segment: str) -> bool:
    if re.fullmatch(r"git\s+push\b(?!.*(?:--force(?:-with-lease)?|-f\b)).*", segment):
        return True
    if re.fullmatch(r"gh\s+pr\s+(?:comment|ready|review|edit)\b.*", segment):
        return True
    if re.fullmatch(r"gh\s+api\s+graphql\b.*", segment):
        return True
    if (re.fullmatch(r"gh\s+api\b.*", segment)
            and re.search(r"(?:-X|--method)\s*(?:POST|PATCH)\b", segment)
            and re.search(r"(?:comments|reviews|pulls)", segment)):
        return True
    return False


def forbidden_reason(command: str, closeout: bool) -> str | None:
    for segment in command_segments(command):
        for label, pattern, _deny_globs in FORBIDDEN:
            if pattern.search(segment) and not (closeout and closeout_segment_allowed(segment)):
                return label
    return None


def closeout_command_allowed(command: str) -> bool:
    if re.search(r"\$\(|`|[<>]\(|[\r\n]", command):
        return False
    segments = command_segments(command)
    return bool(segments) and all(closeout_segment_allowed(segment) for segment in segments)


def permission_reply(stem: pathlib.Path, tool: str, tool_input: dict) -> dict:
    req = load_request(stem)
    log = pathlib.Path(req["jsonl_path"])
    digest = input_digest(tool_input)
    bad_decision = os.environ.get("FOREMAN_CLAUDE_REPLAY_BAD_DECISION") \
        if os.environ.get("FOREMAN_SELFTEST") == "1" else None
    if bad_decision == "json":
        return "{invalid-json"
    if bad_decision == "nobehavior":
        return {"message": "missing behavior"}
    if req.get("review_readonly") == "tools_only":
        reason = "Claude 复审权限 MCP 一律拒绝升级；只使用 Read / Glob / Grep"
        foreman_event(log, {"type": "permission", "tool": tool, "decision": "deny", "reason": reason,
                            "input_digest": digest})
        return {"behavior": "deny", "message": reason}
    command = command_for(tool, tool_input)
    reason = forbidden_reason(command, bool(req.get("closeout"))) if command else None
    if reason:
        foreman_event(log, {"type": "permission", "tool": tool, "decision": "deny", "reason": reason, "input_digest": digest})
        return {"behavior": "deny", "message": f"foreman 禁止此操作：{reason}"}
    if command and bool(req.get("closeout")) and closeout_command_allowed(command):
        foreman_event(log, {"type": "permission", "tool": tool, "decision": "allow", "reason": "收尾阶段白名单", "input_digest": digest})
        return {"behavior": "allow", "updatedInput": tool_input}

    if tool == "AskUserQuestion":
        questions = tool_input.get("questions") or []
        normalized = []
        for q in questions:
            item = dict(q)
            item["id"] = question_id(item)
            normalized.append(item)
        qpath = pathlib.Path(req["questions_path"])
        apath = pathlib.Path(req["answer_path"])
        timeout = int(req.get("question_timeout") or 0)
        record = {"askedAt": int(time.time() * 1000), "itemId": None, "isBlocking": True,
                  "questions": normalized, "timeoutSeconds": timeout}
        write_json(qpath, record)
        for q in normalized:
            foreman_event(log, {"type": "question", "qid": q["id"], "state": "asked"})
        answers: dict[str, str] = {}
        answered = False
        deadline = time.monotonic() + timeout
        while timeout > 0 and time.monotonic() < deadline:
            if apath.exists():
                try:
                    given = json.loads(apath.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    given = {}
                by_id = given.get("answers") if isinstance(given, dict) else None
                for q in normalized:
                    value = (by_id or {}).get(q["id"]) if isinstance(by_id, dict) else None
                    if value is None and isinstance(given, dict) and "all" in given:
                        value = given["all"]
                    if isinstance(value, list):
                        value = ", ".join(map(str, value))
                    if value is not None:
                        answers[q.get("question") or q.get("text") or ""] = str(value)
                answered = bool(answers)
                try:
                    os.replace(apath, pathlib.Path(str(apath) + ".answered"))
                except OSError:
                    pass
                break
            time.sleep(QUESTION_POLL)
        if not answered:
            answers = {q.get("question") or q.get("text") or "": DEFAULT_CANNED_ANSWER for q in normalized}
        state = "answered" if answered else "timeout"
        for q in normalized:
            foreman_event(log, {"type": "question", "qid": q["id"], "state": state})
        try:
            os.replace(qpath, pathlib.Path(str(qpath).replace(".questions.json", ".questions.answered.json")))
        except OSError:
            pass
        foreman_event(log, {"type": "permission", "tool": tool, "decision": "allow", "reason": state, "input_digest": digest})
        updated = dict(tool_input)
        updated["questions"] = questions
        updated["answers"] = answers
        return {"behavior": "allow", "updatedInput": updated}

    reason = "foreman 自动审查未放行：按任务书范围继续，或用 AskUserQuestion 提问"
    foreman_event(log, {"type": "permission", "tool": tool, "decision": "deny", "reason": reason, "input_digest": digest})
    return {"behavior": "deny", "message": reason}


def rpc_response(rid: object, result: object = None, error: dict | None = None) -> dict:
    value = {"jsonrpc": "2.0", "id": rid}
    if error is not None:
        value["error"] = error
    else:
        value["result"] = result
    return value


def serve_permission(stem: pathlib.Path) -> int:
    for raw in sys.stdin:
        rid = None
        try:
            msg = json.loads(raw)
            method, rid = msg.get("method"), msg.get("id")
            if method == "initialize":
                out = rpc_response(rid, {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                                         "serverInfo": {"name": "foreman", "version": "1.5.0"}})
            elif method == "notifications/initialized":
                continue
            elif method == "tools/list":
                out = rpc_response(rid, {"tools": [{"name": "approve", "description": "foreman 权限审查与提问桥",
                    "inputSchema": {"type": "object", "additionalProperties": True}}]})
            elif method == "tools/call":
                params = msg.get("params") or {}
                args = params.get("arguments") or {}
                tool = str(args.get("tool_name") or args.get("toolName") or args.get("name") or "")
                tool_input = args.get("input") or args.get("tool_input") or args.get("toolInput") or {}
                try:
                    decision = permission_reply(stem, tool, tool_input)
                    if not isinstance(decision, dict) or decision.get("behavior") not in {"allow", "deny"}:
                        raise ValueError("权限审查器返回非法 decision")
                except Exception as exc:
                    req = load_request(stem)
                    foreman_event(pathlib.Path(req["jsonl_path"]), {"type": "permission", "tool": tool,
                        "decision": "deny", "reason": f"权限审查器异常: {exc}", "input_digest": input_digest(tool_input)})
                    decision = {"behavior": "deny", "message": "foreman 权限审查器异常，已拒绝操作"}
                out = rpc_response(rid, {"content": [{"type": "text", "text": json.dumps(decision, ensure_ascii=False)}]})
            else:
                out = rpc_response(rid, error={"code": -32601, "message": f"不支持的方法: {method}"})
        except Exception as exc:
            out = rpc_response(rid, error={"code": -32603, "message": str(exc)})
        sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
        sys.stdout.flush()
    return 0


def preflight_permission(stem: pathlib.Path) -> tuple[bool, str]:
    proc = subprocess.Popen([sys.executable, str(SCRIPT), "permission-server", "--run", str(stem)],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert proc.stdin and proc.stdout
        for rid, method in ((1, "initialize"), (2, "tools/list")):
            proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": {}}) + "\n")
            proc.stdin.flush()
            ready, _, _ = select.select([proc.stdout], [], [], 5)
            if not ready:
                return False, f"权限 MCP {method} 超时"
            reply = json.loads(proc.stdout.readline())
            if reply.get("id") != rid or "error" in reply:
                return False, f"权限 MCP {method} 协议错误: {reply}"
        return True, ""
    except Exception as exc:
        return False, f"权限 MCP 不可用: {exc}"
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()


def user_mcp_servers() -> dict:
    override = os.environ.get("FOREMAN_CLAUDE_USER_CONFIG") \
        if os.environ.get("FOREMAN_SELFTEST") == "1" else None
    path = pathlib.Path(override) if override else pathlib.Path.home() / ".claude.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        servers = data.get("mcpServers") or {}
        return servers if isinstance(servers, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def build_settings(roots: list[str], *, full: bool = False, closeout: bool = False,
                   review_readonly: bool = False) -> dict:
    denied = deny_rules(closeout)
    if review_readonly:
        denied = ["Bash(*)", "Write(*)", "Edit(*)", "MultiEdit(*)", "NotebookEdit(*)", *denied]
    return {"sandbox": {"enabled": not full, "failIfUnavailable": True, "autoAllowBashIfSandboxed": False,
                         "allowUnsandboxedCommands": False, "allowWrite": roots},
            "permissions": {"deny": list(dict.fromkeys(denied)), "ask": ["AskUserQuestion"]}}


def write_doctor_config(output_dir: pathlib.Path, work_dir: str) -> int:
    output_dir.mkdir(parents=True, exist_ok=True)
    roots = unique_paths([work_dir, common_gitdir(work_dir)])
    write_json(output_dir / "settings.json", build_settings(roots))
    servers = {}
    for name, raw in user_mcp_servers().items():
        if not isinstance(raw, dict):
            continue
        server = {}
        for key in ("type", "command"):
            if key in raw:
                server[key] = raw[key]
        for key in ("env", "headers", "url"):
            if key in raw:
                value = raw[key]
                if isinstance(value, dict):
                    server[key] = {str(item): "<redacted>" for item in value}
                else:
                    server[key] = "<redacted>"
        servers[str(name)] = server
    servers["foreman"] = {"type": "stdio", "command": sys.executable,
                          "args": [str(SCRIPT), "permission-server", "--run", str(output_dir / "doctor")]}
    write_private_json(output_dir / "mcp.json", {"mcpServers": servers})
    print(json.dumps({"settings": str(output_dir / "settings.json"), "mcp": str(output_dir / "mcp.json"),
                      "mcp_servers": sorted(servers)}, ensure_ascii=False))
    return 0


def deny_rules(closeout: bool) -> list[str]:
    """把共享 FORBIDDEN 表转成 Claude 的纯 glob Bash 规则。

    Claude 2.1.268 只把结尾 ``:*`` 当前缀匹配，其中的星号是字面量；
    因此需要中间通配符的规则统一输出为纯 ``*...*`` glob。
    """
    rules = []
    for _label, _pattern, deny_globs in FORBIDDEN:
        rules.extend(deny_globs)
    if closeout:
        allowed_exact = {
            "*git *push*", "*gh pr edit*", "*gh pr comment*", "*gh pr ready*", "*gh pr review*",
            "*gh *api *graphql*",
            *[pattern for method in ("POST", "PATCH")
              for pattern in (f"*gh *api* -X*{method}*", f"*gh *api* -X {method}*",
                              f"*gh *api* --method*{method}*", f"*gh *api* --method {method}*")],
        }
        rules = [rule for rule in rules if rule not in allowed_exact]
    return list(dict.fromkeys(f"Bash({rule})" for rule in rules))


def common_gitdir(work_dir: str) -> str:
    if not work_dir:
        return ""
    try:
        return subprocess.run(["git", "-C", work_dir, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                              capture_output=True, text=True, check=True, timeout=10).stdout.strip()
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return ""


def unique_paths(values: list[str]) -> list[str]:
    out = []
    for value in values:
        if value and value not in out:
            out.append(value)
    return out


def resolve_claude() -> str:
    override = os.environ.get("CLAUDE_BIN") if os.environ.get("FOREMAN_SELFTEST") == "1" else None
    path = override or shutil.which("claude")
    return os.path.realpath(path) if path else ""


def write_argv(path: pathlib.Path, argv: list[str]) -> None:
    path.write_bytes(b"".join(os.fsencode(arg) + b"\0" for arg in argv))


def update_thread_ref(meta_path: pathlib.Path, thread: str, session_id: str) -> None:
    try:
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        meta = {}
    target = meta.setdefault("threads", {}).setdefault(thread, {})
    target["engine"] = "claude"
    target["ref"] = session_id
    write_json(meta_path, meta)


def classify_engine_down(text: str) -> bool:
    lowered = text.lower()
    return any(word in lowered for word in ("authentication", "not logged", "unauthorized", "model not found",
                                             "overloaded", "service unavailable", "rate limit", "permission mcp",
                                             "mcp tool mcp__foreman__approve", "permission-prompt-tool"))


def has_report_marker(text: str | None, marker: str) -> bool:
    return any(line.strip() == marker for line in (text or "").splitlines())


def run_bridge(request_path: pathlib.Path) -> int:
    req = json.loads(request_path.read_text(encoding="utf-8"))
    stem = pathlib.Path(str(request_path)[:-len(".request.json")])
    jsonl = pathlib.Path(req["jsonl_path"])
    mcp_path = pathlib.Path(str(stem) + ".mcp.json")
    stderr_path = pathlib.Path(req.get("stderr_path") or str(stem) + ".stderr")
    raw_rc = 0
    final_rc = 3
    subtype = "protocol_error"
    terminal_reason = ""
    result_event = None
    init_session = None
    interrupted = False
    proc: subprocess.Popen | None = None
    proc_lock = threading.Lock()
    stderr_fh = None
    hard_stop_started = False
    finished = threading.Event()
    grace = float(os.environ.get("FOREMAN_CLAUDE_INTERRUPT_GRACE", INTERRUPT_GRACE)) \
        if os.environ.get("FOREMAN_SELFTEST") == "1" else INTERRUPT_GRACE

    def kill_group(sig: int) -> None:
        with proc_lock:
            target = proc
            if target is not None:
                try:
                    os.killpg(target.pid, sig)
                except ProcessLookupError:
                    pass

    def hard_stop_after_grace() -> None:
        if not finished.wait(grace):
            kill_group(signal.SIGKILL)

    def request_stop(mark_interrupted: bool) -> None:
        nonlocal interrupted, hard_stop_started
        start_hard_stop = False
        with proc_lock:
            interrupted = interrupted or mark_interrupted
            target = proc
            if target is not None:
                try:
                    os.killpg(target.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            if not hard_stop_started:
                hard_stop_started = True
                start_hard_stop = True
        if start_hard_stop:
            threading.Thread(target=hard_stop_after_grace, daemon=True).start()

    def on_term(_sig, _frame):
        nonlocal interrupted, hard_stop_started
        if not proc_lock.acquire(blocking=False):
            # Python 信号处理器会在主线程重入；Popen 原子段持锁时只留标记，出锁立即终止。
            interrupted = True
            return
        start_hard_stop = False
        try:
            interrupted = True
            target = proc
            if target is not None:
                try:
                    os.killpg(target.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            if not hard_stop_started:
                hard_stop_started = True
                start_hard_stop = True
        finally:
            proc_lock.release()
        if start_hard_stop:
            threading.Thread(target=hard_stop_after_grace, daemon=True).start()

    # 在创建任何轮次文件前安装，让启动期 TERM 也走同一清理路径。
    old_term = signal.signal(signal.SIGTERM, on_term)
    try:
        jsonl.write_text("", encoding="utf-8")
        if os.environ.get("FOREMAN_SELFTEST") == "1":
            delay = float(os.environ.get("FOREMAN_CLAUDE_STARTUP_DELAY", "0"))
            if delay > 0:
                time.sleep(delay)
        if interrupted:
            raise InterruptedError("启动期收到终止信号")
        raw_full = req.get("user_explicitly_approved_full_access")
        reason = str(req.get("full_access_reason") or "")
        invalid_full = not isinstance(raw_full, bool) or (raw_full is True and not reason.strip())
        full = raw_full is True and bool(reason.strip())
        permission_mode = "bypassPermissions" if full else "auto"
        work_dir = str(req.get("work_dir") or "")
        roots = unique_paths([work_dir, *(req.get("writable_roots") or []), common_gitdir(work_dir)])
        if interrupted:
            raise InterruptedError("启动期收到终止信号")
        started = now_iso()
        claude = resolve_claude()
        try:
            version = subprocess.run([claude, "--version"], capture_output=True, text=True, timeout=10).stdout.strip() if claude else "unknown"
        except Exception:
            version = "unknown"
        version = version or "unknown"
        if interrupted:
            raise InterruptedError("启动期收到终止信号")
        review_readonly = req.get("review_readonly") if req.get("review_readonly") == "tools_only" else None
        foreman_event(jsonl, {"engine": "claude", "cli_version": version, "session_id": req.get("session_id"),
                               "role": req.get("role"), "model": req.get("model"), "effort": req.get("effort"),
                               "permission_mode": permission_mode, "cwd": req.get("cwd"),
                               "work_dir": work_dir or None, "writable_roots": roots,
                               "review_readonly": review_readonly, "started_at": started})
        if invalid_full:
            terminal_reason = "bypassPermissions 缺少严格布尔授权标记或非空原话"
            raise RuntimeError(terminal_reason)
        model, effort = str(req.get("model") or ""), str(req.get("effort") or "")
        if not (model in MODEL_ALIASES or model.startswith("claude-")) or effort not in EFFORTS:
            terminal_reason = "Claude model / effort 非法"
            raise RuntimeError(terminal_reason)
        if not claude:
            terminal_reason = "找不到 claude 可执行文件"
            raise RuntimeError(terminal_reason)
        settings_path = pathlib.Path(str(stem) + ".settings.json")
        system_path = pathlib.Path(str(stem) + ".system.md")
        settings = build_settings(roots, full=full, closeout=bool(req.get("closeout")),
                                  review_readonly=review_readonly == "tools_only")
        write_json(settings_path, settings)
        servers = user_mcp_servers() if req.get("inherit_user_mcp", True) else {}
        if not full:
            servers["foreman"] = {"type": "stdio", "command": sys.executable,
                                  "args": [str(SCRIPT), "permission-server", "--run", str(stem)]}
        write_private_json(mcp_path, {"mcpServers": servers})
        dev = pathlib.Path(req["dev_instructions_path"]).read_text(encoding="utf-8")
        mcp_fact = ("- 本轮不继承用户 MCP；只挂 foreman 权限 MCP，任何权限升级一律拒绝。\n"
                    if review_readonly == "tools_only" else
                    "- 用户级 MCP 从 ~/.claude.json 的 mcpServers 内存读取后写入本轮 MCP 配置；foreman MCP 只处理权限与提问。\n")
        question_fact = ("- 本轮没有提问工具；需要澄清时在最终报告说明。\n"
                         if review_readonly == "tools_only" else
                         "- 需要澄清时只用 AskUserQuestion，并等待回答；不要自行启动 claude 或 codex 子进程。\n")
        facts = ("\n\n---\n\n# Claude 引擎事实\n\n"
                 "- Bash 沙箱只约束 Bash 启动的子进程；本轮 cwd 内的可写范围仍以任务书为准。\n"
                 f"- Claude settings 放开的写路径：{', '.join(roots) or '无'}。\n"
                 + mcp_fact + question_fact
                 + "- 一轮一进程：这个 turn 结束就是本轮结束，没有下一轮。所有命令前台跑完再继续；不要 `run_in_background`，不要 ScheduleWakeup / Monitor / `sleep` 轮询去等；后台等待会让本轮在没交付的情况下结束。\n"
                 "- 沙箱内不装依赖，不跑会改写 `node_modules` 的包管理器命令（如 `pnpm install`）；依赖由编排者派活前备好，缺失就报 BLOCKED。\n"
                 "- `.idea` / `.vscode` 等 IDE 目录不可写。\n"
                 "- 环境跑不动（EPERM、mktemp 失败、命令被沙箱拒）就如实报 BLOCKED 并附原始报错；不调试沙箱、不绕沙箱。\n")
        system_path.write_text(dev + facts, encoding="utf-8")
        if not full:
            ok, why = preflight_permission(stem)
            if not ok:
                final_rc, subtype, terminal_reason = 4, "engine_down", why
                raise RuntimeError(terminal_reason)
        if interrupted:
            raise InterruptedError("启动期收到终止信号")

        argv = [claude, "-p", "--output-format", "stream-json", "--verbose", "--input-format", "text",
                "--model", model, "--effort", effort, "--permission-mode", permission_mode,
                "--setting-sources", "", "--settings", str(settings_path), "--strict-mcp-config",
                "--mcp-config", str(mcp_path)]
        if not full:
            argv += ["--permission-prompt-tool", "mcp__foreman__approve"]
        if req.get("tools"):
            argv += ["--tools", str(req["tools"])]
        argv += ["--append-system-prompt-file", str(system_path), "--max-turns", str(req.get("max_turns") or 80),
                 "--max-budget-usd", str(req.get("max_budget_usd") or 5)]
        if req.get("session_id"):
            argv += ["--resume", str(req["session_id"])]
        if req.get("no_session_persistence"):
            argv.append("--no-session-persistence")
        write_argv(pathlib.Path(str(stem) + ".argv"), argv)
        write_json(pathlib.Path(req["claude_json_path"]), {"model": model, "effort": effort,
            "permission_mode": permission_mode, "settings": str(settings_path), "mcp_servers": sorted(servers),
            "session_id": req.get("session_id"), "cli_version": version, "started_at": started})

        if (os.environ.get("FOREMAN_SELFTEST") == "1"
                and os.environ.get("FOREMAN_CLAUDE_STARTUP_DELAY_STAGE") == "pre_popen"):
            delay = float(os.environ.get("FOREMAN_CLAUDE_STARTUP_DELAY", "0"))
            if delay > 0:
                time.sleep(delay)
        stderr_fh = stderr_path.open("wb")
        try:
            with proc_lock:
                if interrupted:
                    raise InterruptedError("启动期收到终止信号")
                proc = subprocess.Popen(argv, cwd=req["cwd"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=stderr_fh, start_new_session=True, bufsize=0)
        except InterruptedError:
            raise
        except OSError as exc:
            final_rc, subtype, terminal_reason = 3, "launch_error", f"Claude 启动失败: {exc}"
            raise RuntimeError(terminal_reason)
        if interrupted:
            request_stop(True)
        assert proc.stdin and proc.stdout
        protocol_failed = False
        # protocol_error 之后仍显式把 stdout 排空到 EOF 再落盘：子进程可能紧跟着还有一行已经在管道里
        # 的输出（比如坏 JSON 后面那行），SIGTERM 是异步的，不能假设它一发出子进程就停止写入。
        # drain_deadline 只在判定失败之后启用（启动期 BrokenPipe 与循环里的坏 JSON 两处都要设），
        # 它只是「别再等下去了、提前收尾」，不是挂死的兜底：真正兜底的是 request_stop 拉起的
        # hard_stop_after_grace，宽限期一到 SIGKILL 整个进程组。select 也只保证有数据可读，
        # 子进程写了半行就不动的话 readline 照样阻塞，同样得等那记 SIGKILL 把管道关掉。
        drain_deadline = None
        try:
            proc.stdin.write(pathlib.Path(req["prompt_path"]).read_bytes())
            proc.stdin.close()
        except BrokenPipeError:
            terminal_reason = "Claude stdin BrokenPipe"
            protocol_failed = True
            foreman_event(jsonl, {"type": "protocol_error", "reason": terminal_reason})
            request_stop(False)
            drain_deadline = time.monotonic() + STDOUT_DRAIN_TIMEOUT
        while True:
            if drain_deadline is not None:
                remaining = drain_deadline - time.monotonic()
                if remaining <= 0:
                    foreman_event(jsonl, {"type": "protocol_error", "reason": "stdout 排空超时，提前收尾"})
                    break
                ready, _, _ = select.select([proc.stdout], [], [], remaining)
                if not ready:
                    continue
            raw = proc.stdout.readline()
            if not raw:
                break
            append_raw(jsonl, raw)
            if protocol_failed or not raw.strip():
                continue
            try:
                event = json.loads(raw)
                if not isinstance(event, dict):
                    raise ValueError("Claude stream-json 行不是 JSON 对象")
            except (json.JSONDecodeError, UnicodeDecodeError, ValueError) as exc:
                terminal_reason = f"Claude stream-json 协议错误: {exc}"
                protocol_failed = True
                foreman_event(jsonl, {"type": "protocol_error", "reason": terminal_reason})
                request_stop(False)
                drain_deadline = time.monotonic() + STDOUT_DRAIN_TIMEOUT
                continue
            if event.get("type") == "system" and event.get("subtype") == "init":
                init_session = event.get("session_id")
                if init_session:
                    expected = req.get("session_id")
                    if expected and init_session != expected:
                        terminal_reason = "resume 的 system.init.session_id 不一致"
                        protocol_failed = True
                        foreman_event(jsonl, {"type": "protocol_error", "reason": terminal_reason})
                        request_stop(False)
                    elif req.get("persist_session", True):
                        update_thread_ref(pathlib.Path(req["meta_path"]), str(req["thread"]), str(init_session))
            if event.get("type") == "result":
                result_event = event
        try:
            raw_rc = proc.wait(timeout=grace + 2 if hard_stop_started else 5)
        except subprocess.TimeoutExpired:
            kill_group(signal.SIGKILL)
            raw_rc = proc.wait()
        stderr_text = stderr_path.read_text(encoding="utf-8", errors="replace")
        if interrupted:
            final_rc, subtype, terminal_reason = 143, "interrupted", "收到超时或终止信号"
        elif protocol_failed or terminal_reason:
            final_rc, subtype = 3, "protocol_error"
        elif not init_session:
            if classify_engine_down(stderr_text):
                final_rc, subtype, terminal_reason = 4, "engine_down", stderr_text.strip()[-1000:]
            else:
                final_rc, subtype, terminal_reason = 3, "protocol_error", "未收到 system.init.session_id"
        elif result_event:
            if result_event.get("session_id") != init_session:
                final_rc, subtype, terminal_reason = 3, "protocol_error", "result.session_id 与 system.init 不一致"
            else:
                subtype = str(result_event.get("subtype") or "")
                if subtype == "success":
                    final_rc, terminal_reason = 0, "success"
                else:
                    combined = subtype + " " + str(result_event.get("result") or "") + " " + stderr_text
                    final_rc = 4 if classify_engine_down(combined) else 1
                    terminal_reason = subtype or "result error"
        elif classify_engine_down(stderr_text):
            final_rc, subtype, terminal_reason = 4, "engine_down", stderr_text.strip()[-1000:]
        else:
            final_rc, subtype, terminal_reason = 3, "protocol_error", "EOF 前未收到 result"
        marker = str(req.get("report_marker") or "").strip()
        final_text = (result_event or {}).get("result")
        if final_rc == 0 and marker and not has_report_marker(final_text if isinstance(final_text, str) else None, marker):
            final_rc, subtype, terminal_reason = 6, "no_report", f"最后一条消息缺 `{marker}`"
    except Exception as exc:
        if not terminal_reason:
            terminal_reason = f"Claude 桥异常: {exc}"
    finally:
        if proc is not None and proc.poll() is None:
            request_stop(interrupted)
            try:
                raw_rc = proc.wait(timeout=grace + 2)
            except subprocess.TimeoutExpired:
                kill_group(signal.SIGKILL)
                raw_rc = proc.wait()
        finished.set()
        signal.signal(signal.SIGTERM, old_term)
        if stderr_fh is not None:
            stderr_fh.close()
        if interrupted:
            final_rc, subtype, terminal_reason = 143, "interrupted", "收到超时或终止信号"
        final_text = (result_event or {}).get("result")
        if isinstance(final_text, str) and req.get("last_path"):
            pathlib.Path(req["last_path"]).write_text(final_text, encoding="utf-8")
        usage = (result_event or {}).get("usage") or {}
        cost = (result_event or {}).get("total_cost_usd")
        foreman_event(jsonl, {"type": "turn_summary", "rc": final_rc, "raw_rc": raw_rc, "subtype": subtype,
            "terminal_reason": terminal_reason, "session_id": init_session or req.get("session_id"), "usage": usage,
            "total_cost_usd": cost if isinstance(cost, (int, float)) else None, "cost_basis": "estimate", "ended_at": now_iso()})
        try:
            mcp_path.unlink()
        except FileNotFoundError:
            pass
        pathlib.Path(str(stem) + ".rc").write_text(str(final_rc), encoding="utf-8")
    return final_rc


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    run = sub.add_parser("run")
    run.add_argument("request")
    perm = sub.add_parser("permission-server")
    perm.add_argument("--run", required=True)
    doctor = sub.add_parser("doctor-config")
    doctor.add_argument("--output-dir", required=True)
    doctor.add_argument("--work-dir", required=True)
    args = parser.parse_args()
    if args.command == "permission-server":
        return serve_permission(pathlib.Path(args.run))
    if args.command == "doctor-config":
        return write_doctor_config(pathlib.Path(args.output_dir), args.work_dir)
    request_path = pathlib.Path(args.request)
    try:
        return run_bridge(request_path)
    finally:
        stem = pathlib.Path(str(request_path)[:-len(".request.json")])
        try:
            pathlib.Path(str(stem) + ".mcp.json").unlink()
        except FileNotFoundError:
            pass


if __name__ == "__main__":
    raise SystemExit(main())
