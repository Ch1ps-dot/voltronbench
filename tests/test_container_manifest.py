import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = PROJECT_ROOT / "scripts" / "record_container_manifest.py"
SPEC = importlib.util.spec_from_file_location("record_container_manifest", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class ContainerManifestTests(unittest.TestCase):
    def test_reads_bounded_postprocess_status_from_archive(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "result.tar.gz"
            payload = json.dumps(
                {
                    "voltron_status": 0,
                    "pair_status": "EMPTY",
                    "pair_count": 0,
                    "compliance_status": "NO_COMPLIANCE_INPUT",
                    "compliance_exit_code": 3,
                    "coverage_status": "COMPLETED",
                    "coverage_exit_code": 0,
                    "voltron_source_commit": "abc123",
                    "lifecycle_mode": "environment_once+ftp_banner_readiness",
                }
            ).encode()
            with tarfile.open(archive, "w:gz") as output:
                info = tarfile.TarInfo("out-target-voltron/postprocess_status.json")
                info.size = len(payload)
                output.addfile(info, io.BytesIO(payload))

            self.assertEqual(
                MODULE.read_postprocess_status(archive)["compliance_status"],
                "NO_COMPLIANCE_INPUT",
            )
            self.assertEqual(
                MODULE.read_postprocess_status(archive)["lifecycle_mode"],
                "environment_once+ftp_banner_readiness",
            )

    def test_missing_or_invalid_status_is_empty(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            invalid = Path(temporary) / "invalid.tar.gz"
            invalid.write_bytes(b"not a tar")
            self.assertEqual(MODULE.read_postprocess_status(invalid), {})
