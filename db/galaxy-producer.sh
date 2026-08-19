#!/bin/bash
# Galaxy DB dump producer — runs ON a dump host. Dumps CHUNK-sized seed ranges
# with dsp_seed dump, zstd-compresses the TSVs, and marks each chunk DONE for
# the collector. Pauses when too many finished chunks await collection (disk
# guard). Fully resumable: finished chunks are skipped via markers, the
# in-progress chunk via dsp_seed's own progress file.
#
# Usage: galaxy-producer.sh <start> <end> <star_count> [nice]
set -uo pipefail
START=${1:?start}; END=${2:?end}; SC=${3:?star_count}; NICENESS=${4:-5}
CHUNK=200000
BASE=/tmp/gchunks
MAX_PENDING=3
BIN=/tmp/dsp_seed_dump

mkdir -p "$BASE"
pos=$START
while [ "$pos" -lt "$END" ]; do
    hi=$((pos + CHUNK)); [ "$hi" -gt "$END" ] && hi=$END
    dir="$BASE/c${SC}-${pos}"
    if [ -f "$dir/DONE" ] || [ -f "$dir/SHIPPED" ]; then pos=$hi; continue; fi
    # disk guard: wait for the collector to drain
    while [ "$(ls -d $BASE/*/DONE 2>/dev/null | wc -l)" -ge "$MAX_PENDING" ]; do
        sleep 30
    done
    mkdir -p "$dir"
    nice -n "$NICENESS" "$BIN" dump --star-count "$SC" --range "$pos:$hi" \
        --out-dir "$dir" --resume >> "$dir/dump.log" 2>&1 || { sleep 10; continue; }
    for f in galaxies stars planets; do
        nice -n "$NICENESS" zstd -q -3 --rm "$dir/$f.tsv" || exit 1
    done
    echo "$pos:$hi" > "$dir/DONE"
    pos=$hi
done
echo "producer complete: $START:$END sc=$SC"
