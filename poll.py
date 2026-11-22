#!/usr/bin/env python3
"""Serialize passes and keep the installation identity and backoff on the host."""
import fcntl
import os
import subprocess
import sys
import uuid
from pathlib import Path

from api import backoff_active

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
        if backoff_active(retry):
            return 0
        env = dict(os.environ, STATE_DIR=str(STATE), INSTALLATION=installation)
        for key in ("GH_TOKEN", "GITHUB_TOKEN"):
            env.pop(key, None)
        return subprocess.call(["/bin/bash", str(ROOT / "poll.sh")],
                               env=env,
                               pass_fds=(lock.fileno(),))


if __name__ == "__main__":
    sys.exit(main())
