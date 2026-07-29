# VoltronBench

VoltronBench is a protocol-fuzzing benchmark harness built on top of
ProFuzzBench and the ChatAFL artifact. It provides AFLNet, ChatAFL, StateAFL,
and Voltron through one experiment flow against the same Dockerized protocol
targets.

The repository is intended to make comparative experiments easy to run:

- build one set of target Docker images;
- run AFLNet, ChatAFL, StateAFL, and Voltron with the same subject list and timeout;
- monitor container progress from the host;
- collect ProFuzzBench-style archives and plots;
- run Voltron's compliance analysis after each Voltron fuzzing task.

## Quick Start

The shortest path is to build the active benchmark images, run one small
non-LLM experiment, and inspect the exported ProFuzzBench archive and combined
result bundle:

```bash
./deps.sh
./setup.sh
./run.sh 1 5 lightftp stateafl
find benchmark/experiment-runs -name 'out-lightftp-stateafl_1.tar.gz'
ls res_experiment_*.tar.gz
```

`setup.sh` uses `https://github.com` directly by default. To route GitHub
source clones through a trusted prefix-style mirror during Docker builds:

```bash
./setup.sh --github-mirror https://mirror.example/
```

For example, the mirror above receives
`https://mirror.example/https://github.com/owner/repository.git`. The same
selection can be supplied as `GITHUB_MIRROR=https://mirror.example/`.
Mirror URLs must not contain credentials because Docker build arguments are
not secret storage. This option affects GitHub source clones only; it does not
configure Docker Hub or APT mirrors.

Existing images are skipped. To rebuild them with a different GitHub source
mode:

```bash
FORCE_REBUILD=1 ./setup.sh --github-mirror https://mirror.example/
FORCE_REBUILD=1 ./setup.sh --github-direct
```

Run AFLNet with the same entry point:

```bash
./run.sh 1 5 lightftp aflnet
```

ChatAFL and Voltron require an OpenAI-compatible API profile. Copy the ignored
local configuration and restrict its permissions:

```bash
cp config/voltron-llm.example.yaml config/voltron-llm.yaml
chmod 600 config/voltron-llm.yaml
```

Edit `config/voltron-llm.yaml`:

```yaml
gateway:
  queue_size: 256
  queue_timeout_seconds: 30
  max_attempts: 2
  default_max_concurrency: 1

profiles:
  - name: primary
    base_url: https://api.example.com/v1
    api_key: replace-with-your-api-key
    model: gpt-5-mini
    max_concurrency: 1
    enabled: true
```

`base_url` is the OpenAI-compatible `/v1` prefix; do not append
`/chat/completions`. The gateway adds that path automatically. Add more
complete entries under `profiles` when several API accounts or endpoints are
available, and set `max_concurrency` to each provider's safe hard limit.

Run ChatAFL or Voltron with the same configuration:

```bash
./run.sh 1 5 lightftp chatafl
./run.sh 1 30 lightftp voltron
```

`run.sh` starts the shared API gateway automatically. Real upstream keys stay
in the ignored local YAML and are not injected into ChatAFL or Voltron target
containers. If the gateway is already running when the YAML is changed, reload
it before the next experiment:

```bash
./run_api_gateway.sh restart
```

`run.sh` automatically generates coverage and state plots after all experiment
containers finish. To rerun analysis manually from existing archives:

```bash
RUN_DIR=$(find benchmark/experiment-runs -mindepth 1 -maxdepth 1 \
  -type d | sort | tail -1)
./analyze.sh lightftp 5 ./reanalyzed "$RUN_DIR"
```

To run several active targets and fuzzers together:

```bash
./run.sh 1 30 lightftp,bftpd,proftpd aflnet,chatafl,stateafl
```

All quick-start commands use the active target set only:

```text
live555 kamailio exim forked-daapd pure-ftpd proftpd bftpd lightftp lighttpd1
```

## Repository Layout

```text
.
├── aflnet/                         # AFLNet source used by the benchmark images
├── ChatAFL/                        # ChatAFL source used by the benchmark images
├── benchmark/
│   ├── subjects/                   # Active protocol targets and Docker build contexts
│   └── scripts/
│       ├── execution/              # Docker execution and monitoring scripts
│       └── analysis/               # CSV generation and plotting scripts
├── crash_data/                     # Existing crash data snapshots
├── cve/                            # CVE-related material
├── scripts/prepare_voltron.sh      # Fetches or selects the Voltron source tree
├── run.sh                          # Main experiment entry point
├── run_voltron.sh                  # Voltron-specific host runner
├── setup.sh                        # Copies fuzzers into subjects and builds images
├── analyze.sh                      # Generates coverage/state plots from results
├── clean.sh                        # Removes selected benchmark containers/images
└── clean_images.sh                 # Removes all images built by this project
```

## Requirements

- Docker
- Bash
- Git
- Python 3 with `rich` for the live container dashboard
- Python 3 with `pandas` and `matplotlib` for result analysis
- Network access while building StateAFL images or fetching Voltron

The helper below installs common dependencies on supported systems:

```bash
./deps.sh
```

## Build Target Images

Build all benchmark Docker images:

```bash
./setup.sh
```

Select a trusted prefix-style GitHub source mirror, or explicitly select the
official site:

```bash
./setup.sh --github-mirror https://mirror.example/
./setup.sh --github-direct
./setup.sh --help
```

ChatAFL model, URL, and API key are selected at experiment runtime. They are
not written into its source by `setup.sh`; see
[Run Experiments](#run-experiments).

The build script skips images that already exist. Force a rebuild with:

```bash
FORCE_REBUILD=1 ./setup.sh
```

The active benchmark set is intentionally limited to these nine targets:

```text
live555 kamailio exim forked-daapd pure-ftpd proftpd bftpd lightftp lighttpd1
```

The image tags built by the project are:

```text
live555-vol kamailio-vol exim-vol forked-daapd-vol pure-ftpd-vol
proftpd-vol bftpd-vol lightftp-vol lighttpd1-vol
```

Each target also has a StateAFL image named
`<target>-stateafl-vol`. The full StateAFL image set is:

```text
live555-stateafl-vol kamailio-stateafl-vol exim-stateafl-vol
forked-daapd-stateafl-vol pure-ftpd-stateafl-vol proftpd-stateafl-vol
bftpd-stateafl-vol lightftp-stateafl-vol lighttpd1-stateafl-vol
```

No other ProFuzzBench subjects are kept under `benchmark/subjects/`.

## Run Experiments

Use `run.sh` for all fuzzers:

```bash
./run.sh <containers_per_target_fuzzer> <minutes> <subjects> <fuzzers>
```

Examples:

```bash
./run.sh 1 30 lightftp voltron
./run.sh 1 30 lightftp chatafl
./run.sh 3 240 bftpd,proftpd,pure-ftpd aflnet,chatafl,stateafl,voltron
```

ChatAFL and Voltron use the same capacity-aware API gateway by default. Copy
the tracked example, then place complete upstream URL, API key, model, and
capacity profiles in the ignored local configuration:

```bash
cp config/voltron-llm.example.yaml config/voltron-llm.yaml
```

The ChatAFL container receives only the internal gateway endpoint, the
`voltron-default` placeholder model, and a temporary mode-`0600` gateway-token
file. The gateway replaces them with the selected profile's real URL, API key,
and model for each request. Upstream credentials are not passed through Docker
environment variables or written to experiment metadata.

When ChatAFL is selected, `run.sh` compiles a small runtime `afl-fuzz` artifact
inside the existing `lightftp-vol` image, caches it under
`.runtime/chatafl/`, and mounts it over `/home/ubuntu/chatafl/afl-fuzz` in each
ChatAFL container. It does not run `docker build` or modify any target image.
Changing the gateway YAML does not rebuild this cached binary; restart the
gateway to reload changed profiles.

Set `CHATAFL_USE_API_GATEWAY=0` to retain the direct-call compatibility path.
In direct mode, model, complete chat-completions URL, and API key can still be
selected at runtime without rebuilding an image:

```bash
CHATAFL_USE_API_GATEWAY=0 \
  CHATAFL_MODEL=model-a \
  CHATAFL_URL=https://api-a.example/v1/chat/completions \
  CHATAFL_API_KEY_FILE=/secure/path/key-a \
  ./run.sh 1 30 lightftp chatafl
```

The API-key file must be readable by the current user and inaccessible to group
and other users, for example:

```bash
mkdir -p .runtime
install -m 600 /dev/null .runtime/chatafl-api-key
printf '%s' 'replace-with-the-key' > .runtime/chatafl-api-key
```

For direct-mode compatibility, `CHATAFL_API_KEY=...` is also accepted by
`run.sh`. It is immediately copied to a temporary mode-`0600` file under
`.runtime/chatafl/secrets/`, removed from the child environment, mounted
read-only into ChatAFL containers, and deleted when `run.sh` exits. The key
itself is never written to experiment metadata or passed as a Docker
environment variable.

If `lightftp-vol` is unavailable, select any existing active target image as
the compatible Ubuntu 20.04 builder:

```bash
CHATAFL_BUILDER_IMAGE=proftpd-vol \
./run.sh 1 30 proftpd chatafl
```

In direct mode only, unset runtime values fall back to the model, URL, or API
key already compiled into an existing builder image. Newly built images retain
the tracked placeholders, so explicit direct-mode settings are recommended.

Supported fuzzer names are:

```text
aflnet chatafl stateafl voltron all
```

The subject list is comma-separated. `all` expands to every configured subject
for the selected fuzzer. The active target set is:

```text
live555 kamailio exim forked-daapd pure-ftpd proftpd bftpd lightftp lighttpd1
```

Each `run.sh` invocation creates a unique run ID and writes its run archives
under an isolated directory:

```text
benchmark/experiment-runs/<run-id>/results-<subject>/
└── out-<subject>-<fuzzer>_<replication>.tar.gz
```

After all selected experiments finish, `run.sh` automatically runs
`analyze.sh` and creates a combined archive in the repository root:

```text
res_experiment_<run-id>.tar.gz
```

The archive contains the experiment parameters and one timestamped analysis
directory per subject. Each subject directory includes the original run
archives, generated CSV files, and coverage/state plots. ChatAFL runs add the
API mode, effective model, URL, API-key source (never the key), runtime source
hash, binary hash, and builder-image ID to `experiment_parameters.txt`.
Gateway-backed runs also record the gateway-configuration hash and unique
profile model names. Each `results-<subject>` directory also contains
`chatafl_runtime_metadata.txt`. The unique run ID prevents sequential or
concurrent `run.sh` invocations from overwriting each other's raw archives,
analysis files, or combined bundles.

This archive naming is shared by AFLNet, ChatAFL, StateAFL, and Voltron. For
example, a single LightFTP StateAFL replication writes:

```text
benchmark/experiment-runs/<run-id>/results-lightftp/out-lightftp-stateafl_1.tar.gz
```

Containers are left in Docker after normal completion unless the lower-level
runner is invoked with its optional delete argument. This is useful for
post-mortem inspection with `docker logs` or `docker cp`.

## StateAFL Integration

StateAFL follows the ProFuzzBench integration model. Every active target has a
`Dockerfile-stateafl` layered on its normal `*-vol` image. The derived image
builds StateAFL, recompiles the same target revision and target-side patches
with StateAFL's `afl-clang-fast`, and installs a target-specific
`run-stateafl` setup script. The only source patch applied to StateAFL itself
is `stateafl-response-metrics.patch`, an independent AFLNet-style response-code
observer that does not feed StateAFL scheduling, coverage, or corpus decisions.

Run it through the same entry point as AFLNet and ChatAFL:

```bash
./run.sh 1 30 lightftp stateafl
./run.sh 1 30 all stateafl
```

Before launching StateAFL containers, `run.sh` temporarily sets the host
`/proc/sys/kernel/core_pattern` to `core` and disables ASLR through
`/proc/sys/kernel/randomize_va_space`. These host-global settings require root
access, so the script may prompt for `sudo`. Their original values are restored
when the top-level experiment command exits. Concurrent top-level StateAFL
commands are serialized to prevent one command from restoring the settings
while another experiment is still running.

StateAFL uses replay-format seed corpora. Every replay corpus contains the same
seed files and request bytes as the corresponding AFLNet `in-*` corpus; only
the per-request length prefixes required by StateAFL are added. The Lighttpd
image performs this deterministic conversion during the image build.

StateAFL exports results through the same ProFuzzBench archive contract as
AFLNet and ChatAFL. The common executor copies
`/home/ubuntu/experiments/out-<target>-stateafl.tar.gz` from each container to
`benchmark/experiment-runs/<run-id>/results-<target>/out-<target>-stateafl_<run>.tar.gz`.
Any files
under the fuzzer output directory are preserved in the archive; the analysis
pipeline specifically consumes `cov_over_time.csv` and `plot_data` when they
are present.

## Voltron Integration

Target images do not contain Voltron. When a Voltron experiment starts,
`scripts/prepare_voltron.sh` fetches the latest `main` revision from GitHub into
`.runtime/voltron/`, creates a source snapshot, and mounts that snapshot into
the target container.

Use a specific Voltron branch, tag, or commit:

```bash
VOLTRON_REF=497d44fabbdd68b542b29ad2801e3a3734b57297 \
./run.sh 1 30 lightftp voltron
```

Use a local Voltron checkout instead of the GitHub snapshot cache:

```bash
VOLTRON_SOURCE_DIR=/path/to/voltron \
./run.sh 1 30 lightftp voltron
```

Override the Voltron repository:

```bash
VOLTRON_REPO=https://github.com/your-org/voltron.git \
./run.sh 1 30 lightftp voltron
```

The shared ChatAFL/Voltron gateway reads its API settings from
`config/voltron-llm.yaml`. Start from the tracked example and keep the real
configuration local:

```bash
cp config/voltron-llm.example.yaml config/voltron-llm.yaml
```

Configure one or more complete API profiles and set a hard concurrency limit
for each profile:

```yaml
gateway:
  queue_size: 256
  queue_timeout_seconds: 30
  max_attempts: 2
  default_max_concurrency: 1

profiles:
  - name: api-1
    base_url: https://api.example.com/v1
    api_key: sk-key-1
    model: example-model
    max_concurrency: 6

  - name: api-2
    base_url: https://api.example.com/v1
    api_key: sk-key-2
    model: example-model
    max_concurrency: 8
```

`run.sh` starts the `voltron-api-gateway` container when a ChatAFL or Voltron
experiment requests gateway mode. All gateway-backed ChatAFL and Voltron
containers connect to it. For every request, the gateway selects an enabled,
non-cooled-down profile with available capacity, preferring the lowest
`inflight / max_concurrency` ratio. Selection and slot reservation are atomic,
so a profile never exceeds its configured hard limit. When every profile is
full, requests wait in the bounded gateway queue.

```bash
./run.sh 2 60 lightftp,bftpd,proftpd voltron
```

Use a configuration stored elsewhere with
`VOLTRON_GATEWAY_CONFIG=/path/to/voltron-llm.yaml`. API settings are accepted
only through this YAML file so each upstream always receives a complete,
internally consistent profile. If `max_concurrency` is omitted, the gateway
uses `gateway.default_max_concurrency`, whose safe default is `1`.

Manage or inspect the gateway independently with:

```bash
./run_api_gateway.sh start
./run_api_gateway.sh status
./run_api_gateway.sh logs
./run_api_gateway.sh stop
```

The gateway exposes `healthz`, `readyz`, and an authenticated `admin/status`
endpoint on `127.0.0.1:8000`. It does not include upstream keys in status
responses. Set `FORCE_GATEWAY_REBUILD=1` when gateway source or dependencies
change, and restart the gateway after changing its YAML configuration. Set
`VOLTRON_USE_API_GATEWAY=0` to use the legacy per-container round-robin profile
assignment for Voltron, or `CHATAFL_USE_API_GATEWAY=0` to use ChatAFL's direct
runtime API settings.

When ChatAFL and Voltron run simultaneously, they intentionally share the same
upstream capacity and can affect each other's API wait time. Run comparison
experiments separately when API latency isolation is required.

Test the concurrency capacity of every API profile before an experiment:

```bash
python3 scripts/test_voltron_api_pool.py \
  --config config/voltron-llm.yaml \
  --concurrency 1,2,4,8,16
```

Each worker sends two minimal chat-completion requests at every concurrency
level. Test the aggregate capacity of the round-robin pool or save a detailed
report with:

```bash
python3 scripts/test_voltron_api_pool.py \
  --mode pool \
  --concurrency 4,8,16,32 \
  --json-output api-pool-report.json
```

The tester reports success rate, throughput, p50/p95 latency, HTTP 429 responses,
timeouts, connection errors, and the highest tested concurrency meeting the
default 95% success threshold. It never includes API keys in console or JSON
output. Use `--requests-per-worker`, `--timeout`, `--endpoint`, `--prompt`, and
`--min-success-rate` to adjust the workload for a provider.

Voltron's Python and package artifacts are cached on the host under:

```text
.runtime/voltron/uv-cache
```

Set a custom cache directory with:

```bash
VOLTRON_UV_CACHE_DIR=/path/to/cache ./run.sh 1 30 lightftp voltron
```

After the requested fuzzing time elapses, the Voltron container runner calls:

```bash
uv run analyze_compliance --sut <target> --output <outdir>
```

The compliance-analysis log is saved in:

```text
<outdir>/analyze_compliance.log
```

If the Voltron analyzer entry point changes, override it with:

```bash
VOLTRON_COMPLIANCE_ANALYZER=<command> ./run.sh 1 30 lightftp voltron
```

Voltron state metrics are adapted to ProFuzzBench's `nodes` and `edges` series
using distinct response types and response transitions. After fuzzing, retained
Voltron `Conversation` test cases are exported to AFLNet's length-prefixed
replay format and replayed against the target's gcov build with the same
`aflnet-replay`, `cov_script`, and `gcovr` pipeline used by the other fuzzers.
The resulting line and branch coverage measurements are stored in
`cov_over_time.csv`. The export mapping is preserved in
`voltron_aflnet_replay_manifest.csv`; if Voltron retains no replayable test
cases, the coverage file contains only its schema header.

## Progress Monitoring

All fuzzer runners use a host-side Python Rich dashboard. The live table shows
the experiment progress, elapsed and remaining time, and one row per Docker
container with its status, runtime, exit code, CPU usage, memory usage, process
count, and abnormal-exit note. The dashboard is transient while an experiment
is running; a final static summary remains in the terminal after all containers
stop. Narrow terminals use a compact table; terminals at least 110 columns wide
also show container names, absolute memory usage, and process counts.

Install the dashboard dependency through `./deps.sh`, or install it directly:

```bash
python3 -m pip install rich
```

Useful options:

```bash
PROFUZZBENCH_MONITOR=0                  # Disable monitoring
PROFUZZBENCH_MONITOR_INTERVAL=2         # Refresh every 2 seconds
PROFUZZBENCH_MONITOR_DASHBOARD=1        # Use Rich's full-screen dashboard
```

The default Rich live region is best for normal foreground runs. Full-screen
mode is useful for a single target/fuzzer job. When several target/fuzzer jobs
run in parallel, each job owns its own live table and final summary.

## Interrupt Handling

The execution scripts handle `Ctrl-C` and `SIGTERM`. On interruption, the runner
stops the monitor, handles all containers started by that run, prints a final
container summary, optionally collects already-created result archives, and
exits with status `130`.

Default interruption behavior:

```text
Ctrl-C -> docker stop containers -> print summary -> try to collect archives
```

Configuration:

```bash
PROFUZZBENCH_INTERRUPT_ACTION=stop      # Default: docker stop
PROFUZZBENCH_INTERRUPT_ACTION=kill      # docker kill
PROFUZZBENCH_INTERRUPT_ACTION=leave     # Leave containers running
PROFUZZBENCH_INTERRUPT_TIMEOUT=10       # docker stop timeout in seconds
PROFUZZBENCH_COLLECT_ON_INTERRUPT=1     # Try to collect existing archives
```

For example, keep containers running after interrupting the host script:

```bash
PROFUZZBENCH_INTERRUPT_ACTION=leave ./run.sh 3 30 lightftp voltron
```

## Analyze Results

`run.sh` invokes analysis automatically after experiment execution succeeds.
To regenerate code-coverage and state-coverage plots from existing archives:

```bash
./analyze.sh <subjects> <minutes>
```

Examples:

```bash
./analyze.sh lightftp 30
./analyze.sh bftpd,proftpd,pure-ftpd 240
RUN_DIR=benchmark/experiment-runs/2026-07-28_22-40-40_pimesa
./analyze.sh lightftp 30 ./reanalyzed "$RUN_DIR"
```

Without optional paths, manual analysis remains compatible with legacy
`benchmark/results-<subject>/` directories. The fourth argument selects an
isolated `benchmark/experiment-runs/<run-id>/` directory created by the current
`run.sh`.

For each subject, analysis reads archives from the selected results root,
generates combined CSV files, plots code coverage and state coverage, and
stores the artifacts under the selected output root. The default output root is
the repository root:

```text
res_<subject>_<timestamp>/
```

Fuzzer names are discovered from archive names such as
`out-lightftp-aflnet_1.tar.gz`, `out-lightftp-chatafl_1.tar.gz`, and
`out-lightftp-stateafl_1.tar.gz`, so StateAFL archives are analyzed alongside
AFLNet and ChatAFL when the expected `cov_over_time.csv` and `plot_data` files
exist in the archive.

## Clean Up

Remove benchmark images and containers for the active subject set:

```bash
./clean.sh
```

Remove all Docker images built by this project:

```bash
./clean_images.sh
```

Preview what would be removed:

```bash
./clean_images.sh --dry-run
```

Do not stop or delete containers before removing images:

```bash
./clean_images.sh --keep-containers
```

Remove copied fuzzer source trees from subject directories:

```bash
./remove.sh
```

## Development Notes

- Changes to AFLNet, StateAFL, target Dockerfiles, or target build contexts
  require image rebuilds.
- Changing `CHATAFL_MODEL`, `CHATAFL_URL`, or the ChatAFL API-key secret does
  not require an image rebuild. Runtime configuration support is prepared and
  cached by `scripts/prepare_chatafl_runtime.sh`; broader ChatAFL changes
  outside that runtime overlay still require updating the image build.
- Voltron changes do not require target image rebuilds; use `VOLTRON_REF` or
  `VOLTRON_SOURCE_DIR`.
- `SKIPCOUNT` controls how often progress samples are recorded.
- `TEST_TIMEOUT` is forwarded into AFLNet/ChatAFL/StateAFL target options where
  those options use `-t ${TEST_TIMEOUT}+`.
- Voltron maps `pure-ftpd` to `pureftpd` and `lighttpd1` to `lighttpd` before
  invoking its CLI.

## Troubleshooting

Inspect containers left after a run:

```bash
docker ps -a
docker logs <container_id>
```

Stop running experiment and API-gateway containers without deleting them:

```bash
./clean_containers.sh
```

Force image rebuilds if a Docker image is stale:

```bash
FORCE_REBUILD=1 ./setup.sh
FORCE_GATEWAY_REBUILD=1 ./run_api_gateway.sh restart
```

Clear cached Voltron snapshots if a local experiment should start fresh:

```bash
rm -rf .runtime/voltron
```

Use `VOLTRON_SOURCE_DIR=/path/to/voltron` when debugging local Voltron changes.

## Citations

VoltronBench reuses infrastructure and source code from AFLNet, ChatAFL,
StateAFL, and ProFuzzBench. If you use this repository in academic work, cite
the relevant upstream systems.

ChatAFL:

```bibtex
@inproceedings{chatafl,
  author={Ruijie Meng and Martin Mirchev and Marcel B\"{o}hme and Abhik Roychoudhury},
  title={Large Language Model guided Protocol Fuzzing},
  booktitle={Proceedings of the 31st Annual Network and Distributed System Security Symposium (NDSS)},
  year={2024}
}
```

ProFuzzBench:

```bibtex
@inproceedings{profuzzbench,
  title={ProFuzzBench: A Benchmark for Stateful Protocol Fuzzing},
  author={Roberto Natella and Van-Thuan Pham},
  booktitle={Proceedings of the 30th ACM SIGSOFT International Symposium on Software Testing and Analysis},
  year={2021}
}
```

## License

This repository contains code derived from upstream projects. See `LICENSE` and
the license files in the vendored components for details.
