#!/bin/bash

# The main-snapshot setup script removes every directory in /home/ubuntu other
# than a legacy allowlist.  That deletes the active voltron-runtime directory
# and loses its status/metrics before the runner can archive them.
set -euo pipefail

pkill pure-ftpd > /dev/null 2>&1 || true
