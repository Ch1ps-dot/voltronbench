#!/bin/bash

set -euo pipefail

start_service() {
  local service="$1"
  if sudo -n "/etc/init.d/${service}" start >/tmp/"${service}"-start.log 2>&1; then
    return 0
  fi
  sudo -n "/etc/init.d/${service}" status >/dev/null 2>&1
}

start_service dbus
start_service avahi-daemon

deadline=$((SECONDS + 10))
while (( SECONDS < deadline )); do
  if [[ -S /run/dbus/system_bus_socket ]] \
      && pgrep -x dbus-daemon >/dev/null \
      && pgrep -x avahi-daemon >/dev/null; then
    echo "forked-daapd environment ready: dbus and avahi are running"
    exit 0
  fi
  sleep 0.1
done

echo "forked-daapd environment setup failed" >&2
echo "dbus socket present: $([[ -S /run/dbus/system_bus_socket ]] && echo yes || echo no)" >&2
pgrep -a dbus-daemon >&2 || true
pgrep -a avahi-daemon >&2 || true
tail -n 20 /tmp/dbus-start.log /tmp/avahi-daemon-start.log >&2 || true
exit 1
