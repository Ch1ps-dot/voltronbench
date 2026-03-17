#!/bin/bash

# Copy the different versions of ChatAFL to the benchmark directories
for subject in ./benchmark/subjects/*/*; do
  rm -r $subject/aflnet 2>&1 >/dev/null

  rm -r $subject/chatafl 2>&1 >/dev/null

  rm -r $subject/voltron 2>&1 >/dev/null

done;