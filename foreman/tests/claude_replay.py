#!/usr/bin/env python3
"""Claude Code stream-json / 权限 MCP 回放夹具。

直接作为 ``CLAUDE_BIN`` 执行时扮演假 claude；``--selftest`` 则驱动真实桥覆盖
协议、权限、提问、resume、full-access 与信号归一化。
"""
from __future__ import annotations

import json
import os
import pathlib
import select
import signal
import subprocess
import sys
import tempfile
import threading
import time

HERE = pathlib.Path(__file__).resolve()
BRIDGE = HERE.parents[1] / "scripts" / "claude_code.py"


def arg_value(argv: list[str], flag: str, default: str = "") -> str:
    try:
        return argv[argv.index(flag) + 1]
    except (ValueError, IndexError):
        return default


class Rpc:
    def __init__(self, config: pathlib.Path):
        cfg = json.loads(config.read_text(encoding="utf-8"))["mcpServers"]["foreman"]
        self.proc = subprocess.Popen([cfg["command"], *cfg.get("args", [])], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.next_id = 1

    def call(self, method: str, params: dict) -> dict:
        rid = self.next_id
        self.next_id += 1
        assert self.proc.stdin and self.proc.stdout
        self.proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n")
        self.proc.stdin.flush()
        ready, _, _ = select.select([self.proc.stdout], [], [], 10)
        if not ready:
            raise RuntimeError(f"MCP {method} 超时")
        reply = json.loads(self.proc.stdout.readline())
        if reply.get("id") != rid or reply.get("error"):
            raise RuntimeError(f"MCP {method} 非法响应: {reply}")
        return reply["result"]

    def approve(self, tool: str, tool_input: dict) -> dict:
        result = self.call("tools/call", {"name": "approve", "arguments": {"tool_name": tool, "input": tool_input}})
        return json.loads(result["content"][0]["text"])

    def close(self) -> None:
        self.proc.terminate()
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def fake_claude(argv: list[str]) -> int:
    if "--version" in argv:
        print("2.1.268 (Claude Code)")
        return 0
    scenario = os.environ.get("CLAUDE_REPLAY_SCENARIO", "success")
    session = arg_value(argv, "--resume") or "session-replay-001"
    if scenario != "no_session":
        print(json.dumps({"type": "system", "subtype": "init", "session_id": session}), flush=True)
    if scenario == "no_session":
        print(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "无会话"}]}}), flush=True)
        return 0
    if scenario == "eof":
        return 0
    if scenario == "bad_json":
        print("{bad json", flush=True)
        return 0
    if scenario == "unknown":
        print(json.dumps({"type": "future_event", "opaque": {"keep": True}}), flush=True)
    if scenario == "signal":
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        while True:
            time.sleep(0.1)
    if scenario in {"deny", "forbidden", "closeout", "question_answered", "question_timeout"}:
        rpc = Rpc(pathlib.Path(arg_value(argv, "--mcp-config")))
        try:
            rpc.call("initialize", {})
            rpc.call("tools/list", {})
            if scenario in {"deny", "forbidden"}:
                decision = rpc.approve("Bash", {"command": "git push origin HEAD"})
                assert decision["behavior"] == "deny", decision
            elif scenario == "closeout":
                decision = rpc.approve("Bash", {"command": "git push origin HEAD"})
                assert decision["behavior"] == "allow", decision
            else:
                if scenario == "question_answered":
                    cfg = json.loads(pathlib.Path(arg_value(argv, "--mcp-config")).read_text())
                    stem = pathlib.Path(cfg["mcpServers"]["foreman"]["args"][-1])
                    req = json.loads(pathlib.Path(str(stem) + ".request.json").read_text())
                    def answer() -> None:
                        qpath = pathlib.Path(req["questions_path"])
                        for _ in range(100):
                            if qpath.exists():
                                q = json.loads(qpath.read_text())["questions"][0]
                                pathlib.Path(req["answer_path"]).write_text(json.dumps({"answers": {q["id"]: ["蓝色"]}}))
                                return
                            time.sleep(0.02)
                    threading.Thread(target=answer, daemon=True).start()
                decision = rpc.approve("AskUserQuestion", {"questions": [{"header": "颜色", "question": "选择颜色？",
                    "options": [{"label": "蓝色", "description": "使用蓝色"}], "multiSelect": False}]})
                assert decision["behavior"] == "allow", decision
                expected = "蓝色" if scenario == "question_answered" else "编排者当前不在线"
                assert expected in decision["updatedInput"]["answers"]["选择颜色？"]
        finally:
            rpc.close()
    if scenario in {"mcp_missing", "invalid_decision"}:
        print(json.dumps({"type": "result", "subtype": "error", "session_id": session,
                          "result": "permission MCP unavailable"}), flush=True)
        return 0
    print(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "完成"}]}}), flush=True)
    print(json.dumps({"type": "result", "subtype": "success", "session_id": session,
                      "usage": {"input_tokens": 10, "output_tokens": 4}, "total_cost_usd": 0.01}), flush=True)
    return 0


def request(root: pathlib.Path, scenario: str, *, session: str = "", full: bool = False,
            closeout: bool = False, qtimeout: int = 1) -> pathlib.Path:
    stem = root / scenario
    prompt = root / f"{scenario}.prompt.md"
    dev = root / f"{scenario}.dev.md"
    prompt.write_text("完成回放任务", encoding="utf-8")
    dev.write_text("回放角色契约", encoding="utf-8")
    meta = root / "meta.json"
    if not meta.exists():
        meta.write_text('{"threads":{}}', encoding="utf-8")
    req = {
        "issue": "C1", "thread": scenario, "role": "implement", "model": "sonnet", "effort": "low",
        "prompt_path": str(prompt), "dev_instructions_path": str(dev), "cwd": str(root), "work_dir": str(root),
        "writable_roots": [], "session_id": session, "timeout": 30,
        "questions_path": str(stem) + ".questions.json", "answer_path": str(stem) + ".answer.json",
        "question_timeout": qtimeout, "user_explicitly_approved_full_access": full,
        "full_access_reason": "用户明确要求完全权限" if full else "", "closeout": closeout,
        "jsonl_path": str(stem) + ".jsonl", "stderr_path": str(stem) + ".stderr",
        "claude_json_path": str(stem) + ".claude.json", "thread_title": scenario,
        "meta_path": str(meta), "max_turns": 8, "max_budget_usd": 0.5,
    }
    path = pathlib.Path(str(stem) + ".request.json")
    path.write_text(json.dumps(req, ensure_ascii=False), encoding="utf-8")
    return path


def events(path: pathlib.Path) -> list[dict]:
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def run_case(root: pathlib.Path, scenario: str, want: int, **kwargs) -> tuple[pathlib.Path, list[dict]]:
    req = request(root, scenario, **kwargs)
    env = dict(os.environ, FOREMAN_SELFTEST="1", CLAUDE_BIN=str(HERE), CLAUDE_REPLAY_SCENARIO=scenario)
    proc = subprocess.run([sys.executable, str(BRIDGE), "run", str(req)], env=env, timeout=20)
    assert proc.returncode == want, (scenario, proc.returncode, want)
    log = pathlib.Path(str(req)[:-len(".request.json")] + ".jsonl")
    data = events(log)
    assert data[0]["_foreman"]["engine"] == "claude"
    assert data[-1]["_foreman"]["type"] == "turn_summary" and data[-1]["_foreman"]["rc"] == want
    print(f"claude replay: {scenario} PASS")
    return req, data


def selftest() -> int:
    with tempfile.TemporaryDirectory(prefix="foreman-claude-replay.") as td:
        root = pathlib.Path(td)
        run_case(root, "success", 0)
        _, deny = run_case(root, "deny", 0)
        assert any(e.get("_foreman", {}).get("decision") == "deny" for e in deny)
        run_case(root, "eof", 3)
        run_case(root, "no_session", 3)
        run_case(root, "bad_json", 3)
        _, unknown = run_case(root, "unknown", 0)
        assert any(e.get("type") == "future_event" for e in unknown)
        run_case(root, "question_answered", 0)
        run_case(root, "question_timeout", 0, qtimeout=0)
        run_case(root, "mcp_missing", 4)
        run_case(root, "invalid_decision", 4)
        run_case(root, "forbidden", 0)
        run_case(root, "closeout", 0, closeout=True)
        full_req, _ = run_case(root, "success_full", 0, full=True)
        argv = pathlib.Path(str(full_req)[:-len(".request.json")] + ".argv").read_bytes().split(b"\0")
        assert b"bypassPermissions" in argv and b"--permission-prompt-tool" not in argv
        resume_req, _ = run_case(root, "success_resume", 0, session="resume-secret")
        argv = pathlib.Path(str(resume_req)[:-len(".request.json")] + ".argv").read_bytes().split(b"\0")
        assert b"--resume" in argv and b"resume-secret" in argv

        req = request(root, "signal")
        env = dict(os.environ, FOREMAN_SELFTEST="1", CLAUDE_BIN=str(HERE), CLAUDE_REPLAY_SCENARIO="signal")
        proc = subprocess.Popen([sys.executable, str(BRIDGE), "run", str(req)], env=env)
        log = pathlib.Path(str(req)[:-len(".request.json")] + ".jsonl")
        for _ in range(100):
            if log.exists() and '"type":"system"' in log.read_text(errors="ignore"):
                break
            time.sleep(0.02)
        proc.terminate()
        assert proc.wait(timeout=10) == 143
        data = events(log)
        assert data[-1]["_foreman"]["rc"] == 143 and json.loads((root / "meta.json").read_text())["threads"]["signal"]["ref"]
        print("claude replay: signal PASS")

        # 纯函数级配置守卫也放进同一回放入口，避免依赖真实 CLI。
        settings = json.loads(pathlib.Path(str(full_req)[:-len(".request.json")] + ".settings.json").read_text())
        assert settings["sandbox"]["enabled"] is False
        print("claude replay: full_access PASS")
    print("claude replay: ALL PASS")
    return 0


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        raise SystemExit(selftest())
    raise SystemExit(fake_claude(sys.argv[1:]))
