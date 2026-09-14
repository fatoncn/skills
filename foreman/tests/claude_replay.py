#!/usr/bin/env python3
"""Claude Code stream-json / 权限 MCP 回放夹具。

直接作为 ``CLAUDE_BIN`` 执行时扮演假 claude；``--selftest`` 则驱动真实桥覆盖
协议、权限、提问、resume、full-access 与信号归一化。
"""
from __future__ import annotations

import json
import difflib
import fnmatch
import os
import pathlib
import re
import select
import signal
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager

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
    if argv[:2] == ["auth", "status"]:
        print("loggedIn: true\naccountType: subscription")
        return 0
    scenario = os.environ.get("CLAUDE_REPLAY_SCENARIO", "success")
    session = arg_value(argv, "--resume") or "session-replay-001"
    if scenario == "resume_mismatch":
        session = "session-replay-mismatch"
    mcp_path = pathlib.Path(arg_value(argv, "--mcp-config"))
    stem = pathlib.Path(str(mcp_path)[:-len(".mcp.json")])
    pathlib.Path(str(stem) + ".fake-started").write_text("started", encoding="utf-8")
    assert mcp_path.is_file() and (mcp_path.stat().st_mode & 0o777) == 0o600
    if scenario != "no_session":
        print(json.dumps({"type": "system", "subtype": "init", "session_id": session}), flush=True)
    if scenario == "no_session":
        print(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "无会话"}]}}), flush=True)
        return 0
    if scenario == "eof":
        return 0
    if scenario == "bad_json":
        # 先装好忽略 SIGTERM 再吐坏行：桥一读到坏 JSON 就会发 SIGTERM，若装信号在吐坏行之后，
        # 两者谁先谁后是竞态——曾经偶发让这个假子进程在装上忽略前被默认处理杀掉，after_bad 就不会落盘。
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        print(' { "type" : "assistant", "opaque" : true } ', flush=True)
        print("{bad json", flush=True)
        print(' { "type" : "after_bad", "keep" : 1 } ', flush=True)
        return 0
    if scenario == "unknown":
        print(json.dumps({"type": "future_event", "opaque": {"keep": True}}), flush=True)
    if scenario in {"signal", "signal_ignore"}:
        signal.signal(signal.SIGTERM, signal.SIG_IGN if scenario == "signal_ignore" else lambda *_: sys.exit(143))
        while True:
            time.sleep(0.1)
    if scenario in {"deny", "forbidden", "closeout", "non_closeout_graphql", "question_answered", "question_timeout"}:
        rpc = Rpc(mcp_path)
        try:
            rpc.call("initialize", {})
            rpc.call("tools/list", {})
            if scenario in {"deny", "forbidden"}:
                decision = rpc.approve("Bash", {"command": "git push origin HEAD"})
                assert decision["behavior"] == "deny", decision
            elif scenario == "closeout":
                checks = {
                    "echo git push > /tmp/x": "deny",
                    "gh api graphql -f query=x; git reset --hard": "deny",
                    "git push origin HEAD": "allow",
                    "git push --force": "deny",
                }
                for command, behavior in checks.items():
                    decision = rpc.approve("Bash", {"command": command})
                    assert decision["behavior"] == behavior, (command, decision)
            elif scenario == "non_closeout_graphql":
                decision = rpc.approve("Bash", {"command": "gh api graphql -f query='mutation{resolveReviewThread}'"})
                assert decision["behavior"] == "deny", decision
            else:
                decision = rpc.approve("AskUserQuestion", {"questions": [{"header": "颜色", "question": "选择颜色？",
                    "options": [{"label": "蓝色", "description": "使用蓝色"}], "multiSelect": False}]})
                assert decision["behavior"] == "allow", decision
                expected = "蓝色" if scenario == "question_answered" else "编排者当前不在线"
                assert expected in decision["updatedInput"]["answers"]["选择颜色？"]
                print(json.dumps({"type": "foreman_replay_answer", "answers": decision["updatedInput"]["answers"]}), flush=True)
        finally:
            rpc.close()
    if scenario == "mcp_missing":
        print("MCP tool mcp__foreman__approve (passed via --permission-prompt-tool) not found", file=sys.stderr, flush=True)
        return 1
    if scenario == "invalid_decision":
        rpc = Rpc(mcp_path)
        try:
            rpc.call("initialize", {})
            result = rpc.call("tools/call", {"name": "approve", "arguments": {"tool_name": "Bash", "input": [1]}})
            decision = json.loads(result["content"][0]["text"])
            assert decision["behavior"] == "deny", decision
        finally:
            rpc.close()
    if scenario == "resume_mismatch":
        return 0
    if scenario == "success_stderr_warning":
        print("warning: cached rate limit notice", file=sys.stderr, flush=True)
    print(json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "完成"}]}}), flush=True)
    if scenario == "report_marker_missing":
        result_text = "完成"
    elif scenario == "success_review" or "--tools" in sys.argv:
        result_text = "## 总体印象\n通过"
    else:
        result_text = "## STATUS\nDONE"
    print(json.dumps({"type": "result", "subtype": "success", "session_id": session, "result": result_text,
                      "usage": {"input_tokens": 10, "output_tokens": 4}, "total_cost_usd": 0.01}), flush=True)
    return 0


def request(root: pathlib.Path, scenario: str, *, session: str = "", full: object = False,
            full_reason: str | None = None, closeout: bool = False, qtimeout: int = 1,
            review: bool = False) -> pathlib.Path:
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
        "full_access_reason": ("用户明确要求完全权限" if full is True else "") if full_reason is None else full_reason,
        "closeout": closeout,
        "review_readonly": "tools_only" if review else None, "inherit_user_mcp": not review,
        "persist_session": not review, "tools": "Read,Glob,Grep" if review else "",
        "no_session_persistence": review,
        "jsonl_path": str(stem) + ".jsonl", "stderr_path": str(stem) + ".stderr",
        "last_path": str(stem) + ".last.md",
        "claude_json_path": str(stem) + ".claude.json", "thread_title": scenario,
        "meta_path": str(meta), "max_turns": 8, "max_budget_usd": 0.5,
        "report_marker": "## 总体印象" if review else "## STATUS",
    }
    path = pathlib.Path(str(stem) + ".request.json")
    path.write_text(json.dumps(req, ensure_ascii=False), encoding="utf-8")
    return path


def events(path: pathlib.Path) -> list[dict]:
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            out.append(value)
    return out


def run_case(root: pathlib.Path, scenario: str, want: int, **kwargs) -> tuple[pathlib.Path, list[dict]]:
    req = request(root, scenario, **kwargs)
    env = dict(os.environ, FOREMAN_SELFTEST="1", CLAUDE_BIN=str(HERE), CLAUDE_REPLAY_SCENARIO=scenario)
    proc = subprocess.run([sys.executable, str(BRIDGE), "run", str(req)], env=env, timeout=20)
    stderr_path = pathlib.Path(str(req)[:-len(".request.json")] + ".stderr")
    assert proc.returncode == want, (scenario, proc.returncode, want,
                                     stderr_path.read_text(errors="replace") if stderr_path.exists() else "")
    log = pathlib.Path(str(req)[:-len(".request.json")] + ".jsonl")
    data = events(log)
    marker = data[0]["_foreman"]
    assert marker["engine"] == "claude"
    assert marker["cwd"] == str(root) and marker["work_dir"] == str(root)
    settings = json.loads(pathlib.Path(str(req)[:-len(".request.json")] + ".settings.json").read_text())
    assert marker["writable_roots"] == settings["sandbox"]["allowWrite"]
    assert data[-1]["_foreman"]["type"] == "turn_summary" and data[-1]["_foreman"]["rc"] == want
    assert not pathlib.Path(str(req)[:-len(".request.json")] + ".mcp.json").exists()
    claude_meta = json.loads(pathlib.Path(str(req)[:-len(".request.json")] + ".claude.json").read_text())
    assert isinstance(claude_meta["mcp_servers"], list) and "mcp_config" not in claude_meta
    if not kwargs.get("full"):
        assert "foreman" in claude_meta["mcp_servers"]
    # 这里不打 PASS：一条用例往往 run_case 之后还有附加断言，两处都能打 PASS 的话，附加断言炸了
    # 输出里会同时出现 PASS 和 FAIL，selftest.sh 只要看到 PASS 就判绿。PASS / FAIL 只由 case() 出。
    return req, data


def claude_rule_matches(rule: str, command: str) -> bool:
    assert rule.startswith("Bash(") and rule.endswith(")"), rule
    pattern = rule[5:-1]
    if pattern.endswith(":*"):
        return command.startswith(pattern[:-2])
    if "*" in pattern:
        return fnmatch.fnmatchcase(command, pattern)
    return command == pattern


def replace_root(text: str, root: pathlib.Path, token: str) -> str:
    """路径分隔符允许重复，兼容 macOS TMPDIR 的 ``.../T//name``。"""
    variants = {str(root).rstrip("/"), os.path.realpath(root).rstrip("/")}
    for value in sorted(variants, key=len, reverse=True):
        if not value:
            continue
        pattern = re.escape(value).replace("/", "/+") + "/?"
        text = re.sub(pattern, token + "/", text)
    return text


def normalize_snapshot(value, tmp_root: pathlib.Path, skill_dir: pathlib.Path):
    if isinstance(value, dict):
        return {key: normalize_snapshot(item, tmp_root, skill_dir) for key, item in sorted(value.items())}
    if isinstance(value, list):
        return [normalize_snapshot(item, tmp_root, skill_dir) for item in value]
    if not isinstance(value, str):
        return value
    value = replace_root(value, skill_dir, "<SKILL>")
    value = replace_root(value, tmp_root, "<TMP>")
    value = replace_root(value, pathlib.Path.home(), "<HOME>")
    value = re.sub(r"foreman-selftest\.[A-Za-z0-9]+--bare", "<REPO_SLUG>", value)
    value = re.sub(r"(?<=/)\d{2}-\d{2}-\d{2}(?=/)", "<DATE>", value)
    value = re.sub(r"(/issues/<REPO_SLUG>/)1(?=/)", r"\1<ISSUE:1>", value)
    value = re.sub(r"(?<![A-Za-z])((?:run|review)-\d+)", r"<ROUND:\1>", value)
    return value


def round_number(path: pathlib.Path) -> int:
    match = re.search(r"(?:run|review)-(\d+)", path.name)
    return int(match.group(1)) if match else -1


def codex_snapshot(d1: pathlib.Path, d2: pathlib.Path, tmp_root: pathlib.Path, skill_dir: pathlib.Path) -> dict:
    meta_path = d1 / "meta.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    meta["threads"]["implement"]["ref"] = "snapshot-session"
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    env = dict(os.environ, FOREMAN_HOME=str(tmp_root / "home"), FOREMAN_CODEX_BIN=str(tmp_root / "fake-codex"))
    shell, brief, cwd = skill_dir / "scripts/foreman.sh", tmp_root / "brief.md", tmp_root / "proj/app"

    before = set(d1.glob("run-*.request.json"))
    subprocess.run([shell, "run", "1", "--thread", "implement", "--prompt", brief, "--title", "resume-snapshot",
                    "--timeout", "30"], cwd=cwd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    resume = max(set(d1.glob("run-*.request.json")) - before, key=round_number)
    before = set(d1.glob("run-*.request.json"))
    subprocess.run([shell, "run", "1", "--thread", "full-snapshot", "--prompt", brief, "--title", "full-snapshot",
                    "--full-access", "用户明确要求完全权限", "--timeout", "30"], cwd=cwd, env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    full = max(set(d1.glob("run-*.request.json")) - before, key=round_number)
    sources = {
        "new": d1 / "run-1.request.json", "resume": resume, "mechanical": d1 / "run-4.request.json",
        "full_access": full, "writable": d2 / "run-2.request.json", "review": d2 / "review-1.request.json",
    }
    cases = {}
    for name, path in sources.items():
        request_value = normalize_snapshot(json.loads(path.read_text(encoding="utf-8")), tmp_root, skill_dir)
        argv_path = pathlib.Path(str(path)[:-len(".request.json")] + ".argv")
        argv = [os.fsdecode(item) for item in argv_path.read_bytes().split(b"\0")[:-1]]
        argv = normalize_snapshot(argv, tmp_root, skill_dir)
        argv = [re.sub(r"/(1|2)/(<ROUND:[^>]+>)", r"/<ISSUE:\1>/\2", item) for item in argv]
        cases[name] = {"request": request_value, "argv": argv}
    hold_argv = [os.fsdecode(item) for item in (d1 / "hold-implement/start.argv").read_bytes().split(b"\0")[:-1]]
    hold_argv = normalize_snapshot(hold_argv, tmp_root, skill_dir)
    hold_argv = [re.sub(r"/(1|2)/(hold-)", r"/<ISSUE:\1>/\2", item) for item in hold_argv]
    return {
        "schema": 3,
        "normalization": ["<SKILL>", "<TMP>", "<HOME>", "<REPO_SLUG>", "<DATE>", "<ISSUE:N>", "<ROUND:kind-N>"],
        "cases": cases,
        "hold_start_argv": hold_argv,
    }


def snapshot_command(argv: list[str]) -> int:
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--d1", required=True)
    parser.add_argument("--d2", required=True)
    parser.add_argument("--tmp-root", required=True)
    parser.add_argument("--skill-dir", required=True)
    output = parser.add_mutually_exclusive_group(required=True)
    output.add_argument("--write")
    output.add_argument("--compare")
    parser.add_argument("--mutate-codex-argv", action="store_true")
    args = parser.parse_args(argv)
    actual = codex_snapshot(*(pathlib.Path(v) for v in (args.d1, args.d2, args.tmp_root, args.skill_dir)))
    if args.mutate_codex_argv:
        actual["cases"]["new"]["argv"].append("--deliberate-snapshot-mutation")
    rendered = json.dumps(actual, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.write:
        pathlib.Path(args.write).write_text(rendered, encoding="utf-8")
        return 0
    expected = pathlib.Path(args.compare).read_text(encoding="utf-8")
    if expected == rendered:
        print("Codex snapshot: MATCH")
        return 0
    print("\n".join(difflib.unified_diff(expected.splitlines(), rendered.splitlines(),
                                           fromfile=str(args.compare), tofile="actual", lineterm="")))
    return 1


def selftest() -> int:
    failed: list[str] = []

    @contextmanager
    def case(name: str):
        """每个用例独立失败：一条用例的断言炸了不该拖累其余用例的展示（issue #27）。"""
        try:
            yield
        except Exception as exc:
            failed.append(name)
            print(f"claude replay: {name} FAIL: {exc}")
        else:
            print(f"claude replay: {name} PASS")

    with tempfile.TemporaryDirectory(prefix="foreman-claude-replay.") as td:
        root = pathlib.Path(td)

        with case("snapshot_date_normalization"):
            normalized_date = normalize_snapshot("feat/26-09-13/b ticket-26-09-13", root, HERE.parents[1])
            assert normalized_date == "feat/<DATE>/b ticket-26-09-13"

        success_stem = success_data = None
        with case("success"):
            success_req, success_data = run_case(root, "success", 0)
            success_stem = str(success_req)[:-len(".request.json")]

        with case("report_marker_missing"):
            _, missing_data = run_case(root, "report_marker_missing", 6)
            summary = missing_data[-1]["_foreman"]
            assert summary["subtype"] == "no_report"
            assert summary["terminal_reason"] == "最后一条消息缺 `## STATUS`"

        with case("report_marker_present"):
            _, present_data = run_case(root, "report_marker_present", 0)
            assert present_data[-1]["_foreman"]["subtype"] == "success"

        with case("mcp_private_cleanup"):
            # 私有 MCP 配置是临时文件：跑完必须删干净，登记只留在 .claude.json 的名单里。
            assert success_stem is not None, "success 用例没跑成，这条无从校验"
            assert not pathlib.Path(success_stem + ".mcp.json").exists()
            claude_meta = json.loads(pathlib.Path(success_stem + ".claude.json").read_text())
            # 名单里是本机继承来的用户级 server + foreman，不能写死成只有 foreman。
            assert "mcp_config" not in claude_meta, claude_meta
            assert isinstance(claude_meta["mcp_servers"], list), claude_meta
            assert "foreman" in claude_meta["mcp_servers"], claude_meta

        with case("first_line_paths"):
            # jsonl 首行的位置块要如实记下这轮跑在哪：cwd / work_dir / 可写根都对得上请求。
            assert success_data is not None, "success 用例没跑成，这条无从校验"
            marker = success_data[0]["_foreman"]
            assert marker["engine"] == "claude", marker
            assert marker["cwd"] == str(root) and marker["work_dir"] == str(root), marker
            settings = json.loads(pathlib.Path(success_stem + ".settings.json").read_text())
            assert marker["writable_roots"] == settings["sandbox"]["allowWrite"], marker

        with case("deny"):
            _, deny = run_case(root, "deny", 0)
            assert any(e.get("_foreman", {}).get("decision") == "deny" for e in deny)

        with case("eof"):
            run_case(root, "eof", 3)

        with case("no_session"):
            run_case(root, "no_session", 3)

        bad_req = bad_data = None
        with case("bad_json"):
            bad_req, bad_data = run_case(root, "bad_json", 3)

        with case("bad_json_raw_drain"):
            bad_raw = pathlib.Path(str(bad_req)[:-len(".request.json")] + ".jsonl").read_text()
            assert ' { "type" : "assistant", "opaque" : true } \n' in bad_raw
            assert ' { "type" : "after_bad", "keep" : 1 } \n' in bad_raw
            assert any(e.get("_foreman", {}).get("type") == "protocol_error" for e in bad_data)

        with case("unknown"):
            _, unknown = run_case(root, "unknown", 0)
            assert any(e.get("type") == "future_event" for e in unknown)

        with case("question_timeout"):
            run_case(root, "question_timeout", 0, qtimeout=1)

        with case("mcp_missing"):
            run_case(root, "mcp_missing", 4)

        with case("invalid_decision"):
            for index, mode in enumerate(("json", "nobehavior"), 1):
                invalid_req = request(root, f"invalid_decision_{mode}")
                invalid_stem = str(invalid_req)[:-len(".request.json")]
                invalid_env = dict(os.environ, FOREMAN_SELFTEST="1", FOREMAN_CLAUDE_REPLAY_BAD_DECISION=mode)
                invalid_proc = subprocess.Popen([sys.executable, str(BRIDGE), "permission-server", "--run", invalid_stem],
                                                env=invalid_env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
                assert invalid_proc.stdin and invalid_proc.stdout
                rid = 700 + index
                invalid_proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                    "params": {"name": "approve", "arguments": {"tool_name": "Bash",
                        "input": {"command": "echo safe"}}}}) + "\n")
                invalid_proc.stdin.flush()
                invalid_reply = json.loads(invalid_proc.stdout.readline())
                invalid_proc.terminate(); invalid_proc.wait(timeout=2)
                invalid_decision = json.loads(invalid_reply["result"]["content"][0]["text"])
                invalid_events = events(pathlib.Path(invalid_stem + ".jsonl"))
                assert invalid_reply["id"] == rid and invalid_decision["behavior"] == "deny"
                assert any("权限审查器异常" in e.get("_foreman", {}).get("reason", "") for e in invalid_events)

        with case("invalid_decision_deny"):
            malformed_req = request(root, "permission_error_id")
            permission_proc = subprocess.Popen([sys.executable, str(BRIDGE), "permission-server", "--run",
                                                str(malformed_req)[:-len(".request.json")]],
                                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
            assert permission_proc.stdin and permission_proc.stdout
            permission_proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 77, "method": "tools/call", "params": 1}) + "\n")
            permission_proc.stdin.flush()
            malformed_reply = json.loads(permission_proc.stdout.readline())
            permission_proc.terminate()
            permission_proc.wait(timeout=2)
            assert malformed_reply["id"] == 77 and "error" in malformed_reply

        with case("forbidden"):
            run_case(root, "forbidden", 0)

        closeout_req = normal_req = None
        with case("closeout"):
            closeout_req, _ = run_case(root, "closeout", 0, closeout=True)

        with case("non_closeout_graphql"):
            normal_req, _ = run_case(root, "non_closeout_graphql", 0)

        import importlib.util
        spec = importlib.util.spec_from_file_location("claude_bridge", BRIDGE)
        bridge = importlib.util.module_from_spec(spec)
        assert spec.loader
        spec.loader.exec_module(bridge)
        forbidden_samples = [
            "git  push origin HEAD", "git remote add x y", "gh issue comment 1 -b x", "gh release create v1",
            "gh api -X PUT repos/x", "gh api repos/x -XPUT", "gh api graphql -f query=x", "vercel redeploy app",
            "vercel api x --method PUT", "supabase db push", "npx sst deploy", "echo eslint-disable",
            "pytest.foo.skip(", "git reset --hard HEAD", "git push origin HEAD --force", "git symbolic-ref HEAD x",
        ]
        closeout_rules = None

        with case("deny_rules_shared_source"):
            for _label, pattern, deny_globs in bridge.FORBIDDEN:
                assert deny_globs
                assert any(pattern.search(command) for command in forbidden_samples), pattern.pattern

        with case("deny_rules_no_false_positive"):
            assert normal_req is not None, "non_closeout_graphql 用例没跑成，这条无从校验"
            normal_deny = json.loads(
                pathlib.Path(str(normal_req)[:-len(".request.json")] + ".settings.json").read_text()
            )["permissions"]["deny"]
            for command in forbidden_samples:
                assert any(claude_rule_matches(rule, command) for rule in normal_deny), command
            closeout_settings = json.loads(pathlib.Path(str(closeout_req)[:-len(".request.json")] + ".settings.json").read_text())
            closeout_rules = closeout_settings["permissions"]["deny"]
            normal_must_deny = (
                "gh api -X PUT repos/x", "gh api repos/x -XPUT", "git  push origin HEAD",
                "gh api graphql -f query=x", "git checkout -- src/a.ts", "vercel env pull",
            )
            never_deny = (
                "grep -n highlight business/api/graphql.ts",
                "git checkout -b x && pnpm install --frozen-lockfile",
                "vercel inspect dep | grep environment", 'rg -n "graphql" src',
            )
            for command in normal_must_deny:
                assert any(claude_rule_matches(rule, command) for rule in normal_deny), command
            for command in never_deny:
                assert not any(claude_rule_matches(rule, command) for rule in normal_deny), command
                assert not any(claude_rule_matches(rule, command) for rule in closeout_rules), command
            for command in ("git push origin HEAD", "gh pr comment 1 -b ok", "gh api graphql -f query=x",
                            "gh api repos/x/pulls/1/comments -X POST"):
                assert not any(claude_rule_matches(rule, command) for rule in closeout_rules), command
            for command in ("gh api -X PUT repos/x", "gh api repos/x -XPUT",
                            "git push -f origin HEAD", "git push origin HEAD --force"):
                assert any(claude_rule_matches(rule, command) for rule in closeout_rules), command

        with case("command_segments_quoted_redirection"):
            closeout_allowed = (
                "git push origin HEAD 2>&1",
                "git push origin HEAD >/dev/null 2>&1 && gh pr ready 1",
                'gh pr comment 1 --body "R&D"', "gh pr comment 1 --body 'a; b'",
            )
            for command in closeout_allowed:
                assert bridge.closeout_command_allowed(command), command
                assert not any(claude_rule_matches(rule, command) for rule in closeout_rules), command
            for command in ("git push origin feat/x-fix", "git push origin HEAD 2>&1"):
                assert not any(claude_rule_matches(rule, command) for rule in closeout_rules), command
            for command in ("git push origin HEAD & git  reset --hard",
                            "git push origin HEAD $(git  reset --hard)",
                            "git push origin `git rev-parse HEAD`"):
                assert not bridge.closeout_command_allowed(command), command

        with case("success_stderr_warning"):
            run_case(root, "success_stderr_warning", 0)

        full_req = None
        with case("success_full_bypass_argv"):
            full_req, _ = run_case(root, "success_full", 0, full=True)
            argv = pathlib.Path(str(full_req)[:-len(".request.json")] + ".argv").read_bytes().split(b"\0")
            assert b"bypassPermissions" in argv and b"--permission-prompt-tool" not in argv

        with case("review_tools_only"):
            review_req, review_data = run_case(root, "success_review", 0, review=True)
            review_stem = pathlib.Path(str(review_req)[:-len(".request.json")])
            review_argv = review_stem.with_suffix(".argv").read_bytes().split(b"\0")
            review_settings = json.loads(review_stem.with_suffix(".settings.json").read_text())
            review_meta = json.loads(review_stem.with_suffix(".claude.json").read_text())
            assert b"--no-session-persistence" in review_argv and b"--tools" in review_argv and b"Read,Glob,Grep" in review_argv
            assert all(rule in review_settings["permissions"]["deny"] for rule in
                       ("Bash(*)", "Write(*)", "Edit(*)", "MultiEdit(*)", "NotebookEdit(*)"))
            assert review_meta["mcp_servers"] == ["foreman"]
            assert review_data[0]["_foreman"]["review_readonly"] == "tools_only"
            assert review_stem.with_suffix(".last.md").read_text() == "## 总体印象\n通过"
            assert "success_review" not in json.loads((root / "meta.json").read_text()).get("threads", {})
            review_mcp = review_stem.with_suffix(".review-test-mcp.json")
            review_mcp.write_text(json.dumps({"mcpServers": {"foreman": {"command": sys.executable,
                "args": [str(BRIDGE), "permission-server", "--run", str(review_stem)]}}}))
            review_rpc = Rpc(review_mcp)
            try:
                review_rpc.call("initialize", {})
                review_decision = review_rpc.approve("AskUserQuestion", {"questions": [{"question": "写吗？"}]})
            finally:
                review_rpc.close()
            assert review_decision["behavior"] == "deny"

        with case("resume_mismatch_no_ledger_write"):
            resume_req, _ = run_case(root, "success_resume", 0, session="resume-secret")
            argv = pathlib.Path(str(resume_req)[:-len(".request.json")] + ".argv").read_bytes().split(b"\0")
            assert b"--resume" in argv and b"resume-secret" in argv
            mismatch_req = request(root, "resume_mismatch", session="resume-secret")
            meta_path = root / "meta.json"
            before_meta = json.loads(meta_path.read_text())
            before_meta.setdefault("threads", {}).setdefault("resume_mismatch", {})["ref"] = "resume-secret"
            meta_path.write_text(json.dumps(before_meta))
            env = dict(os.environ, FOREMAN_SELFTEST="1", CLAUDE_BIN=str(HERE), CLAUDE_REPLAY_SCENARIO="resume_mismatch")
            mismatch = subprocess.run([sys.executable, str(BRIDGE), "run", str(mismatch_req)], env=env, timeout=20)
            assert mismatch.returncode == 3
            assert json.loads(meta_path.read_text())["threads"]["resume_mismatch"]["ref"] == "resume-secret"

        with case("full_access_strict_boolean"):
            for index, (marker, full_reason) in enumerate((("false", "用户原话"), (True, "   "), (None, "用户原话")), 1):
                invalid_req = request(root, f"full_invalid_{index}", full=marker, full_reason=full_reason)
                if marker is None:
                    invalid_value = json.loads(invalid_req.read_text())
                    del invalid_value["user_explicitly_approved_full_access"]
                    invalid_req.write_text(json.dumps(invalid_value, ensure_ascii=False))
                invalid_env = dict(os.environ, FOREMAN_SELFTEST="1", CLAUDE_BIN=str(HERE), CLAUDE_REPLAY_SCENARIO="success")
                invalid_proc = subprocess.run([sys.executable, str(BRIDGE), "run", str(invalid_req)], env=invalid_env, timeout=20)
                assert invalid_proc.returncode == 3
                invalid_events = events(pathlib.Path(str(invalid_req)[:-len(".request.json")] + ".jsonl"))
                assert invalid_events[0]["_foreman"]["permission_mode"] == "auto"
                assert invalid_events[-1]["_foreman"]["rc"] == 3

        with case("signal"):
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

        with case("signal_ignore_hard_deadline"):
            ignore_req = request(root, "signal_ignore")
            ignore_env = dict(os.environ, FOREMAN_SELFTEST="1", CLAUDE_BIN=str(HERE),
                              CLAUDE_REPLAY_SCENARIO="signal_ignore", FOREMAN_CLAUDE_INTERRUPT_GRACE="0.5")
            ignore_proc = subprocess.Popen([sys.executable, str(BRIDGE), "run", str(ignore_req)], env=ignore_env)
            ignore_log = pathlib.Path(str(ignore_req)[:-len(".request.json")] + ".jsonl")
            for _ in range(100):
                if ignore_log.exists() and b'"type": "system"' in ignore_log.read_bytes():
                    break
                time.sleep(0.02)
            started = time.monotonic()
            ignore_proc.terminate()
            assert ignore_proc.wait(timeout=5) == 143 and time.monotonic() - started < 5
            ignore_data = events(ignore_log)
            assert ignore_data[-1]["_foreman"]["rc"] == 143
            assert pathlib.Path(str(ignore_req)[:-len(".request.json")] + ".rc").read_text().strip() == "143"
            assert not pathlib.Path(str(ignore_req)[:-len(".request.json")] + ".mcp.json").exists()

        with case("startup_signal"):
            startup_req = request(root, "startup_signal")
            startup_env = dict(os.environ, FOREMAN_SELFTEST="1", CLAUDE_BIN=str(HERE),
                               CLAUDE_REPLAY_SCENARIO="success", FOREMAN_CLAUDE_STARTUP_DELAY="1")
            startup_proc = subprocess.Popen([sys.executable, str(BRIDGE), "run", str(startup_req)], env=startup_env)
            startup_log = pathlib.Path(str(startup_req)[:-len(".request.json")] + ".jsonl")
            for _ in range(100):
                if startup_log.exists():
                    break
                time.sleep(0.01)
            startup_proc.terminate()
            assert startup_proc.wait(timeout=5) == 143
            startup_stem = str(startup_req)[:-len(".request.json")]
            startup_data = events(startup_log)
            startup_meta = json.loads((root / "meta.json").read_text())
            assert startup_data[-1]["_foreman"]["rc"] == 143
            assert pathlib.Path(startup_stem + ".rc").read_text().strip() == "143"
            assert not pathlib.Path(startup_stem + ".mcp.json").exists()
            assert "ref" not in startup_meta.get("threads", {}).get("startup_signal", {})
            assert not pathlib.Path(startup_stem + ".argv").exists()

        with case("startup_pre_popen_signal"):
            pre_popen_req = request(root, "startup_pre_popen")
            pre_popen_env = dict(os.environ, FOREMAN_SELFTEST="1", CLAUDE_BIN=str(HERE),
                                 CLAUDE_REPLAY_SCENARIO="success", FOREMAN_CLAUDE_STARTUP_DELAY="1",
                                 FOREMAN_CLAUDE_STARTUP_DELAY_STAGE="pre_popen")
            pre_popen_proc = subprocess.Popen([sys.executable, str(BRIDGE), "run", str(pre_popen_req)],
                                              env=pre_popen_env)
            pre_popen_stem = str(pre_popen_req)[:-len(".request.json")]
            pre_popen_argv = pathlib.Path(pre_popen_stem + ".argv")
            for _ in range(200):
                if pre_popen_argv.exists():
                    break
                time.sleep(0.01)
            assert pre_popen_argv.exists()
            pre_popen_proc.terminate()
            assert pre_popen_proc.wait(timeout=5) == 143
            pre_popen_data = events(pathlib.Path(pre_popen_stem + ".jsonl"))
            pre_popen_meta = json.loads((root / "meta.json").read_text())
            assert pre_popen_data[-1]["_foreman"]["rc"] == 143
            assert pathlib.Path(pre_popen_stem + ".rc").read_text().strip() == "143"
            assert not pathlib.Path(pre_popen_stem + ".fake-started").exists()
            assert not pathlib.Path(pre_popen_stem + ".mcp.json").exists()
            assert "ref" not in pre_popen_meta.get("threads", {}).get("startup_pre_popen", {})

        with case("full_access"):
            # 纯函数级配置守卫也放进同一回放入口，避免依赖真实 CLI。
            settings = json.loads(pathlib.Path(str(full_req)[:-len(".request.json")] + ".settings.json").read_text())
            assert settings["sandbox"]["enabled"] is False

    if failed:
        print(f"claude replay: {len(failed)} case(s) FAILED: {', '.join(failed)}")
        return 1
    print("claude replay: ALL PASS")
    return 0


if __name__ == "__main__":
    if "--codex-snapshot" in sys.argv:
        index = sys.argv.index("--codex-snapshot")
        raise SystemExit(snapshot_command(sys.argv[index + 1:]))
    if "--selftest" in sys.argv:
        raise SystemExit(selftest())
    raise SystemExit(fake_claude(sys.argv[1:]))
