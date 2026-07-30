#!/bin/bash

set -euo pipefail

sudo -n /etc/init.d/dbus start > /dev/null
sudo -n /etc/init.d/avahi-daemon start > /dev/null
