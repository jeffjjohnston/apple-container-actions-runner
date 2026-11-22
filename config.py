"""Validate runner definitions and emit enabled slots for the macOS poller."""
import hashlib
import re
import sys
from pathlib import Path

if sys.version_info < (3, 11):
    sys.exit("Runner configuration requires Python 3.11 or newer.")

import tomllib


def matching_text(value, pattern, field):
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise ValueError(f"invalid {field}: {value!r}")
    return value


def slots(path, installation):
    with Path(path).open("rb") as source:
        try:
            config = tomllib.load(source)
        except tomllib.TOMLDecodeError as error:
            raise ValueError(f"{path}: {error}") from error
    if config.keys() != {"runners"} or not isinstance(config["runners"], list):
        raise ValueError(f"{path}: expected [[runners]] tables")
    names = set()
    pools = {}
    required = {"name", "repository", "labels", "enabled", "cpus", "memory", "storage"}
    for index, runner in enumerate(config["runners"], 1):
        try:
            if not isinstance(runner, dict):
                raise ValueError("expected a table")
            missing = required - runner.keys()
            unknown = runner.keys() - required - {"buildkit_gc"}
            if missing:
                raise ValueError("missing fields: " + ", ".join(sorted(missing)))
            if unknown:
                raise ValueError("unknown fields: " + ", ".join(sorted(unknown)))
            slot = matching_text(runner["name"], r"[a-z0-9][a-z0-9-]{0,19}", "name")
            if slot in names:
                raise ValueError(f"duplicate name: {slot}")
            names.add(slot)
            repo = matching_text(runner["repository"], r"[A-Za-z0-9-]+/[A-Za-z0-9_.-]+", "repository").lower()
            if repo.split("/")[1] in (".", ".."):
                raise ValueError("invalid repository name")
            values = runner["labels"]
            if not isinstance(values, list) or not values:
                raise ValueError("labels must be a nonempty array of strings")
            labels = ",".join(sorted({matching_text(label, r"[A-Za-z0-9_-]+", "label").lower()
                                      for label in values}))
            cpu = runner["cpus"]
            if type(cpu) is not int or cpu < 1:
                raise ValueError("cpus must be a positive integer")
            mem = matching_text(runner["memory"], r"[1-9][0-9]*[GM]", "memory")
            storage = matching_text(runner["storage"], r"warm|disposable", "storage")
            gc = ""
            if "buildkit_gc" in runner:
                gc = matching_text(runner["buildkit_gc"], r"[1-9][0-9]*[GM]B", "buildkit_gc")
            if not isinstance(runner["enabled"], bool):
                raise ValueError("enabled must be true or false")
            if not runner["enabled"]:
                continue
            if pools.setdefault(repo, labels) != labels:
                raise ValueError("enabled slots in a repository must share labels")
            digest = hashlib.sha256(repo.encode()).hexdigest()[:12]
            yield "|".join((f"{installation}-{digest}-{slot}", repo, labels, str(cpu),
                            mem, gc, "yes", storage))
        except ValueError as error:
            raise ValueError(f"{path}: runner {index}: {error}") from error


if __name__ == "__main__":
    try:
        rows = list(slots(sys.argv[2], sys.argv[1]))
        if sys.argv[1] != "--check":
            print("\n".join(rows))
    except (OSError, ValueError) as error:
        sys.exit(str(error))
