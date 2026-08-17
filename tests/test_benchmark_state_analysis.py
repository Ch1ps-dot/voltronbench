import csv
import os
from pathlib import Path
import re
import struct
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
    def _write_archive(
        self,
        root: Path,
        plot_data: str | None,
        *,
        fuzzer: str = "stateafl",
        response_metrics: str | None = None,
    ) -> None:
        output = root / f"out-demo-{fuzzer}"
        output.mkdir()
        if plot_data is not None:
            (output / "plot_data").write_text(plot_data, encoding="utf-8")
        if response_metrics is not None:
            (output / "response_ipsm_metrics.csv").write_text(
                response_metrics,
                encoding="utf-8",
            )
        (output / "cov_over_time.csv").write_text(
            "Time,l_per,l_abs,b_per,b_abs\n1,1.0,1,2.0,2\n",
            encoding="utf-8",
        )
        with tarfile.open(
            root / f"out-demo-{fuzzer}_1.tar.gz",
            "w:gz",
        ) as archive:
            archive.add(output, arcname=output.name)

    def _run_conversion(
        self,
        root: Path,
        fuzzer: str = "stateafl",
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                "bash",
                str(GENERATE_CSV),
                "demo",
                "1",
                fuzzer,
                "results.csv",
                "0",
                "states.csv",
            ],
            cwd=root,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_stateafl_uses_only_response_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_archive(
                root,
                None,
                response_metrics=(
                    "# unix_time,total_execs,response_state_num,"
                    "response_transition_num\n"
                    "100,10,3,4\n"
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
            self.assertFalse((root / "stateafl_memory_states.csv").exists())

    def test_aflnet_still_uses_named_plot_data_columns(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_archive(
                root,
                (
                    "# unix_time, cycles_done, cur_path, paths_total, "
                    "pending_total, pending_favs, map_size, unique_crashes, "
                    "unique_hangs, max_depth, execs_per_sec, n_nodes, n_edges\n"
                    "100, 0, 0, 2, 2, 1, 1.0%, 0, 0, 1, 2.0, 5, 7\n"
                ),
                fuzzer="aflnet",
            )

            result = self._run_conversion(root, "aflnet")

            self.assertEqual(result.returncode, 0, result.stderr)
            with (root / "states.csv").open(newline="", encoding="utf-8") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(
                [(row["state_type"], row["state"]) for row in rows],
                [("nodes", "5"), ("edges", "7")],
            )

    def test_voltron_deferred_coverage_still_exports_state_data(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            output = root / "out-demo-voltron"
            output.mkdir()
            (output / "states.csv").write_text(
                "subject,fuzzer,data_type,time,data,event\n"
                "demo,voltron,nodes,100,5,new_response_type\n"
                "demo,voltron,edges,100,7,new_response_transition\n",
                encoding="utf-8",
            )
            (output / "postprocess_status.json").write_text(
                '{"coverage_status": "DEFERRED"}\n', encoding="utf-8"
            )
            with tarfile.open(root / "out-demo-voltron_1.tar.gz", "w:gz") as archive:
                archive.add(output, arcname=output.name)

            result = self._run_conversion(root, "voltron")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(
                (root / ".profuzzbench-coverage-deferred-voltron").is_file()
            )
            self.assertEqual(
                (root / "results.csv").read_text(encoding="utf-8").splitlines(),
                ["time,subject,fuzzer,run,cov_type,cov"],
            )
            with (root / "states.csv").open(newline="", encoding="utf-8") as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(
                [(row["state_type"], row["state"]) for row in rows],
                [("nodes", "5"), ("edges", "7")],
            )

    def test_rejects_stateafl_archive_without_response_metrics(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            self._write_archive(
                root,
                None,
            )

            result = self._run_conversion(root)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("StateAFL response metrics unavailable", result.stderr)
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
                    "100,demo,stateafl,1,nodes,0\n"
                    "100,demo,stateafl,1,nodes,4\n"
                    "100,demo,stateafl,1,edges,0\n"
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
    def test_all_stateafl_images_use_response_patch_and_pinned_commit(self) -> None:
        dockerfiles = sorted(
            (PROJECT_ROOT / "benchmark" / "subjects").glob(
                "**/Dockerfile-stateafl"
            )
        )
        self.assertEqual(len(dockerfiles), 9)

        response_metric_patches = []
        for dockerfile in dockerfiles:
            contents = dockerfile.read_text(encoding="utf-8")
            self.assertIn(STATEAFL_COMMIT, contents, dockerfile)
            self.assertIn("stateafl-response-metrics.patch", contents, dockerfile)
            self.assertIn("ARG GITHUB_MIRROR", contents, dockerfile)
            self.assertIn(
                (
                    'git clone "${GITHUB_MIRROR}https://github.com/'
                    'stateafl/stateafl.git" $STATEAFL'
                ),
                contents,
                dockerfile,
            )
            self.assertIn("make clean all $MAKE_OPT", contents, dockerfile)
            self.assertIn("rm as", contents, dockerfile)
            self.assertIn("cd llvm_mode", contents, dockerfile)
            stateafl_patches = re.findall(
                r"patch -p1 < [^\n]*?(stateafl[^/\s]*\.patch)",
                contents,
            )
            expected_patches = ["stateafl-response-metrics.patch"]
            allows_initial_state_patch = (
                "HTTP/Lighttpd1" in dockerfile.as_posix()
                or "SMTP/Exim" in dockerfile.as_posix()
            )
            if allows_initial_state_patch:
                expected_patches.insert(0, "stateafl-initial-state.patch")
            self.assertEqual(stateafl_patches, expected_patches, dockerfile)
            self.assertNotIn("stateafl-benchmark.patch", contents, dockerfile)
            if not allows_initial_state_patch:
                self.assertNotIn(
                    "stateafl-initial-state.patch",
                    contents,
                    dockerfile,
                )
            if "SMTP/Exim" in dockerfile.as_posix():
                self.assertEqual(
                    contents.count(
                        "objcopy --redefine-sym "
                        "queue_size=stateafl_queue_size"
                    ),
                    2,
                )
            else:
                self.assertNotIn("objcopy --redefine-sym", contents, dockerfile)
            self.assertFalse(
                (dockerfile.parent / "stateafl-benchmark.patch").exists()
            )
            if not allows_initial_state_patch:
                self.assertFalse(
                    (dockerfile.parent / "stateafl-initial-state.patch").exists()
                )
            response_metric_patches.append(
                (
                    dockerfile.parent / "stateafl-response-metrics.patch"
                ).read_bytes()
            )

        self.assertTrue(
            all(
                patch == response_metric_patches[0]
                for patch in response_metric_patches[1:]
            )
        )
        response_patch_text = response_metric_patches[0].decode("utf-8")
        self.assertIn("response_ipsm_metrics.csv", response_patch_text)
        self.assertIn("response_ipsm.dot", response_patch_text)
        self.assertIn("orig_extract_response_codes", response_patch_text)
        self.assertIn("update_response_ipsm_metrics", response_patch_text)

    def test_proftpd_and_exim_have_no_stateafl_only_target_changes(self) -> None:
        subjects = PROJECT_ROOT / "benchmark" / "subjects"
        proftpd = subjects / "FTP" / "ProFTPD"
        proftpd_state = (proftpd / "Dockerfile-stateafl").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("malloc.patch", proftpd_state)
        self.assertNotIn("proftpd-stateafl-trace.patch", proftpd_state)
        self.assertNotIn("STATEAFL_MANUAL_TRACE", proftpd_state)
        self.assertNotIn("libfaketime", proftpd_state)
        self.assertNotIn("FAKETIME", proftpd_state)
        self.assertFalse((proftpd / "malloc.patch").exists())
        self.assertFalse((proftpd / "proftpd-stateafl-trace.patch").exists())

        exim = subjects / "SMTP" / "Exim"
        exim_base = (exim / "Dockerfile").read_text(encoding="utf-8")
        exim_state = (exim / "Dockerfile-stateafl").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("libfaketime", exim_state)
        self.assertNotIn("FAKETIME", exim_state)
        self.assertIn(
            "objcopy --redefine-sym queue_size=stateafl_queue_size",
            exim_state,
        )
        for target_patch in (
            "exim-response-code.patch",
            "exim-rand.patch",
            "exim-log-bug.patch",
            "exim.patch",
        ):
            self.assertIn(target_patch, exim_base)
            self.assertIn(target_patch, exim_state)

    def test_aflnet_style_fuzzers_register_initial_state(self) -> None:
        for relative in ("aflnet/afl-fuzz.c", "ChatAFL/afl-fuzz.c"):
            with self.subTest(source=relative):
                source = (PROJECT_ROOT / relative).read_text(encoding="utf-8")
                self.assertIn("State 0 is the synthetic initial state", source)
                self.assertIn('agnode(ipsm, "0", TRUE)', source)
                self.assertIn("kh_put(hms, khms_states, 0", source)
                self.assertIn("state_ids[state_ids_count++] = 0", source)


class StateAflSeedCorpusTests(unittest.TestCase):
    CORPORA = (
        ("DAAP/forked-daapd", "in-daap", "in-daap-replay", b"\r\n\r\n"),
        ("FTP/BFTPD", "in-ftp", "in-ftp-replay", b"\r\n"),
        ("FTP/LightFTP", "in-ftp", "in-ftp-replay", b"\r\n"),
        ("FTP/ProFTPD", "in-ftp", "in-ftp-replay", b"\r\n"),
        ("FTP/PureFTPD", "in-ftp", "in-ftp-replay", b"\r\n"),
        ("RTSP/Live555", "in-rtsp", "in-rtsp-replay", b"\r\n\r\n"),
        ("SMTP/Exim", "in-smtp", "in-smtp-replay", b"\r\n"),
    )

    @staticmethod
    def _split_like_aflnet(data: bytes, terminator: bytes) -> list[bytes]:
        messages = []
        offset = 0
        while offset < len(data):
            end = data.find(terminator, offset)
            if end == -1:
                messages.append(data[offset:])
                break
            end += len(terminator)
            messages.append(data[offset:end])
            offset = end
        return messages

    @staticmethod
    def _decode_replay(path: Path) -> list[bytes]:
        data = path.read_bytes()
        messages = []
        offset = 0
        while offset < len(data):
            if offset + 4 > len(data):
                raise AssertionError(f"truncated replay length in {path}")
            message_size = struct.unpack_from("<I", data, offset)[0]
            offset += 4
            end = offset + message_size
            if end > len(data):
                raise AssertionError(f"truncated replay message in {path}")
            messages.append(data[offset:end])
            offset = end
        return messages

    def test_replay_corpora_match_aflnet_seed_files_and_regions(self) -> None:
        subjects = PROJECT_ROOT / "benchmark" / "subjects"
        for relative, raw_name, replay_name, terminator in self.CORPORA:
            with self.subTest(subject=relative):
                subject = subjects / relative
                raw_dir = subject / raw_name
                replay_dir = subject / replay_name
                raw_files = {
                    path.name: path
                    for path in raw_dir.iterdir()
                    if path.is_file()
                }
                replay_files = {
                    path.name: path
                    for path in replay_dir.iterdir()
                    if path.is_file()
                }
                self.assertEqual(set(replay_files), set(raw_files))
                for name, raw_path in raw_files.items():
                    expected = self._split_like_aflnet(
                        raw_path.read_bytes(),
                        terminator,
                    )
                    self.assertEqual(
                        self._decode_replay(replay_files[name]),
                        expected,
                        replay_files[name],
                    )

    def test_sip_replay_corpus_has_the_same_files_and_bytes(self) -> None:
        subject = PROJECT_ROOT / "benchmark" / "subjects" / "SIP" / "Kamailio"
        raw_files = {
            path.name: path for path in (subject / "in-sip").iterdir()
        }
        replay_files = {
            path.name: path for path in (subject / "in-sip-replay").iterdir()
        }
        self.assertEqual(set(replay_files), set(raw_files))
        for name, raw_path in raw_files.items():
            self.assertEqual(
                b"".join(self._decode_replay(replay_files[name])),
                raw_path.read_bytes(),
            )

    def test_lighttpd_build_preserves_aflnet_seed_names_and_bytes(self) -> None:
        dockerfile = (
            PROJECT_ROOT
            / "benchmark"
            / "subjects"
            / "HTTP"
            / "Lighttpd1"
            / "Dockerfile-stateafl"
        ).read_text(encoding="utf-8")
        self.assertIn(
            'output="${WORKDIR}/in-http-replay/$(basename "${seed}")"',
            dockerfile,
        )
        self.assertIn('struct.pack("<I", len(data)) + data', dockerfile)


if __name__ == "__main__":
    unittest.main()
