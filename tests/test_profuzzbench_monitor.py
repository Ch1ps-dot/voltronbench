import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timezone


PROJECT_ROOT = Path(__file__).resolve().parents[1]
MONITOR = (
    PROJECT_ROOT
    / "benchmark"
    / "scripts"
    / "execution"
    / "profuzzbench_monitor.py"
)
COMMON = (
    PROJECT_ROOT
    / "benchmark"
    / "scripts"
    / "execution"
    / "profuzzbench_monitor_common.sh"
)


def load_monitor_module():
    spec = importlib.util.spec_from_file_location("profuzzbench_monitor_test", MONITOR)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load monitor module from {MONITOR}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class RichMonitorTests(unittest.TestCase):
    def test_docker_labels_supply_project_order_and_stage_path(self) -> None:
        monitor = load_monitor_module()
        reader = monitor.DockerReader("docker", 1)
        record = {
            "Id": "abcdef1234567890",
            "Name": "/labelled-container",
            "Config": {
                "Labels": {
                    "voltronbench.project": "lightftp",
                    "voltronbench.project_index": "7",
                    "voltronbench.stage_file": "/runtime/out/.stage",
                }
            },
            "State": {
                "Status": "running",
                "ExitCode": 0,
                "StartedAt": "2026-07-30T00:00:00Z",
                "FinishedAt": monitor.ZERO_TIME,
            },
        }

        snapshot = reader._snapshot_for(
            "abcdef123456",
            [record],
            experiment_elapsed=5,
            timeout=60,
            now=datetime(2026, 7, 30, 0, 0, 5, tzinfo=timezone.utc),
        )

        self.assertEqual(snapshot.project, "lightftp")
        self.assertEqual(snapshot.project_index, 7)
        self.assertEqual(snapshot.stage_file, "/runtime/out/.stage")

    def test_live_view_shows_one_project_and_preserves_original_run_number(self) -> None:
        monitor = load_monitor_module()
        snapshots = [
            monitor.ContainerSnapshot(
                container_id="111111111111",
                status="running",
                note="OK",
            ),
            monitor.ContainerSnapshot(
                container_id="222222222222",
                status="running",
                note="OK",
            ),
        ]
        output = io.StringIO()
        console = monitor.Console(file=output, width=120, color_system=None)

        console.print(
            monitor.build_dashboard(
                "carousel",
                timeout=60,
                elapsed=5,
                snapshots=snapshots,
                visible_index=1,
                rotation_interval=5,
                show_project=True,
            )
        )
        rendered = output.getvalue()

        self.assertNotIn("111111111111", rendered)
        self.assertIn("222222222222", rendered)
        self.assertIn("view project 2/2", rendered)
        self.assertIn("rotates every 5s", rendered)
        self.assertIn("PROJECT", rendered)
        self.assertIn("containers=2", rendered)

    def test_snapshot_displays_phase_and_archive_collection_progress(self) -> None:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8") as progress:
            progress.write("Collecting archives 1/2")
            progress.flush()
            completed = subprocess.run(
                [
                    "python3",
                    str(MONITOR),
                    "snapshot",
                    "--label",
                    "demo",
                    "--timeout",
                    "60",
                    "--start-epoch",
                    str(int(time.time()) - 5),
                    "--stage-file",
                    "/tmp/phase",
                    "--progress-file",
                    progress.name,
                    "--demo",
                ],
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("PHASE", completed.stdout)
        self.assertIn("FUZZING 0/4", completed.stdout)
        self.assertIn("workflow Collecting archives 1/2", completed.stdout)

    def test_background_wrapper_pid_is_the_rich_process_and_stops_cleanly(self) -> None:
        command = f'''\
source "{COMMON}"
PROFUZZBENCH_MONITOR_INTERVAL=30
profuzzbench_monitor_containers close-check 60 absent-container &
monitor_pid=$!
sleep 0.3
ps -o comm= -p "$monitor_pid"
kill -TERM "$monitor_pid"
wait "$monitor_pid"
'''
        completed = subprocess.run(
            ["bash", "-c", command],
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("python3", completed.stdout)


if __name__ == "__main__":
    unittest.main()
