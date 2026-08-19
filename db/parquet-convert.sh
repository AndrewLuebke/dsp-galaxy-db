#!/bin/bash
# Runs ON the parquet CT: convert one chunk's three TSVs into Parquet (zstd),
# verify row counts, and clean up. Called by galaxy-parquet-collector.sh.
# Usage: parquet-convert.sh <chunk-name>   e.g. c64-2200000
set -uo pipefail
NAME=${1:?chunk name}
IN=/parquet/incoming/$NAME
OUT=/parquet
[ -d "$IN" ] || { echo "no such chunk dir: $IN" >&2; exit 1; }

mkdir -p "$OUT/galaxies" "$OUT/stars" "$OUT/planets"

# Column types mirror src/dump.rs exactly. Positions / orbital+rotation periods
# are f64 in the generator, so they stay DOUBLE; f32 fields stay FLOAT.
GAL_COLS='"star_count":"UTINYINT","seed":"UINTEGER","bh_count":"UTINYINT","ns_count":"UTINYINT","wd_count":"UTINYINT","giant_count":"UTINYINT","o_count":"UTINYINT","b_count":"UTINYINT","a_count":"UTINYINT","f_count":"UTINYINT","g_count":"UTINYINT","k_count":"UTINYINT","m_count":"UTINYINT","planet_count":"USMALLINT","gas_giant_count":"USMALLINT","tidal_count":"USMALLINT","habitable_count":"USMALLINT","min_bh_dist":"FLOAT","min_ns_dist":"FLOAT","v_iron":"UBIGINT","v_copper":"UBIGINT","v_silicium":"UBIGINT","v_titanium":"UBIGINT","v_stone":"UBIGINT","v_coal":"UBIGINT","v_oil":"UBIGINT","v_fireice":"UBIGINT","v_diamond":"UBIGINT","v_fractal":"UBIGINT","v_crysrub":"UBIGINT","v_grat":"UBIGINT","v_bamboo":"UBIGINT","v_mag":"UBIGINT"'

STAR_COLS='"star_count":"UTINYINT","seed":"UINTEGER","idx":"UTINYINT","star_type":"UTINYINT","spectr":"TINYINT","luminosity":"FLOAT","radius":"FLOAT","mass":"FLOAT","age":"FLOAT","temperature":"FLOAT","pos_x":"DOUBLE","pos_y":"DOUBLE","pos_z":"DOUBLE","birth_dist":"DOUBLE","dyson_radius":"UINTEGER","habitable_radius":"FLOAT","light_balance_radius":"FLOAT","resource_coef":"FLOAT","max_hive":"UTINYINT","initial_hive":"UTINYINT","planet_count":"UTINYINT","gas_giant_count":"UTINYINT","tidal_count":"UTINYINT","satellite_count":"UTINYINT","in_dyson_count":"UTINYINT","v_iron":"UINTEGER","v_copper":"UINTEGER","v_silicium":"UINTEGER","v_titanium":"UINTEGER","v_stone":"UINTEGER","v_coal":"UINTEGER","v_oil":"UINTEGER","v_fireice":"UINTEGER","v_diamond":"UINTEGER","v_fractal":"UINTEGER","v_crysrub":"UINTEGER","v_grat":"UINTEGER","v_bamboo":"UINTEGER","v_mag":"UINTEGER"'

PLANET_COLS='"star_count":"UTINYINT","seed":"UINTEGER","star_idx":"UTINYINT","planet_idx":"UTINYINT","theme_id":"UTINYINT","algo_id":"UTINYINT","planet_type":"UTINYINT","is_gas_giant":"UTINYINT","orbit_around":"TINYINT","orbit_index":"UTINYINT","orbit_radius":"FLOAT","sun_distance":"FLOAT","orbital_period":"DOUBLE","rotation_period":"DOUBLE","tidal_locked":"UTINYINT","resonance":"UTINYINT","obliquity":"FLOAT","water_item_id":"SMALLINT","gas1_item":"SMALLINT","gas1_rate":"FLOAT","gas2_item":"SMALLINT","gas2_rate":"FLOAT","gas3_item":"SMALLINT","gas3_rate":"FLOAT","v_iron":"UINTEGER","v_copper":"UINTEGER","v_silicium":"UINTEGER","v_titanium":"UINTEGER","v_stone":"UINTEGER","v_coal":"UINTEGER","v_oil":"UINTEGER","v_fireice":"UINTEGER","v_diamond":"UINTEGER","v_fractal":"UINTEGER","v_crysrub":"UINTEGER","v_grat":"UINTEGER","v_bamboo":"UINTEGER","v_mag":"UINTEGER"'

convert() { # table cols
    local t=$1 cols=$2
    # write to .tmp first so a crash can never leave a half-written parquet
    # file that later globs would happily read as real data
    duckdb -c "COPY (SELECT * FROM read_csv('$IN/$t.tsv', delim='\t', header=false, columns={$cols}))
               TO '$OUT/$t/$NAME.parquet.tmp' (FORMAT PARQUET, COMPRESSION ZSTD);" || return 1
    mv "$OUT/$t/$NAME.parquet.tmp" "$OUT/$t/$NAME.parquet" || return 1
}

for t in galaxies stars planets; do
    [ -f "$IN/$t.tsv" ] || { echo "missing $IN/$t.tsv" >&2; exit 1; }
    case "$t" in
        galaxies) COLS=$GAL_COLS ;;
        stars)    COLS=$STAR_COLS ;;
        planets)  COLS=$PLANET_COLS ;;
    esac
    convert "$t" "$COLS" || { echo "convert failed for $t" >&2; exit 1; }
done

# verify: parquet row counts must equal source TSV line counts
for t in galaxies stars planets; do
    SRC=$(wc -l < "$IN/$t.tsv")
    PQ=$(duckdb -noheader -list -c "SELECT count(*) FROM read_parquet('$OUT/$t/$NAME.parquet');")
    if [ "$SRC" != "$PQ" ]; then
        echo "VERIFY FAILED $t: tsv=$SRC parquet=$PQ" >&2
        rm -f "$OUT/$t/$NAME.parquet"
        exit 1
    fi
    echo "$t: $PQ rows"
done

rm -rf "$IN"
