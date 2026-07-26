#!/usr/bin/env python3

import argparse
import json
import multiprocessing
import sys
import threading
import time
from collections import Counter, defaultdict
from pathlib import Path

from load_voltron_llm_config import load_profiles
from test_voltron_api_pool import make_request, percentile


def worker(
    process_index: int,
    process_count: int,
    concurrency: int,
    profiles: list[dict[str, str]],
    duration: float,
    timeout: float,
    endpoint: str,
    prompt: str,
    output: multiprocessing.Queue,
) -> None:
    deadline = time.monotonic() + duration
    results = []
    total_workers = process_count * concurrency

    def request_loop(thread_index: int) -> None:
        sequence = 0
        worker_index = process_index * concurrency + thread_index
        while time.monotonic() < deadline:
            profile_index = (worker_index + sequence * total_workers) % len(profiles)
            results.append(
                make_request(
                    profile_index + 1,
                    profiles[profile_index],
                    endpoint,
                    timeout,
                    prompt,
                )
            )
            sequence += 1

    threads = [
        threading.Thread(target=request_loop, args=(index,))
        for index in range(concurrency)
    ]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    output.put(
        [
            (result.profile, result.status, result.latency_seconds)
            for result in results
        ]
    )


def summarize(results: list[tuple[int, str, float]], elapsed: float) -> dict:
    statuses = Counter(status for _, status, _ in results)
    successful = [
        latency for _, status, latency in results if status == "success"
    ]
    per_profile = {}
    grouped = defaultdict(list)
    for result in results:
        grouped[result[0]].append(result)
    for profile, profile_results in sorted(grouped.items()):
        profile_statuses = Counter(status for _, status, _ in profile_results)
        profile_successes = profile_statuses.get("success", 0)
        per_profile[str(profile)] = {
            "requests": len(profile_results),
            "successes": profile_successes,
            "success_rate": profile_successes / len(profile_results),
            "statuses": dict(profile_statuses),
        }

    success_count = statuses.get("success", 0)
    return {
        "requests": len(results),
        "successes": success_count,
        "success_rate": success_count / len(results) if results else 0.0,
        "elapsed_seconds": elapsed,
        "throughput_rps": success_count / elapsed if elapsed else 0.0,
        "latency_p50_seconds": percentile(successful, 0.50),
        "latency_p95_seconds": percentile(successful, 0.95),
        "statuses": dict(statuses),
        "per_profile": per_profile,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run a sustained multi-process test against a Voltron API pool."
    )
    parser.add_argument(
        "--config", type=Path, default=Path("config/voltron-llm.yaml")
    )
    parser.add_argument("--processes", type=int, default=10)
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--duration", type=float, default=300)
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--endpoint", default="chat/completions")
    parser.add_argument("--prompt", default="Reply with OK.")
    parser.add_argument("--json-output", type=Path)
    args = parser.parse_args()

    for name in ("processes", "concurrency", "duration", "timeout"):
        if getattr(args, name) <= 0:
            parser.error(f"--{name} must be positive")

    profiles = load_profiles(args.config)
    context = multiprocessing.get_context("spawn")
    output = context.Queue()
    processes = [
        context.Process(
            target=worker,
            args=(
                index,
                args.processes,
                args.concurrency,
                profiles,
                args.duration,
                args.timeout,
                args.endpoint,
                args.prompt,
                output,
            ),
        )
        for index in range(args.processes)
    ]

    started = time.perf_counter()
    for process in processes:
        process.start()

    results = []
    for _ in processes:
        results.extend(output.get())
    for process in processes:
        process.join()
        if process.exitcode != 0:
            print(f"worker process exited with status {process.exitcode}", file=sys.stderr)
            return 2

    summary = summarize(results, time.perf_counter() - started)
    print(
        f"pool processes={args.processes} concurrency/process={args.concurrency} "
        f"total_concurrency={args.processes * args.concurrency}"
    )
    print(
        f"requests={summary['requests']} successes={summary['successes']} "
        f"rate={summary['success_rate']:.1%} "
        f"rps={summary['throughput_rps']:.2f} "
        f"p50={summary['latency_p50_seconds']:.3f}s "
        f"p95={summary['latency_p95_seconds']:.3f}s "
        f"statuses={summary['statuses']}"
    )
    for profile, profile_summary in summary["per_profile"].items():
        print(
            f"profile-{profile}: success={profile_summary['successes']}/"
            f"{profile_summary['requests']} "
            f"rate={profile_summary['success_rate']:.1%} "
            f"statuses={profile_summary['statuses']}"
        )

    report = {
        "processes": args.processes,
        "concurrency_per_process": args.concurrency,
        "total_concurrency": args.processes * args.concurrency,
        "configured_duration_seconds": args.duration,
        **summary,
    }
    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(
            json.dumps(report, indent=2, ensure_ascii=True) + "\n",
            encoding="utf-8",
        )
        print(f"JSON report: {args.json_output}")

    return 0 if summary["successes"] else 1


if __name__ == "__main__":
    sys.exit(main())
