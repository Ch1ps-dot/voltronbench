import csv
import os
from pathlib import Path
import pickle
import struct
import subprocess
import tarfile
import tempfile
from types import SimpleNamespace
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
EXPORTER = (
    PROJECT_ROOT
    / "benchmark"
    / "scripts"
    / "execution"
    / "profuzzbench_export_voltron_replay.py"
)


def decode_aflnet_case(path: Path) -> list[bytes]:
    data = path.read_bytes()
    requests = []
    offset = 0
    while offset < len(data):
        if offset + 4 > len(data):
            raise AssertionError("truncated AFLNet request length")
        request_size = struct.unpack_from("<I", data, offset)[0]
        offset += 4
        request_end = offset + request_size
        if request_end > len(data):
            raise AssertionError("truncated AFLNet request")
        requests.append(data[offset:request_end])
        offset = request_end
    return requests


class VoltronCoverageExportTests(unittest.TestCase):
    def test_exporter_preserves_order_bytes_and_timestamps(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result_dir = Path(temporary) / "results"
            source_dir = result_dir / "replayable_testcases"
            source_dir.mkdir(parents=True)

            later = source_dir / "cons_000000.pkl"
            earlier = source_dir / "cons_000001.pkl"
            invalid = source_dir / "cons_000002.pkl"
            with later.open("wb") as stream:
                pickle.dump(
                    SimpleNamespace(
                        req_seq=["-", "PASS"],
                        content=[
                            (b"", b"220 ready\r\n"),
                            (b"PASS secret\r\n", b"230 ok\r\n"),
                        ],
                    ),
                    stream,
                )
            with earlier.open("wb") as stream:
                pickle.dump(
                    SimpleNamespace(
                        req_seq=["USER", "NOOP"],
                        content=[
                            (b"USER test\r\n", b"331 password\r\n"),
                            (b"NOOP\r\n", b"200 ok\r\n"),
                        ],
                    ),
                    stream,
                )
            invalid.write_bytes(b"not a pickle")
            os.utime(earlier, (100, 100))
            os.utime(later, (200, 200))
            os.utime(invalid, (300, 300))

            completed = subprocess.run(
                [
                    "python3",
                    str(EXPORTER),
                    "--result-dir",
                    str(result_dir),
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("exported=2 skipped=1", completed.stdout)
            queue = result_dir / "replayable-queue"
            first = queue / "id:000000,src:voltron"
            second = queue / "id:000001,src:voltron"
            self.assertEqual(
                decode_aflnet_case(first),
                [b"USER test\r\n", b"NOOP\r\n"],
            )
            self.assertEqual(
                decode_aflnet_case(second),
                [b"PASS secret\r\n"],
            )
            self.assertEqual(int(first.stat().st_mtime), 100)
            self.assertEqual(int(second.stat().st_mtime), 200)

            with (
                result_dir / "voltron_aflnet_replay_manifest.csv"
            ).open(newline="", encoding="utf-8") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(
                [row["source_pickle"] for row in rows],
                ["cons_000001.pkl", "cons_000000.pkl"],
            )
            self.assertEqual(
                [row["request_count"] for row in rows],
                ["2", "1"],
            )

    def test_runner_mounts_and_executes_coverage_pipeline(self) -> None:
        host_runner = (PROJECT_ROOT / "run_voltron.sh").read_text(
            encoding="utf-8"
        )
        container_runner = (
            PROJECT_ROOT
            / "benchmark"
            / "scripts"
            / "execution"
            / "profuzzbench_voltron_container.sh"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "profuzzbench_export_voltron_replay.py",
            host_runner,
        )
        self.assertIn("profuzzbench_voltron_coverage.sh", host_runner)
        self.assertIn(
            "dst=/opt/voltron-target-cov-script.sh",
            host_runner,
        )
        self.assertIn(
            "uv run python /opt/voltron-export-aflnet-replay.py",
            container_runner,
        )
        self.assertIn(
            "/bin/bash /opt/voltron-coverage.sh",
            container_runner,
        )
        self.assertIn('set_stage "PACKAGING 3/4: creating archive"', container_runner)
        self.assertIn('set_stage "ARCHIVE READY 4/4"', container_runner)
        self.assertIn("Collecting archives", host_runner)
        self.assertLess(
            host_runner.index("collect_results\nprofuzzbench_stop_monitor"),
            host_runner.index('printf "\\nVOLTRON: I am done!\\n"'),
        )
        self.assertNotIn(
            "without inventing coverage measurements",
            container_runner,
        )

    def test_generated_coverage_is_consumed_by_benchmark_analysis(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result_root = Path(temporary)
            output = result_root / "out-demo-voltron"
            output.mkdir()
            (output / "cov_over_time.csv").write_text(
                "Time,l_per,l_abs,b_per,b_abs\n"
                "100,10.0,20,5.0,8\n"
                "110,12.5,25,7.5,12\n",
                encoding="utf-8",
            )
            (output / "plot_data").write_text(
                "# unix_time, cycles_done, cur_path, paths_total, "
                "pending_total, pending_favs, map_size, unique_crashes, "
                "unique_hangs, max_depth, execs_per_sec, n_nodes, "
                "n_edges, chat_times\n"
                "100,0,0,1,0,0,0,0,0,0,0,3,2,0\n",
                encoding="utf-8",
            )
            with tarfile.open(
                result_root / "out-demo-voltron_1.tar.gz",
                "w:gz",
            ) as archive:
                archive.add(output, arcname=output.name)

            completed = subprocess.run(
                [
                    "bash",
                    str(
                        PROJECT_ROOT
                        / "benchmark"
                        / "scripts"
                        / "analysis"
                        / "profuzzbench_generate_csv.sh"
                    ),
                    "demo",
                    "1",
                    "voltron",
                    "results.csv",
                    "0",
                    "states.csv",
                ],
                cwd=result_root,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            with (result_root / "results.csv").open(
                newline="",
                encoding="utf-8",
            ) as stream:
                coverage_rows = list(csv.DictReader(stream))
            self.assertEqual(len(coverage_rows), 8)
            self.assertEqual(coverage_rows[-4]["time"], "110")
            self.assertEqual(coverage_rows[-4]["cov_type"], "l_per")
            self.assertEqual(coverage_rows[-4]["cov"], "12.5")


if __name__ == "__main__":
    unittest.main()
