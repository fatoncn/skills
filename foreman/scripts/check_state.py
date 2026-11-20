"""自动 check 状态判定，供 app-server 与摘要器共用。"""
from __future__ import annotations

import os
from pathlib import Path
import re


TERMINAL_STATUS = re.compile(r"^(SKIPPED|UNCONFIGURED|FAILED)(?::|$)")


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def check_state(prefix) -> str:
    prefix = Path(prefix)
    pending = Path(str(prefix) + ".check.pending")
    if not pending.exists():
        return "TERMINAL"
    if Path(str(prefix) + ".check.rc").exists():
        return "TERMINAL"
    if TERMINAL_STATUS.match(_read(Path(str(prefix) + ".check.status"))):
        return "TERMINAL"
    rc = _read(Path(str(prefix) + ".rc"))
    if not re.fullmatch(r"[0-9]+", rc):
        return "PENDING_RUN"
    if rc != "0":
        return "TERMINAL"
    try:
        pid = int(_read(Path(str(prefix) + ".check.pid")))
        os.kill(pid, 0)
    except (OSError, ValueError):
        return "WORKER_GONE"
    return "CHECKING"


def check_result(prefix) -> str:
    prefix = Path(prefix)
    phase = check_state(prefix)
    if phase == "CHECKING":
        return "中"
    if phase == "WORKER_GONE":
        return "FAIL（worker 消失）"
    check_rc = _read(Path(str(prefix) + ".check.rc"))
    if Path(str(prefix) + ".check.rc").exists():
        return "PASS" if check_rc == "0" else "FAIL"
    status = _read(Path(str(prefix) + ".check.status"))
    if status == "UNCONFIGURED" or status.startswith("UNCONFIGURED:"):
        return "未配置"
    if status == "SKIPPED" or status.startswith("SKIPPED:"):
        return "跳过"
    if status == "FAILED" or status.startswith("FAILED:"):
        return "FAIL"
    return "跳过" if Path(str(prefix) + ".rc").exists() else "—"
