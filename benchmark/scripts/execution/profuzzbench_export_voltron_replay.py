#!/usr/bin/env python3

"""Export Voltron Conversation pickles as AFLNet structured test cases."""

from __future__ import annotations

import argparse
import csv
import os
from pathlib import Path
import pickle
import struct
from typing import Any


def _request_bytes(conversation: Any) -> list[bytes]:
    request_types = getattr(conversation, "req_seq", None)
    content = getattr(conversation, "content", None)
    if not isinstance(request_types, list) or not isinstance(content, list):
        raise TypeError("test case does not contain req_seq/content lists")
    if len(request_types) != len(content):
        raise ValueError("req_seq and content have different lengths")

    requests: list[bytes] = []
    for request_type, exchange in zip(request_types, content):
        if request_type == "-":
            continue
        if not isinstance(exchange, (list, tuple)) or not exchange:
            raise TypeError("conversation exchange is not a request/response pair")
        request = exchange[0]
        if isinstance(request, bytearray):
            request = bytes(request)
        if not isinstance(request, bytes):
            raise TypeError("conversation request is not bytes")
        if request:
            requests.append(request)
    return requests


def _write_aflnet_case(path: Path, requests: list[bytes]) -> None:
    with path.open("wb") as stream:
        for request in requests:
            stream.write(struct.pack("<I", len(request)))
            stream.write(request)


def export_cases(result_dir: Path) -> tuple[int, int, int]:
    source_dir = result_dir / "replayable_testcases"
    output_dir = result_dir / "replayable-queue"
    manifest_path = result_dir / "voltron_aflnet_replay_manifest.csv"
    output_dir.mkdir(parents=True, exist_ok=True)

    candidates = []
    if source_dir.is_dir():
        candidates = sorted(
            source_dir.glob("*.pkl"),
            key=lambda path: (path.stat().st_mtime_ns, path.name),
        )

    exported = 0
    skipped = 0
    with manifest_path.open("w", newline="", encoding="utf-8") as manifest:
        writer = csv.writer(manifest)
        writer.writerow(
            ("testcase", "source_pickle", "unix_time", "request_count")
        )
        for source_path in candidates:
            try:
                with source_path.open("rb") as stream:
                    conversation = pickle.load(stream)
                requests = _request_bytes(conversation)
                if not requests:
                    raise ValueError("conversation has no non-empty requests")
            except Exception as exc:
                skipped += 1
                print(
                    f"VOLTRON coverage: skipping {source_path.name}: {exc}",
                    flush=True,
                )
                continue

            output_name = f"id:{exported:06d},src:voltron"
            output_path = output_dir / output_name
            _write_aflnet_case(output_path, requests)
            source_stat = source_path.stat()
            os.utime(
                output_path,
                ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns),
            )
            writer.writerow(
                (
                    output_name,
                    source_path.name,
                    source_stat.st_mtime_ns // 1_000_000_000,
                    len(requests),
                )
            )
            exported += 1

    return exported, skipped, len(candidates)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--result-dir",
        type=Path,
        required=True,
        help="Voltron result directory containing replayable_testcases",
    )
    args = parser.parse_args()
    result_dir = args.result_dir.expanduser().resolve()
    result_dir.mkdir(parents=True, exist_ok=True)

    exported, skipped, candidates = export_cases(result_dir)
    print(
        "VOLTRON coverage: "
        f"exported={exported} skipped={skipped} candidates={candidates} "
        f"queue={result_dir / 'replayable-queue'}",
        flush=True,
    )
    if candidates > 0 and exported == 0:
        print(
            "VOLTRON coverage: all retained test cases failed to export",
            flush=True,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
