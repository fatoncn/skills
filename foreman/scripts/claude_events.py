#!/usr/bin/env python3
"""Claude Code stream-json 事件的纯函数解析。"""
from __future__ import annotations

import json


KNOWN_TYPES = {"system", "assistant", "user", "result", "stream_event", "rate_limit_event"}
FILE_TOOLS = {"Write", "Edit", "MultiEdit", "NotebookEdit"}


def _stringify(value, limit=600):
    if isinstance(value, str):
        out = value
    else:
        try:
            out = json.dumps(value, ensure_ascii=False)
        except Exception:
            out = repr(value)
    out = out.strip()
    return out if len(out) <= limit else out[:limit] + f"…(+{len(out) - limit})"


def _usage_int(usage, *keys):
    for key in keys:
        try:
            if usage.get(key) is not None:
                return int(usage[key])
        except (AttributeError, TypeError, ValueError):
            pass
    return 0


def _content(message):
    value = (message or {}).get("content") or []
    return value if isinstance(value, list) else []


def _message_id(event):
    message = event.get("message") or {}
    return event.get("uuid") or message.get("id")


def _stream_message_id(event):
    inner = event.get("event") or {}
    message = inner.get("message") or {}
    return event.get("uuid") or inner.get("message_id") or message.get("id")


def _turn_summary(event):
    marker = event.get("_foreman")
    return marker if isinstance(marker, dict) and marker.get("type") == "turn_summary" else None


def is_claude(events):
    """只认首个事件的 foreman Claude 声明。"""
    if not events:
        return False
    marker = events[0].get("_foreman")
    return isinstance(marker, dict) and marker.get("engine") == "claude"


def scan_claude(events, state, probe_forbidden, role=None):
    """把一个 Claude run 的事件归并进调用方提供的 blank_state。"""
    state["engine"] = "claude"
    marker = events[0].get("_foreman") if is_claude(events) else {}
    marker = marker if isinstance(marker, dict) else {}
    state["id"] = marker.get("session_id")
    state["model"] = marker.get("model")
    state["effort"] = marker.get("effort")
    state["permission_mode"] = marker.get("permission_mode")
    state["cost_basis"] = "estimate"
    state["claude_meta"] = {"marker": marker, "turn_summary": {}}
    role = role or marker.get("role")

    assistant_text = {}
    stream_text = {}
    final_order = []
    unknown = {}
    permission_denials = []
    current_stream_mid = None

    for event in events[1:] if is_claude(events) else events:
        fm = event.get("_foreman")
        if isinstance(fm, dict):
            kind = fm.get("type")
            if kind == "permission":
                state["permissions"].append((fm.get("decision") or "?", fm.get("tool") or "?",
                                             _stringify(fm.get("reason") or "", 240),
                                             fm.get("input_digest") or "—"))
            elif kind == "question":
                state["questions"].append({"qid": fm.get("qid") or "?", "state": fm.get("state") or "?"})
            elif kind == "turn_summary":
                state["claude_meta"]["turn_summary"] = fm
                state["status"] = fm.get("subtype") or state.get("status")
                state["duration_ms"] = fm.get("duration_ms") or state.get("duration_ms")
                state["permission_mode"] = fm.get("permission_mode") or state.get("permission_mode")
                state["id"] = fm.get("session_id") or state.get("id")
                state["cost_basis"] = fm.get("cost_basis") or state.get("cost_basis")
            continue

        kind = event.get("type")
        parent = event.get("parent_tool_use_id")
        if kind == "system":
            if event.get("subtype") == "init":
                state["id"] = event.get("session_id") or state["id"]
                state["model"] = event.get("model") or state["model"]
                state["permission_mode"] = event.get("permissionMode") or state["permission_mode"]
                if marker.get("session_id") and event.get("session_id") and marker["session_id"] != event["session_id"]:
                    state["errors"].append("system.init session_id 与 foreman 标记不一致")
            subtype = str(event.get("subtype") or "")
            if "api_error" in subtype or subtype == "error" or event.get("error"):
                state["errors"].append("system: " + _stringify(event.get("error") or event.get("message") or subtype, 800))
        elif kind == "assistant":
            message = event.get("message") or {}
            mid = _message_id(event) or f"assistant-{len(final_order)}"
            texts = []
            for block in _content(message):
                btype = block.get("type")
                if btype == "text" and block.get("text"):
                    texts.append(block["text"])
                elif btype == "tool_use":
                    state["tool_calls"] += 1
                    name = block.get("name") or "?"
                    args = block.get("input") or {}
                    if name == "Bash":
                        command = args.get("command") if isinstance(args, dict) else args
                        probe_forbidden(state, str(command or ""), _stringify(args, 300), role)
                    if name in FILE_TOOLS and isinstance(args, dict) and args.get("file_path"):
                        state["files"].append((name, args["file_path"]))
            if not parent and texts:
                assistant_text[mid] = "\n".join(texts).strip()
                final_order.append(mid)
            state["model"] = message.get("model") or state["model"]
        elif kind == "stream_event":
            inner = event.get("event") or {}
            if inner.get("type") == "message_start":
                current_stream_mid = (inner.get("message") or {}).get("id") or _stream_message_id(event)
                continue
            delta = inner.get("delta") or {}
            if not parent and inner.get("type") == "content_block_delta" and delta.get("type") == "text_delta":
                mid = _stream_message_id(event) or current_stream_mid or "stream"
                stream_text[mid] = stream_text.get(mid, "") + str(delta.get("text") or "")
                final_order.append(mid)
        elif kind == "user":
            for block in _content(event.get("message") or {}):
                if block.get("type") == "tool_result" and block.get("is_error"):
                    state["tool_errors"].append((block.get("tool_use_id") or "tool_result",
                                                 _stringify(block.get("content") or "(无错误正文)", 600)))
        elif kind == "result":
            state["turns"] += 1
            state["settled"] = True
            state["status"] = event.get("subtype") or state["status"]
            state["duration_ms"] = event.get("duration_ms") or state.get("duration_ms")
            state["id"] = event.get("session_id") or state["id"]
            usage = event.get("usage") or {}
            in_tokens = _usage_int(usage, "input_tokens", "inputTokens")
            out_tokens = _usage_int(usage, "output_tokens", "outputTokens")
            cached = (_usage_int(usage, "cache_read_input_tokens", "cacheReadInputTokens", "cached_input_tokens")
                      + _usage_int(usage, "cache_creation_input_tokens", "cacheCreationInputTokens"))
            state["in_tokens"] += in_tokens
            state["out_tokens"] += out_tokens
            state["cached_tokens"] += cached
            state["tokens"] += in_tokens + out_tokens + cached
            try:
                state["cost"] += float(event.get("total_cost_usd") or 0)
            except (TypeError, ValueError):
                state["notices"].append("result.total_cost_usd 不是数字")
            denials = event.get("permission_denials") or []
            permission_denials.extend(denials if isinstance(denials, list) else [denials])
            if event.get("subtype") != "success" or event.get("is_error"):
                state["errors"].append("result " + _stringify(event.get("subtype") or event.get("error") or "error", 800))
        elif kind == "rate_limit_event":
            state["notices"].append("rate_limit_event: " + _stringify(event.get("rate_limit_info") or event, 300))
        elif kind not in KNOWN_TYPES:
            label = str(kind or "(无 type)")
            unknown[label] = unknown.get(label, 0) + 1

    for name, count in sorted(unknown.items()):
        state["notices"].append(f"未知 Claude 事件类型 {name}: {count} 条")
    state["permission_denials"] = permission_denials
    for denial in permission_denials:
        state["tool_errors"].append(("permission_denial", _stringify(denial, 600)))

    for mid in reversed(final_order):
        body = assistant_text.get(mid)
        if body is None:
            body = stream_text.get(mid)
        if body:
            state["final"] = body.strip()
            break
    return state


def event_rows(events):
    """Claude tail 的一行事件摘要。"""
    rows = []
    for event in events:
        fm = event.get("_foreman")
        if isinstance(fm, dict):
            if fm.get("type") in ("permission", "question"):
                rows.append(f"[{fm.get('type')}] {_stringify({k: v for k, v in fm.items() if k != 'type'}, 200)}")
            elif fm.get("type") == "turn_summary":
                rows.append(f"[turn_summary] rc={fm.get('rc')} subtype={fm.get('subtype')} terminal={fm.get('terminal_reason') or '—'}")
            continue
        kind = event.get("type")
        if kind == "assistant":
            for block in _content(event.get("message") or {}):
                if block.get("type") == "text" and block.get("text"):
                    rows.append("💬 " + _stringify(block["text"], 240))
                elif block.get("type") == "tool_use":
                    rows.append(f"[tool_use {block.get('name') or '?'}] {_stringify(block.get('input') or {}, 200)}")
        elif kind == "user":
            for block in _content(event.get("message") or {}):
                if block.get("type") == "tool_result":
                    rows.append(f"[tool_result {'ERROR' if block.get('is_error') else 'ok'}] "
                                + _stringify(block.get("content") or "", 200))
        elif kind == "result":
            rows.append(f"[result] {event.get('subtype') or '?'} rc={'error' if event.get('is_error') else 'ok'} "
                        f"cost=${float(event.get('total_cost_usd') or 0):.4f}")
    return rows
