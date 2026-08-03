#!/usr/bin/env python3
"""Persist container lifecycle metadata for a benchmark experiment."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import subprocess
import tempfile
import tarfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def inspect_container(container_id: str) -> dict[str, Any]:
    result = subprocess.run(
        ["docker", "inspect", "--format", "{{json .}}", container_id],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_postprocess_status(archive: Path) -> dict[str, Any]:
    """Read the bounded Voltron stage summary embedded in a result archive."""
    try:
        with tarfile.open(archive, "r:gz") as result_archive:
            member = next(
                (
                    item
                    for item in result_archive.getmembers()
                    if item.isfile()
                    and item.name.endswith("/postprocess_status.json")
                    and item.size <= 64 * 1024
                ),
                None,
            )
            if member is None:
                return {}
            stream = result_archive.extractfile(member)
            if stream is None:
                return {}
            value = json.loads(stream.read().decode("utf-8"))
            return value if isinstance(value, dict) else {}
    except (OSError, tarfile.TarError, UnicodeDecodeError, json.JSONDecodeError):
        return {}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--event", required=True, choices=("started", "finished", "archived"))
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--fuzzer", required=True)
    parser.add_argument("--replication", required=True, type=int)
    parser.add_argument("--container-id", required=True)
    parser.add_argument("--result-dir", required=True, type=Path)
    parser.add_argument("--archive-path", type=Path)
    parser.add_argument("--exit-code", type=int)
    parser.add_argument("--timeout-seconds", type=int)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    manifest = args.manifest.resolve()
    manifest.parent.mkdir(parents=True, exist_ok=True)
    metadata = inspect_container(args.container_id)
    state = metadata.get("State") or {}
    config = metadata.get("Config") or {}
    host_config = metadata.get("HostConfig") or {}
    now = datetime.now(timezone.utc).isoformat()
    full_id = str(metadata.get("Id") or args.container_id)
    record = {
        "run_id": args.run_id,
        "target": args.target,
        "fuzzer": args.fuzzer,
        "replication": args.replication,
        "container_id_short": full_id[:12],
        "container_id_full": full_id,
        "container_name": str(metadata.get("Name", "")).lstrip("/"),
        "image": str(config.get("Image", "")),
        "created_at": metadata.get("Created"),
        "started_at": state.get("StartedAt"),
        "finished_at": state.get("FinishedAt"),
        "exit_code": state.get("ExitCode"),
        "status": state.get("Status", "unknown"),
        "result_dir": str(args.result_dir.resolve()),
        "fuzzer_timeout_seconds": args.timeout_seconds,
        "last_event": args.event,
        "recorded_at": now,
        "confidence": "direct",
        "container_init": bool(host_config.get("Init") is True),
    }
    if args.exit_code is not None:
        record["exit_code"] = args.exit_code
        record["status"] = "exited" if args.event != "started" else record["status"]
    if args.archive_path is not None and args.archive_path.is_file():
        archive = args.archive_path.resolve()
        record["archive_path"] = str(archive)
        record["archive_sha256"] = sha256(archive)
        stage_status = read_postprocess_status(archive)
        for key in (
            "voltron_status",
            "pair_status",
            "pair_count",
            "compliance_status",
            "compliance_exit_code",
            "coverage_status",
            "coverage_exit_code",
            "component_export_status",
            "voltron_source_commit",
            "lifecycle_mode",
        ):
            if key in stage_status:
                record[key] = stage_status[key]

    lock_path = manifest.with_suffix(manifest.suffix + ".lock")
    with lock_path.open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        records: list[dict[str, Any]] = []
        if manifest.is_file():
            with manifest.open() as stream:
                for line in stream:
                    try:
                        value = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if isinstance(value, dict):
                        records.append(value)
        match = next(
            (
                value
                for value in records
                if value.get("container_id_full") == full_id
                or value.get("container_id_short") == full_id[:12]
            ),
            None,
        )
        if match is None:
            records.append(record)
        else:
            match.update({key: value for key, value in record.items() if value is not None})
        fd, temporary = tempfile.mkstemp(prefix=manifest.name + ".", dir=manifest.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                for value in records:
                    stream.write(json.dumps(value, ensure_ascii=False, sort_keys=True) + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, manifest)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
