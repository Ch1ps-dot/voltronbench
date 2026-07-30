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
    project: str = "-"
    project_index: int | None = None
    name: str = "-"
    status: str = "unknown"
    runtime_seconds: int | None = None
    exit_code: str = "-"
    cpu: str = "-"
    memory: str = "-"
    memory_percent: str = "-"
    pids: str = "-"
    note: str = "UNKNOWN"
    stage: str = "-"
    stage_file: str = ""


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
        stage_file: str | None = None,
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
            if stage_file:
                for snapshot in snapshots:
                    if snapshot.status == "running":
                        snapshot.stage = self._stage(
                            snapshot.container_id,
                            stage_file or snapshot.stage_file,
                        )
            else:
                for snapshot in snapshots:
                    if snapshot.status == "running" and snapshot.stage_file:
                        snapshot.stage = self._stage(
                            snapshot.container_id,
                            snapshot.stage_file,
                        )
        return snapshots

    def container_ids_by_label(self, label: str) -> list[str]:
        self.last_error = ""
        result = self._run(
            [
                "ps",
                "-a",
                "--filter",
                f"label={label}",
                "--format",
                "{{.ID}}",
            ]
        )
        if result is None:
            return []
        return [line.strip() for line in result.stdout.splitlines() if line.strip()]

    def _stage(self, container_id: str, stage_file: str) -> str:
        """Read an optional benchmark phase marker without warning on absence.

        The marker is deliberately best-effort: a container can be running
        before its runner creates the file, and ordinary fuzzers do not create
        one at all.
        """
        try:
            result = subprocess.run(
                [self.executable, "exec", container_id, "cat", stage_file],
                check=False,
                capture_output=True,
                text=True,
                timeout=self.command_timeout,
            )
        except (OSError, subprocess.TimeoutExpired):
            return "STARTING"
        if result.returncode != 0:
            return "STARTING"
        stage = result.stdout.strip().splitlines()
        return stage[-1][:80] if stage else "STARTING"

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
        config = record.get("Config") or {}
        labels = config.get("Labels") or {}
        project_index_value = labels.get("voltronbench.project_index")
        try:
            project_index = int(project_index_value)
        except (TypeError, ValueError):
            project_index = None
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
            project=str(labels.get("voltronbench.project", "-")),
            project_index=project_index,
            name=str(record.get("Name", "-")).lstrip("/") or "-",
            status=status,
            runtime_seconds=runtime,
            exit_code=exit_code,
            note=note,
            stage_file=str(labels.get("voltronbench.stage_file", "")),
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
    show_stage: bool = False,
    progress_status: str = "",
    visible_index: int | None = None,
    rotation_interval: float | None = None,
    show_project: bool = False,
) -> Group:
    remaining = max(0, timeout - elapsed)
    completed = min(max(elapsed, 0), max(timeout, 1))
    indexed_snapshots = list(enumerate(snapshots, start=1))
    visible_position: int | None = None
    if visible_index is not None and indexed_snapshots:
        visible_position = visible_index % len(indexed_snapshots)
        indexed_snapshots = [indexed_snapshots[visible_position]]

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
    if visible_position is not None:
        interval_text = (
            f"   rotates every {rotation_interval:g}s"
            if rotation_interval is not None
            else ""
        )
        summary.add_row(
            Text(
                f"view project {visible_position + 1}/{len(snapshots)}"
                f"{interval_text}",
                style="bright_blue",
            )
        )
    if progress_status:
        summary.add_row(Text(f"workflow {progress_status}", style="magenta"))

    table = Table(box=box.ROUNDED, expand=True, pad_edge=False)
    table.add_column("RUN", justify="right", style="dim", width=3)
    if show_project:
        table.add_column("PROJECT", no_wrap=True, max_width=18)
    table.add_column("CONTAINER", no_wrap=True, width=12)
    table.add_column("STATUS", no_wrap=True)
    table.add_column("RUNTIME", justify="right", no_wrap=True)
    if show_stage:
        table.add_column("PHASE", overflow="ellipsis", min_width=12, max_width=28)
    wide_layout = terminal_width >= 110
    if wide_layout:
        table.add_column("EXIT", justify="right", no_wrap=True)
        table.add_column("CPU", justify="right", no_wrap=True)
        table.add_column("NAME", overflow="ellipsis", max_width=18)
        table.add_column("MEMORY", justify="right", no_wrap=True)
        table.add_column("MEM%", justify="right", no_wrap=True)
        table.add_column("PIDS", justify="right", no_wrap=True)
    elif not show_stage:
        table.add_column("CPU", justify="right", no_wrap=True)
        table.add_column("MEM%", justify="right", no_wrap=True)
    table.add_column("NOTE", no_wrap=True)

    counts: dict[str, int] = {}
    abnormal = 0
    for snapshot in snapshots:
        counts[snapshot.status] = counts.get(snapshot.status, 0) + 1
        if snapshot.note not in ("OK", "OVERTIME", "PENDING"):
            abnormal += 1

    for index, snapshot in indexed_snapshots:
        row: list[Any] = [
            str(index),
        ]
        if show_project:
            row.append(snapshot.project)
        row.extend(
            [
                snapshot.container_id[:12],
                _status_text(snapshot.status),
                format_duration(snapshot.runtime_seconds),
            ]
        )
        if show_stage:
            row.append(snapshot.stage)
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
        elif not show_stage:
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
            stage="FUZZING 0/4",
        ),
        ContainerSnapshot(
            container_id="0f1e2d3c4b5a",
            name="lightftp-run-2",
            status="exited",
            runtime_seconds=max(0, timeout - 12),
            exit_code="1",
            note="EARLY_EXIT EXIT_1",
            stage="ARCHIVE READY 4/4",
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
    parser.add_argument(
        "--project-interval",
        type=float,
        default=5.0,
        help="seconds each project remains visible in the live carousel",
    )
    parser.add_argument(
        "--stage-file",
        help="optional in-container file containing the current benchmark phase",
    )
    parser.add_argument(
        "--progress-file",
        help="optional host file containing overall workflow progress",
    )
    parser.add_argument(
        "--docker-label",
        help="dynamically discover experiment containers with this Docker label",
    )
    parser.add_argument("--screen", action="store_true")
    parser.add_argument("--demo", action="store_true")
    parser.add_argument("containers", nargs="*")
    args = parser.parse_args()

    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if args.interval <= 0:
        parser.error("--interval must be positive")
    if args.project_interval <= 0:
        parser.error("--project-interval must be positive")
    if not args.demo and not args.containers and not args.docker_label:
        parser.error("container IDs or --docker-label are required")
    return args


def _progress_status(path: str | None) -> str:
    if not path:
        return ""
    try:
        with open(path, encoding="utf-8") as stream:
            return stream.read().strip().replace("\n", " ")[:120]
    except OSError:
        return ""


def main() -> int:
    args = parse_args()
    console = Console()
    stopped = threading.Event()
    snapshot_lock = threading.Lock()
    snapshots: list[ContainerSnapshot] = []
    docker_error = ""

    def stop_monitor(_signum: int, _frame: Any) -> None:
        stopped.set()

    signal.signal(signal.SIGINT, stop_monitor)
    signal.signal(signal.SIGTERM, stop_monitor)

    docker = DockerReader(
        os.environ.get("PROFUZZBENCH_DOCKER_BIN", "docker"),
        float(os.environ.get("PROFUZZBENCH_DOCKER_COMMAND_TIMEOUT", "5")),
    )

    def collect_snapshots() -> None:
        nonlocal snapshots, docker_error
        elapsed = max(0, int(time.time()) - args.start_epoch)
        if args.demo:
            current_snapshots = _demo_snapshots(elapsed, args.timeout)
            current_error = ""
        else:
            container_ids = args.containers
            if args.docker_label:
                container_ids = docker.container_ids_by_label(args.docker_label)
                if docker.last_error:
                    with snapshot_lock:
                        snapshots = []
                        docker_error = docker.last_error
                    return
            if not container_ids:
                with snapshot_lock:
                    snapshots = []
                    docker_error = ""
                return
            current_snapshots = docker.snapshots(
                container_ids,
                elapsed,
                args.timeout,
                datetime.now(timezone.utc),
                args.stage_file,
            )
            if args.docker_label:
                current_snapshots.sort(
                    key=lambda snapshot: (
                        snapshot.project_index is None,
                        snapshot.project_index or 0,
                        snapshot.project,
                        snapshot.container_id,
                    )
                )
            current_error = docker.last_error
        with snapshot_lock:
            snapshots = current_snapshots
            docker_error = current_error

    def current_dashboard(
        final: bool = False,
        visible_index: int | None = None,
    ) -> Group:
        with snapshot_lock:
            current_snapshots = list(snapshots)
            current_error = docker_error
        elapsed = max(0, int(time.time()) - args.start_epoch)
        return build_dashboard(
            args.label,
            args.timeout,
            elapsed,
            current_snapshots,
            current_error,
            final=final,
            terminal_width=console.size.width,
            show_stage=bool(args.stage_file or args.docker_label),
            progress_status=_progress_status(args.progress_file),
            visible_index=visible_index,
            rotation_interval=(
                args.project_interval if visible_index is not None else None
            ),
            show_project=bool(args.docker_label),
        )

    collect_snapshots()
    if args.mode == "snapshot":
        console.print(current_dashboard(final=True))
        return 0

    def refresh_snapshots() -> None:
        while not stopped.wait(args.interval):
            collect_snapshots()

    refresh_thread = threading.Thread(
        target=refresh_snapshots,
        name="profuzzbench-snapshot-refresh",
        daemon=True,
    )
    refresh_thread.start()

    screen = bool(args.screen and console.is_terminal)
    visible_index = 0
    with Live(
        current_dashboard(visible_index=visible_index),
        console=console,
        auto_refresh=False,
        screen=screen,
        transient=True,
    ) as live:
        while not stopped.wait(args.project_interval):
            visible_index += 1
            live.update(
                current_dashboard(visible_index=visible_index),
                refresh=True,
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
