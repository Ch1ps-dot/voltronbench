"""Regression checks for recovery artifacts when HTML rendering is unavailable."""

from pathlib import Path
import unittest


SCRIPT = (
    Path(__file__).resolve().parents[1]
    / "benchmark/scripts/execution/profuzzbench_recover_coverage.sh"
)


class RecoveryCoveragePolicyTests(unittest.TestCase):
    def test_valid_csv_is_the_completion_gate(self):
        content = SCRIPT.read_text()
        self.assertIn("render_html_or_note", content)
        self.assertIn("retaining valid CSV evidence", content)
        self.assertIn("coverage_csv=%s", content)
        self.assertIn("coverage_html=%s", content)
        self.assertNotIn("coverage HTML index was not produced", content)
        self.assertNotIn("exit 24", content)


if __name__ == "__main__":
    unittest.main()
