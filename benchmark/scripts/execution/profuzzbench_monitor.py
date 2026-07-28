#!/usr/bin/env python3

"""Rich dashboard for monitoring ProFuzzBench Docker containers."""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

try:
    from rich import box
    from rich.console import Console, Group
    from rich.live import Live
    from rich.panel import Panel
    from rich.progress_bar import ProgressBar
    from rich.table import Table
    from rich.text import Text
except ImportError:
    print(
        "Rich is required for the experiment dashboard. "
        "Run ./deps.sh or: python3 -m pip install rich",
        file=sys.stderr,
    )
    raise SystemExit(2)


ZERO_TIME = "0001-01-01T00:00:00Z"


@dataclass
class ContainerSnapshot:
    container_id: str
    name: str = "-"
    status: str = "unknown"
    runtime_seconds: int | None = None
    exit_code: str = "-"
    cpu: str = "-"
    memory: str = "-"
    memory_percent: str = "-"
    pids: str = "-"
    note: str = "UNKNOWN"


class DockerReader:
    def __init__(self, executable: str, command_timeout: float) -> None:
        self.executable = executable
        self.command_timeout = command_timeout
        self.last_error = ""

    def _run(self, arguments: list[str]) -> subprocess.CompletedProcess[str] | None:
        try:
            result = subprocess.run(
                [self.executable, *arguments],
                check=False,
                capture_output=True,
                text=True,
                timeout=self.command_timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            self.last_error = f"Docker command failed: {error}"
            return None

        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip()
            self.last_error = detail or f"Docker exited with status {result.returncode}"
            return None
        return result

    def snapshots(
        self,
        container_ids: list[str],
        experiment_elapsed: int,
        timeout: int,
        now: datetime,
    ) -> list[ContainerSnapshot]:
        self.last_error = ""
        inspect_records = self._inspect(container_ids)
        snapshots = [
            self._snapshot_for(container_id, inspect_records, experiment_elapsed, timeout, now)
            for container_id in container_ids
        ]

        running_ids = [
            snapshot.container_id
            for snapshot in snapshots
            if snapshot.status == "running"
        ]
        if running_ids:
            stats_records = self._stats(running_ids)
            for snapshot in snapshots:
                stats = _matching_record(snapshot.container_id, stats_records)
                if stats:
                    snapshot.cpu = str(stats.get("CPUPerc", "-"))
                    snapshot.memory = str(stats.get("MemUsage", "-"))
                    snapshot.memory_percent = str(stats.get("MemPerc", "-"))
                    snapshot.pids = str(stats.get("PIDs", "-"))
        return snapshots

    def _inspect(self, container_ids: list[str]) -> list[dict[str, Any]]:
        result = self._run(["inspect", "--format", "{{json .}}", *container_ids])
        if result is None:
            return []
        return _json_lines(result.stdout)

    def _stats(self, container_ids: list[str]) -> list[dict[str, Any]]:
        result = self._run(
            ["stats", "--no-stream", "--format", "{{json .}}", *container_ids]
        )
        if result is None:
            return []
        return _json_lines(result.stdout)

    def _snapshot_for(
        self,
        requested_id: str,
        records: list[dict[str, Any]],
        experiment_elapsed: int,
        timeout: int,
        now: datetime,
    ) -> ContainerSnapshot:
        record = _matching_record(requested_id, records)
        if not record:
            return ContainerSnapshot(container_id=requested_id)

        state = record.get("State") or {}
        status = str(state.get("Status", "unknown"))
        exit_code_value = state.get("ExitCode")
        exit_code = (
            "-"
            if status == "running" or exit_code_value is None
            else str(exit_code_value)
        )
        runtime = _container_runtime(
            status,
            str(state.get("StartedAt", ZERO_TIME)),
            str(state.get("FinishedAt", ZERO_TIME)),
            now,
        )
        note = _container_note(
            status,
            exit_code,
            runtime,
            experiment_elapsed,
            timeout,
        )

        return ContainerSnapshot(
            container_id=str(record.get("Id", requested_id))[:12],
            name=str(record.get("Name", "-")).lstrip("/") or "-",
            status=status,
            runtime_seconds=runtime,
            exit_code=exit_code,
            note=note,
        )


def _json_lines(output: str) -> list[dict[str, Any]]:
    records = []
    for line in output.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            records.append(value)
    return records


def _matching_record(
    requested_id: str, records: list[dict[str, Any]]
) -> dict[str, Any] | None:
    for record in records:
        candidate = str(
            record.get("Id")
            or record.get("ID")
            or record.get("Container")
            or ""
        )
        if candidate and (
            candidate.startswith(requested_id) or requested_id.startswith(candidate)
        ):
            return record
    return None


def _parse_docker_time(value: str) -> datetime | None:
    if not value or value == ZERO_TIME:
        return None
    normalized = value.replace("Z", "+00:00")
    normalized = re.sub(r"(\.\d{6})\d+(?=[+-]\d\d:\d\d$)", r"\1", normalized)
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed


def _container_runtime(
    status: str,
    started_at: str,
    finished_at: str,
    now: datetime,
) -> int | None:
    started = _parse_docker_time(started_at)
    if started is None:
        return None
    finished = now
    if status != "running":
        finished = _parse_docker_time(finished_at) or now
    return max(0, int((finished - started).total_seconds()))


def _container_note(
    status: str,
    exit_code: str,
    runtime: int | None,
    experiment_elapsed: int,
    timeout: int,
) -> str:
    if status == "unknown":
        note = "UNKNOWN"
    elif status == "created":
        note = "PENDING"
    elif status == "restarting":
        note = "RESTARTING"
    elif status == "paused":
        note = "PAUSED"
    elif status == "dead":
        note = "DEAD"
    elif status == "running" and experiment_elapsed > timeout:
        note = "OVERTIME"
    elif status != "running" and runtime is not None and runtime < timeout:
        note = "EARLY_EXIT"
    else:
        note = "OK"

    if exit_code not in ("-", "0"):
        note = f"{note} EXIT_{exit_code}"
    return note


def format_duration(seconds: int | None) -> str:
    if seconds is None:
        return "-"
    seconds = max(0, seconds)
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def _status_text(status: str) -> Text:
    styles = {
        "running": "bold green",
        "exited": "cyan",
        "created": "yellow",
        "restarting": "bold yellow",
        "paused": "yellow",
        "dead": "bold red",
        "unknown": "bold red",
    }
    return Text(status.upper(), style=styles.get(status, "white"))


def _note_text(note: str) -> Text:
    if note == "OK":
        style = "green"
    elif note == "OVERTIME":
        style = "yellow"
    elif note == "PENDING":
        style = "cyan"
    else:
        style = "bold red"
    return Text(note, style=style)


def build_dashboard(
    label: str,
    timeout: int,
    elapsed: int,
    snapshots: list[ContainerSnapshot],
    docker_error: str = "",
    final: bool = False,
    terminal_width: int = 120,
) -> Group:
    remaining = max(0, timeout - elapsed)
    completed = min(max(elapsed, 0), max(timeout, 1))

    summary = Table.grid(expand=True)
    summary.add_column()
    summary.add_row(Text(label, style="bold"))
    summary.add_row(
        Text(
            f"elapsed {format_duration(elapsed)}   "
            f"remaining {format_duration(remaining)}   "
            f"timeout {format_duration(timeout)}",
            style="cyan",
        )
    )
    progress = Table.grid(expand=True)
    progress.add_column(ratio=1)
    progress.add_column(justify="right", width=5)
    progress.add_row(
        ProgressBar(
            total=max(timeout, 1),
            completed=completed,
            width=None,
            pulse=timeout <= 0,
        ),
        Text(f"{min(100, int(completed * 100 / max(timeout, 1)))}%"),
    )
    summary.add_row(progress)

    table = Table(box=box.ROUNDED, expand=True, pad_edge=False)
    table.add_column("RUN", justify="right", style="dim", width=3)
    table.add_column("CONTAINER", no_wrap=True, width=12)
    table.add_column("STATUS", no_wrap=True)
    table.add_column("RUNTIME", justify="right", no_wrap=True)
    wide_layout = terminal_width >= 110
    if wide_layout:
        table.add_column("EXIT", justify="right", no_wrap=True)
        table.add_column("CPU", justify="right", no_wrap=True)
        table.add_column("NAME", overflow="ellipsis", max_width=18)
        table.add_column("MEMORY", justify="right", no_wrap=True)
        table.add_column("MEM%", justify="right", no_wrap=True)
        table.add_column("PIDS", justify="right", no_wrap=True)
    else:
        table.add_column("CPU", justify="right", no_wrap=True)
        table.add_column("MEM%", justify="right", no_wrap=True)
    table.add_column("NOTE", no_wrap=True)

    counts: dict[str, int] = {}
    abnormal = 0
    for index, snapshot in enumerate(snapshots, start=1):
        counts[snapshot.status] = counts.get(snapshot.status, 0) + 1
        if snapshot.note not in ("OK", "OVERTIME", "PENDING"):
            abnormal += 1
        row: list[Any] = [
            str(index),
            snapshot.container_id[:12],
            _status_text(snapshot.status),
            format_duration(snapshot.runtime_seconds),
        ]
        if wide_layout:
            row.extend(
                [
                    snapshot.exit_code,
                    snapshot.cpu,
                    snapshot.name,
                    snapshot.memory,
                    snapshot.memory_percent,
                    snapshot.pids,
                ]
            )
        else:
            row.extend([snapshot.cpu, snapshot.memory_percent])
        row.append(_note_text(snapshot.note))
        table.add_row(*row)

    count_text = "  ".join(
        f"{name}={count}" for name, count in sorted(counts.items())
    )
    footer = Text(
        f"containers={len(snapshots)}  {count_text}  abnormal={abnormal}",
        style="bold red" if abnormal else "green",
    )

    renderables: list[Any] = [
        Panel(
            summary,
            title=(
                "ProFuzzBench final container summary"
                if final
                else "ProFuzzBench live container dashboard"
            ),
            border_style="cyan",
        ),
        table,
        footer,
    ]
    if docker_error:
        renderables.append(
            Panel(
                Text(docker_error, style="bold red"),
                title="Docker warning",
                border_style="red",
            )
        )
    return Group(*renderables)


def _demo_snapshots(elapsed: int, timeout: int) -> list[ContainerSnapshot]:
    return [
        ContainerSnapshot(
            container_id="a1b2c3d4e5f6",
            name="lightftp-run-1",
            status="running",
            runtime_seconds=elapsed,
            cpu="84.2%",
            memory="318MiB / 1GiB",
            memory_percent="31.1%",
            pids="7",
            note="OVERTIME" if elapsed > timeout else "OK",
        ),
        ContainerSnapshot(
            container_id="0f1e2d3c4b5a",
            name="lightftp-run-2",
            status="exited",
            runtime_seconds=max(0, timeout - 12),
            exit_code="1",
            note="EARLY_EXIT EXIT_1",
        ),
    ]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Monitor ProFuzzBench Docker containers with a Rich dashboard."
    )
    parser.add_argument("mode", choices=("monitor", "snapshot"))
    parser.add_argument("--label", required=True)
    parser.add_argument("--timeout", type=int, required=True)
    parser.add_argument("--start-epoch", type=int, required=True)
    parser.add_argument("--interval", type=float, default=5.0)
    parser.add_argument("--screen", action="store_true")
    parser.add_argument("--demo", action="store_true")
    parser.add_argument("containers", nargs="*")
    args = parser.parse_args()

    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.interval <= 0:
        parser.error("--interval must be positive")
    if not args.demo and not args.containers:
        parser.error("at least one container ID is required")
    return args


def main() -> int:
    args = parse_args()
    console = Console()
    stopped = threading.Event()

    def stop_monitor(_signum: int, _frame: Any) -> None:
        stopped.set()

    signal.signal(signal.SIGINT, stop_monitor)
    signal.signal(signal.SIGTERM, stop_monitor)

    docker = DockerReader(
        os.environ.get("PROFUZZBENCH_DOCKER_BIN", "docker"),
        float(os.environ.get("PROFUZZBENCH_DOCKER_COMMAND_TIMEOUT", "5")),
    )

    def current_dashboard(final: bool = False) -> Group:
        elapsed = max(0, int(time.time()) - args.start_epoch)
        if args.demo:
            snapshots = _demo_snapshots(elapsed, args.timeout)
        else:
            snapshots = docker.snapshots(
                args.containers,
                elapsed,
                args.timeout,
                datetime.now(timezone.utc),
            )
        return build_dashboard(
            args.label,
            args.timeout,
            elapsed,
            snapshots,
            docker.last_error,
            final=final,
            terminal_width=console.size.width,
        )

    if args.mode == "snapshot":
        console.print(current_dashboard(final=True))
        return 0

    screen = bool(args.screen and console.is_terminal)
    with Live(
        current_dashboard(),
        console=console,
        auto_refresh=False,
        screen=screen,
        transient=True,
    ) as live:
        while not stopped.wait(args.interval):
            live.update(current_dashboard(), refresh=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
