#!/usr/bin/env python3
"""Claude 事件摘要契约回放测试。"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import pathlib
import shutil
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import summarize  # noqa: E402

CLAUDE = ROOT / "tests" / "fixtures" / "claude"
GOLDEN = ROOT / "tests" / "fixtures" / "summary-golden"


def capture(call, *args):
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        call(*args)
    return out.getvalue()


def load(name):
    return summarize.load(str(CLAUDE / name))


def check(name, condition):
    if not condition:
        raise AssertionError(name)
    print(f"PASS {name}")


def golden_checks():
    for engine in ("appserver", "pi"):
        path = GOLDEN / f"{engine}.jsonl"
        check(f"golden {engine} report",
              capture(summarize.report, str(path), None) == (GOLDEN / f"{engine}.report.txt").read_text())
        rows = "".join(row + "\n" for row in summarize.event_rows(summarize.load(str(path))))
        check(f"golden {engine} event_rows", rows == (GOLDEN / f"{engine}.event_rows.txt").read_text())
        with tempfile.TemporaryDirectory() as tmp:
            started = 1789143211 if engine == "appserver" else 1000
            log = pathlib.Path(tmp) / "run.jsonl"
            shutil.copyfile(path, log)
            log.with_suffix(".started").write_text(str(started))
            log.with_suffix(".timeout").write_text("3600")
            state_path = pathlib.Path(tmp) / "progress.state"
            assert summarize.progress(str(log), str(state_path), f"{engine} golden", "RUNNING", 300, started) == []
            output = "".join(row + "\n" for row in summarize.progress(
                str(log), str(state_path), f"{engine} golden", "DONE", 300, started + 301))
            check(f"golden {engine} progress", output == (GOLDEN / f"{engine}.progress.txt").read_text())


def selftest():
    golden_checks()

    success_events = load("success.jsonl")
    state = summarize.scan(success_events)
    check("首行标记识别 claude", summarize.detect_engine(success_events) == "claude" and state["engine"] == "claude")
    check("成功流 session/model/turn/result", state["id"] == "session-success" and state["model"] == "claude-sonnet"
          and state["turns"] == 1 and state["settled"] and state["status"] == "success")
    check("result usage 与估算成本", (state["in_tokens"], state["cached_tokens"], state["out_tokens"], state["tokens"])
          == (10, 5, 4, 19) and state["cost"] == 0.0123)
    check("工具与文件归并", state["tool_calls"] == 2 and state["files"] == [("Write", "/workspace/result.txt")])
    check("成功 final 与 meta", state["final"] == "success final" and state["cost_basis"] == "estimate"
          and state["claude_meta"]["turn_summary"]["cost_basis"] == "estimate")
    rows = summarize.event_rows(success_events)
    check("tail 文本/工具/结果行", any("💬 success final" in row for row in rows)
          and any("tool_use Write" in row for row in rows) and any("tool_result ok" in row for row in rows)
          and any(row.startswith("[result]") for row in rows))

    deny = summarize.scan(load("deny_rc0.jsonl"))
    deny_report = capture(summarize.report, str(CLAUDE / "deny_rc0.jsonl"), None)
    check("deny 且 rc0 仍需人工判断", deny["settled"] and deny["permission_denials"] and deny["forbidden"]
          and "result.permission_denials 非空" in deny_report and "权限 MCP 的决定" in deny_report)

    eof_report = capture(summarize.report, str(CLAUDE / "eof_no_result.jsonl"), None)
    check("EOF 无 result 阻塞文案", not summarize.scan(load("eof_no_result.jsonl"))["settled"]
          and "没有 result：可能超时被杀、被中断或协议错误（raw_rc=2）" in eof_report)

    unknown = summarize.scan(load("unknown.jsonl"))
    check("未知/rate-limit/system api error", any("future_event: 2" in n for n in unknown["notices"])
          and any("rate_limit_event" in n for n in unknown["notices"])
          and len(unknown["errors"]) == 2)

    child = summarize.scan(load("child_agent.jsonl"))
    check("子 agent 不覆盖 final/不重复 token", child["final"] == "root final" and child["tokens"] == 7
          and child["tool_calls"] == 1)

    stream = summarize.scan(load("stream_dedupe.jsonl"))
    check("stream 与 assistant 按 UUID 去重", stream["final"] == "same final"
          and stream["final"].count("same final") == 1)

    questions = summarize.scan(load("questions.jsonl"))["questions"]
    check("提问 asked/answered/timeout", questions == [
        {"qid": "qid-answered", "state": "asked"}, {"qid": "qid-answered", "state": "answered"},
        {"qid": "qid-timeout", "state": "asked"}, {"qid": "qid-timeout", "state": "timeout"}])

    permissions = summarize.scan(load("permissions.jsonl"))["permissions"]
    check("权限 allow/ask/deny", [item[0] for item in permissions] == ["allow", "ask", "deny"])

    interrupted = summarize.scan(load("rc143.jsonl"))
    interrupted_report = capture(summarize.report, str(CLAUDE / "rc143.jsonl"), None)
    check("rc143 跨消息保留增量 partial 与 raw_rc", interrupted["final"] == "interrupted partial"
          and not interrupted["settled"] and "raw_rc=143" in interrupted_report)

    bypass_report = capture(summarize.report, str(CLAUDE / "bypass.jsonl"), None)
    check("bypass !FULL 横幅", "!FULL ⚠ 本轮使用完全权限（无沙箱、无审批）" in bypass_report
          and "permission_mode=bypassPermissions" in bypass_report)

    explicit = summarize.scan(success_events, "claude")
    not_first = [{"_fleet": "thread", "threadId": "old"}, success_events[0]]
    check("显式 --engine 与首行限定", explicit["engine"] == "claude"
          and summarize.detect_engine(not_first) == "appserver")

    synthetic = json.loads(json.dumps(success_events))
    synthetic[2]["message"]["content"][1]["input"]["command"] = "git push origin topic"
    check("Bash 越界探针", bool(summarize.scan(synthetic)["forbidden"])
          and not summarize.scan(synthetic, role="closeout")["forbidden"])
    synthetic[3]["message"]["content"][0]["is_error"] = True
    check("tool_result.is_error", bool(summarize.scan(synthetic)["tool_errors"]))

    with tempfile.TemporaryDirectory() as tmp:
        issue = pathlib.Path(tmp) / "ticket"
        issue.mkdir()
        (issue / "meta.json").write_text(json.dumps({"branch": "topic", "base": "main", "worktree": tmp}))
        shutil.copyfile(CLAUDE / "success.jsonl", issue / "run-1.jsonl")
        listing = capture(summarize.listing, tmp)
        check("listing claude 字符/成本/token", "runs(a/p/l)" in listing and " l " in listing
              and "$0.012" in listing and "claude tok" in listing)

    with tempfile.TemporaryDirectory() as tmp:
        log = pathlib.Path(tmp) / "run.jsonl"
        shutil.copyfile(CLAUDE / "success.jsonl", log)
        log.with_suffix(".started").write_text("1000")
        log.with_suffix(".timeout").write_text("3600")
        progress_state = pathlib.Path(tmp) / "progress.state"
        assert summarize.progress(str(log), str(progress_state), "claude run", "RUNNING", 300, 1000) == []
        output = summarize.progress(str(log), str(progress_state), "claude run", "DONE", 300, 1301)
        check("claude progress 共用状态契约", len(output) == 1 and "tokens 19" in output[0]
              and "最后：[turn_summary]" in output[0])

    with tempfile.TemporaryDirectory() as tmp:
        log = pathlib.Path(tmp) / "unmarked.jsonl"
        log.write_text("\n".join((CLAUDE / "success.jsonl").read_text().splitlines()[1:]) + "\n")
        log.with_suffix(".started").write_text("1000")
        log.with_suffix(".timeout").write_text("3600")
        state_path = pathlib.Path(tmp) / "explicit.state"
        assert summarize.progress(str(log), str(state_path), "explicit claude", "RUNNING", 300, 1000,
                                  engine="claude") == []
        output = summarize.progress(str(log), str(state_path), "explicit claude", "DONE", 300, 1301,
                                    engine="claude")
        check("--engine claude 贯穿 progress", len(output) == 1 and "tokens 19" in output[0])

    print("ALL PASS")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if not args.selftest:
        parser.error("只支持 --selftest")
    selftest()
