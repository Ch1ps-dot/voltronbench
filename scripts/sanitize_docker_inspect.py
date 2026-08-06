#!/usr/bin/env python3
"""Write a safe subset of docker inspect JSON without environment secrets."""

from __future__ import annotations

import json
import sys


def scrub(value):
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key in {"Env", "ArgsEscaped"}:
                result[key] = "<redacted>"
            else:
                result[key] = scrub(item)
        return result
    if isinstance(value, list):
        return [scrub(item) for item in value]
    return value


payload = json.load(sys.stdin)
json.dump(scrub(payload), sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
