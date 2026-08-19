#!/bin/bash
# Runs ON the MariaDB host: split + parallel-load one verified chunk, then
# write the ledger row. Called by galaxy-collector.sh.
# Usage: galaxy-load.sh <chunk-name> <star_count> <chunk_start> <g> <s> <p>
set -uo pipefail
NAME=${1:?name}; SC=${2:?sc}; START=${3:?start}; G=${4:?g}; S=${5:?s}; P=${6:?p}
DIR=/galaxydb/incoming/$NAME
cd "$DIR" || exit 1

rm -f planets_part_*
split -n l/2 planets.tsv planets_part_ || exit 1

mariadb galaxy -e "SET SESSION sql_log_bin=0; LOAD DATA INFILE '$DIR/galaxies.tsv' IGNORE INTO TABLE galaxies;
                   LOAD DATA INFILE '$DIR/stars.tsv' IGNORE INTO TABLE stars;" &
A=$!
mariadb galaxy -e "SET SESSION sql_log_bin=0; LOAD DATA INFILE '$DIR/planets_part_aa' IGNORE INTO TABLE planets;" &
B=$!
mariadb galaxy -e "SET SESSION sql_log_bin=0; LOAD DATA INFILE '$DIR/planets_part_ab' IGNORE INTO TABLE planets;" &
C=$!
wait "$A" || exit 1
wait "$B" || exit 1
wait "$C" || exit 1

mariadb galaxy -e "SET SESSION sql_log_bin=0; INSERT INTO load_ledger (star_count, chunk_start, rows_g, rows_s, rows_p)
                   VALUES ($SC, $START, $G, $S, $P);" || exit 1
