# dsp-galaxy-db

Pipeline and verification tooling for generating **every galaxy in Dyson Sphere
Program's 10⁸ seed space** at 64 stars, and querying the result.

This repo holds the **tooling only** — the generated dataset is ~1.8 TB and is
not distributable through git. The generator itself lives in a fork of
[DSP-Seed-Finder](https://github.com/DoubleUTH/DSP-Seed-Finder); this repo is
the fleet-parallel harness, the dump→Parquet conveyor, and the integrity audits
built around it.

## The dataset

| | |
|---|---|
| Galaxies | 100,000,000 (seeds 0–99,999,999, all distinct) |
| Stars | 6,400,000,000 |
| Planets | 24,416,296,286 |
| Size | ~1.8 TB (Parquet + zstd) |
| Layout | `/parquet/{galaxies,stars,planets}/c64-<start>.parquet`, 500 chunks of 200k seeds |

Every planet carries its **actual** vein amounts for all 14 resource types, plus
orbital geometry, themes, gases and tidal-locking — not just the summary fields
a rule engine needs.

## Why Parquet and not a database

A row-store was tried first and abandoned on measurement. The deciding
benchmark, same aggregate on the same rows: **MariaDB/InnoDB >600 s (killed)
vs DuckDB/Parquet 0.080 s**. On the full dataset:

| query | time | rate |
|---|---|---|
| Full scan, `SUM(v_iron) GROUP BY seed`, 24.4B rows | **81.9 s** | 298M rows/s |
| Three-table join (galaxies ⋈ stars ⋈ planets) | **141.8 s** | |
| Seed-range query, any width | **~2.6 s** | flat, ~30× faster |
| Single-column cold sum | 58.3 s | 418M rows/s |

The seed-range result is predicate pushdown via row-group statistics — files are
chunk-ordered by seed, so a 1-seed and a 200,000-seed query cost the same. No
indexes exist or are needed.

Note the win is **column projection**, not compression: Parquet+zstd came out
only 1.03× smaller than row-major zstd-19 on this data, which is near-maximum
entropy by construction (it's PRNG output).

## Layout

```
db/galaxy-producer.sh          dumps seed ranges, zstd, marks chunks DONE
db/galaxy-parquet-collector.sh ships finished chunks to the Parquet host
db/parquet-convert.sh          TSV → Parquet (zstd), row-count verified
db/galaxy-stall-check.sh       watchdog; monitors the OUTCOME, not the mechanism
fleet-search.sh                splits a search across hosts by measured throughput

db/integrity-sweep.sh          full-coverage invariant sweep (see below)
db/determinism-audit.sh        regenerate a sample, compare bit-exact
db/regen-chunks.sh             regenerate chunks; verify, then swap
db/regen-convert.sh            per-chunk convert → verify → swap with backup

db/schema.sql                  original MariaDB schema (retired)
db/galaxy-collector.sh         retired MariaDB path, kept for reference
db/mariadb-to-parquet.sh       one-shot migration (retired)

ANALYSIS.md                    the authoritative project record: every
                               benchmark, decision, and trap, including the
                               negative results
```

## Verification

The dataset is not merely assumed correct:

- **Invariant sweep** — galaxy counters reconcile against the stars and planets
  they summarise (star-type and all seven spectral-class counts, planet /
  gas-giant / tidal counts, `min_bh_dist` and `min_ns_dist` recomputed from
  positions); per-star counters likewise; plus structural checks for duplicate
  or non-contiguous `planet_idx`, dangling moons, and range/enum validity.
  **0 violations across all 24.4B rows.**
- **Determinism audit** — 20 seeds from each of the 500 chunks regenerated and
  compared `EXCEPT ALL` in both directions. **0 mismatches on every field**,
  including the ones no invariant can check (obliquity, orbital periods,
  positions).

Both audits earned their keep. The sweep found a single planet in 24.4 billion
whose veins had been written as all-zeros by a transient dump-time fault. The
determinism audit found that 13 chunks had passed through MariaDB during an
early migration and come back with **6-significant-digit floats** — a
systematic 2.6% of the dataset, invisible to every invariant, and caught only
because three planets happened to sit exactly on a Dyson-radius boundary where
a 1-in-10⁶ error flips a comparison. Both are fixed.

## Known upstream issue

`get_actual_vein` sums vein amounts exactly in `i32` and then returns the sum as
`f32`. Above 2²⁴ = 16,777,216 an f32 cannot represent every integer, so star and
galaxy vein totals are silently rounded to the nearest multiple of 4, 32 or 64
depending on magnitude. The fingerprint is unambiguous: **all 6.4 billion stored
star values are exactly f32-representable**, while 6.2 billion planet values are
not. Planet-level sums are therefore the authoritative numbers. Relative error
is ≤2⁻²⁴ (~6×10⁻⁸), so it does not affect rule thresholds — but anyone deriving
totals from planets will not reproduce the stored star/galaxy columns exactly.

## Want some of this data?

The full dataset is ~1.8 TB, which is more than I can casually host — so right
now it lives on my own hardware rather than anywhere public.

**If you want a slice of it, ask.** Open an issue describing what you're after
and I'll generate or extract it. Queries against the whole space are cheap now
(a seed-range query is ~2.6 s regardless of width; a full 24.4B-row scan is
~82 s), so most requests are minutes of work, not days. Things that are easy:

- all galaxies matching some criteria (N O-type stars, a habitable count, a
  minimum total of some ore, a particular planet type…)
- the complete star and planet detail for a list of seeds
- a whole column across the entire space (e.g. every galaxy's iron total)
- aggregate or statistical questions — distributions, extremes, correlations

**If enough people are interested, I'll host something properly.** The natural
tiers, with measured sizes:

| tier | size | contents |
|---|---|---|
| galaxy totals | ~5 GB | one row per seed: star-type and spectral counts, planet/habitable counts, all 14 vein totals |
| star veins | ~150 GB | per-star totals |
| planet detail | ~593 GB | per-planet vein amounts |
| everything | ~1.8 TB | the above plus full orbital geometry, themes, gases |

The galaxy tier is small enough to distribute without much thought, and answers
a large share of the questions people actually ask. Say so in an issue if that
would be useful to you and I'll look at putting it somewhere.

## Upstream

Optimisations and fixes developed here have been submitted back to
[DoubleUTH/DSP-Seed-Finder](https://github.com/DoubleUTH/DSP-Seed-Finder):
golden regression tests (#19), skipping the star-position walk for rules that
don't read positions (#20, 3.0×), pruning actual-vein generation with an exact
estimated upper bound (#21), and an exact integer accessor for vein totals whose
`f32` return silently rounds above 2^24 (#22).
