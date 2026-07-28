#!/bin/bash
sudo apt-get update
sudo apt-get install -y docker python3 python3-pip
python3 -m pip install matplotlib pandas rich
python3 -m pip install -r requirements-gateway.txt
