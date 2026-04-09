#!/bin/bash

TARGET=$1   #name of the docker image
RUNS=$2       #number of runs
SAVETO=$3     #path to folder keeping the results
TIMEOUT=$4    #time for fuzzing
SAVETO=$5     #path to folder keeping the results in container

WORKDIR="/home/ubuntu/experiments"
VOLTRON_DIR="/home/ubuntu/voltron"
DOCKER_IMAGE="${TARGET}-vol:latest"

#keep all container ids
cids=()

#create one container for each run
for i in $(seq 1 $RUNS); do
  id=$(docker run --cpus=1 -d -it $DOCIMAGE /bin/bash -c "cd ${VOLTRON_DIR} && uv run ./cli.py -s ${TARGET} -t ${TIMEOUT} -a state -o ${OUTDIR}")
  cids+=(${id::12}) #store only the first 12 characters of a container ID
done

dlist="" #docker list
for id in ${cids[@]}; do
  dlist+=" ${id}"
done

#wait until all these dockers are stopped
printf "\nvoltron: Fuzzing in progress ..."
printf "\nvoltron: Waiting for the following containers to stop: ${dlist}"
docker wait ${dlist} > /dev/null
wait

#collect the fuzzing results from the containers
printf "\n${FUZZER^^}: Collecting results and save them to ${SAVETO}"
index=1
for id in ${cids[@]}; do
  printf "\n${FUZZER^^}: Collecting results from container ${id}"
  docker cp ${id}:/home/ubuntu/voltron/${OUTDIR}.tar.gz ${SAVETO}/${OUTDIR}_${index}.tar.gz > /dev/null
  if [ ! -z $DELETE ]; then
    printf "\nDeleting ${id}"
    docker rm ${id} # Remove container now that we don't need it
  fi
  index=$((index+1))
done

printf "\n${FUZZER^^}: I am done!\n"