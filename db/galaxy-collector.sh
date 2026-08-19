#!/bin/bash
# Galaxy DB collector — runs on claude-node as a long-lived service. Polls dump
# hosts for DONE chunks, streams them to the MariaDB CT, decompresses, verifies
# row counts, loads (idempotent via load_ledger), records the ledger row, and
# cleans up both sides. One chunk at a time per pass, hosts round-robin.
#
# Usage: galaxy-collector.sh <host1> [host2 ...]
set -uo pipefail
HOSTS=("$@")
[ ${#HOSTS[@]} -gt 0 ] || { echo "usage: $0 host..." >&2; exit 1; }
SSH="ssh -o ConnectTimeout=15"
DB=mariadb
INBOX=/galaxydb/incoming

log() { echo "$(date '+%m-%d %H:%M:%S') $*"; }

load_chunk() { # host chunkdir  (chunkdir like c64-1200000)
    local host=$1 dir=$2 name sc start
    name=$(basename "$dir"); sc=${name#c}; sc=${sc%%-*}; start=${name##*-}

    # idempotency: skip if already loaded
    local seen
    seen=$($SSH $DB "mariadb -N -e \"SELECT COUNT(*) FROM galaxy.load_ledger WHERE star_count=$sc AND chunk_start=$start\"") || return 1
    if [ "$seen" = "1" ]; then
        log "$host $name already in ledger — cleaning producer copy"
        $SSH "$host" "bash -c 'mv $dir/DONE $dir/SHIPPED 2>/dev/null; rm -f $dir/*.zst'"
        return 0
    fi

    log "$host $name: transfer"
    $SSH $DB "rm -rf $INBOX/$name" || return 1
    $SSH "$host" "bash -c 'tar -C /tmp/gchunks -cf - $name'" | $SSH $DB "tar -C $INBOX -xf -" || return 1
    $SSH $DB "bash -c 'cd $INBOX/$name && zstd -q -f -d --rm *.zst && chmod 644 *.tsv'" || return 1

    # verify: galaxies rows == chunk span, stars == span*sc
    local counts span
    span=$($SSH "$host" "bash -c 'cut -d: -f2 $dir/DONE 2>/dev/null'" || echo "")
    if ! [[ "$span" =~ ^[0-9]+$ ]]; then
        log "$host $name: cannot read chunk end from DONE (got '$span') — skipping"
        return 1
    fi
    counts=$($SSH $DB "wc -l $INBOX/$name/galaxies.tsv $INBOX/$name/stars.tsv $INBOX/$name/planets.tsv | awk '{print \$1}' | head -3 | tr '\n' ' '")
    read -r g s p _ <<< "$counts"
    local expect_g=$(( ${span:-0} - start ))
    if [ -z "$span" ] || [ "$g" -ne "$expect_g" ] || [ "$s" -ne $((expect_g * sc)) ]; then
        log "$host $name VERIFY FAILED: g=$g (want $expect_g) s=$s span=$span — leaving for inspection"
        return 1
    fi

    log "$host $name: load (g=$g s=$s p=$p)"
    # Split + parallel loads + ledger all run in a deployed script on the DB
    # host (no nested-quoting; IGNORE keeps crash-retry idempotent).
    $SSH $DB "/usr/local/bin/galaxy-load.sh $name $sc $start $g $s $p" || return 1

    $SSH $DB "rm -rf $INBOX/$name"
    $SSH "$host" "bash -c 'mv $dir/DONE $dir/SHIPPED && rm -f $dir/*.zst $dir/progress'"
    log "$host $name: loaded + cleaned"
}

log "collector watching: ${HOSTS[*]}"
while true; do
    idle=1
    for host in "${HOSTS[@]}"; do
        # numeric sort on the chunk-start suffix — plain ls is lexical and lets
        # c64-1000000 starve c64-600000 indefinitely.
        # bash -c is MANDATORY: desktop/laptop log in to FISH, where this
        # glob+pipe misparses and returns garbage (see fish-shell-ssh trap).
        chunk=$($SSH "$host" "bash -c 'ls -d /tmp/gchunks/*/DONE 2>/dev/null | sort -t- -k2 -n | head -1'" 2>/dev/null | xargs -r dirname)
        if [ -n "${chunk:-}" ]; then
            idle=0
            load_chunk "$host" "$chunk" || log "$host $(basename $chunk): FAILED, will retry"
        fi
    done
    [ "$idle" = "1" ] && sleep 60 || sleep 2
done
