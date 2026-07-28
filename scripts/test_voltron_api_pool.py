#!/usr/bin/env python3

import argparse
import json
import math
import socket
import statistics
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from load_voltron_llm_config import load_profiles


@dataclass
class RequestResult:
    profile: int
    status: str
    latency_seconds: float
    detail: str = ""


def parse_concurrency_levels(value: str) -> list[int]:
    try:
        levels = [int(item.strip()) for item in value.split(",")]
    except ValueError as error:
        raise argparse.ArgumentTypeError("levels must be comma-separated integers") from error
    if not levels or any(level <= 0 for level in levels):
        raise argparse.ArgumentTypeError("all concurrency levels must be positive")
    return list(dict.fromkeys(levels))


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * fraction) - 1)
    return ordered[index]


def chat_completions_url(base_url: str, endpoint: str) -> str:
    return f"{base_url.rstrip('/')}/{endpoint.lstrip('/')}"


def make_request(
    profile_index: int,
    profile: dict[str, str],
    endpoint: str,
    timeout: float,
    prompt: str,
) -> RequestResult:
    payload = json.dumps(
        {
            "model": profile["model"],
            "messages": [{"role": "user", "content": prompt}],
            "stream": False,
        }
    ).encode("utf-8")
    request = Request(
        chat_completions_url(profile["base_url"], endpoint),
        data=payload,
        headers={
            "Authorization": f"Bearer {profile['api_key']}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    started = time.perf_counter()
    try:
        with urlopen(request, timeout=timeout) as response:
            body = json.load(response)
        latency = time.perf_counter() - started
        if not isinstance(body, dict) or "choices" not in body:
            return RequestResult(profile_index, "invalid_response", latency)
        return RequestResult(profile_index, "success", latency)
    except HTTPError as error:
        latency = time.perf_counter() - started
        detail = error.read(512).decode("utf-8", errors="replace").replace("\n", " ")
        return RequestResult(profile_index, f"http_{error.code}", latency, detail)
    except (TimeoutError, socket.timeout):
        return RequestResult(
            profile_index, "timeout", time.perf_counter() - started
        )
    except (URLError, OSError, json.JSONDecodeError) as error:
        return RequestResult(
            profile_index,
            "connection_error",
            time.perf_counter() - started,
            str(error),
        )


def run_level(
    assignments: list[tuple[int, dict[str, str]]],
    concurrency: int,
    endpoint: str,
    timeout: float,
    prompt: str,
) -> tuple[dict[str, object], list[RequestResult]]:
    started = time.perf_counter()
    results = []
    with ThreadPoolExecutor(max_workers=concurrency) as executor:
        futures = [
            executor.submit(
                make_request, profile_index, profile, endpoint, timeout, prompt
            )
            for profile_index, profile in assignments
        ]
        for future in as_completed(futures):
            results.append(future.result())
    elapsed = time.perf_counter() - started

    statuses: dict[str, int] = {}
    for result in results:
        statuses[result.status] = statuses.get(result.status, 0) + 1
    successful_latencies = [
        result.latency_seconds for result in results if result.status == "success"
    ]
    success_count = statuses.get("success", 0)
    summary = {
        "concurrency": concurrency,
        "requests": len(results),
        "successes": success_count,
        "success_rate": success_count / len(results) if results else 0.0,
        "elapsed_seconds": elapsed,
        "throughput_rps": success_count / elapsed if elapsed else 0.0,
        "latency_p50_seconds": (
            statistics.median(successful_latencies) if successful_latencies else 0.0
        ),
        "latency_p95_seconds": percentile(successful_latencies, 0.95),
        "statuses": statuses,
    }
    return summary, results


def print_summary(label: str, summary: dict[str, object]) -> None:
    statuses = ", ".join(
        f"{name}={count}"
        for name, count in sorted(summary["statuses"].items())
    )
    print(
        f"{label:<12} concurrency={summary['concurrency']:<3} "
        f"success={summary['successes']}/{summary['requests']} "
        f"rate={summary['success_rate']:.0%} "
        f"rps={summary['throughput_rps']:.2f} "
        f"p50={summary['latency_p50_seconds']:.3f}s "
        f"p95={summary['latency_p95_seconds']:.3f}s "
        f"[{statuses}]"
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Measure concurrency for Voltron OpenAI-compatible API profiles."
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("config/voltron-llm.yaml"),
        help="Voltron API pool YAML file",
    )
    parser.add_argument(
        "--mode",
        choices=("each", "pool"),
        default="each",
        help="test every profile separately or the round-robin pool",
    )
    parser.add_argument(
        "--concurrency",
        type=parse_concurrency_levels,
        default=parse_concurrency_levels("1,2,4,8"),
        help="comma-separated concurrency levels",
    )
    parser.add_argument(
        "--requests-per-worker",
        type=int,
        default=2,
        help="requests submitted per worker at each level",
    )
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--endpoint", default="chat/completions")
    parser.add_argument("--prompt", default="Reply with OK.")
    parser.add_argument(
        "--min-success-rate",
        type=float,
        default=0.95,
        help="threshold used to report the highest passing concurrency",
    )
    parser.add_argument("--json-output", type=Path)
    args = parser.parse_args()

    if args.requests_per_worker <= 0:
        parser.error("--requests-per-worker must be positive")
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    if not 0 < args.min_success_rate <= 1:
        parser.error("--min-success-rate must be greater than 0 and at most 1")

    profiles = load_profiles(args.config)
    report: dict[str, object] = {
        "config": str(args.config),
        "mode": args.mode,
        "min_success_rate": args.min_success_rate,
        "profiles": [
            {
                "index": index,
                "base_url": profile["base_url"],
                "model": profile["model"],
            }
            for index, profile in enumerate(profiles, start=1)
        ],
        "tests": [],
    }

    for concurrency in args.concurrency:
        request_count = concurrency * args.requests_per_worker
        if args.mode == "pool":
            assignments = [
                (index % len(profiles) + 1, profiles[index % len(profiles)])
                for index in range(request_count)
            ]
            batches = [("pool", assignments)]
        else:
            batches = [
                (f"profile-{index}", [(index, profile)] * request_count)
                for index, profile in enumerate(profiles, start=1)
            ]

        for label, assignments in batches:
            summary, results = run_level(
                assignments, concurrency, args.endpoint, args.timeout, args.prompt
            )
            print_summary(label, summary)
            report["tests"].append(
                {
                    "label": label,
                    **summary,
                    "errors": [
                        asdict(result)
                        for result in results
                        if result.status != "success"
                    ],
                }
            )

    labels = ["pool"] if args.mode == "pool" else [
        f"profile-{index}" for index in range(1, len(profiles) + 1)
    ]
    recommendations = {}
    for label in labels:
        passing = [
            test["concurrency"]
            for test in report["tests"]
            if test["label"] == label
            and test["success_rate"] >= args.min_success_rate
        ]
        recommendations[label] = max(passing) if passing else None
        result = recommendations[label] if passing else "none"
        print(
            f"{label:<12} highest tested concurrency at "
            f"{args.min_success_rate:.0%} success: {result}"
        )
    report["highest_passing_concurrency"] = recommendations

    if args.json_output:
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(
            json.dumps(report, indent=2, ensure_ascii=True) + "\n",
            encoding="utf-8",
        )
        print(f"JSON report: {args.json_output}")

    return 0 if all(test["successes"] > 0 for test in report["tests"]) else 1


if __name__ == "__main__":
    sys.exit(main())
