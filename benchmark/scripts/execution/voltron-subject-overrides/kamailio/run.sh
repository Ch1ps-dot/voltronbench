#!/bin/bash

cd /home/ubuntu/experiments/kamailio
exec ./src/kamailio \
  -f /home/ubuntu/experiments/kamailio-basic.cfg \
  -l udp:127.0.0.1:5061 \
  -L src/modules -Y runtime_dir -n 1 -D -E
