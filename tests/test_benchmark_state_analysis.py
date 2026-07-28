import csv
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
GENERATE_CSV = (
    PROJECT_ROOT
    / "benchmark"
    / "scripts"
    / "analysis"
    / "profuzzbench_generate_csv.sh"
)
STATE_PLOT = (
    PROJECT_ROOT
    / "benchmark"
    / "scripts"
    / "analysis"
    / "profuzzbench_state.py"
)
STATEAFL_COMMIT = "d923e22f7b2688db45b08f3fa3a29a566e7ff3a4"


class StateCsvConversionTests(unittest.TestCase):
    def _write_archive(self, root: Path, plot_data: str) -> None:
        output = root / "out-demo-stateafl"
        output.mkdir()
        (output / "plot_data").write_text(plot_data, encoding="utf-8")
        (output / "cov_over_time.csv").write_text(
            "Time,l_per,l_abs,b_per,b_abs\n1,1.0,1,2.0,2\n",
            encoding="utf-8",
        )
        with tarfile.open(root / "out-demo-stateafl_1.tar.gz", "w:gz") as archive:
            archive.add(output, arcname=output.name)

    def _run_conversion(self, root: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "bash",
                str(GENERATE_CSV),
                "demo",
                "1",
                "stateafl",
                "results.csv",
                "0",
                "states.csv",
            ],
            cwd=root,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_converts_named_state_columns(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_archive(
                root,
                (
                    "# unix_time, cycles_done, cur_path, paths_total, "
                    "pending_total, pending_favs, map_size, unique_crashes, "
                    "unique_hangs, max_depth, execs_per_sec, n_nodes, n_edges\n"
                    "100, 0, 0, 2, 2, 1, 1.0%, 0, 0, 1, 2.0, 3, 4\n"
                ),
            )

            result = self._run_conversion(root)

            self.assertEqual(result.returncode, 0, result.stderr)
            with (root / "states.csv").open(newline="", encoding="utf-8") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(
                [(row["state_type"], row["state"]) for row in rows],
                [("nodes", "3"), ("edges", "4")],
            )

    def test_rejects_legacy_plot_data_without_state_columns(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_archive(
                root,
                (
                    "# unix_time, cycles_done, cur_path, paths_total, "
                    "pending_total, pending_favs, map_size, unique_crashes, "
                    "unique_hangs, max_depth, execs_per_sec\n"
                    "100, 0, 0, 2, 2, 1, 1.0%, 0, 0, 1, 2.0\n"
                ),
            )

            result = self._run_conversion(root)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("State data schema error", result.stderr)
            self.assertEqual(
                (root / "states.csv").read_text(encoding="utf-8").splitlines(),
                ["time,subject,fuzzer,run,state_type,state"],
            )


class StatePlotTests(unittest.TestCase):
    def test_missing_run_is_excluded_instead_of_counted_as_zero(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state_csv = root / "states.csv"
            state_csv.write_text(
                (
                    "time,subject,fuzzer,run,state_type,state\n"
                    "100,demo,stateafl,1,nodes,4\n"
                    "100,demo,stateafl,1,edges,6\n"
                ),
                encoding="utf-8",
            )
            env = os.environ.copy()
            env["MPLBACKEND"] = "Agg"

            result = subprocess.run(
                [
                    "python3",
                    str(STATE_PLOT),
                    "-i",
                    str(state_csv),
                    "-p",
                    "demo",
                    "-r",
                    "2",
                    "-c",
                    "1",
                    "-s",
                    "1",
                    "-o",
                    str(root / "states.png"),
                    "-f",
                    "stateafl",
                ],
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            with (root / "mean_plot_data.csv").open(
                newline="", encoding="utf-8"
            ) as stream:
                rows = list(csv.DictReader(stream))
            values = {
                (row["data_type"], row["time"]): float(row["data"])
                for row in rows
            }
            self.assertEqual(values[("nodes", "0")], 4.0)
            self.assertEqual(values[("nodes", "1")], 4.0)
            self.assertEqual(values[("edges", "0")], 6.0)
            self.assertEqual(values[("edges", "1")], 6.0)


class StateAflImageConfigurationTests(unittest.TestCase):
    def test_all_stateafl_images_use_the_same_patch_and_commit(self) -> None:
        dockerfiles = sorted(
            (PROJECT_ROOT / "benchmark" / "subjects").glob(
                "**/Dockerfile-stateafl"
            )
        )
        self.assertEqual(len(dockerfiles), 9)

        patches = []
        for dockerfile in dockerfiles:
            contents = dockerfile.read_text(encoding="utf-8")
            self.assertIn(STATEAFL_COMMIT, contents, dockerfile)
            self.assertIn("stateafl-benchmark.patch", contents, dockerfile)
            patches.append(
                (dockerfile.parent / "stateafl-benchmark.patch").read_bytes()
            )

        self.assertTrue(all(patch == patches[0] for patch in patches[1:]))

        initial_state_targets = {
            PROJECT_ROOT
            / "benchmark"
            / "subjects"
            / "SMTP"
            / "Exim"
            / "Dockerfile-stateafl",
            PROJECT_ROOT
            / "benchmark"
            / "subjects"
            / "HTTP"
            / "Lighttpd1"
            / "Dockerfile-stateafl",
        }
        for dockerfile in dockerfiles:
            contents = dockerfile.read_text(encoding="utf-8")
            if dockerfile in initial_state_targets:
                self.assertIn("stateafl-initial-state.patch", contents)
            else:
                self.assertNotIn("stateafl-initial-state.patch", contents)


if __name__ == "__main__":
    unittest.main()
