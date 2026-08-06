#!/bin/bash

folder=$1   #fuzzer result folder
pno=$2      #port number
step=$3     #step to skip running gcovr and outputting data to covfile
            #e.g., step=5 means we run gcovr after every 5 test cases
covfile=$4  #path to coverage file
fmode=$5    #file mode -- structured or not
            #fmode = 0: the test case is a concatenated message sequence -- there is no message boundary
            #fmode = 1: the test case is a structured file keeping several request messages

LIFECYCLE="$WORKDIR/pjsua_lifecycle"
export KAMAILIO_PJSUA_LOG="${folder}/kamailio-pjsua-lifecycle.log"

run_replay_case() {
  local testcase=$1
  local setup_pid replay_pid target_pid target_status replay_status setup_status

  "$WORKDIR/run_pjsip" &
  setup_pid=$!
  "$replayer" "$testcase" SIP "$pno" 1 >/dev/null 2>&1 &
  replay_pid=$!
  timeout -k 1s -s SIGTERM 3s \
    ./kamailio-gcov/src/kamailio -f ./kamailio-basic.cfg \
    -L ./kamailio-gcov/src/modules -Y ./kamailio-gcov/runtime_dir/ \
    -n 1 -D -E >/dev/null 2>&1 &
  target_pid=$!

  wait "$target_pid"
  target_status=$?
  wait "$setup_pid"
  setup_status=$?
  wait "$replay_pid"
  replay_status=$?
  "$LIFECYCLE" stop >/dev/null 2>&1 || true

  if (( target_status != 0 || setup_status != 0 || replay_status != 0 )); then
    return 1
  fi
  return 0
}

#delete the existing coverage file
mkdir -p "$(dirname "$covfile")"
rm -f "$covfile"; touch "$covfile"

#clear gcov data
gcovr -r kamailio-gcov -s -d > /dev/null 2>&1

#output the header of the coverage file which is in the CSV format
#Time: timestamp, l_per/b_per and l_abs/b_abs: line/branch coverage in percentage and absolutate number
echo "Time,l_per,l_abs,b_per,b_abs" >> $covfile

#files stored in replayable-* folders are structured
#in such a way that messages are separated
if [ $fmode -eq "1" ]; then
  testdir="replayable-queue"
  replayer="aflnet-replay"
else
  testdir="queue"
  replayer="afl-replay"
fi

#process initial seed corpus first
shopt -s nullglob
seed_files=("$folder/$testdir/"*.raw)
for f in "${seed_files[@]}"; do
  time=$(stat -c %Y "$f")
  run_replay_case "$f" || true
  cov_data=$(gcovr -r kamailio-gcov -s | grep "[lb][a-z]*:")
  l_per=$(echo "$cov_data" | grep lines | cut -d" " -f2 | rev | cut -c2- | rev)
  l_abs=$(echo "$cov_data" | grep lines | cut -d" " -f3 | cut -c2-)
  b_per=$(echo "$cov_data" | grep branch | cut -d" " -f2 | rev | cut -c2- | rev)
  b_abs=$(echo "$cov_data" | grep branch | cut -d" " -f3 | cut -c2-)
  
  echo "$time,$l_per,$l_abs,$b_per,$b_abs" >> $covfile
done

#process fuzzer-generated testcases
count=0
last_testcase=""
testcases=("$folder/$testdir/"id*)
for f in "${testcases[@]}"; do
  last_testcase=$f
  time=$(stat -c %Y "$f")
  run_replay_case "$f" || true
  count=$(expr $count + 1)
  rem=$(expr $count % $step)
  if [ "$rem" != "0" ]; then continue; fi
  cov_data=$(gcovr -r kamailio-gcov -s | grep "[lb][a-z]*:")
  l_per=$(echo "$cov_data" | grep lines | cut -d" " -f2 | rev | cut -c2- | rev)
  l_abs=$(echo "$cov_data" | grep lines | cut -d" " -f3 | cut -c2-)
  b_per=$(echo "$cov_data" | grep branch | cut -d" " -f2 | rev | cut -c2- | rev)
  b_abs=$(echo "$cov_data" | grep branch | cut -d" " -f3 | cut -c2-)
  
  echo "$time,$l_per,$l_abs,$b_per,$b_abs" >> $covfile
done

#ouput cov data for the last testcase(s) if step > 1
if [[ $step -gt 1 && -n "$last_testcase" ]]
then
  time=$(stat -c %Y "$last_testcase")
  cov_data=$(gcovr -r kamailio-gcov -s | grep "[lb][a-z]*:")
  l_per=$(echo "$cov_data" | grep lines | cut -d" " -f2 | rev | cut -c2- | rev)
  l_abs=$(echo "$cov_data" | grep lines | cut -d" " -f3 | cut -c2-)
  b_per=$(echo "$cov_data" | grep branch | cut -d" " -f2 | rev | cut -c2- | rev)
  b_abs=$(echo "$cov_data" | grep branch | cut -d" " -f3 | cut -c2-)
  
  echo "$time,$l_per,$l_abs,$b_per,$b_abs" >> $covfile
fi
