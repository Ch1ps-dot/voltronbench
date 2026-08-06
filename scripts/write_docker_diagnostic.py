#!/usr/bin/env python3
"""Append a redacted, machine-readable Docker diagnostic record."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


def redact(value: str) -> str:
    """Hide values of credentials embedded in command summaries."""
    for key in ("API_KEY", "TOKEN", "PASSWORD", "SECRET", "AUTHORIZATION"):
        marker = f"{key}="
        if marker in value.upper():
            prefix = value[: value.upper().index(marker) + len(marker)]
            return f"{prefix}<redacted>"
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--kind", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--replication", type=int, required=True)
    parser.add_argument("--status", default="")
    parser.add_argument("--returncode", type=int)
    parser.add_argument("--container-id", default="")
    parser.add_argument("--stderr", default="")
    parser.add_argument("--command", default="")
    args = parser.parse_args()

    record = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "kind": args.kind,
        "target": args.target,
        "replication": args.replication,
    }
    for name in ("status", "container_id", "stderr"):
        value = getattr(args, name)
        if value:
            record[name] = redact(value)
    if args.returncode is not None:
        record["returncode"] = args.returncode
    if args.command:
        record["command"] = redact(args.command)

    path = Path(args.output)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        json.dump(record, stream, sort_keys=True)
        stream.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
