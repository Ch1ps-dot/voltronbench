import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
PREPARE_RUNTIME = PROJECT_ROOT / "scripts" / "prepare_chatafl_runtime.sh"
LOAD_LLM_CONFIG = PROJECT_ROOT / "scripts" / "load_voltron_llm_config.py"
EXEC_COMMON = (
    PROJECT_ROOT
    / "benchmark"
    / "scripts"
    / "execution"
    / "profuzzbench_exec_common.sh"
)


class ChatAflRuntimeConfigTests(unittest.TestCase):
    def test_runtime_settings_override_and_fall_back_to_compiled_defaults(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            temporary_path = Path(temporary)
            harness = temporary_path / "runtime_model.c"
            executable = temporary_path / "runtime_model"
            harness.write_text(
                textwrap.dedent(
                    """\
                    #include <stdio.h>
                    #include "chatafl-runtime-config.h"

                    int main(void) {
                        char *api_key;
                        puts(chatafl_runtime_model("compiled-default"));
                        puts(chatafl_runtime_url("https://compiled.invalid"));
                        api_key = chatafl_runtime_api_key("compiled-secret");
                        if (api_key == NULL)
                            return 2;
                        puts(api_key);
                        free(api_key);
                        return 0;
                    }
                    """
                ),
                encoding="utf-8",
            )
            completed = subprocess.run(
                [
                    "cc",
                    "-std=c99",
                    "-Wall",
                    "-Werror",
                    "-I",
                    str(PROJECT_ROOT / "ChatAFL"),
                    str(harness),
                    "-o",
                    str(executable),
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)

            default_result = subprocess.run(
                [str(executable)],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(default_result.returncode, 0)
            self.assertEqual(
                default_result.stdout.splitlines(),
                [
                    "compiled-default",
                    "https://compiled.invalid",
                    "compiled-secret",
                ],
            )

            env = os.environ.copy()
            env["CHATAFL_MODEL"] = 'runtime "model"'
            env["CHATAFL_URL"] = "https://runtime.invalid/v1/chat"
            secret_file = temporary_path / "api-key"
            secret_file.write_text("runtime-secret\n", encoding="utf-8")
            secret_file.chmod(0o600)
            env["CHATAFL_API_KEY_FILE"] = str(secret_file)
            override_result = subprocess.run(
                [str(executable)],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(override_result.returncode, 0)
            self.assertEqual(
                override_result.stdout.splitlines(),
                [
                    'runtime "model"',
                    "https://runtime.invalid/v1/chat",
                    "runtime-secret",
                ],
            )

            env["CHATAFL_API_KEY_FILE"] = str(
                temporary_path / "missing-api-key"
            )
            missing_secret_result = subprocess.run(
                [str(executable)],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(missing_secret_result.returncode, 2)

    def test_llm_request_json_escapes_the_runtime_model(self) -> None:
        source = (PROJECT_ROOT / "ChatAFL" / "chat-llm.c").read_text(
            encoding="utf-8"
        )

        self.assertIn("chatafl_runtime_model(MODEL)", source)
        self.assertIn("json_object_new_string(configured_model)", source)
        self.assertIn("JSON_C_TO_STRING_PLAIN", source)
        self.assertNotIn(
            r'\"model\": \"%s\"',
            source,
        )


class ChatAflRuntimePreparationTests(unittest.TestCase):
    def test_gateway_model_summary_deduplicates_without_printing_keys(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "gateway.yaml"
            config.write_text(
                textwrap.dedent(
                    """\
                    profiles:
                      - base_url: https://one.invalid/v1
                        api_key: secret-one
                        model: model-a
                      - base_url: https://two.invalid/v1
                        api_key: secret-two
                        model: model-b
                      - base_url: https://three.invalid/v1
                        api_key: secret-three
                        model: model-a
                    """
                ),
                encoding="utf-8",
            )

            completed = subprocess.run(
                [
                    "python3",
                    str(LOAD_LLM_CONFIG),
                    "--models-only",
                    str(config),
                ],
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(completed.stdout.strip(), "model-a,model-b")
            self.assertNotIn("secret-", completed.stdout)

    def test_runtime_is_built_once_with_an_existing_image_and_cached(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            docker_log = root / "docker.log"
            fake_docker = fake_bin / "docker"
            fake_docker.write_text(
                textwrap.dedent(
                    """\
                    #!/usr/bin/env python3
                    import os
                    from pathlib import Path
                    import shutil
                    import sys

                    args = sys.argv[1:]
                    with Path(os.environ["FAKE_DOCKER_LOG"]).open(
                        "a", encoding="utf-8"
                    ) as stream:
                        stream.write(" ".join(args) + "\\n")

                    if args[:2] == ["image", "inspect"]:
                        print("sha256:" + "a" * 64)
                        raise SystemExit(0)

                    if args and args[0] == "run":
                        output = None
                        for index, argument in enumerate(args):
                            if argument != "--mount":
                                continue
                            mount = args[index + 1]
                            if "dst=/opt/chatafl-runtime-output" not in mount:
                                continue
                            fields = dict(
                                item.split("=", 1)
                                for item in mount.split(",")
                                if "=" in item
                            )
                            output = Path(fields["src"])
                        if output is None:
                            raise SystemExit("output mount missing")
                        shutil.copy("/bin/true", output / "afl-fuzz")
                        (output / "afl-fuzz").chmod(0o755)
                        (output / "default-model").write_text(
                            "image-default\\n", encoding="utf-8"
                        )
                        (output / "default-url").write_text(
                            "https://image.invalid/chat\\n", encoding="utf-8"
                        )
                        raise SystemExit(0)

                    raise SystemExit("unexpected docker command")
                    """
                ),
                encoding="utf-8",
            )
            fake_docker.chmod(0o755)

            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            env["FAKE_DOCKER_LOG"] = str(docker_log)
            env["CHATAFL_CACHE_DIR"] = str(root / "cache")

            results = []
            for _ in range(2):
                completed = subprocess.run(
                    ["bash", str(PREPARE_RUNTIME), "existing-target-vol"],
                    env=env,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                results.append(Path(completed.stdout.strip()))

            self.assertEqual(results[0], results[1])
            self.assertTrue(results[0].is_file())
            self.assertTrue(os.access(results[0], os.X_OK))
            metadata = (results[0].parent / "metadata.txt").read_text(
                encoding="utf-8"
            )
            self.assertIn("builder_image=existing-target-vol", metadata)
            self.assertIn("compiled_default_model=image-default", metadata)
            self.assertIn(
                "compiled_default_url=https://image.invalid/chat",
                metadata,
            )
            self.assertIn("runtime_binary_sha256=", metadata)

            docker_commands = docker_log.read_text(
                encoding="utf-8"
            ).splitlines()
            self.assertEqual(
                sum(command.startswith("run ") for command in docker_commands),
                1,
            )
            self.assertFalse(
                any(command.startswith("build ") for command in docker_commands)
            )

    def test_all_target_images_use_the_runtime_compatible_base(self) -> None:
        dockerfiles = sorted(
            (PROJECT_ROOT / "benchmark" / "subjects").glob("*/*/Dockerfile")
        )
        self.assertEqual(len(dockerfiles), 9)
        for dockerfile in dockerfiles:
            first_line = dockerfile.read_text(
                encoding="utf-8"
            ).splitlines()[0]
            self.assertEqual(first_line, "FROM ubuntu:20.04", dockerfile)


class ChatAflRuntimeIntegrationTests(unittest.TestCase):
    def test_common_executor_rejects_an_insecure_api_key_file(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runtime_binary = root / "afl-fuzz"
            runtime_binary.write_bytes(b"runtime")
            runtime_binary.chmod(0o755)
            api_key_file = root / "api-key"
            api_key_file.write_text("secret", encoding="utf-8")
            api_key_file.chmod(0o644)

            env = os.environ.copy()
            env["CHATAFL_RUNTIME_BINARY"] = str(runtime_binary)
            env["CHATAFL_MODEL"] = "runtime-model"
            env["CHATAFL_URL"] = "https://runtime.invalid/chat"
            env["CHATAFL_API_KEY_FILE"] = str(api_key_file)
            completed = subprocess.run(
                [
                    "bash",
                    str(EXEC_COMMON),
                    "demo-vol",
                    "1",
                    str(root / "results"),
                    "chatafl",
                    "out-demo-chatafl",
                    "-P FTP",
                    "1",
                    "1",
                ],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertNotEqual(completed.returncode, 0)
            self.assertIn(
                "must not be accessible by group or others",
                completed.stderr,
            )

    def test_common_executor_connects_chatafl_to_the_shared_gateway(
        self,
    ) -> None:
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

                    args = sys.argv[1:]
                    with Path(os.environ["FAKE_DOCKER_LOG"]).open(
                        "a", encoding="utf-8"
                    ) as stream:
                        stream.write(json.dumps(args) + "\\n")

                    if args and args[0] == "run":
                        print("a" * 64)
                    elif args and args[0] == "wait":
                        print("0")
                    elif args and args[0] == "cp":
                        destination = Path(args[-1])
                        destination.parent.mkdir(parents=True, exist_ok=True)
                        destination.write_bytes(b"archive")
                    elif args and args[0] == "inspect":
                        print(json.dumps({
                            "Id": "a" * 64,
                            "Name": "/fake-chatafl",
                            "State": {
                                "Status": "exited",
                                "ExitCode": 0,
                                "StartedAt": "2026-01-01T00:00:00Z",
                                "FinishedAt": "2026-01-01T00:00:01Z"
                            }
                        }))
                    else:
                        raise SystemExit("unexpected docker command")
                    """
                ),
                encoding="utf-8",
            )
            fake_docker.chmod(0o755)
            runtime_binary = root / "afl-fuzz"
            runtime_binary.write_bytes(b"runtime")
            runtime_binary.chmod(0o755)
            api_key_file = root / "api-key"
            api_key_file.write_text(
                "never-write-this-secret-to-metadata",
                encoding="utf-8",
            )
            api_key_file.chmod(0o600)
            results = root / "results"

            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            env["PROFUZZBENCH_DOCKER_BIN"] = str(fake_docker)
            env["PROFUZZBENCH_MONITOR"] = "0"
            env["FAKE_DOCKER_LOG"] = str(docker_log)
            env["CHATAFL_RUNTIME_BINARY"] = str(runtime_binary)
            env["CHATAFL_USE_API_GATEWAY"] = "1"
            env["CHATAFL_API_MODE"] = "gateway"
            env["CHATAFL_DOCKER_NETWORK"] = "shared-llm-network"
            env["CHATAFL_MODEL_EFFECTIVE"] = "voltron-default"
            env["CHATAFL_URL_EFFECTIVE"] = (
                "http://voltron-api-gateway:8000/v1/chat/completions"
            )
            env["CHATAFL_API_KEY_FILE"] = str(api_key_file)
            env["LLM_GATEWAY_CONFIG_SHA256"] = "a" * 64
            env["LLM_GATEWAY_PROFILE_MODELS"] = "model-a,model-b"

            completed = subprocess.run(
                [
                    "bash",
                    str(EXEC_COMMON),
                    "demo-vol",
                    "1",
                    str(results),
                    "chatafl",
                    "out-demo-chatafl",
                    "-P FTP",
                    "1",
                    "1",
                ],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(completed.returncode, 0, completed.stderr)
            metadata = (
                results / "chatafl_runtime_metadata.txt"
            ).read_text(encoding="utf-8")
            self.assertIn("api_mode=gateway", metadata)
            self.assertIn("effective_model=voltron-default", metadata)
            self.assertIn(
                (
                    "effective_url=http://voltron-api-gateway:8000/"
                    "v1/chat/completions"
                ),
                metadata,
            )
            self.assertIn(
                "api_key_source=gateway_internal_token",
                metadata,
            )
            self.assertIn(f"gateway_config_sha256={'a' * 64}", metadata)
            self.assertIn(
                "gateway_profile_models=model-a,model-b",
                metadata,
            )
            self.assertIn("runtime_binary_sha256=", metadata)
            self.assertNotIn("never-write-this-secret", metadata)
            commands = [
                json.loads(line)
                for line in docker_log.read_text(
                    encoding="utf-8"
                ).splitlines()
            ]
            run_command = next(
                command for command in commands if command[0] == "run"
            )
            env_index = run_command.index("--env")
            self.assertEqual(
                run_command[env_index + 1],
                "CHATAFL_MODEL=voltron-default",
            )
            self.assertIn(
                (
                    "CHATAFL_URL=http://voltron-api-gateway:8000/"
                    "v1/chat/completions"
                ),
                run_command,
            )
            network_index = run_command.index("--network")
            self.assertEqual(
                run_command[network_index + 1],
                "shared-llm-network",
            )
            self.assertIn(
                "CHATAFL_API_KEY_FILE=/run/secrets/chatafl_api_key",
                run_command,
            )
            self.assertFalse(
                any(
                    "never-write-this-secret" in argument
                    for argument in run_command
                )
            )
            mount_index = run_command.index("--mount")
            self.assertEqual(
                run_command[mount_index + 1],
                (
                    f"type=bind,src={runtime_binary},"
                    "dst=/home/ubuntu/chatafl/afl-fuzz,readonly"
                ),
            )
            self.assertIn(
                (
                    f"type=bind,src={api_key_file},"
                    "dst=/run/secrets/chatafl_api_key.host,readonly"
                ),
                run_command,
            )
            self.assertIn("--user", run_command)
            self.assertIn("root", run_command)
            self.assertIn("secret_staging=container_root_copy", metadata)

    def test_only_chatafl_containers_receive_runtime_binary_and_model(
        self,
    ) -> None:
        executor = EXEC_COMMON.read_text(encoding="utf-8")

        self.assertIn('if [[ "$FUZZER" == "chatafl" ]]', executor)
        self.assertIn(
            "dst=/home/ubuntu/chatafl/afl-fuzz,readonly",
            executor,
        )
        self.assertIn(
            '--env "CHATAFL_MODEL=${CHATAFL_MODEL_EFFECTIVE}"',
            executor,
        )
        self.assertIn(
            '--env "CHATAFL_URL=${CHATAFL_URL_EFFECTIVE}"',
            executor,
        )
        self.assertIn(
            'docker_args+=(--network "$CHATAFL_DOCKER_NETWORK")',
            executor,
        )
        self.assertIn(
            "dst=/run/secrets/chatafl_api_key.host,readonly",
            executor,
        )
        self.assertIn("container_root_copy", executor)
        self.assertIn('docker "${docker_args[@]}"', executor)
        self.assertIn("chatafl_runtime_metadata.txt", executor)

    def test_top_level_bundle_records_effective_runtime_configuration(
        self,
    ) -> None:
        runner = (PROJECT_ROOT / "run.sh").read_text(encoding="utf-8")

        self.assertIn("scripts/prepare_chatafl_runtime.sh", runner)
        self.assertIn(
            "CHATAFL_USE_API_GATEWAY=${CHATAFL_USE_API_GATEWAY:-1}",
            runner,
        )
        self.assertIn("chatafl_api_mode=%s", runner)
        self.assertIn("chatafl_model=%s", runner)
        self.assertIn("chatafl_url=%s", runner)
        self.assertIn("chatafl_api_key_source=%s", runner)
        self.assertIn("chatafl_secret_staging=%s", runner)
        self.assertIn("chatafl_runtime_binary_sha256=%s", runner)
        self.assertIn("chatafl_runtime_source_sha256=%s", runner)
        self.assertIn("chatafl_runtime_builder_image_id=%s", runner)
        self.assertIn("llm_gateway_config_sha256=%s", runner)
        self.assertIn("llm_gateway_profile_models=%s", runner)
        self.assertIn("gateway_internal_token", runner)

        self.assertNotIn("chatafl_api_key=%s", runner)
        self.assertIn(
            'rm -f -- "$CHATAFL_EPHEMERAL_API_KEY_FILE"',
            runner,
        )

    def test_setup_no_longer_compiles_llm_settings_into_source(
        self,
    ) -> None:
        setup = (PROJECT_ROOT / "setup.sh").read_text(encoding="utf-8")

        self.assertNotIn('s/#define MODEL \\".*\\"/', setup)
        self.assertNotIn('s|#define URL \\".*\\"|', setup)
        self.assertNotIn("OPENAI_TOKEN", setup)
        self.assertIn(
            "model, URL, and API key are selected at container runtime",
            setup,
        )


if __name__ == "__main__":
    unittest.main()
