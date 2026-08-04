from pathlib import Path
import subprocess
import sys
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
CHECKER = PROJECT_ROOT / "scripts" / "check_analysis_dependencies.py"


class AnalysisDependencyTests(unittest.TestCase):
    def test_checker_accepts_current_environment(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(CHECKER)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_checker_reports_action_when_modules_are_unavailable(self) -> None:
        completed = subprocess.run(
            [sys.executable, "-S", str(CHECKER)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("requirements-analysis.txt", completed.stderr)

    def test_entrypoints_run_the_preflight(self) -> None:
        run_script = (PROJECT_ROOT / "run.sh").read_text(encoding="utf-8")
        analyze_script = (PROJECT_ROOT / "analyze.sh").read_text(encoding="utf-8")
        self.assertIn("check_analysis_dependencies.py", run_script)
        self.assertIn("check_analysis_dependencies.py", analyze_script)
