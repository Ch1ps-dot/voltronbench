#!/bin/bash

MODEL="gpt-4-turbo"
URL="https:\/\/xiaoai.plus\/v1"
KEY="sk-vUIK7aS2md6wOsKyEsEEDzzDYNu5BwwaQ9UofpG9N7XB6egQ"

# Update the openAI key
for x in ChatAFL;
do
  sed -i "s/#define MODEL \".*\"/#define MODEL \"$MODEL\"/" $x/chat-llm.h
  sed -i "s/#define URL \".*\"/#define URL \"$URL\"/" $x/chat-llm.h
  sed -i "s/#define OPENAI_TOKEN \".*\"/#define OPENAI_TOKEN \"$KEY\"/" $x/chat-llm.h
done

# Copy the different versions of ChatAFL to the benchmark directories
for subject in ./benchmark/subjects/*/*; do
  rm -r $subject/aflnet 2>&1 >/dev/null
  cp -r aflnet $subject/aflnet

  rm -r $subject/chatafl 2>&1 >/dev/null
  cp -r ChatAFL $subject/chatafl

  rm -r $subject/voltron 2>&1 >/dev/null
  cp -r voltron $subject/voltron
done;

# Build the docker images

PFBENCH="$PWD/benchmark"
cd $PFBENCH
PFBENCH=$PFBENCH scripts/execution/profuzzbench_build_all.sh