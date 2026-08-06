import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import time
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUN_VOLTRON = PROJECT_ROOT / "run_voltron.sh"
EXEC_ALL = (
    PROJECT_ROOT
    / "benchmark"
    / "scripts"
    / "execution"
    / "profuzzbench_exec_all.sh"
)


def wait_for(predicate, timeout: float = 10.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("condition was not satisfied before timeout")


class VoltronOrchestrationTests(unittest.TestCase):
    def test_prepare_voltron_can_extract_a_digest_keyed_source_image(self) -> None:
        prepare = PROJECT_ROOT / "scripts" / "prepare_voltron.sh"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "image-source"
            (source / "config").mkdir(parents=True)
            (source / "voltron" / "synthesizer").mkdir(parents=True)
            (source / "pyproject.toml").write_text("[project]\nname='image'\n")
            (source / "cli.py").write_text("#!/usr/bin/env python3\n")
            (source / "config" / "configs.yaml").write_text("  api_key: test\n")
            (source / "voltron" / "synthesizer" / "synthesizer.py").write_text(
                "# image synthesizer\n"
            )
            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_docker = fake_bin / "docker"
            fake_docker.write_text(
                """#!/bin/bash
set -eu
if [ "$1" = pull ]; then exit 0; fi
if [ "$1" = image ] && [ "$2" = inspect ]; then
  printf 'sha256:%s\\n' 'a'
  exit 0
fi
if [ "$1" = create ]; then printf 'fake-container\\n'; exit 0; fi
if [ "$1" = cp ]; then cp -a "$FAKE_SOURCE/." "${@: -1}"; exit 0; fi
if [ "$1" = rm ]; then exit 0; fi
exit 2
""",
                encoding="utf-8",
            )
            fake_docker.chmod(0o755)
            cache = root / "cache"
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                    "FAKE_SOURCE": str(source),
                    "VOLTRON_SOURCE_IMAGE": "registry.example/voltron:test",
                    "VOLTRON_CACHE_DIR": str(cache),
                }
            )
            completed = subprocess.run(
                ["bash", str(prepare)],
                text=True,
                capture_output=True,
                check=True,
                env=environment,
            )
            snapshot = Path(completed.stdout.strip())
            self.assertTrue(snapshot.is_dir())
            self.assertTrue((snapshot / "cli.py").is_file())
            self.assertEqual(
                (snapshot / ".benchmark-voltron-commit").read_text().strip(),
                "image:sha256:a",
            )
            self.assertEqual(
                (snapshot / ".benchmark-voltron-source-image").read_text().strip(),
                "registry.example/voltron:test",
            )
            self.assertIn(
                "<set-with-VOLTRON_LLM_API_KEY>",
                (snapshot / "config" / "configs.yaml").read_text(),
            )
            self.assertTrue((snapshot / ".benchmark-ready").is_file())

    def test_prepare_voltron_rebuilds_incomplete_cached_snapshot(self) -> None:
        prepare = PROJECT_ROOT / "scripts" / "prepare_voltron.sh"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            (source / "config").mkdir(parents=True)
            (source / "voltron" / "synthesizer").mkdir(parents=True)
            (source / "pyproject.toml").write_text("[project]\nname='test'\n")
            (source / "cli.py").write_text("#!/usr/bin/env python3\n")
            (source / "config" / "configs.yaml").write_text("  api_key: test\n")
            (source / "voltron" / "synthesizer" / "synthesizer.py").write_text(
                "# synthesizer\n"
            )
            subprocess.run(["git", "init", "-q"], cwd=source, check=True)
            subprocess.run(["git", "add", "."], cwd=source, check=True)
            subprocess.run(
                [
                    "git",
                    "-c",
                    "user.name=Test",
                    "-c",
                    "user.email=test@example.invalid",
                    "commit",
                    "-qm",
                    "snapshot",
                ],
                cwd=source,
                check=True,
            )
            environment = os.environ.copy()
            environment.update(
                {
                    "VOLTRON_REPO": str(source),
                    "VOLTRON_REF": "HEAD",
                    "VOLTRON_CACHE_DIR": str(root / "cache"),
                }
            )

            first = subprocess.run(
                ["bash", str(prepare)],
                text=True,
                capture_output=True,
                check=True,
                env=environment,
            )
            snapshot = Path(first.stdout.strip())
            (snapshot / "config" / "configs.yaml").unlink()

            second = subprocess.run(
                ["bash", str(prepare)],
                text=True,
                capture_output=True,
                check=True,
                env=environment,
            )
            self.assertEqual(snapshot, Path(second.stdout.strip()))
            self.assertTrue((snapshot / ".benchmark-ready").is_file())
            self.assertEqual(
                (snapshot / ".benchmark-voltron-commit").read_text().strip(),
                subprocess.check_output(
                    ["git", "rev-parse", "HEAD"],
                    cwd=source,
                    text=True,
                ).strip(),
            )
            self.assertEqual(snapshot.stat().st_mode & 0o777, 0o755)
            self.assertTrue((snapshot / "config" / "configs.yaml").is_file())
            self.assertTrue(
                (snapshot / "voltron" / "synthesizer" / "synthesizer.py").is_file()
            )

            snapshot.chmod(0o700)
            third = subprocess.run(
                ["bash", str(prepare)],
                text=True,
                capture_output=True,
                check=True,
                env=environment,
            )
            self.assertEqual(snapshot, Path(third.stdout.strip()))
            self.assertEqual(snapshot.stat().st_mode & 0o777, 0o755)

    def test_run_voltron_propagates_failed_container_status(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = root / "run_voltron.sh"
            shutil.copy2(RUN_VOLTRON, runner)

            execution_dir = root / "benchmark" / "scripts" / "execution"
            execution_dir.mkdir(parents=True)
            (execution_dir / "profuzzbench_monitor_common.sh").write_text(
                """\
PROFUZZBENCH_MONITOR=0
PROFUZZBENCH_COLLECT_ON_INTERRUPT=1
profuzzbench_stop_monitor() { :; }
profuzzbench_print_final_container_summary() { :; }
profuzzbench_interrupt_containers() { :; }
""",
                encoding="utf-8",
            )

            coverage = (
                root
                / "benchmark"
                / "subjects"
                / "FTP"
                / "BFTPD"
                / "cov_script.sh"
            )
            coverage.parent.mkdir(parents=True)
            coverage.write_text("#!/bin/bash\n", encoding="utf-8")

            source = root / "voltron-source"
            source.mkdir()
            prepare = root / "scripts" / "prepare_voltron.sh"
            prepare.parent.mkdir()
            prepare.write_text(
                f"#!/bin/bash\nprintf '%s\\n' '{source}'\n",
                encoding="utf-8",
            )
            prepare.chmod(0o755)

            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_docker = fake_bin / "docker"
            fake_docker.write_text(
                """\
#!/bin/bash
case "$1" in
  run)
    printf '%s\n' abcdef1234567890
    ;;
  wait)
    printf '2\n'
    ;;
  cp)
    payload_root=$(mktemp -d)
    mkdir -p "$payload_root/$FAKE_OUTDIR"
    printf 'final-result\n' > "$payload_root/$FAKE_OUTDIR/marker.txt"
    tar -zcf "$3" -C "$payload_root" "$FAKE_OUTDIR"
    ;;
  rm)
    ;;
  *)
    exit 2
    ;;
esac
""",
                encoding="utf-8",
            )
            fake_docker.chmod(0o755)

            results = root / "results"
            outdir = "out-bftpd-voltron"
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                    "TMPDIR": str(root),
                    "FAKE_OUTDIR": outdir,
                    "VOLTRON_USE_API_GATEWAY": "1",
                    "VOLTRON_LLM_BASE_URL": "http://gateway.invalid/v1",
                    "VOLTRON_LLM_API_KEY": "internal",
                    "VOLTRON_LLM_MODEL": "test",
                    "VOLTRON_UV_CACHE_MODE": "legacy",
                }
            )

            completed = subprocess.run(
                [
                    "bash",
                    str(runner),
                    "bftpd-vol",
                    "1",
                    str(results),
                    "bftpd",
                    outdir,
                    "60",
                    "1",
                ],
                text=True,
                capture_output=True,
                check=False,
                env=environment,
                timeout=15,
            )

            self.assertEqual(completed.returncode, 1, completed.stdout)
            self.assertIn(
                "Container abcdef123456 exited with status 2",
                completed.stdout,
            )
            self.assertIn(
                "Completed with failed container(s)",
                completed.stdout,
            )
            archive = results / f"{outdir}_1.tar.gz"
            self.assertTrue(archive.is_file())

    def test_run_voltron_interrupts_waiter_and_saves_partial_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = root / "run_voltron.sh"
            shutil.copy2(RUN_VOLTRON, runner)

            execution_dir = root / "benchmark" / "scripts" / "execution"
            execution_dir.mkdir(parents=True)
            (execution_dir / "profuzzbench_monitor_common.sh").write_text(
                """\
PROFUZZBENCH_MONITOR="${PROFUZZBENCH_MONITOR:-0}"
PROFUZZBENCH_COLLECT_ON_INTERRUPT="${PROFUZZBENCH_COLLECT_ON_INTERRUPT:-1}"
profuzzbench_stop_monitor() { :; }
profuzzbench_print_final_container_summary() { :; }
profuzzbench_interrupt_containers() {
  docker stop -t 1 "$@" >/dev/null
}
""",
                encoding="utf-8",
            )

            coverage = (
                root
                / "benchmark"
                / "subjects"
                / "FTP"
                / "BFTPD"
                / "cov_script.sh"
            )
            coverage.parent.mkdir(parents=True)
            coverage.write_text("#!/bin/bash\n", encoding="utf-8")

            source = root / "voltron-source"
            source.mkdir()
            prepare = root / "scripts" / "prepare_voltron.sh"
            prepare.parent.mkdir()
            prepare.write_text(
                f"#!/bin/bash\nprintf '%s\\n' '{source}'\n",
                encoding="utf-8",
            )
            prepare.chmod(0o755)

            fake_bin = root / "bin"
            fake_bin.mkdir()
            fake_docker = fake_bin / "docker"
            fake_docker.write_text(
                """\
#!/bin/bash
case "$1" in
  run)
    printf '%s\n' 1234567890abcdef
    ;;
  wait)
    : > "$FAKE_DOCKER_MARKERS/wait-started"
    trap 'exit 143' INT TERM
    while :; do sleep 0.1; done
    ;;
  stop)
    : > "$FAKE_DOCKER_MARKERS/stopped"
    ;;
  cp)
    source_path=$2
    destination=$3
    if [[ "$source_path" == *.tar.gz ]]; then
      exit 1
    fi
    mkdir -p "$destination/$FAKE_OUTDIR"
    printf 'partial-result\n' > "$destination/$FAKE_OUTDIR/marker.txt"
    ;;
  rm)
    ;;
  *)
    printf 'unexpected docker command: %s\n' "$1" >&2
    exit 2
    ;;
esac
""",
                encoding="utf-8",
            )
            fake_docker.chmod(0o755)

            markers = root / "markers"
            markers.mkdir()
            results = root / "results"
            outdir = "out-bftpd-voltron"
            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}:{environment['PATH']}",
                    "FAKE_DOCKER_MARKERS": str(markers),
                    "FAKE_OUTDIR": outdir,
                    "PROFUZZBENCH_MONITOR": "0",
                    "PROFUZZBENCH_COLLECT_ON_INTERRUPT": "1",
                    "VOLTRON_USE_API_GATEWAY": "1",
                    "VOLTRON_LLM_BASE_URL": "http://gateway.invalid/v1",
                    "VOLTRON_LLM_API_KEY": "internal",
                    "VOLTRON_LLM_MODEL": "test",
                    "VOLTRON_UV_CACHE_MODE": "legacy",
                }
            )

            process = subprocess.Popen(
                [
                    "bash",
                    str(runner),
                    "bftpd-vol",
                    "1",
                    str(results),
                    "bftpd",
                    outdir,
                    "60",
                    "1",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=environment,
            )
            try:
                wait_for(lambda: (markers / "wait-started").exists())
                process.terminate()
                output, _ = process.communicate(timeout=15)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

            self.assertEqual(process.returncode, 130, output)
            self.assertTrue((markers / "stopped").exists())
            self.assertIn("Saved partial result directory", output)
            archive = results / f"{outdir}_1.tar.gz"
            self.assertTrue(archive.is_file())
            with tarfile.open(archive, "r:gz") as result_archive:
                self.assertIn(f"{outdir}/marker.txt", result_archive.getnames())

    def test_exec_all_terminates_all_voltron_launchers_on_signal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            benchmark = root / "benchmark"
            execution_dir = benchmark / "scripts" / "execution"
            execution_dir.mkdir(parents=True)
            runner = execution_dir / "profuzzbench_exec_all.sh"
            shutil.copy2(EXEC_ALL, runner)

            (execution_dir / "profuzzbench_monitor_common.sh").write_text(
                """\
PROFUZZBENCH_MONITOR="${PROFUZZBENCH_MONITOR:-1}"
profuzzbench_monitor_containers() { exec sleep 100; }
profuzzbench_stop_monitor() {
  kill "$1" 2>/dev/null || true
  wait "$1" 2>/dev/null || true
}
profuzzbench_print_final_container_summary() { :; }
""",
                encoding="utf-8",
            )

            launcher = root / "run_voltron.sh"
            launcher.write_text(
                """\
#!/bin/bash
printf '%s\n' "$$" >> "$FAKE_LAUNCHER_PIDS"
trap 'printf "%s\\n" "$$" >> "$FAKE_LAUNCHER_TERMINATED"; exit 130' TERM
while :; do sleep 0.1; done
""",
                encoding="utf-8",
            )
            launcher.chmod(0o755)

            pids_file = root / "launcher-pids"
            terminated_file = root / "launcher-terminated"
            results = root / "results"
            environment = os.environ.copy()
            environment.update(
                {
                    "PFBENCH": str(benchmark),
                    "RESULTS_ROOT": str(results),
                    "NUM_CONTAINERS": "1",
                    "TIMEOUT": "60",
                    "SKIPCOUNT": "1",
                    "PROFUZZBENCH_MONITOR": "1",
                    "FAKE_LAUNCHER_PIDS": str(pids_file),
                    "FAKE_LAUNCHER_TERMINATED": str(terminated_file),
                }
            )

            process = subprocess.Popen(
                [
                    "bash",
                    str(runner),
                    "live555,kamailio",
                    "voltron",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                env=environment,
            )
            try:
                wait_for(
                    lambda: pids_file.exists()
                    and len(pids_file.read_text(encoding="utf-8").splitlines())
                    == 2
                )
                process.terminate()
                output, _ = process.communicate(timeout=15)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()

            self.assertEqual(process.returncode, 130, output)
            self.assertIn("interrupt received", output)
            terminated = terminated_file.read_text(
                encoding="utf-8"
            ).splitlines()
            launched = pids_file.read_text(encoding="utf-8").splitlines()
            self.assertCountEqual(terminated, launched)


if __name__ == "__main__":
    unittest.main()
