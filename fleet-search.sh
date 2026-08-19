#!/bin/bash
# Fleet-parallel DSP-Seed-Finder search: splits a seed range across machines
# proportionally to measured actual-veins throughput, runs dsp_seed CLI on
# each via ssh (detached), and merges results.
#
# Usage: fleet-search.sh start  <rules.json> <start:end> <run-name>
#        fleet-search.sh status <run-name>
#        fleet-search.sh collect <run-name>     # scp + merge into <run-name>.tsv
#        fleet-search.sh stop   <run-name>
#
# Hosts/weights: measured 2026-08-13 on the actual-veins workload (seeds/s).
# desktop runs nice -19 (shares with interactive use / transcode QC batches);
# laptop nice -10. Weights approximate — resume handles any imbalance: re-run
# `start` with the same args and each host continues from its progress file.
set -uo pipefail

SSH="ssh -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3"
SCP="scp -q -o ConnectTimeout=15"

HOSTS=(compiler laptop desktop)
declare -A WEIGHT=([compiler]=351 [laptop]=195 [desktop]=115)
declare -A NICE=([compiler]="nice -n 5" [laptop]="nice -n 10" [desktop]="nice -n 19")
BIN=/tmp/dsp_seed
LOCAL_BIN="$HOME/dsp-seed-finder/target/release/dsp_seed"

MODE=${1:?usage}; shift
case "$MODE" in
start)
    RULES=${1:?rules.json}; RANGE=${2:?start:end}; RUN=${3:?run-name}
    START=${RANGE%%:*}; END=${RANGE##*:}
    TOTAL_W=0; for h in "${HOSTS[@]}"; do TOTAL_W=$((TOTAL_W + WEIGHT[$h])); done
    SPAN=$((END - START)); POS=$START
    for i in "${!HOSTS[@]}"; do
        h=${HOSTS[$i]}
        if [ "$i" -eq $((${#HOSTS[@]} - 1)) ]; then HI=$END
        else HI=$((POS + SPAN * WEIGHT[$h] / TOTAL_W)); fi
        $SCP "$LOCAL_BIN" "$RULES" "$h:/tmp/" 2>/dev/null || $SCP "$RULES" "$h:/tmp/"
        RB=/tmp/$(basename "$RULES")
        $SSH "$h" "bash -c 'cd /tmp && setsid ${NICE[$h]} $BIN search --rules $RB \
            --range $POS:$HI --out /tmp/${RUN}-${h}.tsv --resume \
            > /tmp/${RUN}-${h}.log 2>&1 < /dev/null & echo $h: $POS:$HI launched'"
        POS=$HI
    done
    ;;
status)
    RUN=${1:?run-name}
    for h in "${HOSTS[@]}"; do
        $SSH "$h" "bash -c 'P=\$(cat /tmp/${RUN}-${h}.tsv.progress 2>/dev/null || echo none); \
            L=\$(tail -1 /tmp/${RUN}-${h}.log 2>/dev/null); \
            R=\$(pgrep -f \"out /tmp/${RUN}[-]${h}\" >/dev/null && echo RUNNING || echo stopped); \
            echo \"$h [\$R] progress=\$P :: \$L\"'"
    done
    ;;
collect)
    RUN=${1:?run-name}
    for h in "${HOSTS[@]}"; do
        $SCP "$h:/tmp/${RUN}-${h}.tsv" "./${RUN}-${h}.tsv" 2>/dev/null || true
    done
    sort -n -m ./${RUN}-*.tsv > "./${RUN}.tsv" 2>/dev/null || cat ./${RUN}-*.tsv | sort -n > "./${RUN}.tsv"
    wc -l "./${RUN}.tsv"
    ;;
stop)
    RUN=${1:?run-name}
    for h in "${HOSTS[@]}"; do
        $SSH "$h" "bash -c 'pkill -f \"out /tmp/${RUN}[-]${h}\" && echo $h stopped || echo $h not-running'"
    done
    ;;
*) echo "unknown mode $MODE" >&2; exit 1 ;;
esac
