#!/bin/bash

DOCIMAGE=$1   #name of the docker image
RUNS=$2       #number of runs
SAVETO=$3     #path to folder keeping the results

FUZZER=$4     #fuzzer name (e.g., aflnet) -- this name must match the name of the fuzzer folder inside the Docker container
OUTDIR=$5     #name of the output folder created inside the docker container
OPTIONS=$6    #all configured options for fuzzing
TIMEOUT=$7    #time for fuzzing
SKIPCOUNT=$8  #used for calculating coverage over time. e.g., SKIPCOUNT=5 means we run gcovr after every 5 test cases
DELETE=${9:-}

WORKDIR="/home/ubuntu/experiments"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/profuzzbench_monitor_common.sh"

#keep all container ids
cids=()
MONITOR_PID=""
LABEL="${FUZZER} on ${DOCIMAGE}"
PROFUZZBENCH_RUN_START_EPOCH=$(date +%s)

collect_results() {
  local index=1
  local id

  printf "\n${FUZZER^^}: Collecting results and save them to ${SAVETO}"
  for id in "${cids[@]}"; do
    printf "\n${FUZZER^^}: Collecting results from container ${id}"
    if ! docker cp "${id}:/home/ubuntu/experiments/${OUTDIR}.tar.gz" "${SAVETO}/${OUTDIR}_${index}.tar.gz" > /dev/null 2>&1; then
      printf "\n${FUZZER^^}: No archive available from container ${id}"
    fi
    if [ -n "$DELETE" ]; then
      printf "\nDeleting ${id}"
      docker rm "${id}" > /dev/null 2>&1 || true
    fi
    index=$((index+1))
  done
}

handle_interrupt() {
  trap - INT TERM
  printf "\n${FUZZER^^}: Interrupt received. Cleaning up...\n"
  profuzzbench_stop_monitor "$MONITOR_PID"
  profuzzbench_interrupt_containers "${cids[@]}"
  profuzzbench_print_final_container_summary "$LABEL" "$TIMEOUT" "${cids[@]}"
  if [ "$PROFUZZBENCH_COLLECT_ON_INTERRUPT" = "1" ]; then
    collect_results
  fi
  printf "\n${FUZZER^^}: Interrupted. Exiting with status 130.\n"
  exit 130
}

trap handle_interrupt INT TERM

#create one container for each run
for i in $(seq 1 $RUNS); do
  id=$(docker run --cpus=1 -d -it $DOCIMAGE /bin/bash -c "cd ${WORKDIR} && run ${FUZZER} ${OUTDIR} '${OPTIONS}' ${TIMEOUT} ${SKIPCOUNT}")
  cids+=(${id::12}) #store only the first 12 characters of a container ID
done

dlist="" #docker list
for id in ${cids[@]}; do
  dlist+=" ${id}"
done

#wait until all these dockers are stopped
printf "\n${FUZZER^^}: Fuzzing in progress ..."
printf "\n${FUZZER^^}: Waiting for the following containers to stop: ${dlist}"
if [ "$PROFUZZBENCH_MONITOR" != "0" ]; then
  profuzzbench_monitor_containers "$LABEL" "$TIMEOUT" "${cids[@]}" &
  MONITOR_PID=$!
fi
docker wait ${dlist} > /dev/null
profuzzbench_stop_monitor "$MONITOR_PID"
profuzzbench_print_final_container_summary "$LABEL" "$TIMEOUT" "${cids[@]}"

#collect the fuzzing results from the containers
collect_results

printf "\n${FUZZER^^}: I am done!\n"
