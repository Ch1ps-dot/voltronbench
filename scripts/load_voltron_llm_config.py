#!/usr/bin/env python3

import argparse
import base64
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit(
        "VOLTRON: PyYAML is required to read the LLM configuration "
        "(install it with: python3 -m pip install PyYAML)"
    )


FIELDS = ("base_url", "api_key", "model")


def fail(message: str) -> None:
    sys.exit(f"VOLTRON: invalid LLM configuration: {message}")


def load_profiles(config_path: Path) -> list[dict[str, str]]:
    try:
        document = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    except OSError as error:
        fail(f"cannot read {config_path}: {error}")
    except yaml.YAMLError as error:
        fail(f"cannot parse {config_path}: {error}")

    if not isinstance(document, dict):
        fail("the document root must be a mapping")

    profiles = document.get("profiles")
    if not isinstance(profiles, list) or not profiles:
        fail("'profiles' must be a non-empty list")

    normalized = []
    for index, profile in enumerate(profiles, start=1):
        if not isinstance(profile, dict):
            fail(f"profiles[{index}] must be a mapping")

        values = {}
        for field in FIELDS:
            value = profile.get(field)
            if not isinstance(value, str) or not value.strip():
                fail(f"profiles[{index}].{field} must be a non-empty string")
            if "\0" in value:
                fail(f"profiles[{index}].{field} cannot contain a NUL byte")
            values[field] = value.strip()
        normalized.append(values)

    return normalized


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--models-only",
        action="store_true",
        help="print a comma-separated list of unique profile models",
    )
    parser.add_argument("config", type=Path)
    args = parser.parse_args()

    profiles = load_profiles(args.config)
    if args.models_only:
        print(",".join(dict.fromkeys(profile["model"] for profile in profiles)))
        return

    for profile in profiles:
        for field in FIELDS:
            encoded = base64.b64encode(profile[field].encode("utf-8"))
            sys.stdout.buffer.write(encoded + b"\n")


if __name__ == "__main__":
    main()
