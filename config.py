"""Validate the complete slot table before making any changes."""
import hashlib
import re
import sys
from pathlib import Path


def slots(path, installation):
    names = set()
    pools = {}
    for line, raw in enumerate(Path(path).read_text().splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        try:
            slot, repo, labels, cpu, mem, gc, enabled, storage = raw.strip().split("|")
            repo = repo.lower()
            labels = ",".join(sorted(set(labels.lower().split(","))))
            valid = (
                re.fullmatch(r"[a-z0-9][a-z0-9-]{0,19}", slot) and slot not in names
                and re.fullmatch(r"[a-z0-9-]+/[a-z0-9_.-]+", repo)
                and repo.split("/")[1] not in (".", "..")
                and re.fullmatch(r"[a-z0-9_-]+(,[a-z0-9_-]+)*", labels)
                and re.fullmatch(r"[1-9][0-9]*", cpu)
                and re.fullmatch(r"[1-9][0-9]*[GM]", mem)
                and (not gc or re.fullmatch(r"[1-9][0-9]*[GM]B", gc))
                and enabled in ("yes", "no") and storage in ("warm", "disposable")
            )
            if not valid:
                raise ValueError("invalid or duplicate slot")
            names.add(slot)
            if enabled == "no":
                continue
            if pools.setdefault(repo, labels) != labels:
                raise ValueError("enabled slots in a repository must share labels")
            digest = hashlib.sha256(repo.encode()).hexdigest()[:12]
            yield "|".join((f"{installation}-{digest}-{slot}", repo, labels, cpu,
                            mem, gc, enabled, storage))
        except ValueError as error:
            raise ValueError(f"{path} line {line}: {error}") from error


if __name__ == "__main__":
    try:
        rows = list(slots(sys.argv[2], sys.argv[1]))
        if sys.argv[1] != "--check":
            print("\n".join(rows))
    except (OSError, ValueError) as error:
        sys.exit(str(error))
