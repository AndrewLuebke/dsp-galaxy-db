# DSP-Seed-Finder — optimization & GPU assessment (2026-08-12)

> **IMPLEMENTATION UPDATE (same day, evening)**: fork AndrewLuebke/DSP-Seed-Finder
> carries the first wave, all tests green, PRs awaiting Andrew's review:
> `golden-tests` (regression net), `stage0-skip-walk` (163→54.6µs = 3.0× on rare
> position-free searches; 10^8 sweep at 32+64 stars = ZERO walk shorts; worst case
> 1.47× when >50% of seeds match), `vein-max-prune` (sound upper bound, 1.2–3.3×,
> never slower), `native-cli` (`dsp_seed search`, resumable, ~5k seeds/s/old-Xeon
> core), `integration` (everything merged). Allowlist corrections vs the consult:
> GasRate IS position-tainted (resource_coef^0.3 in get_gases); GasCount clean.
> Bound exceptions found in code review: birth-planet bonus iron/copper groups
> (birth stars never pruned) and single-vs-double rounding of the resource
> multiplier (+multiplier+1 per-node slack).
>
> **FINAL PROOFS (late evening)**: 10^8 sweep completed at EVERY star count
> 32-64 (all 33 values) — ZERO walk shorts anywhere in the seed space; the
> fast path has no false negatives at any UI-selectable count. Demo run:
> integrated CLI searched the FULL 10^8 seed space in 267s (374,505 seeds/s,
> 112-thread Compiler CT, >=4 O-star rule, 9.36M hits; hit rate matches the
> local 1M-seed run at 9.3-9.4%). The "4.6 core-hour" workload is now a
> 4.5-minute job on one fleet machine.

Repo: https://github.com/DoubleUTH/DSP-Seed-Finder (Rust core → WASM browser mode +
native websocket binary; TS/React UI; bit-exact DSP galaxy gen incl. .NET
System.Random). Local clone: claude-node `~/dsp-seed-finder`, branch `bench-harness`
carries bench + posehist probe modes. Grok consult transcripts in this dir
(grok-brief/round1/round2). Grok workspace: grok-node `~/seedfinder-work`.

## Measured baselines (claude-node, 1 old-Xeon thread, 64 stars, release)

| path | µs/seed | full 10^8 space |
|---|---|---|
| star-only rule (luminosity) | 163 | 4.6 core-hours (~5 min on 56-core CT) |
| lazy planets (planet_count) | 233 | |
| estimated veins | 526 | 14.6 core-hours |
| **actual veins** | **177,846** | **~206 core-days** |
| create_galaxy (viewer) | 431 | |

Callgrind: cheap path = 74% drunk-walk star positions (O(n²) f64 collision) + 15%
DspRandom::new (~66 .NET-Random seedings/seed), 1.5M instr/seed. Actual veins = 64%
SimplexNoise::noise_3d + 10% query_height_normalized (161,604-vertex grid, multi-
octave f64) feeding a sequential 200-try placement walk; 878M instr/seed.

## Key probe result (gates biggest cheap win)

tmp_poses.len() == star_count for ALL 10^6 seeds at both 32 and 64 stars (zero
shorts). Star seeds are drawn from the galaxy RNG *independently* of the pose RNG
(stream: 1 pose next_seed + 4 type-count next_f32 + N star next_seed). So
position-free rules (type/spectr/lum/dyson/planet-count/tidal/theme/ocean/gas/
max-hive — NOT distances, veins, initial-hive, resource_coef) can skip the walk
entirely: ~163→~40µs/seed, full space ≈ 1 min on the 56-core CT.
Safety = verify-on-match (re-run real walk on each hit before reporting), not an
exception table (33 star_count values, future-patch fragility).

## Agreed plan (Claude + Grok converged, 2 rounds)

1. Golden tests first: find_stars bitmask + vein-total hashes over fixed seed lists
   at 32/48/64 (repo has almost no regression net).
2. Stage-0 skip-walk + verify-on-match (~4× cheap path).
3. Exact vein upper-bound prune: estimated max (maxGroup×maxPatch×maxAmount) is a
   true upper bound — actual placement can only fail to place. Skip terrain when
   max < threshold. 10–100× on typical "≥ X" rare-vein searches. (Not valid for
   `<=`/equality conditions.)
4. Native CLI (range/threads/resume/results file) — bypasses the WS pipeline, which
   starves many-core boxes (200-seed batches × only 4 in flight ≈ 0.6ms of work per
   RTT on 56 cores). Enables fleet runs.
5. Spatial hash (cell size 2.0, 27-neighbor) for the walk on Stage-1 survivors, +
   SoA slim search galaxy (no Rc/OnceCell/trait objects), deferred hive RNG.
6. Upstream boring bit-exact PRs: spatial hash, max-prune, batch depth/size,
   golden tests, useActualVeins default (=true today — accidental 206-core-day UX).
   CUDA + CLI live in a companion crate/fork (wasm-pack GitHub Pages app can't
   link CUDA).
7. ~~GPU (LAST, optional): 5090 as f64 terrain-height co-processor~~
   **CUDA SIDECAR KILLED BY MEASUREMENT 2026-08-13** (validation item #4 ran
   before any kernel code — as designed). The vein walk touches only **874 of
   161,604 grid vertices per planet (0.5% avg, 4.3% max)**; probe positions are
   sequentially height-dependent (rejection-loop draw count depends on prior
   height answers) so the query set cannot be pre-batched, and placement bias is
   too weak for cap-region prediction. Full-map kernel = 185× overcompute; at
   1:64 f64 the whole-galaxy GPU pipeline lands ~32 seeds/s vs ~90+ seeds/s for
   the host's own 16 CPU threads doing lazy eval. No GPU shape survives (Grok
   round 3 concurred: persistent noise coprocessor needs ~10^5 in-flight vertex
   jobs to beat PCIe/launch latency; warp-per-planet walk = dual-implementation
   trap). Working-set probe: `veinstats` mode on fork branch `cuda-height-spike`.
   DO NOT RE-PROPOSE GPU for this workload. Whole-galaxy-on-GPU and
   f32-conservative-prefilter remain rejected for the earlier reasons (WGSL no
   f64; walk chaos). CUDA toolkit left installed on andrew-pc (/opt/cuda).
   IF actual-vein throughput ever matters again, the gated path is: measure
   Stage-2 share of wall time on real rare rules after the cascade — if >15-20%,
   consider miss-histogram-guided AVX-512 noise batching (realistic 1.3–1.8×,
   NOT 2-4×: mean 2.2 cache-misses/query starves 8-wide f64) or spacing-before-
   height test reorder; otherwise fleet-parallel the range via the CLI.

## Traps (from Grok, verified)

- habitable_count + used_theme_ids are sequential across the galaxy in star-index
  order — never parallelize theme/planet gen inside one galaxy without prefix replay
  (evaluate_unsafe! exists for exactly this).
- resource_coef = f(|pos|/32) feeds BOTH vein paths → vein rules always need the walk.
- Stage-0 stream trap: must still consume the pose next_seed; type-count draws are
  next_f32 not next_seed.
- Bit-exact minefield for any port: round_ties_even, f64→f32→f64 ceils in star-type
  counts, wrapping subtract vs i32::MAX, new_system_random inextp=21 bug replication.

## Validation queue before/during implementation

- 10^8 pose-length sweep on Compiler CT (confidence check, ~15 min).
- Max-prune hit rate on realistic rare-vein rules.
- Height working set: distinct get_height nodes per planet in vein gen (if ≪161k,
  full-map GPU kernel over-computes; lazy CPU eval may win).
- Single-planet CUDA f64 get_height timing on the 5090 (go/no-go for the sidecar:
  budget 2–8ms/planet batched).

## Hardware shootout: the drunk walk (measured 2026-08-13)

Single-thread, clean core, 100k seeds: i9-14900K P-core = 17µs/seed @32 stars,
52µs @64. Xeon 8280L core (4.0GHz turbo) = 33µs / 105µs → **14900K P-core = 2.0×
per core**. Full-box 10^8 @64: dual-8280L (112t) measured 218.7s (~457k seeds/s;
HT ≈ +4%, all-core clock drop eats most of it); 14900K estimated ~300s (~330k/s,
P+E) — verify when desktop idle. **ISA-tuned builds are worthless here**:
target-cpu=cascadelake (AVX-512) = -4% single-thread, ±0% full-box (818 zmm instrs
all off the hot path + frequency licensing); target-cpu=raptorlake (AVX2) = -2%.
The walk is branchy early-exit scalar f64 — LLVM cannot auto-vectorize the
collision any() loop. 8280L's advantage is 56 cores, not AVX-512; don't ship
target-cpu builds. (14900K has no AVX-512 at all — fused off.)

## Fleet-parallel search (built + validated 2026-08-13)

`~/dsp-mods/seed-finder/fleet-search.sh start|status|collect|stop` splits a seed
range across compiler/laptop/desktop proportional to measured throughput, runs
the CLI detached on each (desktop always nice -19, laptop -10), merges TSVs.
Validated end-to-end: 60k actual-vein seeds across 3 boxes → contiguous merge,
resume-idempotent re-start. Measured actual-veins rates: CT dual-8280L 351
seeds/s; laptop 13900HX 195/s; desktop 14900K 115/s NICED under transcode-QC
batch (~240/s est. idle). Aggregate ~660/s → exhaustive unfiltered 10^8 ≈ 42h
(~35h with desktop idle). The two i9s ≈ double the CT alone — "206 core-days"
is OLD-XEON core-days; modern P-cores count ~2×. Open design point for a real
exhaustive run: current CLI outputs rule-hits; a per-seed vein-DATABASE dump
would need a new output mode (galaxy totals ≈ 5.6GB; per-star ≈ 360GB).

## Galaxy database (pipeline built + proven 2026-08-13; big burn awaiting go)

MariaDB 11.8.6 on CT 114 (8c/32G). Fork branch `db-dump`: `dsp_seed dump` emits
galaxies/stars/planets TSVs (full detail incl. per-planet actual veins, orbit
mechanics, gases, hives; names omitted = regenerable; multiplier fixed 1.0).
Schema+loader: ~/dsp-mods/seed-finder/db/. PROVEN: 10k seeds → 3.09M rows loaded
(110k rows/s), row byte-identity verified, joins instant. SIZING (full 10^8 at
count 64): raw TSV 5.9TB transient; InnoDB ≈ stars 940G + planets 3.4T + galaxies
30G = 4.4TB pre-index (ZFS zstd-3 beneath → ~2-3T on pool). Dump rate CT 323
seeds/s → fleet ≈ 2 days. Load 78h serial → parallelize 3-4 sessions overlapped
with generation. ALL-33-COUNTS full detail = INFEASIBLE (~145TB, ~2 fleet-months);
menu = 64 full, then 32 full, stop. BLOCKED ON ANDREW: `pct set 114 -mp0
Datastore:6000,mp=/galaxydb` (classifier denied pct on pve) + `zfs set
recordsize=16k Datastore/subvol-114-disk-1`; then tables recreate with DATA
DIRECTORY, innodb_buffer_pool 128M→16G before load. SpectrType stored RAW game
values (M=-4..O=2,X=3); star_type 0=main..4=BH; water_item_id -2=lava.

## Compression measurements + conveyor LIVE (2026-08-13 afternoon)

MEASURED on the 10k proof: TSV transport zstd-3 = 2.0-2.5x. InnoDB pages on ZFS
zstd-3 = 2.08x REAL ratio — but ONLY at recordsize=128K. At 16K (the "DB best
practice" I first set): 6-wide RAIDZ2 parity+padding on tiny records ate 100% of
the gains (445M vs 234M used, same data). recordsize=128k NOW SET on
Datastore/subvol-114-disk-0. Engine compression LOSES on this stack: ROW_FORMAT=
COMPRESSED 1.37x, PAGE_COMPRESSED 1.6x (punch-hole works on OpenZFS 2.3) — both
below plain-InnoDB-on-ZFS 2.07x; verdict: no engine compression. Full-space
on-pool ≈ 2.2T data + indexes → ~3T of the 6T quota.
CONVEYOR RUNNING: galaxy-producer.service on compiler (200k-seed chunks, count 64,
range 0:10^8), galaxy-collector.service on claude-node (User=andrew — root has no
fleet key!). load_ledger table = idempotency. Desktop/laptop producer legs ready,
awaiting Andrew's go (laptop only viable on-LAN: DERP relay can't move 1.3GB
chunks). CT-only ETA ~3.6 days; +desktop ~2.2 days.

CONVEYOR CYCLE 1 VERIFIED (chunk 0: 61.8M rows ledgered) but load-bound: 19min
load vs 10.4min production. Fixes applied 08-13: innodb_io_capacity 200→3000
(default throttled background flush) + collector loads parallelized (3 sessions,
planets split in two) + LOAD ... IGNORE (idempotent retry after crash-before-
ledger; unique_checks=0 removed — PK dupes with it = corruption risk). DEDUP
MEASURED: 0.00% duplicate non-zero blocks in .ibd at 128K and 16K granularity
(all dupes = InnoDB zero-fill pages, already free under compression) — dedup
verdict NO, compression owns this dataset's redundancy.

STEADY STATE (08-13 14:05): chunk load = 4m21s (was 19m: io_capacity 200→3000
= 1.3x, script-parallelized loads = 3.3x) vs 10.4min CT production — producer-
bound with headroom for both i9 legs. Conveyor bugs fixed en route: shell-
precedence race (split vs backgrounded loads → deployed galaxy-load.sh on the
DB host), stale-inbox zstd refusal (scrub before transfer + zstd -f). OPS:
galaxy-producer.service on compiler / galaxy-collector.service on claude-node
(User=andrew!) / galaxy-stall-check.timer hourly on claude-node → mails
fleet@ on stall (rate-limited 3h, self-disarms at 500 chunks). To add desktop
leg: scp dsp_seed_dump binary + galaxy-producer.sh to desktop, systemd-run
producer with a DISJOINT range (e.g. 60000000:100000000 desktop, shrink CT to
0:60000000 by stopping/restarting its producer — resume handles it), add
"desktop" to collector args + restart collector.

BINLOG TRAP CAUGHT 08-13 ~14:15 (before it killed the run): CT 114 has log_bin
ON (7-day expiry) → each chunk double-wrote ~62M rows to binlogs on the 64G
rootfs — 16G eaten in the first hour; 500 chunks would have FILLED the rootfs
and halted MariaDB mid-run. Fix: SET SESSION sql_log_bin=0 in all galaxy-load.sh
sessions + PURGE BINARY LOGS (in-flight chunk holds recent files until done —
re-purge after). Also: compressratio holding at 2.25x; CT clock is UTC (+7 from
PDT) — mind it when reading mariadb journal timestamps vs collector's local ones
(caused a false stall diagnosis).

DESKTOP LEG ADDED 08-13 14:32: range split CT 0:80000000 / desktop 80000000:
100000000; collector watches both. KEY TECHNIQUE — **E-core pinning beats nice
alone for gaming coexistence**: systemd CPUAffinity=16-31 confines the producer
to the 14900K's 16 E-cores (P-cores 0-15 = 5700MHz, E = 16-31), so DSP's
sim thread never contends for execution slots OR the P-core power budget;
nice 19 only rations CPU *time* and cannot protect shared L3/power/memory-BW.
Measured 106 seeds/s E-cores-only (vs ~240 est. all-core). Desktop /tmp is
TMPFS (63G, RAM-backed) — fine at 128G RAM and saves ~6GB/chunk SSD write
churn; chunks peak ~13GB RAM. Combined fleet ≈ 426 seeds/s → count-64 ETA
~2.7 days. Rebalance when desktop's 20M finishes early: hand it a slice of
CT's tail (resume makes reassignment free).

BINLOG POSTSCRIPT (08-13): sql_log_bin=0 fix CONFIRMED WORKING — post-fix binlog
000045 = 13KB while carrying ~62M rows of loads, vs 3.0GB pre-fix files. Run is
safe (growth stopped; CT rootfs 44/64G). Correction to earlier alarm: "90 files"
was 45 binlogs + 45 .idx sidecars (MariaDB 11.x per-file index) — count them with
`ls mariadb-bin.0*[0-9] | grep -v idx`. SEPARATE PRE-EXISTING BUG FOUND on CT 114
(NOT ours, affects his gmail/firewall DBs too): **binlog purging is broken** —
binlog_expire_logs_seconds=604800 (7d) yet mariadb-bin.000001 from 2026-07-13
survives, and `PURGE BINARY LOGS BEFORE NOW()` returns success while deleting
nothing; no purge errors in the log ("InnoDB Stopping/Resuming purge" lines are
undo-log, unrelated). 29GB accumulated. No replicas (SHOW REPLICA HOSTS empty) so
RESET MASTER would clear it safely — ANDREW'S CALL (destructive on a shared prod
DB; costs binlog-based PITR for gmail/firewall between PBS backups).

FISH TRAP BIT THE COLLECTOR 08-13 15:11 (desktop leg's first chunk): compiler is
Debian/bash so `$SSH host "ls -d /tmp/gchunks/*/DONE | sort | head -1"` and
`"cut -d: -f2 .../DONE"` worked there and MISPARSED on desktop (login shell =
FISH). Symptoms: empty span → "VERIFY FAILED g=200000 (want -80000000)", then
`basename: extra operand` from a multi-line chunk var. Per
[[fish-shell-ssh-remote-trap]] EVERY remote command to desktop/laptop must be
`bash -c '...'`-wrapped — now 7 wrapped sites in galaxy-collector.sh + the
producer-check in galaxy-stall-check.sh. Added a numeric guard on span so a
bad read fails loudly instead of computing a negative expectation. NO bad data
reached the DB (verify runs pre-load; ledger stayed clean at 7 chunks).

## Parquet CT + columnar experiment (2026-08-13) — MEASURED, surprising

Built **CT 118 `parquet`** (Debian 13, 12c/24G, 800G Datastore
mount at /parquet, backup=0, DuckDB 1.5.5, apt via local mirror, fleet key,
`ssh parquet`). Test: 10.95M real planet rows (1907 MB raw TSV).

| form | size | vs raw |
|---|---|---|
| raw TSV | 1907.3 MB | 1.00x |
| zstd-19 row-major | 602.4 MB | 3.17x |
| **Parquet + zstd** | **585.9 MB** | **3.26x** |

**Parquet beats row-major zstd-19 by only 1.03x — columnar compression is NOT
the win here.** Root cause measured: the data is PRNG output and near-maximum
entropy. v_iron has 8.3M distinct values in 10.9M rows; orbital_period (DOUBLE)
has 10.49M distinct in 10.9M rows (~unique per row). Only the structural columns
compress (theme_id 25 distinct; v_mag 99.2% zero, v_grat 88.3% zero) and they're
a small share of bytes. ~3.2x IS the entropy floor — which also explains why
zstd-3→19 gained only 22% and xz-9 gained nothing.

**Parquet's REAL value is column projection, not compression** (measured on the
same rows): veins-only 266.1 MB (45%) vs metadata-only 323.9 MB (55%). So
shipping only the expensive-to-compute columns halves the payload — the thing
row-major formats can't do.

CORRECTED FULL-SPACE SIZING (earlier 930GB figure was wrong — bad raw-TSV base):
raw TSV ~5.9TB (42.5 KB/seed planets + 16.9 stars + 0.2 galaxies); compressed
~1.83TB total. Distribution tiers, measured: galaxy vein totals ~5GB / star vein
totals ~150GB / planet vein detail ~593GB / everything ~1.83TB. Star+galaxy
totals are SUMs of planet veins — ship planet-level once, derive the rest.

## ARCHITECTURE SWITCHED TO PARQUET 2026-08-13 16:08 (Andrew's call, measured)

DECIDING BENCHMARK — same aggregate (SUM(v_iron) GROUP BY seed):
MariaDB/InnoDB 48.8M rows = **>600s (killed)**; DuckDB/Parquet 10.9M rows =
**0.080s**. ~137M rows/s vs <81k. Structural, not tuning: columnar reads 2 of
38 columns, vectorized, 12 cores, vs InnoDB reading every byte single-threaded.
(MariaDB handicapped by cold pool + concurrent loads, but not by 1000x.)

NEW PIPELINE: producer (unchanged, dumps TSV+zstd) -> galaxy-parquet-collector
.sh on claude-node -> parquet CT: decompress, `parquet-convert.sh` (DuckDB
TSV->Parquet zstd, .tmp+rename so no partial file is ever globbed, row-count
verify vs source TSV) -> cleanup. NO DB server, NO binlog, NO LOAD DATA;
conversion ~17s/chunk vs 4m21s load. Files are BOTH the query surface and the
distributable artifact. Layout /parquet/{galaxies,stars,planets}/c64-<start>.
parquet; query via read_parquet('/parquet/planets/*.parquet').
Old MariaDB path (galaxy-collector.service) STOPPED but intact as fallback;
galaxy DB retains 10 chunks (seeds 0-2M + 80-80.2M) — backfill or regenerate
(~78 min fleet) once the parquet path is proven.

ZFS on CT 118: compression=OFF (parquet self-compresses; the 1.47x I first
measured was the scratch TSV, parquet itself is ~1.0x), volume grown to 2.5TB.
**primarycache LEFT AT `all` — do NOT set metadata**: [[zfs-primarycache-
metadata-breaks-prefetch]] measured 96% prefetch miss / 3.7x reader collapse,
and full-scan analytics is exactly that access pattern. DuckDB has no
persistent cache of its own — ARC *is* its buffer pool. No memory pressure
anyway (ARC 384G of 768G).

## MariaDB fully retired 2026-08-13 evening — migration COMPLETE

Backfill: all 13 MariaDB chunks exported via INTO OUTFILE (**verified to preserve
full f64: 5361.2343925487385 round-tripped exact through MariaDB->TSV->Parquet**)
-> parquet-convert.sh. VERIFIED: 13/13 ledger chunks present with EXACT matching
planet row counts, 0 mismatches. Then: DROP DATABASE galaxy, drop pqexport user,
detach + destroy the /galaxydb volume, MariaDB healthy after (gmail +
firewall_blocks intact, 41,886 rows sampled). Datastore back to 187G used /
6.96T free; parquet volume grown to 4TB.

**RESTORED SAFE DURABILITY** on CT 114 — the bulk-load tuning I had added
(innodb_doublewrite=0, flush_log_at_trx_commit=2, 16G pool, 4G logs,
local_infile) was UNSAFE to leave for gmail/firewall_blocks; 70-galaxy.cnf now
keeps only innodb_io_capacity 3000/8000 (the 200 default is rotational-era and
wrong for this all-flash host). Verified doublewrite=ON, flush mode=1.

PVE GOTCHA: `pct set <id> --delete mp0` on a RUNNING container returns exit 0 and
`pct config` stops showing the mountpoint, but the change is only PENDING — the
raw /etc/pve/lxc/<id>.conf keeps mp0 and the volume stays mounted+busy, so
`pvesm free` fails with "dataset is busy". It applies on STOP (becomes unusedN),
then `pct set --delete unusedN` destroys it. Also note the name collision trap:
rootfs and the data volume were BOTH `subvol-114-disk-0`, differing only by pool
(VM-Pool vs Datastore) — always fully qualify before destroying.

WATCHDOG REWRITTEN 08-14: the old galaxy-stall-check.sh still queried
galaxy.load_ledger, which the Parquet migration DELETED — so it emailed fleet@ a
false "cannot reach mariadb/ledger" every 3h overnight. Lesson: when migrating
away from a datastore, the monitoring that watches it is part of the migration.
New version monitors the OUTCOME (count + mtime of /parquet/planets/*.parquet,
target 500, stall threshold 90min) not the mechanism, so a producer Andrew
deliberately stops for gaming no longer pages him; only an actual halt does.

## Parquet validated at scale 2026-08-14 (22% of the run loaded)

Same query shape MariaDB never finished:
- **Q1 top-seeds-by-total-iron over ALL 5,322,766,999 planet rows: 79 s**
  (67M rows/s). MariaDB: 48.8M rows, killed at 47 min without completing
  (<17k rows/s) => **~3,900x, on 109x more data**.
- **Q2 three-table join** (>=3 O-stars AND a star >60M iron AND a tidally-locked
  ocean world with oil): 21.8M galaxies + 1.4B stars + 5.3B planets, two
  aggregating CTEs + two joins = **116 s**. This class of question the rule
  engine cannot express at all.
Both run on the 12-core CT *while* the conveyor was converting chunks.
Extrapolated to the full run (4.6x more data): Q1 ~6 min unindexed full scan;
seed-ranged queries far faster still via Parquet row-group stats / predicate
pushdown (no indexes needed, files are chunk-ordered by seed).
Sample findings: richest-iron galaxy so far seed **9403494** (13.77e9);
best "perfect start" seed **17885366** (3 O-stars, 21 habitable, 12.7e9 iron,
tidal-locked ocean world with oil).

FLEET-SEARCH AUDIT 08-14: no fish exposure left (all $SSH calls already
`bash -c`-wrapped; scp uses the sftp subsystem, never the login shell). But
found a REAL bug while looking — `status` used an UNBRACKETED pgrep pattern, so
it matched its own `bash -c` command line and reported every host RUNNING
forever ([[pkill-self-match-footgun]]; `stop` had the bracket, `status` didn't).
Fixed to `${RUN}[-]${h}`. NOTE ON TESTING IT: the first proof was INVALID —
running both patterns in one `bash -c` put the unbracketed literal in the shared
command line, so the bracketed pattern matched *that*. Isolate each pattern in
its own invocation. Verified: unbracketed = "falsely RUNNING", bracketed =
"correctly stopped".

## FULL-DATASET BENCHMARKS + INTEGRITY SWEEP 2026-08-18

Run COMPLETE 08-17 05:15. Verified: 100,000,000 galaxy rows, seeds 0-99,999,999,
100,000,000 distinct (no gaps, no dupes). 6,400,000,000 stars.
**24,416,296,286 planets.** 1.8 TB.

BENCHMARKS on the full space (12-core CT 118, idle):
| query | 22% checkpoint | FULL | data x | time x |
|---|---|---|---|---|
| Q1 full-scan SUM(v_iron) GROUP BY seed | 79s / 5.3B rows | **81.9s / 24.4B** | 4.59x | 1.04x |
| Q2 three-table join | 116s | **141.8s** | 4.59x | 1.22x |
Q1 = 298M rows/s (the 22% figure of 67M rows/s was measured WHILE the conveyor
converted chunks — it always understated the real rate). My own extrapolation
said ~6 min for Q1; actual 81.9s, i.e. the prediction was 4.4x pessimistic.

Other measured points: cold single-column sum 58.3s (418M rows/s); the SAME Q1
shape warm = 37.4s, so **cold/warm = 2.2x** => workload is ~55% I/O-bound cold,
which vindicates leaving primarycache=all. `count(*)` over GROUP BY seed = 11.8s
because DuckDB projects away v_iron entirely and `seed` is 244 identical
consecutive values per galaxy (RLE) — column projection, exactly the thing
Parquet was adopted for. v_grat > 0 on all planets = 32.5s (2,853,308,033 hits).

**PREDICATE PUSHDOWN — claim now MEASURED, not predicted:** single seed 2.79s /
1k-seed range 2.66s / 200k-seed range (48.8M rows) 2.61s. FLAT regardless of
width, ~30x faster than the full scan; cost is dominated by opening 500 footers.
No indexes.

vs MariaDB (48.8M rows, killed at 47 min, <17.3k rows/s): ~24,000x throughput.
Extrapolated, MariaDB needs ~16 DAYS for the 58s scan — and it never finished.

Q2's ANSWER CHANGED at full scale: "perfect start" seed 17885366 (the 22%
winner) fell to 5th; new best **62865047** (3 O, 20 habitable, 12.95e9 iron),
and **22029308 has FOUR O-type stars**. Q1's richest-iron seed **9403494**
(13.77e9) held #1 — a max over one scalar is already well-sampled at 22M seeds,
but a multi-constraint query has so few qualifying galaxies that the remaining
78% mattered. Worth remembering when deciding whether a partial run is enough.

### ONE CORRUPT ROW IN 24.4 BILLION — found, diagnosed, repaired
Spotted by accident: two query outputs disagreed on seed 62865047's iron by 6.
Chasing it, galaxies.v_iron != SUM(planet v_iron) for 98.4% of seeds — but the
-0.029 average was ENTIRELY one outlier; the other 99,999,999 seeds net +84,366
(~0). Level isolation: `galaxy = SUM(stars)` EXACTLY 100,000,000/100,000,000, so
galaxy/star are consistent; star totals are an INDEPENDENT computation, not a
sum of planets (`sp.get_actual_vein()` vs per-vein `planet.get_actual_veins()`),
which is why a +-200 noise band exists at all. NOTE: my first explanation —
trunc-order bias, Sum(trunc) <= trunc(Sum) — was WRONG; it predicts a one-sided
negative bias and the data is symmetric.

Culprit: seed **401732**, star 6 (K-type, no gas giants), planet_idx 3, orbit 5 —
a rocky planet with ALL 14 veins = 0. Census over all 24.4B planets: exactly
**1** such row. Among 1,120,818,899 planets of the same type+theme (avg iron
4.3M), exactly 1 has zero iron. **Regenerating seed 401732 does NOT reproduce
it** (0.23s) — the generator emits iron 3020121 / copper 2630165 / silicium
3314787 / titanium 15268396 / stone 45713916, matching the shortfall exactly.
=> transient write fault during the original multi-threaded dump, NOT a
deterministic generator bug.

FULL 14-VEIN SWEEP (per-seed galaxy-vs-planet-sum, all resources, 9m39s):
stone/titanium/silicium/iron/copper each show exactly ONE seed over 1k — the
same seed, matching that planet's five non-zero veins. The other 9 veins max out
at <=50. Worst seed after 401732 is 21426512 at 231, so the defect sat ~197,000x
above the noise floor. NOTHING else is wrong anywhere in the dataset.

REPAIR: rebuilt planets/c64-400000.parquet replacing ALL 243 rows for seed
401732 from a fresh single-seed dump (regenerating 200k seeds was unnecessary —
we already had the correct rows in 0.23s). Wrote .parquet.new, verified FOUR
things before swapping (row parity 48,832,355=48,832,355; seed rows 243=243;
planet now carries ore; zero-vein census on the rebuilt file = 0; seed 401732
galaxy-vs-planet diff now **28**, inside the noise band, was -3,020,149), then
mv'd the original to .parquet.bak. Neither `.bak` nor `.new` matches the
`*.parquet` glob, so queries never see a half-state. **Post-repair census over
all 24,416,296,286 planets: 0.** Dataset is clean.
(Leftover: /parquet/planets/c64-400000.parquet.bak, 2.7GB — delete when happy.)

### DuckDB-in-LXC OOM TRAP (cost one frozen container)
The 14-column census killed CT 118: ssh exit 255 "not responding", `pct status`
still "running", host showed CT118 memory.pressure full avg60=93.4 (whole cgroup
stalled in reclaim, sshd included), no OOM line in host syslog. Cause:
`free -g` inside the CT correctly says 24G (lxcfs works), but DuckDB's
`memory_limit` autodetected **603.5 GiB** — 80% of the HOST's 768G — because it
sizes from a syscall lxcfs does not cover. Light streaming scans (Q1/Q2/bench3)
never trip it; anything that BUFFERS (many columns, count(DISTINCT), big GROUP
BY) does. Fixed permanently in /root/.duckdbrc: `SET memory_limit='16GB'` +
`SET temp_directory='/parquet/duckdb-tmp'` (the temp dir matters as much — with
it, DuckDB SPILLS instead of dying; the re-run then completed in 237s).
See [[duckdb-lxc-memory-limit-trap]].

## INTEGRITY SWEEP + DETERMINISM AUDIT 2026-08-18 (revises "dataset is clean")

Built `db/integrity-sweep.sh` (full-coverage invariants) and
`db/determinism-audit.sh` (regenerate-and-compare). Results:

**Sweep phases B/C/D: CLEAN across every row.** Galaxy planet/gas-giant/tidal
counts reconcile with the planets; all range+enum checks 0 (spectr, star_type,
luminosity, mass/radius, birth_dist, resource_coef, sun_distance, periods,
orbit refs, gas giants have no veins and do have gas); per-STAR planet_count /
gas_giant_count / tidal_count / satellite_count all reconcile; zero duplicate or
non-contiguous planet_idx; zero dangling moons. 100/100 batches, 137m41s.
Phase A (galaxy-vs-STAR counters) OOM'd on `count(DISTINCT idx)` over 100M
groups — DISTINCT aggregates don't spill. STILL UNVERIFIED, re-run with
sum(idx)+sum(idx*idx) instead (cheap, catches permutations just as well).

**THE REAL FINDING — 13 chunks have 6-SIGNIFICANT-DIGIT FLOATS.**
Phase D flagged only 3 stars, all `in_dyson_count`, all in batches 1-2. Chasing
them: seeds 58378/969926/1802035 each have a planet sitting EXACTLY on the Dyson
boundary (sun_distance*40000 - dyson_radius = 0.0), so a 1e-6 error flips the
strict `<`. Regeneration showed stored 1.8799999952 vs fresh 1.8799969 — and
stored is f32("1.88"), stored 2.7095599174 is f32("2.70956"), stored
3.7552099228 is f32("3.75521"). ALL are the f32 of a **6-sig-digit decimal**:
the MariaDB round-trip (LOAD DATA -> INTO OUTFILE prints FLOAT at 6 sig digits).
NOTE: my first two hypotheses were both WRONG — I guessed f32-vs-f64 in my own
SQL (both agreed), then a lazy-init bug in get_sun_distance (it correctly
returns orbital_radius for non-moons). Only regeneration found it.

Scoped by testing `value == f32(printf('%.6g', value))` per chunk:
**13 of 500 chunks affected** = c64-0 .. c64-2000000 (seeds 0-2,199,999) plus
c64-80000000 and c64-80200000 (seeds 80,000,000-80,399,999) — exactly the
MariaDB backfill range. 487 chunks are full precision.
INTEGERS ARE UNAFFECTED (veins/counts/ids exact). Derived integer counts like
in_dyson_count are CORRECT — computed before the round-trip — which is why
recomputing them from degraded floats disagreed.

**DETERMINISM AUDIT confirms it independently and exactly.** 20 seeds from each
of the 500 chunks (10,000 seeds) regenerated and compared with EXCEPT ALL both
ways: galaxies 260 mismatched, stars 16,640 (=260x64), planets 63,439 (=260x244).
260 = 13 chunks x 20 seeds EXACTLY. Row counts identical and mismatch counts
symmetric => every diff is an ALTERED row, nothing missing or extra.
**The other 9,740 seeds match BIT-EXACT on every field** — including
obliquity/periods/positions, which no invariant can check. 17m53s.

FIX REQUIRED before distribution: regenerate those 13 chunks natively
(TSV->parquet, no MariaDB). 2.6M seeds ~= 2.3h on compiler + ~17s/chunk convert.
Note c64-400000 is also the chunk repaired earlier today, so seed 401732's rows
in it are currently full-precision while the rest of that chunk is not —
regeneration resolves both at once.

### RESOLVED 2026-08-18 evening — all 13 chunks regenerated, dataset VERIFIED
Regenerated natively via `db/regen-chunks.sh` + `db/regen-convert.sh` (generate
on compiler -> stream -> convert to .parquet.new -> VERIFY -> swap, old kept as
.bak). Gates per chunk: row parity vs TSV lines, seed range must equal the
chunk's own range (so a bad --range cannot write wrong seeds under the right
filename), and the %.6g test inverted to prove precision was actually restored.
13/13 OK, ~712s each (~2.6h total). six_sig_now fell 100% -> 3.0-4.1% on every
chunk (the residual is values that genuinely have <=6 digits).

**PROOF the fix is real, not just "the files changed":** re-ran the determinism
audit against the SAME 10,000-seed sample generated BEFORE the fix and untouched
since. galaxies 260->**0**, stars 16,640->**0**, planets 63,439->**0**.
All 10,000 seeds across all 500 chunks now match the generator BIT-EXACT on
every field.

**Sweep Phase A finally ran** (rewrite: sum(idx)+sum(idx*idx) instead of
count(DISTINCT idx), plus preserve_insertion_order=false; 167s vs OOM before —
for a complete 0..63 set those must be 2016 and 85344, which no duplicate or
permutation can hit by accident). 100,000,000 seeds checked, ALL NINE CHECKS 0:
64 stars each with idx 0-63 unique, bh/ns/wd/giant counts, all 7 spectral class
counts, and min_bh_dist/min_ns_dist recomputed from star positions.

DATASET STATUS: every invariant verified across every row; both defects fixed;
bit-exactness demonstrated on a 10k-seed sample spanning all 500 chunks.
Leftover: 39 *.parquet.bak (~50GB) + the earlier c64-400000.parquet.bak.
Still open upstream: get_actual_vein returns the exact i32 sum AS f32, so star/
galaxy vein totals >2^24 are silently rounded (all 6.4B stored star values are
exactly f32-representable = the fingerprint). One-line return-type fix; bundle
with the queued PRs.
