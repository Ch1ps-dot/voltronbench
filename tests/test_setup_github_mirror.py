import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SETUP = PROJECT_ROOT / "setup.sh"
BUILD_ALL = (
    PROJECT_ROOT
    / "benchmark"
    / "scripts"
    / "execution"
    / "profuzzbench_build_all.sh"
)


class SetupGithubMirrorTests(unittest.TestCase):
    def test_setup_help_documents_mirror_selection(self) -> None:
        completed = subprocess.run(
            ["bash", str(SETUP), "--help"],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("--github-mirror URL_PREFIX", completed.stdout)
        self.assertIn("--github-direct", completed.stdout)
        self.assertIn("GITHUB_MIRROR", completed.stdout)

    def test_setup_rejects_non_http_mirror_before_building(self) -> None:
        completed = subprocess.run(
            [
                "bash",
                str(SETUP),
                "--github-mirror",
                "ssh://untrusted.invalid/",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("must be an HTTP(S) URL prefix", completed.stderr)

    def test_setup_rejects_credentials_in_mirror_url(self) -> None:
        completed = subprocess.run(
            [
                "bash",
                str(SETUP),
                "--github-mirror",
                "https://user:secret@mirror.invalid/",
            ],
            text=True,
            capture_output=True,
            check=False,
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("must not contain embedded credentials", completed.stderr)

    def test_build_all_forwards_mirror_to_every_docker_build(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            docker_log = root / "docker.jsonl"
            fake_docker = fake_bin / "docker"
            fake_docker.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    import json
                    import os
                    from pathlib import Path
                    import sys

                    with Path(os.environ["FAKE_DOCKER_LOG"]).open(
                        "a", encoding="utf-8"
                    ) as stream:
                        stream.write(json.dumps(sys.argv[1:]) + "\\n")
                    raise SystemExit(0)
                    """
                ),
                encoding="utf-8",
            )
            fake_docker.chmod(0o755)

            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            env["FAKE_DOCKER_LOG"] = str(docker_log)
            env["PFBENCH"] = str(PROJECT_ROOT / "benchmark")
            env["FORCE_REBUILD"] = "1"
            env["GITHUB_MIRROR"] = "https://mirror.invalid/"
            completed = subprocess.run(
                ["bash", str(BUILD_ALL)],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            commands = [
                json.loads(line)
                for line in docker_log.read_text(
                    encoding="utf-8"
                ).splitlines()
            ]
            builds = [command for command in commands if command[0] == "build"]
            self.assertEqual(len(builds), 18)
            for command in builds:
                self.assertIn(
                    "GITHUB_MIRROR=https://mirror.invalid/",
                    command,
                )

    def test_active_dockerfiles_prefix_every_github_clone(self) -> None:
        dockerfiles = sorted(
            (PROJECT_ROOT / "benchmark" / "subjects").glob(
                "*/*/Dockerfile*"
            )
        )
        active = [
            path
            for path in dockerfiles
            if path.name in {"Dockerfile", "Dockerfile-stateafl"}
        ]
        github_dockerfiles = []
        github_clone_count = 0
        for dockerfile in active:
            content = dockerfile.read_text(encoding="utf-8")
            clone_lines = [
                line
                for line in content.splitlines()
                if "git clone" in line and "https://github.com/" in line
            ]
            if not clone_lines:
                continue
            github_dockerfiles.append(dockerfile)
            self.assertIn("ARG GITHUB_MIRROR", content, dockerfile)
            for line in clone_lines:
                github_clone_count += 1
                self.assertIn(
                    '"${GITHUB_MIRROR}https://github.com/',
                    line,
                    dockerfile,
                )

        self.assertEqual(len(github_dockerfiles), 15)
        self.assertEqual(github_clone_count, 28)


if __name__ == "__main__":
    unittest.main()
