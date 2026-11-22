#!/usr/bin/env python3
"""Dispatch the sample workflow to a dedicated private scratch repository."""
import argparse
import json
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from config import slots
from poll import STATE


def command(*args):
    return subprocess.check_output(args, text=True, timeout=30).strip()


def wait_for(check, deadline, message):
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(3)
    raise TimeoutError(message)


def main(repo):
    installation = (STATE / "installation").read_text().strip()
    owned = {"gh-" + row.split("|")[0] for row in slots(ROOT / "runners.toml", installation)
             if row.split("|")[1] == repo.lower() and "apple-container" in row.split("|")[2].split(",")}
    if not owned:
        sys.exit("Enable a matching apple-container slot and install the poller first.")
    if command("gh", "repo", "view", repo, "--json", "visibility", "--jq", ".visibility") != "PRIVATE":
        sys.exit("Use a dedicated private scratch repository.")
    token = uuid.uuid4().hex
    title = "apple-container-probe-" + token
    deadline = time.monotonic() + 600
    command("gh", "workflow", "run", "probe.yml", "-R", repo, "-f", "probe_id=" + token)

    def find_run():
        runs = json.loads(command("gh", "run", "list", "-R", repo, "--workflow", "probe.yml",
                                  "--event", "workflow_dispatch", "--limit", "100",
                                  "--json", "databaseId,displayTitle"))
        return next((r["databaseId"] for r in runs if r["displayTitle"] == title), None)

    run_id = wait_for(find_run, deadline, "Could not locate " + title)
    print(f"https://github.com/{repo}/actions/runs/{run_id}", flush=True)

    def finished():
        return command("gh", "api", f"repos/{repo}/actions/runs/{run_id}",
                       "--jq", '.conclusion // ""')

    try:
        result = wait_for(finished, deadline, "Timed out waiting for the probe")
    except TimeoutError:
        command("gh", "run", "cancel", str(run_id), "-R", repo)
        raise
    if result != "success":
        sys.exit("Probe conclusion: " + result)
    jobs = json.loads(command("gh", "api", f"repos/{repo}/actions/runs/{run_id}/jobs"))["jobs"]
    job, = jobs
    if job["runner_name"] not in owned:
        sys.exit("Probe ran on a different installation: " + job["runner_name"])

    def removed():
        ids = command("gh", "api", "--paginate", f"repos/{repo}/actions/runners?per_page=100",
                      "--jq", ".runners[].id").splitlines()
        guests = json.loads(command("container", "ls", "-a", "--format", "json"))
        return str(job["runner_id"]) not in ids and all(g["id"] != job["runner_name"] for g in guests)

    wait_for(removed, time.monotonic() + 240, "Registration or guest still present")
    print("Passed on " + job["runner_name"] + ". Registration and guest removed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", metavar="OWNER/PRIVATE-REPO")
    try:
        main(parser.parse_args().repository)
    except (OSError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
