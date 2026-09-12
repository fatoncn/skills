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
    """Append one Claude stdout record without JSON re-serialization."""
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
    """Split shell control operators and discard redirection targets for policy checks."""
    segments = []
    for raw in re.split(r"&&|\|\||[;|\n]", command):
        segment = re.sub(r"(?:^|\s)\d*(?:>>?|<<?)\s*(?:'[^']*'|\"[^\"]*\"|\S+)", " ", raw).strip()
        if segment:
            segments.append(segment)
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
        for pattern, label in FORBIDDEN:
            if pattern.search(segment) and not (closeout and closeout_segment_allowed(segment)):
                return label
    return None


def closeout_command_allowed(command: str) -> bool:
    segments = command_segments(command)
    return bool(segments) and all(closeout_segment_allowed(segment) for segment in segments)


def permission_reply(stem: pathlib.Path, tool: str, tool_input: dict) -> dict:
    req = load_request(stem)
    log = pathlib.Path(req["jsonl_path"])
    digest = input_digest(tool_input)
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
    path = pathlib.Path.home() / ".claude.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        servers = data.get("mcpServers") or {}
        return servers if isinstance(servers, dict) else {}
    except (OSError, json.JSONDecodeError):
        return {}


def deny_rules(closeout: bool) -> list[str]:
    """Translate the shared FORBIDDEN table into Claude's pure-glob Bash rules.

    Claude 2.1.268 only treats a trailing ``:*`` as a prefix matcher; stars in
    that form are literals.  Every rule that needs an interior wildcard is
    therefore emitted in the pure ``*...*`` glob form.
    """
    by_label = {
        "git push": ["*git push*"],
        "git remote 写操作": ["*git remote add*", "*git remote set-url*", "*git remote remove*"],
        "gh 写操作": [
            *[f"*gh {kind} {action}*" for kind in ("issue", "pr")
              for action in ("create", "edit", "comment", "close", "merge", "reopen", "ready", "review")],
            *[f"*gh {kind}*" for kind in ("release", "workflow", "secret", "repo")],
        ],
        "gh api 写": [f"*gh api * {flag} {method}*" for flag in ("-X", "--method")
                      for method in ("POST", "PUT", "PATCH", "DELETE")],
        "gh api graphql": ["*gh api graphql*"],
        "vercel 写操作或 env": [f"*vercel {action}*" for action in
            ("deploy", "promote", "rollback", "redeploy", "alias", "env", "domains", "dns", "certs",
             "rm", "remove", "link", "project", "teams", "switch", "login", "logout", "git")],
        "vercel api 写": [f"*vercel api * {flag} {method}*" for flag in ("-X", "--method")
                          for method in ("POST", "PUT", "PATCH", "DELETE")],
        "supabase 远端": ["*supabase link*", "*supabase db push*", "*supabase db remote*"],
        "sst deploy": ["*npx sst*", "*npm sst*", "*sst deploy*"],
        "eslint-disable": ["*eslint-disable*"],
        "测试 skip/only": ["*.skip(*", "*.only(*"],
        "git 破坏性操作": ["*git reset --hard*", "*git clean -*f*", "*git checkout -- *", "*git stash*"],
        "git push --force": ["*git push *--force*", "*git push * -f*"],
        "git 底层改写（绕过索引/沙箱）": ["*GIT_INDEX_FILE=*", "*git update-ref*", "*git commit-tree*",
            "*git write-tree*", "*git symbolic-ref*", "*git --git-dir=*"],
    }
    rules = []
    for _pattern, label in FORBIDDEN:
        if label not in by_label:
            raise ValueError(f"FORBIDDEN 缺少 Claude deny 映射: {label}")
        rules.extend(by_label[label])
    if closeout:
        allowed_exact = {
            "*git push*", "*gh pr edit*", "*gh pr comment*", "*gh pr ready*", "*gh pr review*",
            "*gh api graphql*",
            *[f"*gh api * {flag} {method}*" for flag in ("-X", "--method") for method in ("POST", "PATCH")],
        }
        rules = [rule for rule in rules if rule not in allowed_exact]
    return list(dict.fromkeys(f"Bash({rule})" for rule in rules))


def common_gitdir(work_dir: str) -> str:
    if not work_dir:
        return ""
    try:
        return subprocess.run(["git", "-C", work_dir, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                              capture_output=True, text=True, check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
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
    stderr_fh = None
    hard_stop_started = False
    finished = threading.Event()
    grace = float(os.environ.get("FOREMAN_CLAUDE_INTERRUPT_GRACE", INTERRUPT_GRACE)) \
        if os.environ.get("FOREMAN_SELFTEST") == "1" else INTERRUPT_GRACE

    def kill_group(sig: int) -> None:
        if proc is None:
            return
        try:
            os.killpg(proc.pid, sig)
        except ProcessLookupError:
            pass

    def hard_stop_after_grace() -> None:
        if not finished.wait(grace):
            kill_group(signal.SIGKILL)

    def request_stop(mark_interrupted: bool) -> None:
        nonlocal interrupted, hard_stop_started
        interrupted = interrupted or mark_interrupted
        kill_group(signal.SIGTERM)
        if not hard_stop_started:
            hard_stop_started = True
            threading.Thread(target=hard_stop_after_grace, daemon=True).start()

    def on_term(_sig, _frame):
        request_stop(True)

    # Install before creating any per-run file so startup-stage TERM follows the same cleanup path.
    old_term = signal.signal(signal.SIGTERM, on_term)
    try:
        jsonl.write_text("", encoding="utf-8")
        raw_full = req.get("user_explicitly_approved_full_access")
        reason = str(req.get("full_access_reason") or "")
        invalid_full = not isinstance(raw_full, bool) or (raw_full is True and not reason.strip())
        full = raw_full is True and bool(reason.strip())
        permission_mode = "bypassPermissions" if full else "auto"
        work_dir = str(req.get("work_dir") or "")
        roots = unique_paths([work_dir, *(req.get("writable_roots") or []), common_gitdir(work_dir)])
        started = now_iso()
        claude = resolve_claude()
        try:
            version = subprocess.run([claude, "--version"], capture_output=True, text=True, timeout=10).stdout.strip() if claude else "unknown"
        except Exception:
            version = "unknown"
        version = version or "unknown"
        foreman_event(jsonl, {"engine": "claude", "cli_version": version, "session_id": req.get("session_id"),
                               "role": req.get("role"), "model": req.get("model"), "effort": req.get("effort"),
                               "permission_mode": permission_mode, "cwd": req.get("cwd"),
                               "work_dir": work_dir or None, "writable_roots": roots, "started_at": started})
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
        settings = {"sandbox": {"enabled": not full, "failIfUnavailable": True, "autoAllowBashIfSandboxed": False,
                                 "allowUnsandboxedCommands": False, "allowWrite": roots},
                    "permissions": {"deny": deny_rules(bool(req.get("closeout"))), "ask": ["AskUserQuestion"]}}
        write_json(settings_path, settings)
        servers = user_mcp_servers()
        if not full:
            servers["foreman"] = {"type": "stdio", "command": sys.executable,
                                  "args": [str(SCRIPT), "permission-server", "--run", str(stem)]}
        write_private_json(mcp_path, {"mcpServers": servers})
        dev = pathlib.Path(req["dev_instructions_path"]).read_text(encoding="utf-8")
        facts = ("\n\n---\n\n# Claude 引擎事实\n\n"
                 "- Bash 沙箱只约束 Bash 启动的子进程；本轮 cwd 内的可写范围仍以任务书为准。\n"
                 f"- Claude settings 放开的写路径：{', '.join(roots) or '无'}。\n"
                 "- 用户级 MCP 从 ~/.claude.json 的 mcpServers 内存读取后写入本轮 MCP 配置；foreman MCP 只处理权限与提问。\n"
                 "- 需要澄清时只用 AskUserQuestion，并等待回答；不要自行启动 claude 或 codex 子进程。\n")
        system_path.write_text(dev + facts, encoding="utf-8")
        if not full:
            ok, why = preflight_permission(stem)
            if not ok:
                final_rc, subtype, terminal_reason = 4, "engine_down", why
                raise RuntimeError(terminal_reason)

        argv = [claude, "-p", "--output-format", "stream-json", "--verbose", "--input-format", "text",
                "--model", model, "--effort", effort, "--permission-mode", permission_mode,
                "--setting-sources", "", "--settings", str(settings_path), "--strict-mcp-config",
                "--mcp-config", str(mcp_path)]
        if not full:
            argv += ["--permission-prompt-tool", "mcp__foreman__approve"]
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

        stderr_fh = stderr_path.open("wb")
        try:
            proc = subprocess.Popen(argv, cwd=req["cwd"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                    stderr=stderr_fh, start_new_session=True, bufsize=0)
        except OSError as exc:
            final_rc, subtype, terminal_reason = 3, "launch_error", f"Claude 启动失败: {exc}"
            raise RuntimeError(terminal_reason)
        if interrupted:
            request_stop(True)
        assert proc.stdin and proc.stdout
        protocol_failed = False
        try:
            proc.stdin.write(pathlib.Path(req["prompt_path"]).read_bytes())
            proc.stdin.close()
        except BrokenPipeError:
            terminal_reason = "Claude stdin BrokenPipe"
            protocol_failed = True
            foreman_event(jsonl, {"type": "protocol_error", "reason": terminal_reason})
            request_stop(False)
        for raw in proc.stdout:
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
                    else:
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
    args = parser.parse_args()
    if args.command == "permission-server":
        return serve_permission(pathlib.Path(args.run))
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
