#!/usr/bin/env python3
"""可编排的 app-server stdio 回放夹具。

新增用例时，在 ``CASES`` 中加入一个函数。函数用 ``Replay`` 声明服务端依次期待的
请求及随后发出的响应/通知；每个 emit 项可带 ``delay``（秒）。最后调用 ``run()``，
夹具会同时校验客户端请求顺序、固定 JSON-RPC 基线和隔离后的进程环境。
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BRIDGE_PATH = ROOT / "scripts" / "codex_appserver.py"


def load_bridge():
    scripts = str(BRIDGE_PATH.parent)
    if scripts not in sys.path:
        sys.path.insert(0, scripts)
    spec = importlib.util.spec_from_file_location("foreman_codex_appserver", BRIDGE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class Replay:
    """Launch the real AppServer client against this file's scripted fake server."""

    def __init__(self, steps):
        self.steps = steps

    def run(self, client):
        bridge = load_bridge()
        with tempfile.TemporaryDirectory(prefix="foreman-appserver-replay-") as tmp:
            root = Path(tmp)
            scenario = root / "scenario.json"
            observed = root / "observed.json"
            scenario.write_text(json.dumps({"steps": self.steps}), encoding="utf-8")
            fake = root / "codex"
            fake.write_text(f"#!/bin/sh\nexec python3 {str(Path(__file__).resolve())!r} --fake-server\n", encoding="utf-8")
            fake.chmod(fake.stat().st_mode | stat.S_IXUSR)
            old_env = dict(os.environ)
            try:
                for key in list(os.environ):
                    upper = key.upper()
                    if upper.startswith(("CODEX_", "CLAUDE_")) or "PLUGIN" in upper:
                        os.environ.pop(key, None)
                os.environ["FOREMAN_REPLAY_SCENARIO"] = str(scenario)
                os.environ["FOREMAN_REPLAY_OBSERVED"] = str(observed)
                home = root / "codex-home"
                home.mkdir()
                server = bridge.AppServer(str(fake), str(home), str(root), [],
                                          str(root / "events.jsonl"), str(root / "stderr"))
                server.replay_root = root
                try:
                    result = client(server, bridge)
                finally:
                    server.close(.2)
            finally:
                os.environ.clear()
                os.environ.update(old_env)
            record = json.loads(observed.read_text(encoding="utf-8"))
            assert record["ok"], record
            assert record["jsonrpc"] == ["2.0"] * len(record["jsonrpc"]), record
            assert record["codexHome"] == str(home), record
            assert record["inherited"] == [], record
            record["events"] = [json.loads(line) for line in (root / "events.jsonl").read_text().splitlines()]
            return result, record


def fake_server():
    scenario = json.loads(Path(os.environ["FOREMAN_REPLAY_SCENARIO"]).read_text(encoding="utf-8"))
    observed = []
    failure = ""
    try:
        for step in scenario["steps"]:
            line = sys.stdin.readline()
            if not line:
                raise AssertionError(f"expected {step['method']}, got EOF")
            request = json.loads(line)
            observed.append(request)
            if "responseId" in step:
                if request.get("id") != step["responseId"] or "method" in request:
                    raise AssertionError(f"expected response {step['responseId']}, got {request}")
            elif request.get("method") != step["method"]:
                raise AssertionError(f"expected {step['method']}, got {request.get('method')}")
            for outgoing in step.get("emit", []):
                time.sleep(float(outgoing.get("delay", 0)))
                message = dict(outgoing["message"])
                if message.pop("$requestId", False):
                    message["id"] = request["id"]
                message.setdefault("jsonrpc", "2.0")
                print(json.dumps(message), flush=True)
    except Exception as exc:  # parent reports the exact scripted mismatch
        failure = str(exc)
    finally:
        inherited = sorted(key for key in os.environ
                           if (key.upper().startswith(("CODEX_", "CLAUDE_")) or "PLUGIN" in key.upper())
                           and key != "CODEX_HOME")
        Path(os.environ["FOREMAN_REPLAY_OBSERVED"]).write_text(json.dumps({
            "ok": not failure,
            "error": failure,
            "methods": [item.get("method") for item in observed],
            "jsonrpc": [item.get("jsonrpc") for item in observed],
            "codexHome": os.environ.get("CODEX_HOME"),
            "inherited": inherited,
        }), encoding="utf-8")
    return 0 if not failure else 1


def baseline_request():
    replay = Replay([{"method": "initialize", "emit": [{
        "message": {"$requestId": True, "result": {"protocol": "2025-04-01"}},
    }]}])
    result, record = replay.run(lambda server, bridge: server.request("initialize", {}, 2))
    assert result == {"protocol": "2025-04-01"}
    assert record["methods"] == ["initialize"]
    print("fixture baseline: initialize -> protocol 2025-04-01")


def nested_case(outer_first):
    notice = {"method": "notice", "params": {}}
    outer = {"id": 1, "result": {"value": "outer"}}
    inner = {"id": 2, "result": {"value": "inner"}}
    steps = [{"method": "outer", "emit": []}, {"method": "inner", "emit": []}]
    if outer_first:
        steps[0]["emit"] = [{"message": notice}, {"message": outer}]
        steps[1]["emit"] = [{"message": inner}]
    else:
        steps[0]["emit"] = [{"message": notice}]
        steps[1]["emit"] = [{"message": inner}, {"message": outer}]

    def client(server, bridge):
        nested = []
        server.on_notification = lambda msg: nested.append(server.request("inner", {}, 2))
        result = server.request("outer", {}, 2)
        assert nested == [{"value": "inner"}]
        return result

    result, _ = Replay(steps).run(client)
    assert result == {"value": "outer"}
    print(f"request routing: {'outer-first' if outer_first else 'inner-first'} PASS")


def outer_timeout():
    replay = Replay([{"method": "outer", "emit": [{"delay": .15, "message": {"id": 1, "result": {}}}]}])
    def client(server, bridge):
        try:
            server.request("outer", {}, .03)
        except bridge.ProtocolError as exc:
            assert "没有响应" in str(exc)
            assert server._pending == {}
            return "timeout"
        raise AssertionError("timeout expected")
    result, _ = replay.run(client)
    assert result == "timeout"
    print("request routing: timeout cleanup PASS")


def nested_error():
    steps = [
        {"method": "outer", "emit": [{"message": {"method": "notice"}}]},
        {"method": "inner", "emit": [
            {"message": {"id": 2, "error": {"code": -1, "message": "inner failed"}}},
            {"message": {"id": 1, "result": {"ok": True}}},
        ]},
    ]
    def client(server, bridge):
        errors = []
        def notified(msg):
            try: server.request("inner", {}, 2)
            except bridge.ProtocolError as exc: errors.append(str(exc))
        server.on_notification = notified
        result = server.request("outer", {}, 2)
        assert errors and "inner failed" in errors[0]
        return result
    result, _ = Replay(steps).run(client)
    assert result == {"ok": True}
    print("request routing: nested error PASS")


def eof_cleanup():
    def client(server, bridge):
        try: server.request("outer", {}, 2)
        except bridge.ProtocolError as exc:
            assert "stdout 关闭" in str(exc) and server._pending == {}
            return "eof"
        raise AssertionError("EOF expected")
    result, _ = Replay([{"method": "outer"}]).run(client)
    assert result == "eof"
    print("request routing: EOF cleanup PASS")


def orphan_diagnostics():
    emits = [{"message": {"id": 999, "result": {}}},
             {"message": {"id": 1, "result": {"ok": True}}},
             {"message": {"id": 1, "result": {"late": True}}}]
    def client(server, bridge):
        result = server.request("outer", {}, 2)
        server.dispatch(server.next_message(1))
        return result
    result, record = Replay([{"method": "outer", "emit": emits}]).run(client)
    assert result == {"ok": True}
    reasons = [event.get("reason") for event in record["events"] if event.get("_fleet") == "orphan_response"]
    assert reasons == ["unknown_id", "unknown_id"], reasons
    print("request routing: unknown/late diagnostic PASS")


def failure_classification_uses_only_eof_tail():
    bridge = load_bridge()
    class MemoryServer:
        def __init__(self, stderr_path):
            self.stderr_path = str(stderr_path)
            self._stderr = open(stderr_path, "ab")
            self.events = []
        def log_event(self, event):
            self.events.append(event)

    with tempfile.TemporaryDirectory() as tmp:
        stderr = Path(tmp) / "stderr"
        def classify(error, content):
            stderr.write_bytes(content)
            server = MemoryServer(stderr)
            runner = bridge.Runner({})
            runner.server = server
            try:
                return runner._classify_failure(bridge.ProtocolError(error))
            finally:
                server._stderr.close()
        history = b"connection refused\n" + b"x" * 9000
        assert classify("invalid params", b"INFO login helper initialized\n") == 3
        assert classify("active writer", b"INFO login helper initialized\n") == 5
        assert classify("app-server 在等待 initialize 响应时退出（stdout 关闭）",
                        b"connection refused\n") == 4
        assert classify("app-server 在等待 initialize 响应时退出（stdout 关闭）", history) == 3
    print("request routing: EOF-only stderr classification PASS")


def expired_nested_response():
    steps = [
        {"method": "outer", "emit": [{"message": {"method": "notice"}}]},
        {"method": "inner", "emit": [
            {"delay": 1.1, "message": {"id": 1, "result": {"late": True}}},
            {"message": {"id": 2, "result": {"inner": True}}},
        ]},
    ]
    def client(server, bridge):
        server.on_notification = lambda msg: server.request("inner", {}, 3)
        try:
            server.request("outer", {}, 1)
        except bridge.ProtocolError as exc:
            assert "没有响应" in str(exc)
            return
        raise AssertionError("expired outer response must not resolve its slot")
    _, record = Replay(steps).run(client)
    assert "expired" in [e.get("reason") for e in record["events"]]
    print("request routing: expired nested response PASS")


def duplicate_pending_and_suppression():
    steps = [
        {"method": "outer", "emit": [{"message": {"method": "notice"}}]},
        {"method": "inner", "emit": [
            {"message": {"id": 1, "result": {"outer": True}}},
            {"message": {"id": 1, "result": {"duplicate": True}}},
            *[{"message": {"id": 1000 + n, "result": {}}} for n in range(33)],
            {"message": {"id": 2, "result": {"inner": True}}},
        ]},
    ]
    def client(server, bridge):
        server.on_notification = lambda msg: server.request("inner", {}, 3)
        return server.request("outer", {}, 3)
    result, record = Replay(steps).run(client)
    assert result == {"outer": True}
    events = record["events"]
    assert any(e.get("reason") == "duplicate_response" for e in events)
    assert len([e for e in events if e.get("_fleet") == "orphan_response"]) == 32
    assert len([e for e in events if e.get("_fleet") == "orphan_response_suppressed"]) == 1
    print("request routing: pending duplicate + diagnostic suppression PASS")


def real_question_steer_chain():
    question = {"jsonrpc": "2.0", "id": 500, "method": "item/tool/requestUserInput",
                "params": {"questions": [{"id": "q", "question": "continue?"}]}}
    steps = [
        {"method": "outer", "emit": [{"message": question}]},
        {"method": "turn/steer", "emit": [
            {"message": {"id": 1, "result": {"outer": True}}},
            {"message": {"id": 2, "result": {"turnId": "root-turn"}}},
        ]},
        {"responseId": 500},
    ]
    def client(server, bridge):
        answer = server.replay_root / "answer.json"
        answer.write_text(json.dumps({"all": "continue"}), encoding="utf-8")
        runner = bridge.Runner({"thread_id": "root-thread", "prompt": "fixture",
                                "question_timeout": 1, "answer_path": str(answer)})
        runner.server = server
        runner.turn_id = "root-turn"
        hold_dir = server.replay_root / "hold-fixture"
        (hold_dir / "steer").mkdir(parents=True)
        (hold_dir / "hold.json").write_text("{}", encoding="utf-8")
        (hold_dir / "steer" / "001.json").write_text(json.dumps({
            "text": "queued steering", "at": 1, "fromRun": "fixture",
            "expectedTurnId": "root-turn"}), encoding="utf-8")
        holder = bridge.Holder(str(hold_dir))
        holder.current = runner
        server.on_server_request = runner.handle_server_request
        runner.consume_steers = lambda: holder.consume_steers(server)
        result = server.request("outer", {}, 3)
        assert (hold_dir / "steer" / "sent" / "001.json").exists()
        return result
    result, record = Replay(steps).run(client)
    assert result == {"outer": True}
    assert record["methods"] == ["outer", "turn/steer", None]
    print("request routing: request_user_input -> consume_steers -> turn/steer PASS")


def turn_event(method, thread, turn, **extra):
    params = {"threadId": thread, **extra}
    if method.startswith("turn/"):
        params["turn"] = {"id": turn, "status": extra.pop("status", "inProgress")}
    else:
        params["turnId"] = turn
    return {"method": method, "params": params}


def run_turn(events, expect_error=False, pre_response=True, observer=None):
    response = {"$requestId": True, "result": {"turn": {"id": "root-turn"}}}
    emitted = [{"message": event} for event in events]
    step = {"method": "turn/start", "emit": (emitted + [{"message": response}]) if pre_response else ([{"message": response}] + emitted)}
    def client(server, bridge):
        runner = bridge.Runner({"thread_id": "root-thread", "prompt": "fixture"})
        runner.server = server
        def notify(message):
            runner.handle_notification(message)
            if observer:
                observer(runner, message)
        server.on_notification = notify
        try:
            rc = runner.turn()
            if expect_error:
                raise AssertionError("ProtocolError expected")
            return runner, rc
        except bridge.ProtocolError:
            if not expect_error:
                raise
            return runner, None
    return Replay([step]).run(client)[0]


def root_final_then_child_final():
    collab = turn_event("item/completed", "root-thread", "root-turn", item={
        "type": "collabAgentToolCall", "receiverThreadIds": ["child-thread"]})
    root_final = turn_event("item/completed", "root-thread", "root-turn",
                            item={"type": "agentMessage", "phase": "final_answer", "text": "ROOT"})
    child_final = turn_event("item/completed", "child-thread", "child-turn",
                             item={"type": "agentMessage", "phase": "final_answer", "text": "CHILD"})
    child_tokens = turn_event("thread/tokenUsage/updated", "child-thread", "child-turn",
                              tokenUsage={"total": {"inputTokens": 3, "outputTokens": 2}})
    completed = turn_event("turn/completed", "root-thread", "root-turn", status="completed")
    runner, rc = run_turn([collab, root_final, child_final, child_tokens, completed])
    assert rc == 0 and runner.final_text == "ROOT"
    assert runner.token_usage is None and runner.child_token_usage["subagent-1"]["total"]["inputTokens"] == 3
    print("turn identity: root final survives child final PASS")


def old_turn_is_ignored():
    old = turn_event("item/completed", "root-thread", "old-turn",
                     item={"type": "agentMessage", "phase": "final_answer", "text": "OLD"})
    root = turn_event("item/completed", "root-thread", "root-turn",
                      item={"type": "agentMessage", "phase": "final_answer", "text": "ROOT"})
    completed = turn_event("turn/completed", "root-thread", "root-turn", status="completed")
    runner, rc = run_turn([root, old, completed])
    assert rc == 0 and runner.final_text == "ROOT"
    print("turn identity: stale turn ignored PASS")


def child_completion_is_not_root_completion():
    collab = turn_event("item/completed", "root-thread", "root-turn", item={
        "type": "collabAgentToolCall", "receiverThreadIds": ["child-thread"]})
    child_done = turn_event("turn/completed", "child-thread", "child-turn", status="completed")
    root_done = turn_event("turn/completed", "root-thread", "root-turn", status="completed")
    after_child = []
    def observer(runner, message):
        if message.get("method") == "turn/completed" and (message.get("params") or {}).get("threadId") == "child-thread":
            after_child.append(runner.turn_status)
    runner, rc = run_turn([collab, child_done, root_done], pre_response=False, observer=observer)
    assert after_child == [None], after_child
    assert rc == 0 and runner.turn_status == "completed"
    print("turn identity: child completion does not settle root PASS")


def pre_response_notifications_replayed():
    final = turn_event("item/completed", "root-thread", "root-turn",
                       item={"type": "agentMessage", "phase": "final_answer", "text": "EARLY ROOT"})
    completed = turn_event("turn/completed", "root-thread", "root-turn", status="completed")
    runner, rc = run_turn([final, completed])
    assert rc == 0 and runner.final_text == "EARLY ROOT"
    print("turn identity: pre-response notifications replayed PASS")


def no_root_completion_is_not_inferred():
    final = turn_event("item/completed", "root-thread", "root-turn",
                       item={"type": "agentMessage", "phase": "final_answer", "text": "ROOT"})
    runner, rc = run_turn([final], expect_error=True)
    assert rc is None and runner.turn_status is None and runner.final_text == "ROOT"
    print("turn identity: no inferred root completion PASS")


def child_second_turn_is_tracked():
    collab = turn_event("item/completed", "root-thread", "root-turn", item={
        "type": "collabAgentToolCall", "receiverThreadIds": ["child-thread"]})
    events = [collab,
              turn_event("turn/started", "child-thread", "c1"),
              turn_event("turn/completed", "child-thread", "c1", status="completed"),
              turn_event("turn/started", "child-thread", "c2"),
              turn_event("thread/tokenUsage/updated", "child-thread", "c2",
                         tokenUsage={"total": {"inputTokens": 7, "outputTokens": 4}}),
              turn_event("item/completed", "child-thread", "c2",
                         item={"type": "agentMessage", "text": "C2"}),
              turn_event("turn/started", "child-thread", "c1"),
              turn_event("turn/completed", "child-thread", "c1", status="completed"),
              turn_event("thread/tokenUsage/updated", "child-thread", "c1",
                         tokenUsage={"total": {"inputTokens": 99}}),
              turn_event("turn/completed", "root-thread", "root-turn", status="completed")]
    message_scope = []
    def observer(runner, message):
        item = (message.get("params") or {}).get("item") or {}
        if item.get("text") == "C2":
            message_scope.append(runner.identity.scope(message))
    runner, rc = run_turn(events, pre_response=False, observer=observer)
    assert rc == 0
    assert runner.child_token_usage["subagent-1"]["total"]["inputTokens"] == 7
    assert runner.identity.children["child-thread"]["turn"] == "c2"
    assert message_scope == ["child"]
    print("turn identity: child second turn tracked PASS")


def summary_uses_same_identity_rules():
    spec = importlib.util.spec_from_file_location("foreman_summarize", ROOT / "scripts" / "summarize.py")
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    events = [
        {"_fleet": "thread", "threadId": "root-thread"},
        turn_event("item/completed", "root-thread", "root-turn", item={
            "type": "collabAgentToolCall", "receiverThreadIds": ["child-thread"]}),
        turn_event("item/completed", "child-thread", "child-turn", item={
            "type": "agentMessage", "phase": "final_answer", "text": "CHILD"}),
        turn_event("item/completed", "root-thread", "old-turn", item={
            "type": "agentMessage", "phase": "final_answer", "text": "OLD"}),
        turn_event("item/completed", "root-thread", "root-turn", item={
            "type": "agentMessage", "phase": "final_answer", "text": "ROOT"}),
        turn_event("turn/completed", "child-thread", "child-turn", status="completed"),
        turn_event("turn/completed", "root-thread", "root-turn", status="completed"),
        {"_fleet": "turn_summary", "threadId": "root-thread", "turnId": "root-turn",
         "status": "completed", "tokenUsage": {"total": {"inputTokens": 5, "outputTokens": 2}},
         "childTokenUsage": {"subagent-1": {"total": {"inputTokens": 3, "outputTokens": 1}}}},
    ]
    state = module.scan_appserver(events)
    assert state["settled"] and state["final"] == "ROOT"
    assert state["child_tokens"]["subagent-1"]["total"]["inputTokens"] == 3
    assert state["tokens"] == 11
    legacy = module.scan_appserver([{"method": "turn/completed", "params": {"turn": {"status": "completed"}}}])
    assert any("旧 app-server 日志" in note for note in legacy["notices"])
    print("turn identity: summarize strict + legacy downgrade PASS")


CASES = [baseline_request, lambda: nested_case(True), lambda: nested_case(False),
         outer_timeout, nested_error, eof_cleanup, orphan_diagnostics, failure_classification_uses_only_eof_tail,
         expired_nested_response,
         duplicate_pending_and_suppression, real_question_steer_chain,
         root_final_then_child_final, old_turn_is_ignored, child_completion_is_not_root_completion,
         pre_response_notifications_replayed, no_root_completion_is_not_inferred, child_second_turn_is_tracked,
         summary_uses_same_identity_rules]


def selftest():
    for case in CASES:
        case()
    print(f"app-server replay: {len(CASES)} case(s) PASS")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--fake-server", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if args.fake_server:
        raise SystemExit(fake_server())
    if args.selftest:
        selftest()
    else:
        parser.error("use --selftest")
