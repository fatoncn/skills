#!/usr/bin/env python3
"""foreman · codex 执行体（`codex app-server` JSON-RPC over stdio）

用法:
  codex_appserver.py run <request.json>
  codex_appserver.py serve <hold-dir>     常驻占着一条线程：队列里来一轮跑一轮，release 文件出现才退出
  codex_appserver.py probe [--home DIR] [--codex BIN]

`run` 读一份由 foreman.sh 生成的 request.json，起一个 `codex app-server --listen stdio://`，
新建或续接线程，发一轮 turn，把全部协议消息原样落到 jsonl，处理服务端请求
（审批按策略、执行者的提问转给编排者），turn 结束后写 last.md 并把 thread_id 记进 meta.json。

这里不做任何「对不对」的判断——判断在 SKILL.md 里由编排者做。
协议实测笔记见 references/codex-app-server.md；request.json 字段表也在那里。

退出码: 0 = turn 正常完成; 1 = turn failed; 2 = 被中断（turn/interrupt 生效）;
        3 = 启动 / 协议阶段失败（没跑起来）; 4 = 执行器不可用; 5 = 线程被别的客户端占着（shared home 下桌面端打开了它）; 143 = 被 SIGTERM 杀且未能优雅中断。
"""
from __future__ import annotations

import json
import fcntl
from functools import lru_cache
from contextlib import contextmanager
from pathlib import Path
import uuid
import re
import os
import queue
import signal
import subprocess
import sys
import threading
import time

CLIENT_NAME = "foreman"
CLIENT_VERSION = "1.0.0"

# 这些增量通知只对实时 UI 有用，全落盘会把 jsonl 撑到几十 MB。opt-out 后 item/completed 仍然会到，
# 汇总只认 completed 级事件（summarize.py），不受影响。
OPT_OUT_NOTIFICATIONS = [
    "item/agentMessage/delta",
    "item/plan/delta",
    "item/reasoning/summaryTextDelta",
    "item/reasoning/textDelta",
    "item/reasoning/summaryPartAdded",
    "item/commandExecution/outputDelta",
    "item/fileChange/outputDelta",
    "item/fileChange/patchUpdated",
    "command/exec/outputDelta",
    "process/outputDelta",
    "turn/diff/updated",
    "account/rateLimits/updated",
    "thread/realtime/transcript/delta",
    "thread/realtime/outputAudio/delta",
    "thread/realtime/item/transcript/delta",
]

DEFAULT_CANNED_ANSWER = (
    "编排者当前不在线，无法实时回答。请按你最合理的理解把能做的部分做完，"
    "不要在关键取舍上猜着做；把这个问题原文写进交付报告的「需要澄清」一节，"
    "STATUS 按实际情况用 PARTIAL 或 BLOCKED。"
)

START_TIMEOUT = 180       # initialize / thread.start / turn.start 的响应上限（秒）
INTERRUPT_GRACE = 20      # 收到 SIGTERM 后等 turn/interrupt；shell HOLD_TERM_GRACE 必须至少比这里多 5 秒
QUESTION_POLL = 2         # 等编排者回答时的轮询间隔（秒）


def now_ms() -> int:
    return int(time.time() * 1000)


# 执行器不可用的判别（服务端 404 / 5xx / 连不上 / 额度用尽 / 登录失效）：这类不是任务失败，是 engine 暂时用不了。
# 编排者的处理只有一种：告知用户该执行器暂时不可用并附原始报错，不自行排障（用户 2026-09-11）。
_UNAVAILABLE_PATTERNS = [
    ("quota", re.compile(r"\b429\b|usage limit|rate limit|quota|too many requests", re.I)),
    ("auth", re.compile(r"\b401\b|\b403\b|unauthorized|forbidden|not logged in|login|token expired|refresh token", re.I)),
    ("server", re.compile(r"\b404\b|\b5\d\d\b|bad gateway|service unavailable|gateway time-?out|internal server error|"
                          r"server had an error|stream disconnected|connection (refused|reset|closed)|failed to connect|"
                          r"econnrefused|econnreset|network (error|unreachable)|timed? ?out|dns|tls handshake|ssl|"
                          r"没有响应|时退出|进行中退出", re.I)),
]

def classify_unavailable(text) -> str | None:
    """返回 'server' / 'quota' / 'auth'，不像不可用就返回 None。"""
    if not text:
        return None
    blob = text if isinstance(text, str) else json.dumps(text, ensure_ascii=False)
    for kind, pat in _UNAVAILABLE_PATTERNS:
        if pat.search(blob):
            return kind
    return None

_UNAVAILABLE_HINT = {
    "server": "codex 服务端不可用（404 / 5xx / 连接失败）",
    "quota": "codex 额度或限流（429 / usage limit）",
    "auth": "codex 登录失效（401 / 403）",
}

class ProtocolError(RuntimeError):
    pass


REQUEST_INPUT_FEATURE = "default_mode_request_user_input"
REQUEST_INPUT_KEY = "features." + REQUEST_INPUT_FEATURE


@lru_cache(maxsize=None)
def request_input_feature(codex_bin, home, cwd):
    """同一执行体只探测一次；缺失或探测失败都不阻止 app-server 启动。"""
    try:
        result = subprocess.run([codex_bin, "features", "list"], cwd=cwd,
                                env={**os.environ, "CODEX_HOME": home}, capture_output=True,
                                text=True, timeout=15)
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                match = re.fullmatch(re.escape(REQUEST_INPUT_FEATURE) + r"\s+(.+?)\s+(true|false)\s*", line.strip())
                if match:
                    return {"present": True, "stage": match[1], "value": match[2]}
        reason = "not_listed" if result.returncode == 0 else f"probe_exit_{result.returncode}"
    except (OSError, subprocess.SubprocessError) as exc:
        reason = type(exc).__name__
    return {"present": False, "stage": "未列出", "value": "未知", "reason": reason}


def feature_report(feature, requested="true"):
    carried = "是" if feature["present"] else "否"
    effective = requested if feature["present"] else "不传"
    return (f"功能位 {REQUEST_INPUT_FEATURE}: 阶段={feature['stage']}  当前生效值（CLI配置）={feature['value']}  "
            f"执行体会否按进程带上={carried}  执行体进程值={effective}")


class AppServer:
    """一个 app-server 子进程 + 一条 JSON-RPC 连接。所有进出消息都追加到 log_path。"""

    def __init__(self, codex_bin: str, home: str, cwd: str, overrides: list[tuple[str, str]],
                 log_path: str, stderr_path: str):
        env = dict(os.environ)
        env["CODEX_HOME"] = home
        args = [codex_bin, "app-server", "--listen", "stdio://"]
        # Default 模式的提问工具默认关闭；由执行体显式开启，不依赖用户级 config.toml。
        # 项目 request_user_input=false 通过 overrides 覆盖默认值；警告只在本进程抑制。
        feature = request_input_feature(codex_bin, home, cwd)
        process_overrides = dict(overrides)
        if feature["present"]:
            process_overrides.setdefault(REQUEST_INPUT_KEY, "true")
            process_overrides.setdefault("suppress_unstable_features_warning", "true")
        else:
            process_overrides.pop(REQUEST_INPUT_KEY, None)
        for key, value in process_overrides.items():
            args += ["-c", f"{key}={value}"]
        self._stderr = open(stderr_path, "ab")
        self.proc = subprocess.Popen(
            args, cwd=cwd, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self._stderr,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
        )
        self._log = open(log_path, "a", encoding="utf-8")
        if not feature["present"]:
            self.log_event({"_fleet": "feature_missing", "feature": REQUEST_INPUT_FEATURE,
                            "reason": feature["reason"], "at": now_ms()})
        self._q: "queue.Queue[dict | None]" = queue.Queue()
        self._next_id = 1
        self._pending: dict[int, dict] = {}
        self._orphan_diagnostics = 0
        self._reader = threading.Thread(target=self._read_loop, daemon=True)
        self._reader.start()
        self.on_server_request = None   # callable(msg) -> None（必须自己 respond）
        self.on_notification = None     # callable(msg) -> None

    # ---- 底层 IO ----
    def _read_loop(self):
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                self.log_event({"_fleet": "raw_stdout", "line": line[:2000]})
                continue
            self._q.put(msg)
        self._q.put(None)

    def set_log(self, path: str):
        """常驻（hold）模式下每轮切到那一轮的 jsonl，轮间回到 hold.jsonl。"""
        self._log.close()
        self._log = open(path, "a", encoding="utf-8")

    def log_event(self, obj: dict):
        stamped = dict(obj)
        stamped.setdefault("_at", now_ms())
        self._log.write(json.dumps(stamped, ensure_ascii=False) + "\n")
        self._log.flush()

    def _write(self, obj: dict):
        assert self.proc.stdin is not None
        self.log_event({"_fleet": "out", **obj})
        self.proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
        self.proc.stdin.flush()

    def notify(self, method: str, params: dict | None = None):
        self._write({"jsonrpc": "2.0", "method": method, "params": params or {}})

    def respond(self, req_id, result=None, error: dict | None = None):
        msg = {"jsonrpc": "2.0", "id": req_id}
        if error is not None:
            msg["error"] = error
        else:
            msg["result"] = result if result is not None else {}
        self._write(msg)

    def request(self, method: str, params: dict | None, timeout: float) -> dict:
        """发请求并阻塞等它的响应；等待期间照常分发其它消息。"""
        req_id = self._next_id
        self._next_id += 1
        slot = {"response": None}
        self._pending[req_id] = slot
        deadline = time.time() + timeout
        try:
            self._write({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}})
            while slot["response"] is None:
                remaining = deadline - time.time()
                if remaining <= 0:
                    raise ProtocolError(f"{method} 在 {timeout}s 内没有响应")
                msg = self.next_message(timeout=remaining)
                if msg is None:
                    raise ProtocolError(f"app-server 在等待 {method} 响应时退出（stdout 关闭）")
                self.dispatch(msg)
            response = slot["response"]
            if "error" in response:
                raise ProtocolError(f"{method} 出错: {json.dumps(response['error'], ensure_ascii=False)[:800]}")
            return response.get("result") or {}
        finally:
            self._pending.pop(req_id, None)

    def next_message(self, timeout: float | None):
        """取下一条消息（已落盘）。None = 连接关闭。"""
        try:
            msg = self._q.get(timeout=timeout)
        except queue.Empty:
            return {}
        if msg is None:
            return None
        self.log_event(msg)
        return msg

    def dispatch(self, msg: dict):
        if not msg:
            return
        if "id" in msg and "method" not in msg:
            slot = self._pending.get(msg.get("id"))
            reason = None
            if slot is None:
                reason = "unknown_id"
            elif slot["response"] is not None:
                reason = "duplicate_response"
            else:
                slot["response"] = msg
            if reason:
                # 不缓存孤儿响应；最多落 32 条明细，随后只落一次抑制标记。
                self._orphan_diagnostics += 1
                if self._orphan_diagnostics <= 32:
                    self.log_event({"_fleet": "orphan_response", "id": msg.get("id"), "reason": reason})
                elif self._orphan_diagnostics == 33:
                    self.log_event({"_fleet": "orphan_response_suppressed", "limit": 32})
        elif "method" in msg and "id" in msg:
            if self.on_server_request:
                self.on_server_request(msg)
            else:
                self.respond(msg["id"], error={"code": -32601, "message": "foreman: no handler"})
        elif "method" in msg:
            if self.on_notification:
                self.on_notification(msg)

    def close(self, grace: float = 5.0):
        try:
            if self.proc.stdin:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                self.proc.kill()
        self._log.close()
        self._stderr.close()


# ---------- steer：文件通道与轮次账本（同一票的写入共用短锁） ----------

@contextmanager
def runs_lock(issue_dir):
    with open(Path(issue_dir) / ".runs.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def write_json(path, value):
    """只发布完整的状态文件；源码文件的修改仍原地写入。"""
    path = Path(path)
    tmp = path.with_name(path.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def run_numbers(directory):
    return sorted({int(m[1]) for p in Path(directory).glob("run-*.*")
                   if (m := re.fullmatch(r"run-(\d+)\..+", p.name))})


def position_parts(prompt):
    # 当前脚本的位置块包含空行，必须跨过整个生成块，不能只删标题行。
    if prompt.startswith("# 本轮位置"):
        head, sep, body = prompt.partition("\n---\n")
        if sep:
            return head + sep + "\n", body[1:] if body.startswith("\n") else body
        head, sep, body = prompt.partition("\n\n")
        return head + sep, body
    return "", prompt


def template_for(directory, n):
    prefix = Path(directory) / f"run-{n}"
    req = json.loads(Path(str(prefix) + ".request.json").read_text(encoding="utf-8"))
    fields = {}
    for suffix in ("role", "pr", "cwd", "timeout", "rmwt", "engine", "home", "dev.md", "full-access"):
        path = Path(str(prefix) + "." + suffix)
        if path.is_file():
            fields[suffix] = path.read_text(encoding="utf-8")
    return {"request": req, "files": fields}


def original_prompt(directory, n, template):
    source = template["request"].get("prompt_source")
    if source:
        try:
            return Path(source).read_text(encoding="utf-8")
        except OSError:
            pass
    path = Path(directory) / f"run-{n}.prompt.md"
    if path.is_file():
        return position_parts(path.read_text(encoding="utf-8"))[1]
    raise ValueError("原任务书和 run-N.prompt.md 都不可读，不能转引导")


def enqueue_steer(directory, tname, message):
    """调用者持有 runs_lock；沿用原轮次执行配置，建齐新轮次再发布队列。"""
    directory = Path(directory)
    pr = message["template"]["files"].get("pr", "")
    # 转排队也遵守 run 的同 PR 单执行者守卫；业务拒绝保留到 failed 回执。
    for mark in list(directory.glob("run-*.pr")) + list(directory.glob("review-*.pr")):
        prefix = str(mark)[:-3]
        if mark.read_text() != pr or Path(prefix + ".rc").exists():
            continue
        thread_file = Path(prefix + ".thread")
        other = thread_file.read_text() if thread_file.exists() else Path(prefix).name
        if other == tname:
            continue
        try:
            os.kill(int(Path(prefix + ".pid").read_text()), 0)
        except (OSError, ValueError):
            continue
        raise ValueError(f"PR「{pr}」上线程 '{other}' 仍在跑：同一 PR 同时只准一条线程；引导保留，请等它结束再重发")
    n = max(run_numbers(directory), default=0) + 1
    prefix = directory / f"run-{n}"
    req = dict(message["template"]["request"])
    files = dict(message["template"]["files"])
    header, _ = position_parts(req["prompt"])
    req["prompt"] = header + message["text"]
    req["prompt_source"] = str(prefix) + ".source.md"
    req["title"] = "引导转排队"
    for key, suffix in (("out_jsonl", "jsonl"), ("out_stderr", "stderr"), ("out_last", "last.md"),
                        ("out_rc", "rc"), ("questions_path", "questions.json"), ("answer_path", "answer.json")):
        req[key] = str(prefix) + "." + suffix
    files.update({"thread": tname, "engine": "codex", "prompt.md": req["prompt"],
                  "source.md": message["text"], "started": str(int(time.time())),
                  "timeout": str(req.get("timeout") or 1800)})
    hd = directory / f"hold-{tname}"
    pid = hd / "bridge.pid"
    if pid.is_file():
        files["pid"] = pid.read_text()
    event = {"_fleet": "steer_requeued", "text": message["text"], "at": message["at"],
             "fromRun": message.get("fromRun"), "run": n, "title": "引导转排队"}
    files["jsonl"] = json.dumps(event, ensure_ascii=False) + "\n"
    if files.get("role") in ("review", "accept", "research") and req.get("work_dir"):
        before = subprocess.run(["git", "-C", req["work_dir"], "status", "--porcelain"],
                                capture_output=True, text=True, check=True)
        files["wt-before"] = before.stdout
    for suffix, text in files.items():
        Path(str(prefix) + "." + suffix).write_text(text, encoding="utf-8")
    # argv 的契约是执行器 argv（NUL 分隔），并不是原 foreman 命令。
    Path(str(prefix) + ".argv").write_bytes(("\0".join(
        ["python3", str(Path(__file__).resolve()), "run", str(prefix) + ".request.json"]) + "\0").encode())
    write_json(str(prefix) + ".request.json", req)
    meta_path = directory / "meta.json"
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    meta["threads"][tname].setdefault("runs", []).append(f"run-{n}")
    write_json(meta_path, meta)
    (hd / "queue").mkdir(parents=True, exist_ok=True)
    write_json(hd / "queue" / f"run-{n}.request.json", req)
    return event


def submit_steer(directory, tname, text, source_file, from_run):
    directory = Path(directory)
    hd = directory / f"hold-{tname}"
    with runs_lock(directory):
        candidates = [n for n in run_numbers(directory)
                      if (directory / f"run-{n}.thread").is_file()
                      and (directory / f"run-{n}.thread").read_text() == tname
                      and (directory / f"run-{n}.request.json").is_file()]
        if from_run is not None and not (hd / "queue" / f"run-{from_run}.request.json").is_file():
            raise ValueError(f"run #{from_run} 已不在 queue：它已经在跑，本来就是你要的效果；另有纠偏用 steer <文本>")
        if not candidates or (from_run is not None and from_run not in candidates):
            raise ValueError("没有可续接的 codex 线程，用 run 起新一轮")
        active = {}
        try:
            active = json.loads((hd / "active.json").read_text(encoding="utf-8"))
        except FileNotFoundError:
            pass
        active_name = active.get("run", "")
        active_n = int(active_name[4:]) if re.fullmatch(r"run-\d+", active_name) else None
        template_n = from_run if from_run is not None else (active_n if active_n in candidates else candidates[-1])
        template = template_for(directory, template_n)
        if template["files"].get("engine", "codex") != "codex":
            raise ValueError("steer 只支持 codex app-server 线程，用 run 起新一轮")
        if from_run is not None:
            text = original_prompt(directory, from_run, template)
        elif source_file:
            text = Path(source_file).read_text(encoding="utf-8")
        if not text or not text.strip():
            raise ValueError("steer: 引导消息不能为空")
        message = {"text": text, "at": now_ms(), "fromRun": from_run, "template": template,
                   "expectedTurnId": active.get("turnId")}
        inbox = hd / "steer"
        inbox.mkdir(parents=True, exist_ok=True)
        path = inbox / f"{time.time_ns()}-{uuid.uuid4().hex}.json"
        write_json(path, message)
        if from_run is not None:
            # Holder 取队列也持有同一把锁；检查到删除之间不会被拿起。
            (hd / "queue" / f"run-{from_run}.request.json").unlink()
            for old in directory.glob(f"run-{from_run}.*"):
                old.unlink()
            meta_path = directory / "meta.json"
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            runs = meta["threads"][tname].get("runs", [])
            meta["threads"][tname]["runs"] = [r for r in runs if r != f"run-{from_run}"]
            write_json(meta_path, meta)
    return str(path)


def steer_result(path):
    path = Path(path)
    for state in ("sent", "failed"):
        ack = path.parent / state / path.name
        if ack.exists():
            result = json.loads(ack.read_text(encoding="utf-8"))
            if state == "failed":
                print("引导失败：" + result["error"], file=sys.stderr)
                return 1
            if result.get("_fleet") == "steer_requeued":
                print(f"turn 已结束，这条消息已转为 run #{result['run']} 排队")
            else:
                print(f"已注入 turn {result['turnId']}")
            return 0
    return None


# ---------- run ----------

class Runner:
    def __init__(self, req: dict):
        self.req = req
        self.thread_id: str | None = req.get("thread_id") or None
        self.turn_id: str | None = None
        self.turn_status: str | None = None
        self.turn_error: dict | None = None
        self.final_text = ""
        self.final_phase = None
        self.token_usage = None
        self.declined = 0
        self.questions_asked = 0
        self.interrupt_requested = False
        self.interrupt_sent = False
        self.started = now_ms()
        self.server: AppServer | None = None
        self.deadline: float | None = None   # hold 模式下这一轮的绝对截止（秒）
        self.timed_out = False
        self.boot_info: dict = {}
        self.consume_steers = lambda: None
        self.on_turn_started = lambda: None

    # ---- 服务端请求 ----
    def handle_server_request(self, msg: dict):
        method = msg["method"]
        params = msg.get("params") or {}
        rid = msg["id"]
        policy = self.req.get("approvals", "decline")
        accept = policy == "accept"
        srv = self.server
        assert srv is not None

        if method == "item/commandExecution/requestApproval":
            decision = "accept" if accept else "decline"
            if not accept:
                self.declined += 1
            srv.log_event({"_fleet": "approval", "kind": "command", "decision": decision,
                           "command": params.get("command"), "reason": params.get("reason")})
            srv.respond(rid, {"decision": decision})
        elif method == "item/fileChange/requestApproval":
            decision = "accept" if accept else "decline"
            if not accept:
                self.declined += 1
            srv.log_event({"_fleet": "approval", "kind": "fileChange", "decision": decision,
                           "reason": params.get("reason"), "grantRoot": params.get("grantRoot")})
            srv.respond(rid, {"decision": decision})
        elif method in ("execCommandApproval", "applyPatchApproval"):
            decision = "approved" if accept else "denied"
            if not accept:
                self.declined += 1
            srv.log_event({"_fleet": "approval", "kind": method, "decision": decision,
                           "command": params.get("command"), "reason": params.get("reason")})
            srv.respond(rid, {"decision": decision})
        elif method == "item/tool/requestUserInput":
            self.handle_questions(rid, params)
        elif method == "mcpServer/elicitation/request":
            srv.log_event({"_fleet": "approval", "kind": "elicitation", "decision": "decline"})
            srv.respond(rid, {"action": "decline"})
        else:
            # item/permissions/requestApproval、item/tool/call、attestation 等：不支持就明确报错，
            # 让模型把它当成失败的工具调用继续，而不是挂着等。
            srv.log_event({"_fleet": "approval", "kind": method, "decision": "unsupported"})
            srv.respond(rid, error={"code": -32601, "message": f"foreman: 不处理 {method}（按策略拒绝）"})

    def handle_questions(self, rid, params: dict):
        """执行者向编排者提问：落 questions 文件，等 answer 文件；超时给兜底答复。"""
        srv = self.server
        assert srv is not None
        questions = params.get("questions") or []
        self.questions_asked += len(questions) or 1
        qpath = self.req.get("questions_path")
        apath = self.req.get("answer_path")
        timeout = int(self.req.get("question_timeout") or 0)
        canned = self.req.get("canned_answer") or DEFAULT_CANNED_ANSWER
        record = {"askedAt": now_ms(), "itemId": params.get("itemId"), "isBlocking": params.get("isBlocking"),
                  "questions": questions, "timeoutSeconds": timeout}
        if qpath:
            with open(qpath, "w", encoding="utf-8") as fh:
                json.dump(record, fh, ensure_ascii=False, indent=2)
        srv.log_event({"_fleet": "question", **record})

        answers_by_id: dict[str, list[str]] = {}
        answered = False
        if apath and timeout > 0:
            deadline = time.time() + timeout
            while time.time() < deadline and not self.interrupt_requested:
                self.consume_steers()
                if os.path.exists(apath):
                    try:
                        with open(apath, encoding="utf-8") as fh:
                            given = json.load(fh)
                    except Exception:
                        given = {}
                    if isinstance(given, dict):
                        if isinstance(given.get("answers"), dict):
                            for qid, val in given["answers"].items():
                                answers_by_id[qid] = val if isinstance(val, list) else [str(val)]
                        if "all" in given:
                            for q in questions:
                                answers_by_id.setdefault(q.get("id", ""), [str(given["all"])])
                    answered = bool(answers_by_id)
                    try:
                        os.replace(apath, apath + ".consumed")
                    except OSError:
                        pass
                    break
                time.sleep(QUESTION_POLL)
        if not answered:
            for q in questions:
                answers_by_id[q.get("id", "")] = [canned]
            if not questions:
                answers_by_id[""] = [canned]
        srv.log_event({"_fleet": "answer", "answered": answered, "answers": answers_by_id})
        if qpath and os.path.exists(qpath):
            try:
                os.replace(qpath, qpath.replace(".questions.json", ".questions.answered.json"))
            except OSError:
                pass
        srv.respond(rid, {"answers": {qid: {"answers": vals} for qid, vals in answers_by_id.items()}})

    # ---- 通知 ----
    def handle_notification(self, msg: dict):
        method = msg.get("method")
        params = msg.get("params") or {}
        if method == "turn/completed":
            turn = params.get("turn") or {}
            if self.turn_id is None or turn.get("id") == self.turn_id:
                self.turn_status = turn.get("status")
                self.turn_error = turn.get("error")
        elif method == "item/completed":
            item = params.get("item") or {}
            if item.get("type") == "agentMessage":
                text = (item.get("text") or "").strip()
                phase = item.get("phase")
                if text:
                    # final_answer 优先；否则取最后一条
                    if phase == "final_answer" or self.final_phase != "final_answer":
                        self.final_text = text
                        self.final_phase = phase
        elif method == "thread/tokenUsage/updated":
            self.token_usage = params.get("tokenUsage")
        elif method == "error":
            err = params.get("error") or {}
            if not params.get("willRetry"):
                self.turn_error = self.turn_error or err

    # ---- 主流程 ----
    # ---- 主流程：boot（起 app-server + 载入线程，持有写锁）→ turn（跑一轮）----
    def boot(self):
        req = self.req
        srv = AppServer(
            codex_bin=req["codex_bin"], home=req["home"], cwd=req["cwd"],
            overrides=[tuple(x) for x in req.get("config_overrides", [])],
            log_path=req["out_jsonl"], stderr_path=req["out_stderr"],
        )
        self.server = srv
        srv.on_server_request = self.handle_server_request
        srv.on_notification = self.handle_notification

        srv = self.server
        req = self.req
        srv.request("initialize", {
            "clientInfo": {"name": CLIENT_NAME, "title": "foreman", "version": CLIENT_VERSION},
            "capabilities": {"experimentalApi": True, "optOutNotificationMethods": OPT_OUT_NOTIFICATIONS},
        }, timeout=START_TIMEOUT)
        srv.notify("initialized")

        sandbox = req.get("sandbox", "workspace-write")
        # 硬规矩（用户 2026-09-11）：分工默认禁止「完全权限」；唯一口子是用户明确要求，由 foreman run --full-access
        # 带上原话生成 user_explicitly_approved_full_access=true。没这个标记的 danger-full-access 一律拒绝。
        if sandbox == "danger-full-access":
            if not req.get("user_explicitly_approved_full_access"):
                raise ProtocolError("sandbox=danger-full-access 被拒绝：只有用户明确要求（foreman run --full-access \"<原话>\"）才允许")
            srv.log_event({"_fleet": "full_access", "reason": req.get("full_access_reason") or "(未记录原话)"})
        elif sandbox not in ("workspace-write", "read-only"):
            raise ProtocolError(f"sandbox={sandbox!r} 不认识：只允许 workspace-write / read-only，或用户明确要求的 danger-full-access")
        common = {
            "cwd": req["cwd"],
            "sandbox": sandbox,
            # 默认「替我审批」：模型可以按需请求审批（on-request），请求交给 Codex 自动审查（auto_review），
            # 自动审查不接的才回到本执行体，按 approvals 兜底（默认 decline）。完全权限档 approvalPolicy=never。
            "approvalPolicy": req.get("approval_policy") or "on-request",
            "developerInstructions": req.get("developer_instructions") or None,
            "model": req.get("model") or None,
        }
        if req.get("approvals_reviewer"):
            common["approvalsReviewer"] = req["approvals_reviewer"]
        if self.thread_id:
            resp = srv.request("thread/resume", {"threadId": self.thread_id, "excludeTurns": True, **common},
                               timeout=START_TIMEOUT)
        else:
            resp = srv.request("thread/start", {"ephemeral": bool(req.get("ephemeral")), **common},
                               timeout=START_TIMEOUT)
        thread = resp.get("thread") or {}
        self.thread_id = thread.get("id") or self.thread_id
        # 线程命名：按本机 config.toml 的 codex.thread_name 模板拼好传进来；失败不阻塞
        name = req.get("thread_name")
        # ephemeral 线程（复审）不支持 metadata 更新（实测 -32600 "ephemeral thread does not
        # support metadata updates"），命名直接跳过，不再每次留一条 thread_name_error。
        if name and self.thread_id and not bool(req.get("ephemeral")):
            try:
                srv.request("thread/name/set", {"threadId": self.thread_id, "name": name}, timeout=30)
                srv.log_event({"_fleet": "thread_name", "name": name})
            except ProtocolError as exc:
                srv.log_event({"_fleet": "thread_name_error", "error": str(exc)})
        if not self.thread_id:
            raise ProtocolError("thread/start 没有返回 thread.id")
        self.write_meta()
        self.boot_info = {"_fleet": "thread", "threadId": self.thread_id,
                          "model": resp.get("model"), "reasoningEffort": resp.get("reasoningEffort"),
                          "sandbox": resp.get("sandbox"), "cwd": resp.get("cwd"),
                          "instructionSources": resp.get("instructionSources")}
        srv.log_event({**self.boot_info, "workDir": req.get("work_dir") or None})

        return srv

    def turn(self) -> int:
        srv = self.server
        req = self.req
        assert srv is not None
        turn_params = {
            "threadId": self.thread_id,
            "input": [{"type": "text", "text": req["prompt"]}],
        }
        if req.get("effort"):
            turn_params["effort"] = req["effort"]
        # 只在显式要求时才传 turn 级 sandboxPolicy。0.153.4 实测：带上它，git 写 worktree gitdir 的
        # index.lock / HEAD.lock 一律 EPERM，且那些命令不产生 commandExecution 事件。默认靠 thread 级
        # sandbox 模式 + 进程级 -c（writable_roots / network_access），与 codex exec 一致、实测可提交。
        if req.get("sandbox_policy") and req.get("force_turn_sandbox_policy"):
            turn_params["sandboxPolicy"] = req["sandbox_policy"]
        turn = srv.request("turn/start", turn_params, timeout=START_TIMEOUT)
        self.turn_id = (turn.get("turn") or {}).get("id")
        self.on_turn_started()

        # 主循环：直到我们这一轮 turn/completed
        while self.turn_status is None:
            if self.deadline and not self.interrupt_requested and time.time() > self.deadline:
                self.interrupt_requested = True; self.timed_out = True
            if self.interrupt_requested and not self.interrupt_sent:
                self.interrupt_sent = True
                srv.log_event({"_fleet": "interrupt", "at": now_ms()})
                try:
                    srv.request("turn/interrupt", {"threadId": self.thread_id, "turnId": self.turn_id},
                                timeout=INTERRUPT_GRACE)
                except ProtocolError as exc:
                    srv.log_event({"_fleet": "interrupt_error", "error": str(exc)})
                deadline = time.time() + INTERRUPT_GRACE
                while self.turn_status is None and time.time() < deadline:
                    msg = srv.next_message(timeout=1.0)
                    if msg is None:
                        break
                    srv.dispatch(msg)
                break
            self.consume_steers()
            if self.turn_status is not None:
                break
            msg = srv.next_message(timeout=5.0)
            if msg is None:
                raise ProtocolError("app-server 在 turn 进行中退出")
            srv.dispatch(msg)

        if self.turn_status == "completed":
            rc = 0
        elif self.turn_status == "interrupted":
            rc = 2
        elif self.turn_status == "failed":
            rc = 1
            kind = classify_unavailable(self.turn_error)
            if kind:
                rc = 4
                self.mark_unavailable(srv, kind, self.turn_error)
        elif self.interrupt_requested:
            rc = 143
        else:
            rc = 1
        if self.timed_out:
            rc = 143
        return rc

    def _classify_failure(self, exc) -> int:
        srv = self.server
        assert srv is not None
        srv.log_event({"_fleet": "protocol_error", "error": str(exc)})
        sys.stderr.write(f"codex_appserver: {exc}\n")
        rc = 3 if self.turn_id is None else 1
        kind = classify_unavailable(str(exc))
        if kind:
            rc = 4
            self.mark_unavailable(srv, kind, str(exc))
        elif "active writer" in str(exc):
            # shared home：桌面端打开了这条线程就持有写锁，resume 被拒。不是任务失败，也不是执行器不可用。
            rc = 5
            hint = "这条线程正被别的客户端打开着（shared home 下多半是 Codex 桌面端），关掉它再续；急的话 foreman release 后 run --thread <新名> 另起并在 prompt 里补上下文"
            srv.log_event({"_fleet": "thread_busy", "hint": hint, "error": str(exc)})
            sys.stderr.write(f"codex_appserver: THREAD_BUSY {hint}\n")
        return rc

    def run(self) -> int:
        def on_term(signum, _frame):
            self.interrupt_requested = True
        signal.signal(signal.SIGTERM, on_term)
        signal.signal(signal.SIGINT, on_term)
        rc = 3
        try:
            self.boot()
            rc = self.turn()
        except ProtocolError as exc:
            rc = self._classify_failure(exc)
        finally:
            if self.server is not None:
                self.finish(rc)
                self.server.close()
        return rc

    def write_meta(self):
        path = self.req.get("meta_path")
        if not path or not self.thread_id:
            return
        with runs_lock(Path(path).parent):
            try:
                meta = json.load(open(path, encoding="utf-8"))
            except Exception:
                meta = {}
            key = self.req.get("meta_thread_key", "codex_thread")
            # 点路径（threads.<名>.ref）：票的账本里一条线程一条记录，引擎无关
            node = meta
            parts = key.split(".")
            for part in parts[:-1]:
                node = node.setdefault(part, {})
            node[parts[-1]] = self.thread_id
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(meta, fh, ensure_ascii=False, indent=2)

    def mark_unavailable(self, srv, kind: str, detail):
        msg = _UNAVAILABLE_HINT.get(kind, "codex 不可用")
        srv.log_event({"_fleet": "engine_unavailable", "kind": kind, "hint": msg, "error": detail})
        sys.stderr.write(f"codex_appserver: ENGINE_DOWN {msg}。告知用户该执行器暂时不可用，附原始报错；不要自行排障。\n")

    def finish(self, rc: int):
        srv = self.server
        assert srv is not None
        last = self.req.get("out_last")
        if last:
            with open(last, "w", encoding="utf-8") as fh:
                fh.write(self.final_text or "")
        srv.log_event({
            "_fleet": "turn_summary",
            "rc": rc,
            "status": self.turn_status or ("interrupted" if self.interrupt_requested else "unknown"),
            "threadId": self.thread_id,
            "turnId": self.turn_id,
            "error": self.turn_error,
            "tokenUsage": self.token_usage,
            "declinedApprovals": self.declined,
            "questions": self.questions_asked,
            "durationMs": now_ms() - self.started,
            "finalPhase": self.final_phase,
            "hasFinalText": bool(self.final_text),
        })


# ---------- hold：常驻占着线程，直到编排者 release ----------
#
# 用户 2026-09-11：foreman 管的线程要由编排脚本加锁，解锁由编排者明确结束工作时做。app-server 的写锁跟着「线程被哪个
# app-server 进程载入」走：每轮起一个进程、跑完就退，轮间锁就空了，桌面端一点开线程就把锁抢走（already has an active writer）。
# 所以改成：一条线程一个常驻执行体（serve），boot 一次载入线程后一直活着、持有写锁，每轮只是往队列里丢一个请求；
# `foreman release` / `cleanup` 落 release 文件才退出；空闲超过 idle_seconds 也退出（编排者会话没了不至于永久占着）。
class Holder:
    def __init__(self, hold_dir: str):
        self.dir = hold_dir
        with open(os.path.join(hold_dir, "hold.json"), encoding="utf-8") as fh:
            self.cfg = json.load(fh)
        self.queue_dir = os.path.join(hold_dir, "queue")
        os.makedirs(self.queue_dir, exist_ok=True)
        self.stop = False
        self.current: Runner | None = None

    def _queued(self) -> list[str]:
        try:
            names = sorted((n for n in os.listdir(self.queue_dir) if re.fullmatch(r"run-\d+\.request\.json", n)),
                           key=lambda n: int(n.split("-")[1].split(".")[0]))
        except FileNotFoundError:
            return []
        return [os.path.join(self.queue_dir, n) for n in names]

    def _claim(self, path: str):
        """与 shell 取消方共用 runs_lock；取消标记优先于领取。"""
        with runs_lock(Path(self.dir).parent):
            try:
                with open(path, encoding="utf-8") as fh:
                    req = json.load(fh)
                cancelled = Path(req["out_rc"]).with_suffix(".cancelled") if req.get("out_rc") else None
                if cancelled and cancelled.exists():
                    os.remove(path)
                    return None
                write_json(Path(self.dir) / "active.json",
                           {"run": Path(req["out_jsonl"]).stem, "turnId": None, "state": "claimed"})
                os.remove(path)
                return req
            except FileNotFoundError:
                return None

    def consume_steers(self, srv):
        inbox = Path(self.dir) / "steer"
        for path in sorted(inbox.glob("*.json")):
            processing = inbox / "processing" / path.name
            with runs_lock(Path(self.dir).parent):
                processing.parent.mkdir(exist_ok=True)
                try:
                    path.rename(processing)
                except FileNotFoundError:
                    continue
            message = {}
            try:
                message = json.loads(processing.read_text(encoding="utf-8"))
                r = self.current
                target = message.get("expectedTurnId")
                requeue = not r or r.turn_status is not None or not target or target != r.turn_id
                if not requeue:
                    try:
                        result = srv.request("turn/steer", {"threadId": r.thread_id,
                            "expectedTurnId": r.turn_id, "input": [{"type": "text", "text": message["text"]}]}, timeout=20)
                    except ProtocolError as exc:
                        # 仅明确的 turn 结束/前置条件失败可转排队；协议/鉴权等其它错误要可见。
                        if r.turn_status is not None or re.search(
                                r"expected active turn id|expected.?turn|turn.*mismatch|no active turn|not.*active turn|turn.*already.*(completed|finished)",
                                str(exc), re.I):
                            requeue = True
                        else:
                            raise
                if requeue:
                    with runs_lock(Path(self.dir).parent):
                        event = enqueue_steer(Path(self.dir).parent, Path(self.dir).name[5:], message)
                else:
                    event = {"_fleet": "steer", "text": message["text"], "at": message["at"],
                             "fromRun": message.get("fromRun"), "turnId": result["turnId"]}
                srv.log_event(event)
                destination = inbox / "sent" / path.name
            except (OSError, ValueError, KeyError, ProtocolError, subprocess.SubprocessError) as exc:
                event = {"_fleet": "steer_error", "text": message.get("text"), "at": message.get("at", now_ms()),
                         "fromRun": message.get("fromRun"), "error": str(exc)}
                srv.log_event(event)
                destination = inbox / "failed" / path.name
            destination.parent.mkdir(exist_ok=True)
            # 失败保留原始消息及模板，便于明确恢复；成功回执只留结果。
            write_json(destination, {**(message if event["_fleet"] == "steer_error" else {}), **event})
            processing.unlink()

    def _fail_queued(self, rc: int, note: str):
        # 把 hold.jsonl 里的失败事件（protocol_error / engine_unavailable / thread_busy）抄给每个排队轮次，report 据此出横幅
        events = []
        try:
            with open(os.path.join(self.dir, "hold.jsonl"), encoding="utf-8") as fh:
                for line in fh:
                    if any(k in line for k in ('"_fleet": "protocol_error"', '"_fleet": "engine_unavailable"', '"_fleet": "thread_busy"')):
                        events.append(line if line.endswith("\n") else line + "\n")
        except OSError:
            pass
        for path in self._queued():
            with runs_lock(Path(self.dir).parent):
                if not os.path.isfile(path):
                    continue
                try:
                    with open(path, encoding="utf-8") as fh:
                        req = json.load(fh)
                    if req.get("out_jsonl"):
                        with open(req["out_jsonl"], "a", encoding="utf-8") as fh:
                            fh.writelines(events)
                            fh.write(json.dumps({"_fleet": "turn_summary", "rc": rc, "status": "not_started", "error": note}, ensure_ascii=False) + "\n")
                    if req.get("out_stderr"):
                        with open(req["out_stderr"], "a", encoding="utf-8") as fh:
                            fh.write(note + "\n")
                    if req.get("out_rc"):
                        with open(req["out_rc"], "w", encoding="utf-8") as fh:
                            fh.write(str(rc))
                finally:
                    try:
                        os.remove(path)
                    except OSError:
                        pass

    def serve(self) -> int:
        cfg = self.cfg
        pid_path = os.path.join(self.dir, "bridge.pid")
        with open(pid_path, "w", encoding="utf-8") as fh:
            fh.write(str(os.getpid()))
        (Path(self.dir) / "steer.pid").write_text(str(os.getpid()))

        def on_term(signum, _frame):
            self.stop = True
            if self.current is not None:
                self.current.interrupt_requested = True
        signal.signal(signal.SIGTERM, on_term)
        signal.signal(signal.SIGINT, on_term)
        hold_log = os.path.join(self.dir, "hold.jsonl")
        boot = Runner({**cfg, "out_jsonl": hold_log, "out_stderr": os.path.join(self.dir, "hold.stderr")})
        rc = 0
        try:
            try:
                srv = boot.boot()
            except ProtocolError as exc:
                rc = boot._classify_failure(exc)
                hint = {4: "执行器不可用", 5: "线程被别的客户端占着（桌面端打开了它）"}.get(rc, "线程没载入")
                self._fail_queued(rc, f"codex_appserver: hold 启动失败（{hint}）: {exc}")
                if boot.server is not None:
                    boot.server.close()
                return rc
            srv.log_event({"_fleet": "hold_started", "threadId": boot.thread_id, "pid": os.getpid()})
            idle_seconds = int(cfg.get("idle_seconds") or 0)
            last_activity = time.time()
            while True:
                self.consume_steers(srv)
                queued = self._queued()
                if not queued:
                    if self.stop or os.path.exists(os.path.join(self.dir, "release")):
                        break
                    if idle_seconds and time.time() - last_activity > idle_seconds:
                        srv.log_event({"_fleet": "hold_idle_timeout", "idleSeconds": idle_seconds})
                        break
                    msg = srv.next_message(timeout=1.0)   # 轮间也把服务端通知吃掉、落进 hold.jsonl
                    if msg is None:
                        srv.log_event({"_fleet": "hold_server_exited"})
                        rc = 3
                        break
                    srv.dispatch(msg)
                    continue
                path = queued[0]
                req = self._claim(path)
                if req is None:  # 编排者刚把这轮取消或转成引导
                    continue
                r = Runner(req)
                r.server = srv
                r.thread_id = boot.thread_id
                r.deadline = (time.time() + int(req["timeout"])) if req.get("timeout") else None
                srv.on_server_request = r.handle_server_request
                srv.on_notification = r.handle_notification
                srv.set_log(req["out_jsonl"])
                srv.log_event({**boot.boot_info, "workDir": req.get("work_dir") or None, "held": True})
                self.current = r
                r.consume_steers = lambda: self.consume_steers(srv)
                r.on_turn_started = lambda: write_json(Path(self.dir) / "active.json",
                    {"turnId": r.turn_id, "run": Path(req["out_jsonl"]).stem})
                trc = 1
                try:
                    trc = r.turn()
                except ProtocolError as exc:
                    trc = r._classify_failure(exc)
                finally:
                    self.current = None
                    r.finish(trc)
                    if req.get("out_rc"):
                        with open(req["out_rc"], "w", encoding="utf-8") as fh:
                            fh.write(str(trc))
                    (Path(self.dir) / "active.json").unlink(missing_ok=True)
                    srv.set_log(hold_log)
                    srv.log_event({"_fleet": "hold_turn_done", "run": os.path.basename(req.get("out_jsonl") or ""), "rc": trc})
                last_activity = time.time()
                if srv.proc.poll() is not None:
                    self._fail_queued(3, "codex_appserver: app-server 已退出，排队的轮次作废")
                    rc = 3
                    break
            srv.log_event({"_fleet": "hold_released", "threadId": boot.thread_id})
            srv.close()
        finally:
            for name in ("bridge.pid", "steer.pid", "active.json", "release"):
                try:
                    os.remove(os.path.join(self.dir, name))
                except OSError:
                    pass
            with open(os.path.join(self.dir, "hold.rc"), "w", encoding="utf-8") as fh:
                fh.write(str(rc))
        return rc


# ---------- probe ----------

def probe(argv: list[str]) -> int:
    home = os.environ.get("CODEX_HOME") or os.path.expanduser("~/.codex")
    codex_bin = "codex"
    ask = "true"
    i = 0
    while i < len(argv):
        if argv[i] == "--home":
            home = argv[i + 1]; i += 2
        elif argv[i] == "--codex":
            codex_bin = argv[i + 1]; i += 2
        elif argv[i] == "--request-user-input":
            ask = argv[i + 1]; i += 2
        else:
            i += 1
    log_path = os.path.join(home, "fleet-probe.jsonl")
    try:
        os.remove(log_path)
    except OSError:
        pass
    print(feature_report(request_input_feature(codex_bin, home, os.getcwd()), ask))
    srv = AppServer(codex_bin, home, os.getcwd(), [(REQUEST_INPUT_KEY, ask)], log_path, os.path.join(home, "fleet-probe.stderr"))
    srv.on_server_request = lambda m: srv.respond(m["id"], error={"code": -32601, "message": "probe"})
    srv.on_notification = lambda m: None
    try:
        init = srv.request("initialize", {
            "clientInfo": {"name": CLIENT_NAME, "title": "foreman probe", "version": CLIENT_VERSION},
            "capabilities": {"experimentalApi": True},
        }, timeout=60)
        srv.notify("initialized")
        print(f"app-server ok  codexHome={init.get('codexHome')}  userAgent={init.get('userAgent')}")
        acct = srv.request("account/read", {}, timeout=60).get("account") or {}
        print(f"account: type={acct.get('type')} plan={acct.get('planType')}")
        limits = srv.request("account/rateLimits/read", None, timeout=60).get("rateLimits") or {}
        primary = limits.get("primary") or {}
        if primary:
            reset = time.strftime("%m-%d %H:%M", time.localtime(primary.get("resetsAt", 0)))
            print(f"quota: used {primary.get('usedPercent')}% of {primary.get('windowDurationMins', 0) // 1440}d window, resets {reset}")
        models = srv.request("model/list", {}, timeout=60).get("data") or []
        print("models:")
        for m in models:
            efforts = [e.get("reasoningEffort") for e in (m.get("supportedReasoningEfforts") or [])]
            print(f"  {m.get('id'):22} default={m.get('defaultReasoningEffort'):7} efforts={','.join(efforts)}  — {m.get('description', '')}")
        return 0
    except ProtocolError as exc:
        print(f"!! probe 失败: {exc}", file=sys.stderr)
        return 1
    finally:
        srv.close()


def main(argv: list[str]) -> int:
    if argv and argv[0] == "steer-submit":
        try:
            print(submit_steer(argv[1], argv[2], argv[3], argv[4], int(argv[5]) if argv[5] else None))
            return 0
        except (OSError, ValueError, KeyError) as exc:
            print(f"foreman: {exc}", file=sys.stderr)
            return 1
    if argv and argv[0] == "steer-wait":
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            rc = steer_result(argv[1])
            if rc is not None:
                return rc
            time.sleep(0.2)
        print(f"引导已提交，30 秒内未收到回执；消息保留在 {argv[1]}，请检查 sent / failed，勿重复发送", file=sys.stderr)
        return 2
    if len(argv) >= 2 and argv[0] == "run":
        with open(argv[1], encoding="utf-8") as fh:
            req = json.load(fh)
        return Runner(req).run()
    if len(argv) >= 2 and argv[0] == "serve":
        return Holder(argv[1]).serve()
    if argv and argv[0] == "probe":
        return probe(argv[1:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
