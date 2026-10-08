#!/usr/bin/env python3
"""主动读取详情：正文、工具关联、范围和输出预算。无需启动执行器。"""
import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import summarize


def item(kind, **fields):
    return {"method": "item/completed", "params": {"item": {"type": kind, **fields}}}


class TailDetails(unittest.TestCase):
    def render(self, events, **options):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "run.jsonl"
            path.write_text("\n".join(json.dumps(e) for e in events) + '\n{"partial":')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                summarize.tail(str(path), **options)
            return output.getvalue()

    def test_default_stays_compact_and_details_include_output(self):
        text = "x" * 250 + "plan-end"
        events = [item("agentMessage", text=text),
                  item("commandExecution", id="cmd1", command="pytest", exitCode=1,
                       aggregatedOutput="failure-details"),
                  item("mcpToolCall", id="mcp1", server="db", tool="query",
                       arguments={"limit": 3}, result={"content": "query-result"})]
        compact = self.render(events)
        self.assertNotIn("plan-end", compact)
        self.assertNotIn("failure-details", compact)
        self.assertIn("[mcpToolCall]", compact)
        full = self.render(events, verbose=True)
        for value in (text, "cmd1", "failure-details", "mcp1", "limit", "query-result"):
            self.assertIn(value, full)

    def test_claude_pairs_tools_and_omits_thinking(self):
        events = [{"_foreman": {"engine": "claude"}},
                  {"type": "assistant", "message": {"content": [
                      {"type": "text", "text": "plan-text"},
                      {"type": "thinking", "thinking": "hidden-thinking"},
                      {"type": "tool_use", "id": "call-9", "name": "Bash", "input": {"command": "ls"}}]}},
                  {"type": "user", "message": {"content": [
                      {"type": "tool_result", "tool_use_id": "call-9", "content": "result-body"}]}}]
        full = self.render(events, verbose=True)
        self.assertIn("plan-text", full)
        self.assertEqual(full.count("call-9"), 2)
        self.assertIn("result-body", full)
        self.assertNotIn("hidden-thinking", full)

    def test_page_budget_and_incomplete_event(self):
        events = [item("agentMessage", text=f"text-{n}") for n in range(6)]
        for verbose in (False, True):
            page = self.render(events, count=2, skip=2, verbose=verbose)
            self.assertIn("text-2", page)
            self.assertIn("text-3", page)
            self.assertNotIn("text-1", page)
            self.assertNotIn("text-4", page)
        capped = self.render(events, verbose=True, max_chars=50)
        self.assertIn("字符上限", capped)
        self.assertLess(len(capped), 150)
        self.assertIn("没有详情记录", self.render(events, verbose=True, skip=99))

    def test_active_command_and_pi(self):
        event = {"method": "item/started", "params": {"item": {
            "type": "commandExecution", "id": "active", "command": "sleep 100"}}}
        self.assertIn("未提供输出正文", self.render([event], verbose=True))
        events = [{"type": "message_end", "message": {"role": "assistant", "content": [
            {"type": "text", "text": "pi-plan"}]}},
            {"type": "tool_execution_end", "toolCallId": "pi-call", "result": "pi-result"}]
        self.assertIn("pi-result", self.render(events, verbose=True))


if __name__ == "__main__":
    unittest.main()
