#!/bin/bash
# Runs ON the parquet CT. Convert one regenerated chunk's TSVs to parquet,
# VERIFY before replacing anything, then swap with a .bak kept behind.
# Usage: regen-convert.sh c64-<start>
set -uo pipefail
NAME=${1:?chunk name}
BASE=${NAME#c64-}; HI=$((BASE + 200000 - 1))
IN=/parquet/incoming/$NAME
OUT=/parquet
GAL='"star_count":"UTINYINT","seed":"UINTEGER","bh_count":"UTINYINT","ns_count":"UTINYINT","wd_count":"UTINYINT","giant_count":"UTINYINT","o_count":"UTINYINT","b_count":"UTINYINT","a_count":"UTINYINT","f_count":"UTINYINT","g_count":"UTINYINT","k_count":"UTINYINT","m_count":"UTINYINT","planet_count":"USMALLINT","gas_giant_count":"USMALLINT","tidal_count":"USMALLINT","habitable_count":"USMALLINT","min_bh_dist":"FLOAT","min_ns_dist":"FLOAT","v_iron":"UBIGINT","v_copper":"UBIGINT","v_silicium":"UBIGINT","v_titanium":"UBIGINT","v_stone":"UBIGINT","v_coal":"UBIGINT","v_oil":"UBIGINT","v_fireice":"UBIGINT","v_diamond":"UBIGINT","v_fractal":"UBIGINT","v_crysrub":"UBIGINT","v_grat":"UBIGINT","v_bamboo":"UBIGINT","v_mag":"UBIGINT"'
STAR='"star_count":"UTINYINT","seed":"UINTEGER","idx":"UTINYINT","star_type":"UTINYINT","spectr":"TINYINT","luminosity":"FLOAT","radius":"FLOAT","mass":"FLOAT","age":"FLOAT","temperature":"FLOAT","pos_x":"DOUBLE","pos_y":"DOUBLE","pos_z":"DOUBLE","birth_dist":"DOUBLE","dyson_radius":"UINTEGER","habitable_radius":"FLOAT","light_balance_radius":"FLOAT","resource_coef":"FLOAT","max_hive":"UTINYINT","initial_hive":"UTINYINT","planet_count":"UTINYINT","gas_giant_count":"UTINYINT","tidal_count":"UTINYINT","satellite_count":"UTINYINT","in_dyson_count":"UTINYINT","v_iron":"UINTEGER","v_copper":"UINTEGER","v_silicium":"UINTEGER","v_titanium":"UINTEGER","v_stone":"UINTEGER","v_coal":"UINTEGER","v_oil":"UINTEGER","v_fireice":"UINTEGER","v_diamond":"UINTEGER","v_fractal":"UINTEGER","v_crysrub":"UINTEGER","v_grat":"UINTEGER","v_bamboo":"UINTEGER","v_mag":"UINTEGER"'
PLAN='"star_count":"UTINYINT","seed":"UINTEGER","star_idx":"UTINYINT","planet_idx":"UTINYINT","theme_id":"UTINYINT","algo_id":"UTINYINT","planet_type":"UTINYINT","is_gas_giant":"UTINYINT","orbit_around":"TINYINT","orbit_index":"UTINYINT","orbit_radius":"FLOAT","sun_distance":"FLOAT","orbital_period":"DOUBLE","rotation_period":"DOUBLE","tidal_locked":"UTINYINT","resonance":"UTINYINT","obliquity":"FLOAT","water_item_id":"SMALLINT","gas1_item":"SMALLINT","gas1_rate":"FLOAT","gas2_item":"SMALLINT","gas2_rate":"FLOAT","gas3_item":"SMALLINT","gas3_rate":"FLOAT","v_iron":"UINTEGER","v_copper":"UINTEGER","v_silicium":"UINTEGER","v_titanium":"UINTEGER","v_stone":"UINTEGER","v_coal":"UINTEGER","v_oil":"UINTEGER","v_fireice":"UINTEGER","v_diamond":"UINTEGER","v_fractal":"UINTEGER","v_crysrub":"UINTEGER","v_grat":"UINTEGER","v_bamboo":"UINTEGER","v_mag":"UINTEGER"'

for t in galaxies stars planets; do
    [ -f "$IN/$t.tsv" ] || { echo "MISSING $IN/$t.tsv" >&2; exit 1; }
done

# 1) convert to .new (never touching the live file)
for t in galaxies stars planets; do
    case $t in galaxies) C=$GAL;; stars) C=$STAR;; planets) C=$PLAN;; esac
    duckdb -c "COPY (SELECT * FROM read_csv('$IN/$t.tsv', delim='\t', header=false, columns={$C}))
               TO '$OUT/$t/$NAME.parquet.new' (FORMAT PARQUET, COMPRESSION ZSTD);" \
        || { echo "CONVERT FAILED $t" >&2; exit 1; }
done

# 2) VERIFY before replacing: row parity, seed range, and that precision is
#    actually restored (the whole point -- a MariaDB-degraded chunk matches its
#    own %.6g rendering on ~100% of rows; a native one only rarely).
for t in galaxies stars planets; do
    SRC=$(wc -l < "$IN/$t.tsv")
    GOT=$(duckdb -csv -noheader -c "SELECT count(*) FROM read_parquet('$OUT/$t/$NAME.parquet.new');")
    [ "$SRC" = "$GOT" ] || { echo "ROW MISMATCH $t: tsv=$SRC parquet=$GOT" >&2; exit 1; }
done
RANGE=$(duckdb -csv -noheader -c "SELECT min(seed)||'-'||max(seed) FROM read_parquet('$OUT/galaxies/$NAME.parquet.new');")
[ "$RANGE" = "$BASE-$HI" ] || { echo "SEED RANGE WRONG: got $RANGE want $BASE-$HI" >&2; exit 1; }
PCT=$(duckdb -csv -noheader -c "
  SELECT round(100.0*count(*) FILTER (WHERE sun_distance = CAST(printf('%.6g', sun_distance::DOUBLE) AS FLOAT))/count(*),1)
  FROM (SELECT sun_distance FROM read_parquet('$OUT/planets/$NAME.parquet.new') LIMIT 5000);")
BAD=$(awk -v p="$PCT" 'BEGIN{print (p>50)?1:0}')
[ "$BAD" = "0" ] || { echo "PRECISION NOT RESTORED: ${PCT}% still 6-sig-digit" >&2; exit 1; }

# 3) swap, keeping the previous file behind
for t in galaxies stars planets; do
    [ -f "$OUT/$t/$NAME.parquet" ] && mv "$OUT/$t/$NAME.parquet" "$OUT/$t/$NAME.parquet.bak"
    mv "$OUT/$t/$NAME.parquet.new" "$OUT/$t/$NAME.parquet"
done
rm -rf "$IN"
echo "OK $NAME  seeds=$RANGE  six_sig_now=${PCT}%"
