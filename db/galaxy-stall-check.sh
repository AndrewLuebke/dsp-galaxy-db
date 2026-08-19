#!/bin/bash
# Hourly conveyor health check (systemd timer on claude-node).
#
# Monitors the OUTCOME (parquet chunks landing) rather than the mechanism, so a
# producer Andrew deliberately stops for gaming does not page him — only an
# actual halt in progress does. Emails fleet@ on stall, quiet otherwise.
set -uo pipefail
TARGET_CHUNKS=500          # full 10^8 space at 200k seeds/chunk, star_count 64
STALL_MIN=90               # a chunk takes ~10 min (both producers) to ~34 (desktop alone)
STATE=/home/andrew/.galaxy-stall-state

COUNT=$(ssh -o ConnectTimeout=20 parquet \
    "bash -c 'ls /parquet/planets/*.parquet 2>/dev/null | wc -l'" 2>/dev/null) || COUNT=-1
AGE=$(ssh -o ConnectTimeout=20 parquet \
    "bash -c 'find /parquet/planets -name \"*.parquet\" -printf \"%T@\\n\" 2>/dev/null | sort -n | tail -1'" 2>/dev/null)

PROBLEM=""
if [ "$COUNT" = "-1" ] || [ -z "$COUNT" ]; then
    PROBLEM="cannot reach the parquet CT"
elif [ "$COUNT" -ge "$TARGET_CHUNKS" ]; then
    if [ ! -f "$STATE.done" ]; then
        { echo "Subject: galaxy-db: RUN COMPLETE"
          echo "To: fleet@customcomputercare.com"; echo
          echo "All $COUNT/$TARGET_CHUNKS parquet chunks present in /parquet."; } | /usr/sbin/sendmail -t
        touch "$STATE.done"
    fi
    exit 0
elif [ -n "${AGE:-}" ]; then
    MINS=$(( ( $(date +%s) - ${AGE%.*} ) / 60 ))
    if [ "$MINS" -gt "$STALL_MIN" ]; then
        PROBLEM="no new parquet chunk in ${MINS}min ($COUNT/$TARGET_CHUNKS done)"
    fi
fi
# the collector is the one component with no redundancy — if it is dead nothing
# lands regardless of how healthy the producers look
if [ -z "$PROBLEM" ] && ! systemctl is-active -q galaxy-parquet; then
    PROBLEM="galaxy-parquet collector not active ($COUNT/$TARGET_CHUNKS done)"
fi

if [ -n "$PROBLEM" ]; then
    LAST=$(cat "$STATE" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    if [ $((NOW - LAST)) -gt 10800 ]; then     # one mail per 3h per ongoing problem
        {
            echo "Subject: galaxy-db STALL: $PROBLEM"
            echo "To: fleet@customcomputercare.com"; echo
            echo "Galaxy parquet conveyor problem: $PROBLEM"
            echo
            echo "Recent collector log:"
            journalctl -u galaxy-parquet -n 15 --no-pager 2>/dev/null
        } | /usr/sbin/sendmail -t
        echo "$NOW" > "$STATE"
    fi
fi
