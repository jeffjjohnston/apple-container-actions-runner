#!/usr/bin/env python3
"""Serialize passes and keep the installation identity and backoff on the host."""
import fcntl
import os
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent
STATE = Path(os.environ.get("STATE_DIR", Path.home() / "Library/Application Support/apple-container-actions-runner"))


def main():
    os.umask(0o077)
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / "lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 0
        identity = STATE / "installation"
        if not identity.exists():
            temp = identity.with_suffix(".tmp")
            temp.write_text(uuid.uuid4().hex[:16])
            temp.replace(identity)
        installation = identity.read_text().strip()
        if len(installation) != 16 or any(c not in "0123456789abcdef" for c in installation):
            sys.exit(f"Invalid installation identity in {identity}")
        retry = STATE / "retry-at"
        if retry.exists() and int(retry.read_text()) > time.time():
            return 0
        return subprocess.call(["/bin/bash", str(ROOT / "poll.sh")],
                               env=dict(os.environ, STATE_DIR=str(STATE), INSTALLATION=installation),
                               pass_fds=(lock.fileno(),))


if __name__ == "__main__":
    sys.exit(main())
