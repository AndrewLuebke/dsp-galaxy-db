#!/bin/bash
# One-shot backfill: export the chunks already loaded in MariaDB out to TSV via
# INTO OUTFILE (verified to preserve full f64 precision), ship them to the
# parquet CT, and convert with the same parquet-convert.sh the live pipeline
# uses. Idempotent: chunks whose parquet already exists are skipped.
set -uo pipefail
SSH="ssh -o ConnectTimeout=15"
DB=mariadb
PQ=parquet
EXPORT=/galaxydb/export

log() { echo "$(date '+%H:%M:%S') $*"; }

CHUNKS=$($SSH $DB "mariadb -N -e 'SELECT CONCAT(star_count,\":\",chunk_start) FROM galaxy.load_ledger ORDER BY chunk_start'")
[ -n "$CHUNKS" ] || { echo "no chunks in ledger" >&2; exit 1; }

for entry in $CHUNKS; do
    sc=${entry%%:*}; start=${entry##*:}
    name="c${sc}-${start}"
    end=$((start + 200000))

    if $SSH $PQ "test -f /parquet/planets/$name.parquet" 2>/dev/null; then
        log "$name: parquet exists, skip"
        continue
    fi

    log "$name: exporting from MariaDB (seeds $start..$end)"
    $SSH $DB "rm -rf $EXPORT/$name && mkdir -p $EXPORT/$name && chmod 777 $EXPORT/$name" || { log "$name: mkdir failed"; continue; }
    ok=1
    for t in galaxies stars planets; do
        $SSH $DB "mariadb galaxy -e \"SELECT * FROM $t WHERE star_count=$sc AND seed >= $start AND seed < $end INTO OUTFILE '$EXPORT/$name/$t.tsv'\"" \
            || { log "$name: export of $t FAILED"; ok=0; break; }
    done
    [ "$ok" = "1" ] || { $SSH $DB "rm -rf $EXPORT/$name"; continue; }

    log "$name: transfer"
    $SSH $PQ "rm -rf /parquet/incoming/$name" || continue
    $SSH $DB "tar -C $EXPORT -cf - $name" | $SSH $PQ "tar -C /parquet/incoming -xf -" || { log "$name: transfer FAILED"; continue; }

    log "$name: convert"
    if $SSH $PQ "/usr/local/bin/parquet-convert.sh $name"; then
        $SSH $DB "rm -rf $EXPORT/$name"
        log "$name: DONE"
    else
        log "$name: CONVERT FAILED — left in place for inspection"
    fi
done

log "backfill complete"
$SSH $PQ "ls /parquet/planets/*.parquet | wc -l | xargs echo 'total planet parquet files:'"
