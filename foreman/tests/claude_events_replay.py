#!/usr/bin/env python3
"""Claude 事件摘要契约回放测试。"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import pathlib
import re
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
        if engine == "appserver":
            report = capture(summarize.report, str(path), None)
            check("golden appserver 长提问不二次截断", "…(+100)" in report and "…(+7)" not in report)
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
    check("工具与文件归并", state["tool_calls"] == 2
          and state["files"] == [("Write", "/workspace/project/worktree/result.txt")])
    check("首行目录契约进入 state", state["cwd"] == "/workspace/project"
          and state["work_dir"] == "/workspace/project/worktree"
          and state["writable_roots"] == ["/workspace/project/shared"])
    check("成功 final 与 meta", state["final"] == "success final" and state["cost_basis"] == "estimate"
          and state["claude_meta"]["turn_summary"]["cost_basis"] == "estimate")
    rows = summarize.event_rows(success_events)
    check("tail 文本/工具/结果行", any("💬 success final" in row for row in rows)
          and any("tool_use Write" in row for row in rows) and any("tool_result ok" in row for row in rows)
          and any(row.startswith("[result]") for row in rows))

    real_events = load("real-run.jsonl")
    real = summarize.scan(real_events)
    check("真实 CLI 流字段齐全且可解析", real["id"] == "session-real"
          and real["model"] == "claude-sonnet-5" and real["effort"] == "low" and real["settled"]
          and real["turns"] == 1 and real["tool_calls"] == 3 and real["tokens"] > 0
          and real["files"] == [("Edit", "/workspace/project/README.md")]
          and "## STATUS\nDONE" in real["final"] and not real["tool_errors"])
    def string_values(value):
        if isinstance(value, str):
            yield value
        elif isinstance(value, dict):
            for item in value.values():
                yield from string_values(item)
        elif isinstance(value, list):
            for item in value:
                yield from string_values(item)
    local_paths = [value for value in string_values(real_events)
                   if re.match(r"^/(?:tmp|var|private|Users)/", value)]
    check("真实 fixture 无本机临时绝对路径", not local_paths)

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
    check("真实多片段 stream 与完整 assistant 按 message id 去重", stream["final"] == "SECOND_FINAL"
          and stream["final"].count("SECOND_FINAL") == 1 and stream["tokens"] == 26752)

    questions = summarize.scan(load("questions.jsonl"))["questions"]
    check("提问 asked/answered/timeout", questions == [
        {"qid": "qid-answered", "state": "asked"}, {"qid": "qid-answered", "state": "answered"},
        {"qid": "qid-timeout", "state": "asked"}, {"qid": "qid-timeout", "state": "timeout"}])

    permissions = summarize.scan(load("permissions.jsonl"))["permissions"]
    check("权限 allow/ask/deny", [item[0] for item in permissions] == ["allow", "ask", "deny"])

    interrupted = summarize.scan(load("rc143.jsonl"))
    interrupted_report = capture(summarize.report, str(CLAUDE / "rc143.jsonl"), None)
    check("真实多片段中断只靠 stream 仍保留 final", interrupted["final"] == "SECOND_FINAL"
          and not interrupted["settled"] and "raw_rc=143" in interrupted_report)

    notebook = summarize.scan(load("notebook_edit.jsonl"))
    check("NotebookEdit 使用 notebook_path", notebook["files"]
          == [("NotebookEdit", "/workspace/project/worktree/analysis.ipynb")])

    outside_report = capture(summarize.report, str(CLAUDE / "outside_write.jsonl"), None)
    check("Claude Write 到 work_dir 外触发目录探针", "工作目录之外的改动" in outside_report
          and "/workspace/project/outside.txt" in outside_report)

    missing_marker_fields = json.loads(json.dumps(success_events))
    for key in ("cwd", "work_dir", "writable_roots"):
        missing_marker_fields[0]["_foreman"].pop(key)
    missing = summarize.scan(missing_marker_fields)
    check("首行目录字段缺失保持 None/空列表", missing["cwd"] is None and missing["work_dir"] is None
          and missing["writable_roots"] == [])

    bypass_report = capture(summarize.report, str(CLAUDE / "bypass.jsonl"), None)
    check("bypass !FULL 横幅", "!FULL ⚠ 本轮使用完全权限（无沙箱、无审批）" in bypass_report
          and "permission_mode=bypassPermissions" in bypass_report)

    review_events = json.loads(json.dumps(success_events))
    review_events[0]["_foreman"]["role"] = "review"
    review_events[0]["_foreman"]["review_readonly"] = "tools_only"
    with tempfile.TemporaryDirectory() as tmp:
        review_log = pathlib.Path(tmp) / "review.jsonl"
        review_log.write_text("\n".join(json.dumps(event, ensure_ascii=False) for event in review_events) + "\n")
        review_report = capture(summarize.report, str(review_log), None)
    check("Claude 复审横幅展示 tools_only", "review_readonly=tools_only" in review_report)

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
        marker_started = summarize._claude_started_at(success_events)
        assert marker_started is not None
        log.with_suffix(".started").write_text(str(marker_started - 10))
        log.with_suffix(".timeout").write_text("3600")
        progress_state = pathlib.Path(tmp) / "progress.state"
        assert summarize.progress(str(log), str(progress_state), "claude run", "RUNNING", 300,
                                  marker_started) == []
        initial_state = json.loads(progress_state.read_text())
        output = summarize.progress(str(log), str(progress_state), "claude run", "DONE", 300,
                                    marker_started + 301)
        check("Claude progress 用 started_at 计算预算", initial_state["execution_started_at"] == marker_started
              and len(output) == 1 and "tokens 19" in output[0] and "距 run --timeout 54m59s" in output[0]
              and "排队中" not in output[0] and "最后：[turn_summary]" in output[0])

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
