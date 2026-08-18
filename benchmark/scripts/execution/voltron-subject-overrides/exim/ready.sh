#!/bin/bash

# Verify the protocol contract instead of treating an open TCP socket as an
# SMTP-ready Exim instance.  The Executor supplies host, port and timeout.
set -euo pipefail

host=${1:-${VOLTRON_READINESS_HOST:-127.0.0.1}}
port=${2:-${VOLTRON_READINESS_PORT:-25}}
timeout=${3:-${VOLTRON_READINESS_TIMEOUT:-5}}

python3 - "$host" "$port" "$timeout" <<'PYTHON'
import socket
import sys

host, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
with socket.create_connection((host, port), timeout=timeout) as sock:
    sock.settimeout(timeout)
    banner = sock.recv(1024)
if not banner.startswith(b"220 "):
    raise SystemExit("unexpected SMTP banner: " + repr(banner[:200]))
print(banner.rstrip().decode("latin-1", errors="replace"))
PYTHON
