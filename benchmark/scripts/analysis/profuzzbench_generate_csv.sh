#!/bin/bash
prog=$1        #name of the subject program (e.g., lightftp)
runs=$2        #total number of runs
fuzzers=$3     #fuzzer name (e.g., aflnet) -- this name must match the name of the fuzzer folder inside the Docker container
covfile=$4     #output CSV file
append=$5      #append mode
               #enable this mode when the results of different fuzzers need to be merged
states_data=$6

#create a new file if append = 0
if [ $append = "0" ]; then
  #echo "Trying to delete $PWD/$covfile"
  rm -f "$PWD/$covfile"
  touch "$covfile"
  echo "time,subject,fuzzer,run,cov_type,cov" >> "$covfile"

  #echo "Trying to delete $PWD/$states_data"
  rm -f "$states_data"
  touch "$states_data"
  echo "time,subject,fuzzer,run,state_type,state" >> "$states_data"

  # This legacy file mixed StateAFL memory states with AFLNet response states.
  rm -f stateafl_memory_states.csv
fi

#remove space(s) 
#it requires that there is no space in the middle
strim() {
  trimmedStr=$1
  echo "${trimmedStr##*( )}"
}

#original format: time,l_per,l_abs,b_per,b_abs
#converted format: time,subject,fuzzer,run,cov_type,cov
convert() {
  fuzzer=$1
  subject=$2
  run_index=$3
  ifile=$4
  ofile=$5

  {
    read #ignore the header
    while read -r line; do
      time=$(strim $(echo $line | cut -d',' -f1))
      l_per=$(strim $(echo $line | cut -d',' -f2))
      l_abs=$(strim $(echo $line | cut -d',' -f3))
      b_per=$(strim $(echo $line | cut -d',' -f4))
      b_abs=$(strim $(echo $line | cut -d',' -f5))
      echo $time,$subject,$fuzzer,$run_index,"l_per",$l_per >> $ofile
      echo $time,$subject,$fuzzer,$run_index,"l_abs",$l_abs >> $ofile
      echo $time,$subject,$fuzzer,$run_index,"b_per",$b_per >> $ofile
      echo $time,$subject,$fuzzer,$run_index,"b_abs",$b_abs >> $ofile
    done 
  } < $ifile
}

#original format: unix_time, cycles_done, cur_path, paths_total, pending_total, pending_favs, map_size, unique_crashes, unique_hangs, max_depth, execs_per_sec, n_nodes, n_edges, chat_times
#converted format: time,subject,fuzzer,run,data_type,data
convert_state() {
  local fuzzer=$1
  local subject=$2
  local run_index=$3
  local ifile=$4
  local ofile=$5
  local converted

  converted=$(mktemp)
  if ! awk -F',' \
      -v subject="$subject" \
      -v fuzzer="$fuzzer" \
      -v run_index="$run_index" '
    function trim(value) {
      gsub(/^[[:space:]#]+/, "", value)
      gsub(/[[:space:]]+$/, "", value)
      return value
    }

    NR == 1 {
      for (column_index = 1; column_index <= NF; column_index++) {
        columns[trim($column_index)] = column_index
      }
      if (!("unix_time" in columns) ||
          !("n_nodes" in columns) ||
          !("n_edges" in columns)) {
        print "State data schema error: expected unix_time,n_nodes,n_edges in " FILENAME > "/dev/stderr"
        exit 2
      }
      next
    }

    {
      time = trim($(columns["unix_time"]))
      nodes = trim($(columns["n_nodes"]))
      edges = trim($(columns["n_edges"]))
      if (time !~ /^[0-9]+$/ || nodes !~ /^[0-9]+$/ || edges !~ /^[0-9]+$/) {
        print "State data value error in " FILENAME " at line " NR > "/dev/stderr"
        exit 3
      }
      print time "," subject "," fuzzer "," run_index ",nodes," nodes
      print time "," subject "," fuzzer "," run_index ",edges," edges
    }
  ' "$ifile" > "$converted"; then
    rm -f "$converted"
    return 1
  fi

  cat "$converted" >> "$ofile"
  rm -f "$converted"
}

convert_response_state() {
  local fuzzer=$1
  local subject=$2
  local run_index=$3
  local ifile=$4
  local ofile=$5
  local converted

  converted=$(mktemp)
  if ! awk -F',' \
      -v subject="$subject" \
      -v fuzzer="$fuzzer" \
      -v run_index="$run_index" '
    function trim(value) {
      gsub(/^[[:space:]#]+/, "", value)
      gsub(/[[:space:]]+$/, "", value)
      return value
    }

    NR == 1 {
      for (column_index = 1; column_index <= NF; column_index++) {
        columns[trim($column_index)] = column_index
      }
      if (!("unix_time" in columns) ||
          !("response_state_num" in columns) ||
          !("response_transition_num" in columns)) {
        print "StateAFL response metrics schema error: expected unix_time,response_state_num,response_transition_num in " FILENAME > "/dev/stderr"
        exit 2
      }
      next
    }

    {
      time = trim($(columns["unix_time"]))
      nodes = trim($(columns["response_state_num"]))
      edges = trim($(columns["response_transition_num"]))
      if (time !~ /^[0-9]+$/ || nodes !~ /^[0-9]+$/ || edges !~ /^[0-9]+$/) {
        print "StateAFL response metrics value error in " FILENAME " at line " NR > "/dev/stderr"
        exit 3
      }
      print time "," subject "," fuzzer "," run_index ",nodes," nodes
      print time "," subject "," fuzzer "," run_index ",edges," edges
    }
  ' "$ifile" > "$converted"; then
    rm -f "$converted"
    return 1
  fi

  cat "$converted" >> "$ofile"
  rm -f "$converted"
}

#extract tar files & process the data
status=0
for fuzzer in $fuzzers; do 
  for i in $(seq 1 $runs); do 
    printf "\nProcessing out-${prog}-${fuzzer}-${i} ..."
    rm -rf out-${prog}-${fuzzer}-${i}
    archive="out-${prog}-${fuzzer}_${i}.tar.gz"
    output_dir="out-${prog}-${fuzzer}"
    members=("${output_dir}/cov_over_time.csv")
    if [ "$fuzzer" = "stateafl" ]; then
      members+=("${output_dir}/response_ipsm_metrics.csv")
    else
      members+=("${output_dir}/plot_data")
    fi
    if ! tar -axf "$archive" "${members[@]}"; then
      if [ "$fuzzer" = "stateafl" ]; then
        echo "StateAFL response metrics unavailable in $archive; refusing to compare memory states with AFLNet response states." >&2
      fi
      status=1
      rm -rf "$output_dir"
      continue
    fi
    mv out-${prog}-${fuzzer} out-${prog}-${fuzzer}-${i}
    #combine all csv files
    if [ -s out-${prog}-${fuzzer}-${i}/cov_over_time.csv ]; then
      convert $fuzzer $prog $i out-${prog}-${fuzzer}-${i}/cov_over_time.csv $covfile
    fi
    if [ "$fuzzer" = "stateafl" ]; then
      if ! convert_response_state \
          "$fuzzer" "$prog" "$i" \
          "out-${prog}-${fuzzer}-${i}/response_ipsm_metrics.csv" \
          "$states_data"; then
        status=1
      fi

    elif [ -s out-${prog}-${fuzzer}-${i}/plot_data ]; then
      if ! convert_state \
          "$fuzzer" "$prog" "$i" \
          "out-${prog}-${fuzzer}-${i}/plot_data" "$states_data"; then
        status=1
      fi
    fi
  done 
done

exit "$status"
