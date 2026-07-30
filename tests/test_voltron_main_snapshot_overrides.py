from pathlib import Path
import subprocess
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
EXECUTION_DIR = PROJECT_ROOT / "benchmark" / "scripts" / "execution"


class VoltronMainSnapshotOverrideTests(unittest.TestCase):
    def test_overrides_are_shell_valid_and_cover_failed_suts(self) -> None:
        expected = {
            "forked-daapd": {"setup.sh", "run.sh"},
            "kamailio": {"run.sh"},
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

        self.assertIn("voltron-subject-overrides", host_runner)
        self.assertIn("voltron-main-runtime.patch", host_runner)
        self.assertIn("apply_subject_overrides", container_runner)
        self.assertIn("apply_main_runtime_patch", container_runner)
        self.assertIn("COMPLIANCE_ANALYZER:-analyze_compliance.py", container_runner)
        self.assertIn('--input "$OUTDIR"', container_runner)
        self.assertIn("generation_retry_limit", runtime_patch)
        self.assertIn("giving up mutator generation", runtime_patch)
        self.assertIn("giving up checker generation", runtime_patch)
        self.assertIn("giving up observer generation", runtime_patch)
        self.assertIn("if result is None:", runtime_patch)
        self.assertNotIn("lighttpd", str(list((EXECUTION_DIR / "voltron-subject-overrides").rglob("*"))))


if __name__ == "__main__":
    unittest.main()
