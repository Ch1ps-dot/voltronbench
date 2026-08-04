#!/usr/bin/env python3

"""Fail early when host-side analysis or monitoring dependencies are missing."""

from __future__ import annotations

import importlib
import pathlib
import sys


REQUIRED = {
    "pandas": "pandas",
    "matplotlib": "matplotlib",
    "rich": "rich",
}


def main() -> int:
    missing: list[str] = []
    for module, package in REQUIRED.items():
        try:
            importlib.import_module(module)
        except ImportError:
            missing.append(package)
    if missing:
        root = pathlib.Path(__file__).resolve().parents[1]
        requirements = root / "requirements-analysis.txt"
        print(
            "Missing host analysis/monitoring dependencies: "
            + ", ".join(missing),
            file=sys.stderr,
        )
        print(
            f"Install them with: python3 -m pip install -r {requirements}",
            file=sys.stderr,
        )
        return 2
    print("Host analysis/monitoring Python dependencies: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
