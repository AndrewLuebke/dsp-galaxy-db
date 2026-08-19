#!/bin/bash
# Full integrity sweep of the DSP galaxy parquet dataset. Runs ON the parquet CT.
# Every check prints a VIOLATION COUNT -- 0 everywhere means clean.
#   A: galaxy counters vs the stars they summarise   (GROUP BY seed, 6.4B rows)
#   B: galaxy counters vs the planets                (GROUP BY seed, 24.4B rows)
#   C: domain / range / enum validity + enum census  (single pass each)
#   D: per-STAR counters + structural integrity      (batched: 6.4B groups will
#      not fit in 16G, so chunks are processed BATCH at a time)
# Field definitions mirror src/dump.rs exactly (star_type 0..4 =
# MainSeq/Giant/WhiteDwarf/Neutron/BlackHole; spectr O=2..M=-4; absent
# min_bh/ns_dist emitted as -1; galaxy min_*_dist is FLOAT so the f64 star
# birth_dist is cast to FLOAT before comparing -- exact, not a tolerance).
set -uo pipefail
P=/parquet
BATCH=${BATCH:-5}
D=$(dirname "$0")

run() { duckdb -c "$1"; }

echo "############ PHASE A: galaxy vs stars ############"
run "
WITH s AS (
  SELECT seed, count(*) AS n_stars,
    sum((star_type=4)::INT) AS bh, sum((star_type=3)::INT) AS ns,
    sum((star_type=2)::INT) AS wd, sum((star_type=1)::INT) AS giant,
    sum((spectr=2)::INT) AS o, sum((spectr=1)::INT) AS b,
    sum((spectr=0)::INT) AS a, sum((spectr=-1)::INT) AS f,
    sum((spectr=-2)::INT) AS g, sum((spectr=-3)::INT) AS k,
    sum((spectr=-4)::INT) AS m,
    min(CASE WHEN star_type=4 THEN birth_dist END) AS min_bh,
    min(CASE WHEN star_type=3 THEN birth_dist END) AS min_ns,
    count(DISTINCT idx) AS n_idx, min(idx) AS mn, max(idx) AS mx
  FROM read_parquet('$P/stars/*.parquet') GROUP BY seed)
SELECT
  count(*) FILTER (WHERE s.n_stars <> 64)                             AS A1_not_64_stars,
  count(*) FILTER (WHERE s.n_idx<>s.n_stars OR s.mn<>0 OR s.mx<>63)   AS A2_star_idx_broken,
  count(*) FILTER (WHERE g.bh_count<>s.bh)                            AS A3_bh_count,
  count(*) FILTER (WHERE g.ns_count<>s.ns)                            AS A4_ns_count,
  count(*) FILTER (WHERE g.wd_count<>s.wd)                            AS A5_wd_count,
  count(*) FILTER (WHERE g.giant_count<>s.giant)                      AS A6_giant_count,
  count(*) FILTER (WHERE g.o_count<>s.o OR g.b_count<>s.b OR g.a_count<>s.a
                      OR g.f_count<>s.f OR g.g_count<>s.g OR g.k_count<>s.k
                      OR g.m_count<>s.m)                              AS A7_spectral_counts,
  count(*) FILTER (WHERE g.min_bh_dist <> coalesce(s.min_bh,-1)::FLOAT) AS A8_min_bh_dist,
  count(*) FILTER (WHERE g.min_ns_dist <> coalesce(s.min_ns,-1)::FLOAT) AS A9_min_ns_dist
FROM read_parquet('$P/galaxies/*.parquet') g JOIN s USING (seed);"

echo "############ PHASE B: galaxy vs planets ############"
run "
WITH p AS (
  SELECT seed, count(*) AS n, sum(is_gas_giant::INT) AS gg, sum(tidal_locked::INT) AS td
  FROM read_parquet('$P/planets/*.parquet') GROUP BY seed)
SELECT
  count(*) FILTER (WHERE g.planet_count    <> p.n)  AS B1_planet_count,
  count(*) FILTER (WHERE g.gas_giant_count <> p.gg) AS B2_gas_giant_count,
  count(*) FILTER (WHERE g.tidal_count     <> p.td) AS B3_tidal_count
FROM read_parquet('$P/galaxies/*.parquet') g JOIN p USING (seed);"

echo "############ PHASE C: domain / range validity ############"
run "
SELECT
  count(*) FILTER (WHERE spectr < -4 OR spectr > 3)      AS C1_spectr_range,
  count(*) FILTER (WHERE star_type > 4)                  AS C2_star_type_range,
  count(*) FILTER (WHERE luminosity <= 0)                AS C3_luminosity,
  count(*) FILTER (WHERE mass <= 0 OR radius <= 0)       AS C4_mass_radius,
  count(*) FILTER (WHERE birth_dist < 0)                 AS C5_birth_dist,
  count(*) FILTER (WHERE resource_coef <= 0)             AS C6_resource_coef,
  count(*) FILTER (WHERE planet_count > 0 AND dyson_radius = 0) AS C7_dyson_radius
FROM read_parquet('$P/stars/*.parquet');"
run "
SELECT
  count(*) FILTER (WHERE is_gas_giant > 1)               AS C8_gg_flag,
  count(*) FILTER (WHERE tidal_locked > 1)               AS C9_tidal_flag,
  count(*) FILTER (WHERE sun_distance <= 0)              AS C10_sun_distance,
  count(*) FILTER (WHERE orbital_period = 0)             AS C11_orbital_period,
  count(*) FILTER (WHERE rotation_period = 0)            AS C12_rotation_period,
  count(*) FILTER (WHERE orbit_around < -1)              AS C13_orbit_ref_range,
  count(*) FILTER (WHERE is_gas_giant=1 AND greatest(v_iron,v_copper,v_silicium,
       v_titanium,v_stone,v_coal,v_oil,v_fireice,v_diamond,v_fractal,v_crysrub,
       v_grat,v_bamboo,v_mag) > 0)                       AS C14_gasgiant_with_veins,
  count(*) FILTER (WHERE is_gas_giant=1 AND gas1_rate <= 0) AS C15_gasgiant_no_gas
FROM read_parquet('$P/planets/*.parquet');"
echo '--- enum census (eyeball for impossible values) ---'
run "SELECT 'planet_type' AS col, min(planet_type)::INT AS lo, max(planet_type)::INT AS hi,
            count(DISTINCT planet_type) AS n_distinct FROM read_parquet('$P/planets/*.parquet')
     UNION ALL SELECT 'theme_id', min(theme_id), max(theme_id), count(DISTINCT theme_id)
            FROM read_parquet('$P/planets/*.parquet')
     UNION ALL SELECT 'algo_id', min(algo_id), max(algo_id), count(DISTINCT algo_id)
            FROM read_parquet('$P/planets/*.parquet')
     UNION ALL SELECT 'water_item_id', min(water_item_id), max(water_item_id), count(DISTINCT water_item_id)
            FROM read_parquet('$P/planets/*.parquet');"

echo "############ PHASE D: per-star counters + structure (batched x$BATCH) ############"
mapfile -t CH < <(ls $P/planets/c64-*.parquet | sed 's#.*/##; s#\.parquet$##' | sort -t- -k2 -n)
echo "chunks: ${#CH[@]}  batch size: $BATCH"
TOT_D=0
for ((i=0; i<${#CH[@]}; i+=BATCH)); do
    PL=""; ST=""
    for ((j=i; j<i+BATCH && j<${#CH[@]}; j++)); do
        PL="$PL,'$P/planets/${CH[$j]}.parquet'"; ST="$ST,'$P/stars/${CH[$j]}.parquet'"
    done
    PL="[${PL#,}]"; ST="[${ST#,}]"
    OUT=$(duckdb -csv -noheader -c "
    WITH j AS (
      SELECT p.seed, p.star_idx, p.planet_idx, p.is_gas_giant, p.tidal_locked,
             p.orbit_around, p.sun_distance, s.dyson_radius
      FROM read_parquet($PL) p JOIN read_parquet($ST) s ON s.seed=p.seed AND s.idx=p.star_idx),
    ps AS (
      SELECT seed, star_idx, count(*) AS n, sum(is_gas_giant::INT) AS gg,
             sum(tidal_locked::INT) AS td, sum((orbit_around<>-1)::INT) AS sat,
             sum((is_gas_giant=0 AND sun_distance*40000 < dyson_radius)::INT) AS dy,
             count(DISTINCT planet_idx) AS nd, min(planet_idx) AS mn, max(planet_idx) AS mx
      FROM j GROUP BY seed, star_idx),
    dangling AS (
      SELECT count(*) AS c FROM read_parquet($PL) p
      WHERE p.orbit_around <> -1 AND NOT EXISTS (
        SELECT 1 FROM read_parquet($PL) q
        WHERE q.seed=p.seed AND q.star_idx=p.star_idx AND q.planet_idx=p.orbit_around))
    SELECT
      count(*) FILTER (WHERE s.planet_count    <> coalesce(ps.n,0))  AS D1_planet_count,
      count(*) FILTER (WHERE s.gas_giant_count <> coalesce(ps.gg,0)) AS D2_gas_giant,
      count(*) FILTER (WHERE s.tidal_count     <> coalesce(ps.td,0)) AS D3_tidal,
      count(*) FILTER (WHERE s.satellite_count <> coalesce(ps.sat,0))AS D4_satellite,
      count(*) FILTER (WHERE s.in_dyson_count  <> coalesce(ps.dy,0)) AS D5_in_dyson,
      count(*) FILTER (WHERE ps.nd <> ps.n)                          AS D6_dup_planet_idx,
      count(*) FILTER (WHERE ps.n>0 AND (ps.mn<>0 OR ps.mx<>ps.n-1)) AS D7_noncontig_idx,
      (SELECT c FROM dangling)                                       AS D8_dangling_moon
    FROM read_parquet($ST) s LEFT JOIN ps ON ps.seed=s.seed AND ps.star_idx=s.idx;")
    SUM=$(echo "$OUT" | tr ',' '\n' | awk '{s+=$1} END{print s+0}')
    TOT_D=$((TOT_D + SUM))
    printf 'batch %3d/%3d (%s..): violations=%s\n' $((i/BATCH+1)) \
        $(( (${#CH[@]}+BATCH-1)/BATCH )) "${CH[$i]}" "$SUM"
    [ "$SUM" != "0" ] && echo "  !! $OUT"
done
echo "PHASE D total violations: $TOT_D"
