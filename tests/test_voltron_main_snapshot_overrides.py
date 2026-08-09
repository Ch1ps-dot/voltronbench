from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
EXECUTION_DIR = PROJECT_ROOT / "benchmark" / "scripts" / "execution"


class VoltronMainSnapshotOverrideTests(unittest.TestCase):
    def test_kamailio_voltron_ports_are_consistent(self) -> None:
        kamailio_runner = (
            EXECUTION_DIR / "voltron-subject-overrides" / "kamailio" / "run.sh"
        ).read_text(encoding="utf-8")
        coverage_runner = (
            EXECUTION_DIR / "profuzzbench_voltron_coverage.sh"
        ).read_text(encoding="utf-8")
        udp_patch = (
            EXECUTION_DIR / "voltron-udp-bind-runtime.patch"
        ).read_text(encoding="utf-8")
        aflnet_launcher = (
            EXECUTION_DIR / "profuzzbench_exec_all.sh"
        ).read_text(encoding="utf-8")
        aflnet_runner = (
            PROJECT_ROOT / "benchmark" / "subjects" / "SIP" / "Kamailio"
            / "run.sh"
        ).read_text(encoding="utf-8")

        self.assertNotIn("-l udp:127.0.0.1:5061", kamailio_runner)
        self.assertIn("PORT=5060", coverage_runner)
        self.assertIn("5061", udp_patch)
        self.assertIn("-N udp://127.0.0.1/5060", aflnet_runner)
        self.assertIn("-l 5061", aflnet_launcher)

    def test_overrides_are_shell_valid_and_cover_failed_suts(self) -> None:
        expected = {
            "bftpd": {"run.sh"},
            "exim": {"setup.sh", "run.sh", "ready.sh"},
            "forked-daapd": {"setup.sh", "run.sh"},
            "kamailio": {"setup.sh", "run.sh", "pjsua_lifecycle.sh"},
            "lightftp": {"setup.sh", "run.sh"},
            "pure-ftpd": {"setup.sh"},
        }
        overrides = EXECUTION_DIR / "voltron-subject-overrides"
        for target, names in expected.items():
            target_dir = overrides / target
            self.assertEqual({path.name for path in target_dir.iterdir()}, names)
            for name in names:
                completed = subprocess.run(
                    ["bash", "-n", str(target_dir / name)],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_bftpd_override_execs_the_owned_server_process(self) -> None:
        run_script = (
            EXECUTION_DIR / "voltron-subject-overrides" / "bftpd" / "run.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("exec /home/ubuntu/experiments/bftpd/bftpd", run_script)
        self.assertIn("/home/ubuntu/experiments/basic.conf", run_script)

    def test_exim_setup_is_idempotent_and_pid_scoped(self) -> None:
        setup = EXECUTION_DIR / "voltron-subject-overrides" / "exim" / "setup.sh"

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pidfile = root / "exim.pid"
            environment = {**os.environ, "EXIM_PIDFILE": str(pidfile)}

            for contents in (None, "", "not-a-pid\n", "999999999\n"):
                if contents is None:
                    pidfile.unlink(missing_ok=True)
                else:
                    pidfile.write_text(contents, encoding="utf-8")
                completed = subprocess.run(
                    [str(setup)],
                    env=environment,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertFalse(pidfile.exists())

            foreign = subprocess.Popen(["sleep", "60"])
            try:
                pidfile.write_text(f"{foreign.pid}\n", encoding="utf-8")
                completed = subprocess.run(
                    [str(setup)],
                    env=environment,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertIsNone(foreign.poll())
                self.assertFalse(pidfile.exists())
            finally:
                foreign.terminate()
                foreign.wait(timeout=5)

            exim = root / "exim"
            shutil.copy2("/bin/sleep", exim)
            exim.chmod(0o755)
            target = subprocess.Popen([str(exim), "60"])
            try:
                pidfile.write_text(f"{target.pid}\n", encoding="utf-8")
                completed = subprocess.run(
                    [str(setup)],
                    env=environment,
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                target.wait(timeout=5)
                self.assertFalse(pidfile.exists())
            finally:
                if target.poll() is None:
                    target.kill()
                    target.wait(timeout=5)

    def test_exim_override_owns_server_and_checks_smtp_banner(self) -> None:
        exim_dir = EXECUTION_DIR / "voltron-subject-overrides" / "exim"
        run_script = (exim_dir / "run.sh").read_text(encoding="utf-8")
        readiness_script = (exim_dir / "ready.sh").read_text(encoding="utf-8")
        container_runner = (
            EXECUTION_DIR / "profuzzbench_voltron_container.sh"
        ).read_text(encoding="utf-8")

        self.assertIn("exec /usr/exim/bin/exim", run_script)
        self.assertIn("/tmp/voltron-exim.pid", run_script)
        self.assertIn("banner.startswith(b\"220 \")", readiness_script)
        self.assertIn("apply_exim_lifecycle_override", container_runner)
        self.assertIn("readiness_script: ready.sh", container_runner)

    def test_forked_daapd_uses_a_target_scoped_readiness_default(self) -> None:
        container_runner = (
            EXECUTION_DIR / "profuzzbench_voltron_container.sh"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "VOLTRON_FORKED_DAAPD_READINESS_TIMEOUT_SECONDS:-10",
            container_runner,
        )
        self.assertIn("apply_forked_daapd_timeout_overrides", container_runner)

    def test_runner_applies_overrides_and_main_retry_patch(self) -> None:
        host_runner = (PROJECT_ROOT / "run_voltron.sh").read_text(
            encoding="utf-8"
        )
        container_runner = (
            EXECUTION_DIR / "profuzzbench_voltron_container.sh"
        ).read_text(encoding="utf-8")
        runtime_patch = (EXECUTION_DIR / "voltron-main-runtime.patch").read_text(
            encoding="utf-8"
        )
        generator_patch = (
            EXECUTION_DIR / "voltron-generator-evolution-runtime.patch"
        ).read_text(encoding="utf-8")

        self.assertIn("voltron-subject-overrides", host_runner)
        self.assertIn("voltron-main-runtime.patch", host_runner)
        self.assertIn("voltron-generator-evolution-runtime.patch", host_runner)
        self.assertIn("apply_subject_overrides", container_runner)
        self.assertIn("verify_subject_lifecycle_override", container_runner)
        self.assertIn(
            "Bftpd lifecycle override did not take ownership",
            container_runner,
        )
        self.assertIn("apply_main_runtime_patch", container_runner)
        self.assertIn("main_runtime_patch_is_present", container_runner)
        self.assertIn("apply_generator_evolution_runtime_patch", container_runner)
        self.assertIn(
            "falling back to the best generator for %s after %d attempts",
            container_runner,
        )
        self.assertIn("RAW_SHA256_OBSERVER", container_runner)
        self.assertIn("using raw SHA-256 observer fallback", container_runner)
        self.assertIn("COMPLIANCE_ANALYZER:-analyze_compliance.py", container_runner)
        self.assertIn('--input "$OUTDIR"', container_runner)
        self.assertIn("generation_retry_limit", runtime_patch)
        self.assertIn("giving up mutator generation", runtime_patch)
        self.assertIn("giving up checker generation", runtime_patch)
        self.assertIn("giving up observer generation", runtime_patch)
        self.assertIn("if result is None:", runtime_patch)
        self.assertIn("giving up generator evolution", generator_patch)
        self.assertIn("no generated baseline exists", generator_patch)
        self.assertIn("PLAY_NOTIFY (scale-change)", generator_patch)
        self.assertNotIn("lighttpd", str(list((EXECUTION_DIR / "voltron-subject-overrides").rglob("*"))))

    def test_main_runtime_detector_recognizes_hardened_upstream_source(self) -> None:
        runner = (
            EXECUTION_DIR / "profuzzbench_voltron_container.sh"
        ).read_text(encoding="utf-8")
        start = runner.index("main_runtime_patch_is_present()")
        end = runner.index("apply_main_runtime_patch()")
        detector = runner[start:end]

        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "voltron" / "synthesizer"
            source.mkdir(parents=True)
            (source / "synthesizer.py").write_text(
                "\n".join(
                    [
                        "generation_retry_limit",
                        "'Producer: falling back to the best generator for %s after %d attempts'",
                        "RAW_SHA256_OBSERVER",
                        "using raw SHA-256 observer fallback for %s",
                        "giving up checker generation for %s after %d attempts",
                    ]
                ),
                encoding="utf-8",
            )
            completed = subprocess.run(
                ["bash", "-c", f"{detector}\nmain_runtime_patch_is_present"],
                cwd=temporary,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)


if __name__ == "__main__":
    unittest.main()
