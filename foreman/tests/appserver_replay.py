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


CASES = [baseline_request]


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
