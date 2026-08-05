from pathlib import Path
import os
import shutil
import socket
import subprocess
import tempfile
import textwrap
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
EXEC_ALL = (
    PROJECT_ROOT
    / "benchmark"
    / "scripts"
    / "execution"
    / "profuzzbench_exec_all.sh"
)
COMMON_RUNNER = (
    PROJECT_ROOT
    / "benchmark"
    / "scripts"
    / "execution"
    / "profuzzbench_exec_common.sh"
)
TARGET_RUNNER = (
    PROJECT_ROOT / "benchmark" / "subjects" / "DAAP" / "forked-daapd" / "run.sh"
)
PREFLIGHT = TARGET_RUNNER.with_name("preflight.sh")


class ForkedDaapdStateAFLTimeoutTests(unittest.TestCase):
    def test_timeout_floor_and_start_stagger_are_target_scoped(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            benchmark = root / "benchmark"
            execution = benchmark / "scripts" / "execution"
            execution.mkdir(parents=True)
            runner = execution / EXEC_ALL.name
            shutil.copy2(EXEC_ALL, runner)
            (execution / "profuzzbench_monitor_common.sh").write_text(
                "PROFUZZBENCH_MONITOR=0\n",
                encoding="utf-8",
            )

            fake_bin = root / "bin"
            fake_bin.mkdir()
            capture = root / "capture.txt"
            fake_common = fake_bin / "profuzzbench_exec_common.sh"
            fake_common.write_text(
                textwrap.dedent(
                    """\
                    #!/bin/bash
                    printf 'delay=%s\n' "$PROFUZZBENCH_CONTAINER_START_DELAY_SECONDS" > "$CAPTURE"
                    printf 'arg=%s\n' "$@" >> "$CAPTURE"
                    """
                ),
                encoding="utf-8",
            )
            fake_common.chmod(0o755)

            environment = os.environ.copy()
            environment.pop("FORKED_DAAPD_MIN_TEST_TIMEOUT_MS", None)
            environment.pop("FORKED_DAAPD_CONTAINER_START_DELAY_SECONDS", None)
            environment.update(
                {
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                    "PFBENCH": str(benchmark),
                    "RESULTS_ROOT": str(root / "results"),
                    "NUM_CONTAINERS": "2",
                    "TIMEOUT": "600",
                    "SKIPCOUNT": "1",
                    "TEST_TIMEOUT": "5000",
                    "CAPTURE": str(capture),
                    "PROFUZZBENCH_MONITOR": "0",
                }
            )
            completed = subprocess.run(
                ["bash", str(runner), "forked-daapd", "stateafl"],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            invocation = capture.read_text(encoding="utf-8")
            self.assertIn("delay=20", invocation)
            self.assertIn("-t 20000+", invocation)
            self.assertIn("forked-daapd-stateafl-vol", invocation)

    def test_non_stateafl_target_does_not_receive_start_stagger(self) -> None:
        source = EXEC_ALL.read_text(encoding="utf-8")
        self.assertIn('container_start_delay=0', source)
        self.assertIn('if [[ "$target" == "forked-daapd" ]]', source)
        self.assertIn(
            "container_start_delay=$FORKED_DAAPD_CONTAINER_START_DELAY_SECONDS",
            source,
        )

    @unittest.skipUnless(shutil.which("nc"), "netcat is required for the preflight")
    def test_preflight_requires_http_response_and_cleans_up_target(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                port = reservation.getsockname()[1]

            target = root / "fake-forked-daapd"
            target.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    from http.server import BaseHTTPRequestHandler, HTTPServer
                    import os

                    class Handler(BaseHTTPRequestHandler):
                        def do_GET(self):
                            body = b"{}"
                            self.send_response(200)
                            self.send_header("Content-Length", str(len(body)))
                            self.end_headers()
                            self.wfile.write(body)

                        def log_message(self, *args):
                            pass

                    HTTPServer(("127.0.0.1", int(os.environ["FAKE_PORT"])), Handler).serve_forever()
                    """
                ),
                encoding="utf-8",
            )
            target.chmod(0o755)
            config = root / "forked-daapd.conf"
            config.write_text("test\n", encoding="utf-8")
            log = root / "preflight.log"
            environment = os.environ.copy()
            environment.update(
                {
                    "FAKE_PORT": str(port),
                    "FORKED_DAAPD_PREFLIGHT_PORT": str(port),
                    "FORKED_DAAPD_PREFLIGHT_ATTEMPTS": "30",
                    "FORKED_DAAPD_PREFLIGHT_INTERVAL_SECONDS": "0.05",
                }
            )
            completed = subprocess.run(
                ["bash", str(PREFLIGHT), str(target), str(config), str(log)],
                text=True,
                capture_output=True,
                env=environment,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            evidence = log.read_text(encoding="utf-8")
            self.assertIn("http_status_line=HTTP/1.0 200 OK", evidence)
            self.assertIn("preflight_status=passed", evidence)
            with socket.socket() as probe:
                self.assertNotEqual(probe.connect_ex(("127.0.0.1", port)), 0)

    def test_runner_rejects_incomplete_stateafl_initial_seed_calibration(self) -> None:
        source = TARGET_RUNNER.read_text(encoding="utf-8")
        self.assertIn("validate_stateafl_initial_seeds", source)
        self.assertIn("replayed_initial_seeds", source)
        self.assertIn("STATUS=1", source)
        self.assertIn("shorter than 300 seconds", source)

    def test_shell_entrypoints_are_valid(self) -> None:
        for script in (EXEC_ALL, COMMON_RUNNER, TARGET_RUNNER, PREFLIGHT):
            completed = subprocess.run(
                ["bash", "-n", str(script)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)


if __name__ == "__main__":
    unittest.main()
