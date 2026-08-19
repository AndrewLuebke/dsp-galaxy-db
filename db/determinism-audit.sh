#!/bin/bash
# Determinism audit: regenerate a scattered sample of seeds and compare EVERY
# field bit-exact against what is stored in parquet.
#
# WHY: the 08-18 corruption (seed 401732, all 14 veins zeroed) was only
# detectable because veins are computed twice by independent code paths. Fields
# with no redundancy -- obliquity, orbital_period, pos_*, luminosity -- have no
# cross-check at all. Regeneration is the ONLY detector for a transient fault
# landing in one of those.
#
# Comparison is valid bit-exact because both sides take the identical path:
# dsp_seed TSV -> duckdb read_csv with the SAME column spec -> parquet. Same
# text in, same binary out.
#
# Usage: determinism-audit.sh generate   # on compiler, builds the sample
#        determinism-audit.sh compare    # on parquet CT, EXCEPT ALL both ways
set -uo pipefail
MODE=${1:?generate|compare}
SAMPLE=${SAMPLE:-20}          # seeds per chunk
CHUNK=200000
NCHUNKS=500
BIN=/tmp/dsp_seed_dump
WORK=/tmp/det-audit

case "$MODE" in
generate)
    rm -rf $WORK && mkdir -p $WORK/parts
    for ((c=0; c<NCHUNKS; c++)); do
        base=$((c * CHUNK))
        # deterministic scatter inside each chunk (prime stride), never off the end
        off=$(( (c * 7919) % (CHUNK - SAMPLE) ))
        lo=$((base + off)); hi=$((lo + SAMPLE))
        d=$WORK/parts/r$lo
        mkdir -p $d
        $BIN dump --star-count 64 --range $lo:$hi --out-dir $d >/dev/null 2>&1 \
            || { echo "dump FAILED for $lo:$hi" >&2; exit 1; }
    done
    for t in galaxies stars planets; do
        cat $WORK/parts/*/$t.tsv > $WORK/$t.tsv
    done
    echo "generated:"; wc -l $WORK/galaxies.tsv $WORK/stars.tsv $WORK/planets.tsv
    ;;
compare)
    P=/parquet
    GAL='"star_count":"UTINYINT","seed":"UINTEGER","bh_count":"UTINYINT","ns_count":"UTINYINT","wd_count":"UTINYINT","giant_count":"UTINYINT","o_count":"UTINYINT","b_count":"UTINYINT","a_count":"UTINYINT","f_count":"UTINYINT","g_count":"UTINYINT","k_count":"UTINYINT","m_count":"UTINYINT","planet_count":"USMALLINT","gas_giant_count":"USMALLINT","tidal_count":"USMALLINT","habitable_count":"USMALLINT","min_bh_dist":"FLOAT","min_ns_dist":"FLOAT","v_iron":"UBIGINT","v_copper":"UBIGINT","v_silicium":"UBIGINT","v_titanium":"UBIGINT","v_stone":"UBIGINT","v_coal":"UBIGINT","v_oil":"UBIGINT","v_fireice":"UBIGINT","v_diamond":"UBIGINT","v_fractal":"UBIGINT","v_crysrub":"UBIGINT","v_grat":"UBIGINT","v_bamboo":"UBIGINT","v_mag":"UBIGINT"'
    STAR='"star_count":"UTINYINT","seed":"UINTEGER","idx":"UTINYINT","star_type":"UTINYINT","spectr":"TINYINT","luminosity":"FLOAT","radius":"FLOAT","mass":"FLOAT","age":"FLOAT","temperature":"FLOAT","pos_x":"DOUBLE","pos_y":"DOUBLE","pos_z":"DOUBLE","birth_dist":"DOUBLE","dyson_radius":"UINTEGER","habitable_radius":"FLOAT","light_balance_radius":"FLOAT","resource_coef":"FLOAT","max_hive":"UTINYINT","initial_hive":"UTINYINT","planet_count":"UTINYINT","gas_giant_count":"UTINYINT","tidal_count":"UTINYINT","satellite_count":"UTINYINT","in_dyson_count":"UTINYINT","v_iron":"UINTEGER","v_copper":"UINTEGER","v_silicium":"UINTEGER","v_titanium":"UINTEGER","v_stone":"UINTEGER","v_coal":"UINTEGER","v_oil":"UINTEGER","v_fireice":"UINTEGER","v_diamond":"UINTEGER","v_fractal":"UINTEGER","v_crysrub":"UINTEGER","v_grat":"UINTEGER","v_bamboo":"UINTEGER","v_mag":"UINTEGER"'
    PLAN='"star_count":"UTINYINT","seed":"UINTEGER","star_idx":"UTINYINT","planet_idx":"UTINYINT","theme_id":"UTINYINT","algo_id":"UTINYINT","planet_type":"UTINYINT","is_gas_giant":"UTINYINT","orbit_around":"TINYINT","orbit_index":"UTINYINT","orbit_radius":"FLOAT","sun_distance":"FLOAT","orbital_period":"DOUBLE","rotation_period":"DOUBLE","tidal_locked":"UTINYINT","resonance":"UTINYINT","obliquity":"FLOAT","water_item_id":"SMALLINT","gas1_item":"SMALLINT","gas1_rate":"FLOAT","gas2_item":"SMALLINT","gas2_rate":"FLOAT","gas3_item":"SMALLINT","gas3_rate":"FLOAT","v_iron":"UINTEGER","v_copper":"UINTEGER","v_silicium":"UINTEGER","v_titanium":"UINTEGER","v_stone":"UINTEGER","v_coal":"UINTEGER","v_oil":"UINTEGER","v_fireice":"UINTEGER","v_diamond":"UINTEGER","v_fractal":"UINTEGER","v_crysrub":"UINTEGER","v_grat":"UINTEGER","v_bamboo":"UINTEGER","v_mag":"UINTEGER"'
    for t in galaxies stars planets; do
        case $t in galaxies) C=$GAL;; stars) C=$STAR;; planets) C=$PLAN;; esac
        echo "--- $t ---"
        # EXCEPT ALL (not EXCEPT): preserves multiplicity, so a duplicated row
        # cannot hide inside set-dedup.
        duckdb -c "
        CREATE TEMP TABLE fresh AS
          SELECT * FROM read_csv('$WORK/$t.tsv', delim='\t', header=false, columns={$C});
        CREATE TEMP TABLE sd AS SELECT DISTINCT seed FROM fresh;
        CREATE TEMP TABLE stored AS
          SELECT * FROM read_parquet('$P/$t/*.parquet') WHERE seed IN (SELECT seed FROM sd);
        SELECT (SELECT count(*) FROM fresh)  AS fresh_rows,
               (SELECT count(*) FROM stored) AS stored_rows,
               (SELECT count(*) FROM sd)     AS seeds_sampled,
               (SELECT count(*) FROM (SELECT * FROM fresh  EXCEPT ALL SELECT * FROM stored)) AS in_fresh_not_stored,
               (SELECT count(*) FROM (SELECT * FROM stored EXCEPT ALL SELECT * FROM fresh))  AS in_stored_not_fresh;"
    done
    ;;
*) echo "usage: $0 generate|compare" >&2; exit 1 ;;
esac
