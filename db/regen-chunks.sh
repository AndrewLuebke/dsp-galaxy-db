#!/bin/bash
# Regenerate the 13 chunks whose floats were degraded to 6 significant digits by
# the MariaDB backfill (LOAD DATA -> INTO OUTFILE). Runs FROM claude-node.
# Generates natively on compiler, streams to the parquet CT, converts, VERIFIES,
# then swaps. One chunk at a time so compiler's tmpfs never holds more than one.
set -uo pipefail
CHUNKS="${CHUNKS:-0 200000 400000 600000 800000 1000000 1200000 1400000 1600000 1800000 2000000 80000000 80200000}"
SSH="ssh -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
n=0; total=$(echo $CHUNKS | wc -w)
for base in $CHUNKS; do
    n=$((n+1)); name=c64-$base; hi=$((base + 200000))
    t0=$(date +%s)
    echo "[$n/$total] $name  seeds $base:$hi  $(date +%H:%M:%S)"

    $SSH compiler "bash -c 'rm -rf /tmp/regen/$name && mkdir -p /tmp/regen/$name &&
        /tmp/dsp_seed_dump dump --star-count 64 --range $base:$hi --out-dir /tmp/regen/$name > /tmp/regen/$name/dump.log 2>&1'" \
        || { echo "  GENERATE FAILED $name"; continue; }

    $SSH compiler "bash -c 'cd /tmp/regen/$name && tar c galaxies.tsv stars.tsv planets.tsv | zstd -3 -q'" 2>/dev/null \
      | $SSH parquet "bash -c 'rm -rf /parquet/incoming/$name && mkdir -p /parquet/incoming/$name &&
            cd /parquet/incoming/$name && zstd -dq | tar x'" \
        || { echo "  TRANSFER FAILED $name"; $SSH compiler "rm -rf /tmp/regen/$name"; continue; }

    $SSH parquet "bash -c '/root/regen-convert.sh $name'" \
        || { echo "  CONVERT/VERIFY FAILED $name -- live file left untouched"; }

    $SSH compiler "rm -rf /tmp/regen/$name"
    echo "  elapsed $(( $(date +%s) - t0 ))s"
done
echo "=== regeneration pass complete ==="
