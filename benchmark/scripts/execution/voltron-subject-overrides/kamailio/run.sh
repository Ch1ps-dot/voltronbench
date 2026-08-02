#!/bin/bash

cd /home/ubuntu/experiments/kamailio
exec ./src/kamailio \
  -f /home/ubuntu/experiments/kamailio-basic.cfg \
  -L src/modules -Y runtime_dir -n 1 -D -E
