#!/bin/bash

# Keep the Exim process in the session created by Executor.run_exe().  The
# previous shell wrapper allowed a daemonized listener to outlive the tracked
# process, leaving TCP/25 occupied for the next interaction.
set -euo pipefail

PIDFILE=${EXIM_PIDFILE:-/tmp/voltron-exim.pid}
rm -f -- "$PIDFILE"

exec /usr/exim/bin/exim -bd -d -oX 25 -oP "$PIDFILE"
