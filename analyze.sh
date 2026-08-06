#!/bin/bash

# Generate the state and coverage graphs

FILTER=$1
TIME=${2:-1440}
PROJECT_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUTPUT_ROOT=${3:-$PROJECT_ROOT}
PFBENCH="$PROJECT_ROOT/benchmark"
RESULTS_ROOT=${4:-$PFBENCH}

reset="\e[0m"
green="\e[0;92m"
yellow="\e[0;33m"
function warn  { echo -e "${yellow}[!] $1$reset"; }
function info  { echo -e "${green}[+]$reset $1"; }

if [ -z "$FILTER" ]; then
    echo "Usage: analyze.sh <subject names> <time in minutes> [output root] [results root]"
    exit 1
fi

if ! python3 "$PROJECT_ROOT/scripts/check_analysis_dependencies.py"; then
    echo "Analysis cannot continue without host analysis dependencies." >&2
    exit 1
fi

if ! mkdir -p "$OUTPUT_ROOT"; then
    echo "Failed to create analysis output directory: $OUTPUT_ROOT" >&2
    exit 1
fi
OUTPUT_ROOT=$(cd "$OUTPUT_ROOT" && pwd)
if [[ ! -d "$RESULTS_ROOT" ]]; then
    echo "Results directory does not exist: $RESULTS_ROOT" >&2
    exit 1
fi
RESULTS_ROOT=$(cd "$RESULTS_ROOT" && pwd)
cd "$RESULTS_ROOT" || exit 1

if [[ "$FILTER" == "all" ]]; then
    mapfile -t SUBJECTS < <(
        find . -maxdepth 1 -type d -name 'results-*' -printf '%f\n' \
            | sed 's/^results-//' \
            | sort
    )
else
    IFS=',' read -r -a SUBJECTS <<< "$FILTER"
fi

if [[ "${#SUBJECTS[@]}" == "0" ]]; then
    warn "No result directories were found."
    exit 1
fi

RUN_TIMESTAMP=$(date "+%b-%d_%H-%M-%S")
ANALYSIS_STATUS=0

for SUBJECT in "${SUBJECTS[@]}"; do
    echo "Analyzing $SUBJECT"
    RESULT_DIR="results-$SUBJECT"

    # Check if results exists
    if [[ ! -d "$RESULT_DIR" || -z "$(find "$RESULT_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        warn "No results for subject $SUBJECT."
        warn "Please check whether the fuzzing has completed via the following command:"
        warn "  docker ps -a | grep $SUBJECT"
        docker ps -a | grep "$SUBJECT"
        warn ""
        warn "If the containers' status is 'Up ..', please wait for the fuzzing to complete."
        warn "Once the fuzzing complete, the containers' status will change to 'Exited ..'"
        ANALYSIS_STATUS=1
        continue
    fi

    RES_FOLDER="res_${SUBJECT}_${RUN_TIMESTAMP}"
    RES_PATH="$OUTPUT_ROOT/$RES_FOLDER"
    if ! mkdir -p "$RES_PATH"; then
        warn "Failed to create analysis directory: $RES_PATH"
        ANALYSIS_STATUS=1
        continue
    fi

    if PATH=$PATH:$PFBENCH/scripts/execution:$PFBENCH/scripts/analysis \
        "$PFBENCH/scripts/analysis/profuzzbench_generate_all.sh" \
        "$SUBJECT" "$TIME"; then
        for plot in "cov_over_time_${SUBJECT}.png" "state_over_time_${SUBJECT}.png"; do
            if [[ -f "$plot" ]]; then
                cp "$plot" "$RES_PATH/"
            else
                warn "Expected analysis plot is missing: $plot"
                ANALYSIS_STATUS=1
            fi
        done
    else
        warn "Analysis failed for subject $SUBJECT; preserving its raw results."
        ANALYSIS_STATUS=1
    fi

    if ! cp -r "$RESULT_DIR" "$RES_PATH/"; then
        warn "Failed to copy raw results for subject $SUBJECT."
        ANALYSIS_STATUS=1
    fi
    info "Results from analysis for ${SUBJECT} are stored in $RES_PATH"
done

exit "$ANALYSIS_STATUS"
