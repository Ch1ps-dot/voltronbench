#!/bin/bash

set -eu

exec /home/ubuntu/experiments/bftpd/bftpd \
  -D -c /home/ubuntu/experiments/basic.conf
