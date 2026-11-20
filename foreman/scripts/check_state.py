"""自动 check 状态判定，供 app-server 与摘要器共用。"""
from __future__ import annotations

import os
import re
from pathlib import Path


TERMINAL_STATUS = re.compile(r"^(SKIPPED|UNCONFIGURED|FAILED)(?::|$)")


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def _pid_reused(pid, started_file, pid_file):
    if not started_file:
        return False

    import subprocess
    from datetime import datetime, timezone

    try:
        path = Path(started_file)
        started = _read(path)
        recorded_at = int(started) if started else path.stat().st_mtime
        # The dispatcher can publish the actual child PID after recording the
        # round start. A live child born within that interval is not proof of reuse.
        if pid_file:
            recorded_at = max(recorded_at, Path(pid_file).stat().st_mtime)
        actual = subprocess.check_output(
            ["ps", "-o", "lstart=", "-p", str(pid)], text=True, stderr=subprocess.DEVNULL,
            env={**os.environ, "LC_ALL": "C", "TZ": "UTC"}, timeout=3,
        ).strip()
        process_start = datetime.strptime(actual, "%a %b %d %H:%M:%S %Y").replace(tzinfo=timezone.utc)
        return process_start.timestamp() > recorded_at
    except (OSError, ValueError, OverflowError, subprocess.SubprocessError):
        return False


def pid_alive(value, started_file=None, pid_file=None) -> bool:
    """Keep a PID live when the process exists but its identity is uncertain."""
    try:
        pid = int(value)
        if pid <= 0:
            return False
        os.kill(pid, 0)
    except (ProcessLookupError, ValueError, TypeError, OverflowError):
        return False
    except PermissionError:
        return not _pid_reused(pid, started_file, pid_file)
    except OSError:
        pass
    return True


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
    pid_file = Path(str(prefix) + ".check.pid")
    return "CHECKING" if pid_alive(_read(pid_file), str(prefix) + ".check.started", pid_file) else "WORKER_GONE"


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


if __name__ == "__main__":
    import sys

    sys.exit(0 if pid_alive(*sys.argv[1:]) else 3)
