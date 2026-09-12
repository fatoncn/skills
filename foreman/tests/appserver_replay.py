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
            if request.get("method") != step["method"]:
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


CASES = [baseline_request, lambda: nested_case(True), lambda: nested_case(False),
         outer_timeout, nested_error, eof_cleanup, orphan_diagnostics]


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
