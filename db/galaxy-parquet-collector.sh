#!/bin/bash
# Galaxy Parquet collector — runs on claude-node. Polls dump hosts for DONE
# chunks, streams them to the parquet CT, converts TSV->Parquet (zstd) there,
# verifies row counts, and cleans up both sides.
#
# Replaces galaxy-collector.sh (MariaDB LOAD DATA path): no DB server, no
# binlog, ~17s conversion instead of ~4m21s load, and the resulting files ARE
# both the query surface (DuckDB) and the distributable artifact.
#
# Idempotent: a chunk whose parquet already exists is skipped. Conversion
# writes .tmp then renames, so a crash can't leave a partial file in a glob.
#
# Usage: galaxy-parquet-collector.sh <host1> [host2 ...]
set -uo pipefail
HOSTS=("$@")
[ ${#HOSTS[@]} -gt 0 ] || { echo "usage: $0 host..." >&2; exit 1; }
# bash -c wrapping is MANDATORY on every remote call: desktop/laptop log in to
# fish, where globs+pipes misparse (see fish-shell-ssh-remote-trap).
SSH="ssh -o ConnectTimeout=15"
PQ=parquet
INBOX=/parquet/incoming

log() { echo "$(date '+%m-%d %H:%M:%S') $*"; }

load_chunk() { # host chunkdir
    local host=$1 dir=$2 name span expect_g g s p
    name=$(basename "$dir")

    if $SSH $PQ "test -f /parquet/planets/$name.parquet" 2>/dev/null; then
        log "$host $name already converted — cleaning producer copy"
        $SSH "$host" "bash -c 'mv $dir/DONE $dir/SHIPPED 2>/dev/null; rm -f $dir/*.zst'"
        return 0
    fi

    span=$($SSH "$host" "bash -c 'cut -d: -f2 $dir/DONE 2>/dev/null'" || echo "")
    if ! [[ "$span" =~ ^[0-9]+$ ]]; then
        log "$host $name: cannot read chunk end from DONE (got '$span') — skipping"
        return 1
    fi

    log "$host $name: transfer"
    $SSH $PQ "rm -rf $INBOX/$name && mkdir -p $INBOX" || return 1
    $SSH "$host" "bash -c 'tar -C /tmp/gchunks -cf - $name'" | $SSH $PQ "tar -C $INBOX -xf -" || return 1
    $SSH $PQ "bash -c 'cd $INBOX/$name && zstd -q -f -d --rm *.zst'" || return 1

    # sanity: galaxies rows == chunk span, stars == span * star_count
    local sc=${name#c}; sc=${sc%%-*}
    local start=${name##*-}
    expect_g=$(( span - start ))
    read -r g s _ <<< "$($SSH $PQ "bash -c 'wc -l < $INBOX/$name/galaxies.tsv; wc -l < $INBOX/$name/stars.tsv'" | tr '\n' ' ')"
    if [ "${g:-0}" -ne "$expect_g" ] || [ "${s:-0}" -ne $((expect_g * sc)) ]; then
        log "$host $name VERIFY FAILED: g=$g (want $expect_g) s=$s — leaving for inspection"
        return 1
    fi

    log "$host $name: convert (g=$g s=$s)"
    $SSH $PQ "/usr/local/bin/parquet-convert.sh $name" || return 1

    $SSH "$host" "bash -c 'mv $dir/DONE $dir/SHIPPED && rm -f $dir/*.zst $dir/progress'"
    log "$host $name: converted + cleaned"
}

log "parquet collector watching: ${HOSTS[*]}"
while true; do
    idle=1
    for host in "${HOSTS[@]}"; do
        chunk=$($SSH "$host" "bash -c 'ls -d /tmp/gchunks/*/DONE 2>/dev/null | sort -t- -k2 -n | head -1'" 2>/dev/null | xargs -r dirname)
        if [ -n "${chunk:-}" ]; then
            idle=0
            load_chunk "$host" "$chunk" || log "$host $(basename "$chunk"): FAILED, will retry"
        fi
    done
    [ "$idle" = "1" ] && sleep 60 || sleep 2
done
