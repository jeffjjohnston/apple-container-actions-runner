#!/usr/bin/env python3
"""Call the authenticated GitHub CLI and honor rate limits between poll passes."""
import getpass
import json
import os
import subprocess
import sys
import time
from pathlib import Path


def backoff_active(retry):
    try:
        return int(retry.read_text()) > time.time()
    except FileNotFoundError:
        return False
    except ValueError:
        print(f"Ignoring invalid backoff deadline in {retry}", file=sys.stderr)
        retry.unlink(missing_ok=True)
        return False


def main(method, endpoint, field=None):
    retry = Path(os.environ["STATE_DIR"]) / "retry-at"
    if backoff_active(retry):
        sys.exit("GitHub rate-limit backoff active")
    secret = subprocess.run(
        ["security", "find-generic-password", "-a", getpass.getuser(),
         "-s", "apple-container-actions-runner", "-w"],
        stdout=subprocess.PIPE, text=True)
    if secret.returncode or not secret.stdout.strip():
        sys.exit("Cannot read the poller credential from the login keychain")
    env = dict(os.environ, GH_TOKEN=secret.stdout.strip())
    items = []
    page = 1
    while True:
        url = endpoint if not field else f"{endpoint}&page={page}"
        command = ["gh", "api", "--hostname", "github.com", "--include", "-X", method, url]
        if method == "POST":
            command.extend(["--input", "-"])
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=45)
        headers, sep, body = result.stdout.replace(b"\r\n", b"\n").partition(b"\n\n")
        meta = {}
        for line in headers.decode(errors="replace").splitlines()[1:]:
            key, _, value = line.partition(":")
            meta[key.lower()] = value.strip()
        if result.returncode:
            err = result.stderr.decode(errors="replace").strip()
            if ("retry-after" in meta or meta.get("x-ratelimit-remaining") == "0"
                    or "rate limit" in err.lower() or "HTTP 429" in err):
                until = max(int(time.time()) + int(meta.get("retry-after", "60")),
                            int(meta.get("x-ratelimit-reset", "0")) if meta.get("x-ratelimit-remaining") == "0" else 0)
                temp = retry.with_suffix(".tmp")
                temp.write_text(str(until))
                temp.replace(retry)
            sys.exit(err or "GitHub API request failed")
        if not sep:
            sys.exit("Incomplete GitHub response")
        if not field:
            sys.stdout.buffer.write(body)
            return
        values = json.loads(body)[field]
        if not isinstance(values, list):
            sys.exit(f"Expected a list in {field}")
        items.extend(values)
        if 'rel="next"' not in meta.get("link", ""):
            break
        page += 1
    print(json.dumps({field: items}))


if __name__ == "__main__":
    main(*sys.argv[1:])
