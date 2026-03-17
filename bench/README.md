# Irmini Benchmarks

Performance comparison across all Irmin implementations and backends.

## Implementations

| Implementation | Branch / Repo | Concurrency | Description |
|---|---|---|---|
| **Irmin-Lwt** | irmin `main` | Lwt | Official Irmin with Lwt |
| **Irmin-Eio** | irmin `cuihtlauac-inline-small-objects-v2` | Eio | Official Irmin with Eio + inlining |
| **Irmini** | irmini `perf` | Eio | Irmini with all optimizations |

Each implementation is benchmarked with multiple backends: memory, fs, git, pack/lavyek.

## Backend architecture

Irmini supports three storage backends with different performance/durability trade-offs:

### Memory

Pure in-memory storage using immutable OCaml maps (`Map.Make(String)`).
No persistence — all data is lost on process exit.
Zero-overhead single-core; for multi-domain use, wrapped with a read-write lock
(`thread_safe_rw`) that allows concurrent readers with exclusive writers.

### Disk

Append-only data file + WAL (Write-Ahead Log) for crash safety.

- **Data file** (`objects.data`): single append-only file, all objects concatenated.
  Writes use `pwrite` at atomically-reserved offsets (`Atomic.fetch_and_add`).
  Reads use `pread` at known (offset, length) — no lock needed.
- **Index** (`objects.idx`): in-memory `Atomic.t` map (hash → offset+length),
  updated via CAS (compare-and-set). Persisted on flush.
- **Bloom filter** (`objects.bloom`): fast negative lookup, avoids disk reads
  for missing keys.
- **Per-domain WAL** (`wal-{N}.log`): each OS domain has its own WAL file with
  its own mutex. Writes append to the domain-local WAL then fsync (if enabled).
  On recovery, all WAL files are replayed. Content-addressed storage makes
  cross-domain duplicates harmless.
- **Crash recovery**: on startup, replay all WAL entries not yet in the index,
  then delete WAL files.

Multi-core: fully lock-free reads (`Atomic.get` + `pread`), lock-free offset
reservation (`Atomic.fetch_and_add`), CAS index updates, per-domain WAL
eliminates write contention between domains.

### Lavyek

LSM-tree (Log-Structured Merge-tree) key-value store — a separate library.

- **Write path**: append to in-memory memtable (lock-free atomic buckets) +
  WAL log file. When the memtable is full (~2 MB), it is flushed to an
  immutable SSTable (Sorted String Table) on disk.
- **Read path**: search memtable first (newest), then SSTables from newest
  to oldest. Each SSTable has a bloom filter and a FANout index for fast lookup.
- **Compaction**: background merging of SSTables across levels (L0 → L1 → L2).
- **Crash recovery**: replay WAL, restore SSTables from control file.

Multi-core: lock-free memtable, parallel compaction. The main write bottleneck
is that `Lavyek.put ~sync:true` fsyncs per key — a `put_batch` API would
amortize the cost.

## Optimizations since `main`

### All backends — single-core

| Optimization | Commit | Impact |
|---|---|---|
| **Value inlining** — small values (< 48 bytes) stored directly in tree nodes, avoiding content-addressable store lookups | `f4907ab` | commits-20B: **9×** (memory), **2.2×** (disk); reads-20B: **3×** (disk) |
| **Inode structural sharing** — HAMT trie for large tree nodes, O(log n) updates instead of O(n) re-serialization | `9ae61ec`, `7d9997b` | incremental: **2.4×** (all); commits-20B: **4×** (memory) |
| **LRU cache** — O(1) doubly-linked-list cache at backend level, avoids repeated deserialization | `b6e855f`, `1421b0a`, `ebdbc1f`, `2f5f6ca`, `17622d1` | reads-20B: **1.4×** (disk) |
| **Resolved-child cache** — Hashtbl cache in tree navigation, avoids re-traversing already-resolved subtrees | `cf1fda2`, `1a09cb4` | reads: measurable improvement on deep trees |
| **Write batching** — `Store.commit` accumulates all objects in a pending list, writes them in a single `write_batch` call | `b1b2e73` | disk: **1 fsync per commit** instead of per object |
| **Dirty check** — skip unmodified subtrees in `write_tree` | `30eeaae` | incremental: avoids re-serializing unchanged nodes |
| **Map/Set children** — replace list-based tree children with `Map`/`Set` for O(log n) lookups | `59de7b3` | tree operations faster on wide nodes |

### Disk backend — multi-core

| Optimization | Commit | Impact |
|---|---|---|
| **Lock-free reads** — `Atomic.get` on index + positional `pread`, zero locks | `35fbbf5` | reads: **5–10×** faster in parallel, zero overhead single-core |
| **Lock-free writes** — `Atomic.fetch_and_add` for offset reservation, parallel `pwrite`, CAS index updates | `35fbbf5` | enables true multi-core write parallelism |
| **Per-domain WAL** — each domain gets its own WAL file, eliminating the single `wal_mutex` bottleneck | `9789a4f` | parallel fsync no longer serialized across domains |
| **Configurable fsync** — `?use_fsync` parameter to disable WAL fsync for benchmarking | `fd4f2e3` | no-fsync: commits-20B **2.5×** faster |

### Bug fixes

Several correctness fixes were also necessary for correct multi-core
operation (O_APPEND removal, domain-safe Tree/Link, Memory read-write lock,
Lavyek ref mutex, inode hash exhaustion, etc.). See `test/README.md` for the
full list with commits.

## Prerequisites

To reproduce all benchmarks, you need:

1. **Monopampam monorepo** — contains irmini + its dependencies (lavyek, ocaml-wal,
   ocaml-bloom, etc.)
2. **Irmin checkout** — the official [irmin](https://github.com/mirage/irmin) repo,
   with two branches:
   - `main` — for Irmin-Lwt benchmarks
   - `cuihtlauac-inline-small-objects-v2` — for Irmin-Eio benchmarks
3. **Tezos trace file** *(optional, for trace replay)* — `data4_10310commits.repr`
   (267 MiB), placed at the root of the irmin checkout. This file contains 10,310
   Tezos blocks totaling ~4M operations.

The `run_all.sh` script handles branch switching automatically. Set `IRMIN_DIR`
to point to your irmin checkout.

## Quick start

Run everything and update README (recommended):

```
cd /path/to/monopampam
IRMIN_DIR=/path/to/irmin ./irmini/bench/run_bench.sh
```

This runs all benchmarks (irmini + irmin), generates SVG charts, and updates
the Results section of this README. Without `IRMIN_DIR`, only irmini benchmarks
are run and Irmin comparison rows are omitted from the tables.

`run_bench.sh` options:

| Flag                     | Default | Description                                    |
|--------------------------|---------|------------------------------------------------|
| `--skip-irmini`          |         | Skip irmini standard benchmarks (step 1)       |
| `--skip-optims`          |         | Skip optimization comparison (step 2)          |
| `--skip-trace`           |         | Skip trace replay (step 3)                     |
| `--skip-parallel`        |         | Skip parallel scaling sweep (step 4)           |
| `--skip-irmin`           |         | Skip Irmin-Lwt/Eio benchmarks (step 5)         |
| `--skip-charts`          |         | Skip chart generation (step 6)                 |
| `--skip-readme`          |         | Skip README update (step 7)                    |
| `--regen`                |         | Skip all benchmarks, only regenerate charts + README |
| `--trace FILE`           | auto    | Path to `.repr` trace file                     |
| `--trace-commits N`      | 10310   | Max commits to replay                          |
| `--parallel-fibers LIST` | 1,10,...,100000 | Comma-separated fiber counts for scaling sweep |
| `--parallel-domains N`   | 12      | Number of OS domains for parallel replay       |
| `--ncommits N`           | 100     | Override commit count (passed to benchmarks)   |
| `--tree-add N`           | 1000    | Override tree-add (passed to benchmarks)       |

Steps: 1) Irmini standard (all backends), 2) Optimization comparison (5 variants
× disk/memory), 3) Trace replay (sequential), 4) Parallel scaling sweep (14
fiber counts), 5) Irmin-Lwt/Eio benchmarks + trace replay (needs `IRMIN_DIR`),
6) Generate SVG charts, 7) Update this README from JSON results.

Irmini only (from monopampam monorepo):

```
cd /path/to/monopampam
dune exec irmini/bench/bench_irmin4_main.exe -- --json bench/results/irmini.json
```

Full comparison across all implementations:

```
IRMIN_DIR=/path/to/irmin ./bench/run_all.sh
```

Run a single backend or scenario:

```
cd /path/to/monopampam
dune exec irmini/bench/bench_irmin4_main.exe -- --only-backend lavyek
dune exec irmini/bench/bench_irmin4_main.exe -- --only-scenario commits
dune exec irmini/bench/bench_irmin4_main.exe -- --only-backend memory --only-scenario reads
```

Tezos trace replay (irmini, all active backends):

```
cd /path/to/monopampam
dune exec irmini/bench/bench_irmin4_main.exe -- \
  --trace /path/to/data4_10310commits.repr --trace-commits 10310
```

Tezos trace replay (irmin, disk and memory):

```
cd /path/to/irmin
dune exec bench/irmin-pack/tree.exe -- \
  --mode=trace --store-type=pack --ncommits-trace=10310 \
  --empty-blobs data4_10310commits.repr

dune exec bench/irmin-pack/tree.exe -- \
  --mode=trace --store-type=pack-mem --ncommits-trace=10310 \
  --empty-blobs data4_10310commits.repr
```

## Options

| Flag                  | Default | Description                              |
|-----------------------|---------|------------------------------------------|
| `--ncommits`          | 100     | Number of commits                        |
| `--tree-add`          | 1000    | Tree entries added per commit            |
| `--depth`             | 10      | Depth of paths                           |
| `--nreads`            | 10000   | Number of reads in read scenario         |
| `--value-size`        | 100     | Size of values in bytes                  |
| `--skip-memory`       | false   | Skip the memory backend                  |
| `--skip-lavyek`       | false   | Skip the Lavyek backend                  |
| `--skip-disk`         | false   | Skip the disk backend                    |
| `--skip-git`          | false   | Skip the git backend                     |
| `--cache`             | 0       | LRU cache capacity (0 = no cache)        |
| `--no-inode`          | false   | Disable inode splitting                  |
| `--name`              | —       | Override benchmark name                  |
| `--json`              | —       | Write JSON results to file               |
| `--trace`             | —       | Run trace replay from .repr file         |
| `--trace-commits`     | 0       | Max commits to replay (0 = all)          |
| `--trace-empty-blobs` | false   | Replace blobs with empty strings         |
| `--no-flatten`        | false   | Disable Tezos path flattening            |
| `--parallel-domains`  | 0       | Domains for parallel scenarios and trace replay (0 = skip) |
| `--parallel-fibers`   | 100     | Fibers per domain for parallel scenarios and trace replay |
| `--only-backend`      | —       | Run only this backend: memory\|disk\|lavyek\|git |
| `--only-scenario`     | —       | Run only this scenario: commits\|reads\|incremental |

## Scenarios

Each scenario runs twice: once with small values (from `--value-size`, default
20B) and once with large values (10 KiB). Scenario names include the value
size suffix, e.g. `commits-20B`, `commits-10K`.

Running with small values (below the 48-byte inline threshold, e.g. 20B)
tests the effectiveness of **value inlining** (small values stored directly
in tree nodes, avoiding content-addressable store lookups). Running with
large values (10 KiB) tests raw I/O throughput where inlining cannot help.

1. **commits** — Performs `ncommits` sequential commits, each adding
   `tree-add` entries at `depth`-level paths. Each commit reads the current
   tree, adds entries, then serializes and stores the new tree + commit
   object. This is the primary **write throughput** benchmark: it exercises
   tree construction, content-addressable hashing, and backend write I/O.
   It is sensitive to **inlining** (fewer store writes when values are
   inlined), **inodes** (O(log n) tree updates instead of O(n)
   re-serialization), and **backend write speed**.

2. **reads** — Populates a tree with `tree-add` entries, commits it, then
   performs `nreads` random lookups by path from the committed tree. The tree
   is loaded fresh from the store (not from memory), so each read must
   navigate the serialized tree structure and fetch content from the backend.
   This is the primary **read throughput** benchmark: it exercises tree
   navigation, deserialization, and backend read I/O. It is sensitive to
   **LRU cache** (avoids repeated deserialization), **inodes** (O(log n)
   navigation), and **resolved-child cache** (avoids re-navigating already
   resolved subtrees).

3. **incremental** — Builds a large tree (`tree-add` entries), commits it,
   then performs `ncommits` commits each modifying a single entry. Each
   iteration checks out the tree, updates one path, and commits. This
   simulates the common real-world pattern of **small updates on a large
   tree** (e.g. updating a single file in a repository). Without structural
   sharing (inodes), the entire tree must be re-serialized on each commit
   even though only one entry changed. With **inodes**, only the affected
   HAMT trie path is rewritten (O(log n) instead of O(n)). This scenario
   is the most sensitive to inode optimization.

4. **trace-replay** *(via `--trace`)* — Replays a recorded Tezos trace
   (`.repr` file in `IrmRepBT` format) against the store. The trace
   contains real operations from a Tezos node: Checkout, Add, Remove,
   Copy, Find, Mem, Mem_tree, Commit. This is the most **realistic**
   benchmark as it reproduces actual Tezos workloads with realistic
   tree shapes and access patterns. The `data4_10310commits.repr` trace
   contains 10,310 blocks totaling 4 million operations.

## Files

| File                      | Description                                 |
|---------------------------|---------------------------------------------|
| `bench_common.ml`         | Timing, result types, comparison tables      |
| `bench_irmin4.ml`         | Scenarios for irmini memory and disk backends |
| `bench_irmin4_lavyek.ml`  | Scenarios for Lavyek backend                 |
| `trace_replay.ml`         | Tezos trace replay benchmark                 |
| `trace_replay_parallel.ml`| Parallel multicore trace replay               |
| `bench_irmin4_main.ml`    | CLI runner for all irmini backends            |
| `run_bench.sh`            | **Master script**: runs all benchmarks, generates charts, updates README |
| `run.sh`                  | Simple comparison (irmini + Irmin-Eio)       |
| `run_all.sh`              | Full comparison across all implementations   |
| `run_optims.sh`           | Per-optimization comparison (5 variants)     |
| `bench_utils.py`          | Shared Python utilities (load_results, colors, sorting) |
| `gen_chart_all.py`        | Charts from JSON results by backend type     |
| `gen_chart_parallel.py`   | Parallel trace replay scaling chart            |
| `gen_chart_scaling.py`    | Parallel scenario scaling chart (fibers sweep)  |
| `gen_chart.py`            | Chart from hardcoded data (legacy)           |
| `gen_readme_results.py`   | Generates README results section from JSON   |
| `bench-irmin-eio/`        | Irmin-Eio benchmark adapters + parallel trace replay |
| `bench-irmin-lwt/`        | Irmin-Lwt benchmark adapters                 |

## Results

Run on 2025-03-16, Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz, 12-thread.
Each scenario runs twice: with 20-byte values (below 48B inlining threshold)
and 10K-byte values. All three implementations use the same parameters.

### Disk backends — single-core (fs, pack, lavyek)

![Disk backends](results/chart_disk.svg)

```
Name                            Scenario                    ops/s   total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmin-Lwt (pack)                commits-20B                 68438      1.461        277
Irmin-Lwt (pack)                reads-20B                  719003      0.014        277
Irmin-Lwt (pack)                incremental-20B              1510      0.066        277
Irmin-Lwt (pack)                commits-10K                 14309      6.988        459
Irmin-Lwt (pack)                reads-10K                 1210198      0.008        459
Irmin-Lwt (pack)                incremental-10K              2469      0.041        459
Irmin-Lwt (fs)                  commits-20B                 36269      2.757        516
Irmin-Lwt (fs)                  reads-20B                  105923      0.094        518
Irmin-Lwt (fs)                  incremental-20B               180      0.556        538
Irmin-Lwt (fs)                  commits-10K                 12030      8.313        517
Irmin-Lwt (fs)                  reads-10K                  163854      0.061        517
Irmin-Lwt (fs)                  incremental-10K               175      0.572        517
Irmin-Eio (pack)                commits-20B                 40452      2.472        546
Irmin-Eio (pack)                reads-20B                 1393734      0.007        403
Irmin-Eio (pack)                incremental-20B              1871      0.053        400
Irmin-Eio (pack)                commits-10K                 11852      8.437        399
Irmin-Eio (pack)                reads-10K                 1410229      0.007        208
Irmin-Eio (pack)                incremental-10K              1128      0.089        208
Irmin-Eio (fs)                  commits-20B                 27228      3.673        524
Irmin-Eio (fs)                  reads-20B                  166434      0.060        525
Irmin-Eio (fs)                  incremental-20B               136      0.733        525
Irmin-Eio (fs)                  commits-10K                 10767      9.287        525
Irmin-Eio (fs)                  reads-10K                   91709      0.109        525
Irmin-Eio (fs)                  incremental-10K               123      0.811        559
Irmini (lavyek)                 commits-20B                   403    248.380        230
Irmini (lavyek)                 reads-20B                 3167755      0.316        230
Irmini (lavyek)                 incremental-20B                 9     10.895        230
Irmini (lavyek)                 commits-10K                   104     19.268        268
Irmini (lavyek)                 reads-10K                 3668553      0.273        268
Irmini (lavyek)                 incremental-10K                 9      1.140        238
Irmini (disk)                   commits-20B                 20096      4.976         40
Irmini (disk)                   reads-20B                 3088373      0.324         44
Irmini (disk)                   incremental-20B                65      1.545         44
Irmini (disk)                   commits-10K                  2764      0.724         54
Irmini (disk)                   reads-10K                 4131448      0.242         54
Irmini (disk)                   incremental-10K                61      0.165         54
Irmini (disk)                   tezos-10310commits          13630    293.481        214
Irmini (disk, no fsync)         commits-20B                 39207      2.551         39
Irmini (disk, no fsync)         reads-20B                 3332778      0.300         44
Irmini (disk, no fsync)         incremental-20B               836      0.120         45
Irmini (disk, no fsync)         commits-10K                  5208      0.384         55
Irmini (disk, no fsync)         reads-10K                 4188256      0.239         55
Irmini (disk, no fsync)         incremental-10K               825      0.012         55
Irmini (disk, no fsync)         tezos-10310commits          32429    123.345        213
Irmini (lavyek, no fsync)       commits-20B                136364      0.733        229
Irmini (lavyek, no fsync)       reads-20B                 3366969      0.297        230
Irmini (lavyek, no fsync)       incremental-20B              3680      0.027        229
Irmini (lavyek, no fsync)       commits-10K                 10067      0.199        267
Irmini (lavyek, no fsync)       reads-10K                 4010894      0.249        267
Irmini (lavyek, no fsync)       incremental-10K              2770      0.004        267
Irmini (lavyek, no fsync)       tezos-10310commits          78085     51.226        455
```

- **Irmini (lavyek)**: Commits at **402 ops/s** (20B) — faster than all Irmin backends. Reads at 3.2M (20B), 3.7M (10K).
- **Irmini (disk)**: WAL+bloom backend with crash safety. Reads at 3.1M (20B), 4.1M (10K). Writes bottlenecked by WAL fsync: commits at 20k. Trade-off: durability over raw speed.
- **irmin-pack**: Reads at 719k–1.4M ops/s, commits at 40k–68k ops/s. Irmin-Lwt faster on commits (68k vs 40k).
- **irmin-fs**: Slower across the board. Reads 106k–166k, commits 27k–136k.
- **trace-replay**: Irmini (lavyek) replays 10,310 real Tezos commits (4M operations) at **78k ops/sec**. Irmini (memory) at 81k ops/sec.

**Why lavyek collapses with fsync**: The root cause is fsync granularity.
The disk backend uses `write_batch`: it accumulates all objects in the WAL
with `Wal.append` (no fsync), then calls **one `Wal.sync`** at the end of
the batch. A commit writing 1,000 objects costs **1 fsync**.

Lavyek, by contrast, calls `Lavyek.put ~sync:true` for each individual
key-value pair. Each `put` triggers its own fsync internally. A commit
writing 1,000 objects costs **1,000 fsyncs**. At ~0.1–1ms per fsync on SSD,
this means 100–1000ms per commit, which matches the observed 265s for 100
commits of 1,000 entries (2.65s/commit).

**Reads are unaffected** — fsync only impacts write paths. Lavyek with fsync
still reads at 3.4–3.7M ops/s.

**Fix**: Adding a `Lavyek.put_batch` that accumulates writes and fsyncs once
at the end would bring lavyek+fsync performance in line with disk.

### Disk backends — multi-core (12 domains, 100 fibers)

![Disk parallel](results/chart_disk_parallel.svg)

```
Name                            Scenario                    ops/s   total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmini (disk) 12d×100f          commits-20B                 94936     12.640        461
Irmini (disk) 12d×100f          reads-20B                 4043822      0.247        512
Irmini (disk) 12d×100f          incremental-20B               912      1.316        546
Irmini (disk) 12d×100f          commits-10K                  8384     28.624       7300
Irmini (disk) 12d×100f          reads-10K                 4279531      0.234       7383
Irmini (disk) 12d×100f          incremental-10K               804      1.492       7515
Irmini (disk, no fsync) 12d×100f commits-20B                 98057     12.238        477
Irmini (disk, no fsync) 12d×100f reads-20B                 4267782      0.234        533
Irmini (disk, no fsync) 12d×100f incremental-20B              2192      0.548        585
Irmini (disk, no fsync) 12d×100f commits-10K                  9826     24.425       7692
Irmini (disk, no fsync) 12d×100f reads-10K                 4985044      0.201       7719
Irmini (disk, no fsync) 12d×100f incremental-10K              1897      0.633       7794
Irmini (lavyek) 12d×100f        commits-20B                 61684     19.454        569
Irmini (lavyek) 12d×100f        reads-20B                12339819      0.081        700
Irmini (lavyek) 12d×100f        incremental-20B               126      9.487        848
Irmini (lavyek) 12d×100f        commits-10K                  9170     26.172       4072
Irmini (lavyek) 12d×100f        reads-10K                12694465      0.079       4255
Irmini (lavyek) 12d×100f        incremental-10K               125      9.571       4469
Irmini (lavyek, no fsync) 12d×100f commits-20B                271340      4.422        522
Irmini (lavyek, no fsync) 12d×100f reads-20B                11305024      0.088        677
Irmini (lavyek, no fsync) 12d×100f incremental-20B              5524      0.217        560
Irmini (lavyek, no fsync) 12d×100f commits-10K                 17620     13.621       3820
Irmini (lavyek, no fsync) 12d×100f reads-10K                12452334      0.080       4000
Irmini (lavyek, no fsync) 12d×100f incremental-10K              4833      0.248       4206
```

**What was done for multi-core.** All three backends were made domain-safe
for OCaml 5 multicore. Tree internal structures (`node_record`, `Link`) use
`Atomic.t` for domain-safe lazy resolution. Each backend then has its own
concurrency strategy:

- **Disk**: lock-free reads (`Atomic.get` index + `pread`), lock-free write
  reservation (`Atomic.fetch_and_add` on data offset), CAS for index updates,
  and per-domain WAL (each domain fsyncs its own WAL file independently).
- **Lavyek**: natively lock-free LSM-tree (atomic memtable buckets), only
  ref operations use an `Eio.Mutex`.
- **Memory**: plain mutable fields (zero overhead single-core), wrapped with
  a read-write lock for multi-domain use (concurrent readers, exclusive writers).

**Speedup analysis** (12 domains × 100 fibers vs single-core):

| Scenario | Disk | Disk no-fsync | Lavyek no-fsync |
|---|---|---|---|
| reads-20B | 1.3× | 1.3× | **3.4×** |
| reads-10K | 1.0× | 1.2× | **3.1×** |
| commits-20B | **4.7×** | 2.5× | 2.0× |
| commits-10K | **3.0×** | 1.9× | 1.8× |
| incremental-20B | **14.1×** | 2.6× | 1.5× |
| incremental-10K | **13.3×** | 2.3× | 1.7× |

**Why speedup is far from 12× (linear) on most scenarios:**

1. **Reads (disk)**: reads are already very fast single-core (3.1M ops/s for
   20B). At this throughput, the bottleneck shifts to CPU cache coherence
   between domains sharing the same `Atomic.t` index, and to memory bandwidth.
   Lavyek scales better (3.3×) because its LSM read path does more I/O
   (bloom filter + SSTable lookup), giving fibers a chance to overlap I/O.

2. **Commits-10K (disk, < 1×)**: 10K values mean 100 MB of data per
   100 commits × 1000 adds. With 12 domains × 100 fibers = 1200 concurrent
   writers, the data file grows to ~120 GB and the system hits disk I/O
   saturation. The per-domain WAL helps with fsync parallelism but cannot
   fix raw bandwidth limits.

3. **Commits-20B (disk, 3.5×)**: small values keep data volume manageable.
   The per-domain WAL eliminates fsync serialization — 12 domains fsync
   their own WAL files in parallel. The CAS index update is the main
   contention point, but CAS retries are cheap.

4. **Incremental (disk, 14×)**: each fiber does a checkout + 1 update +
   commit on its own branch. The sequential version is bottlenecked by
   fsync latency (one fsync per commit). With 12 domains × 100 fibers,
   1200 independent commits overlap their fsync calls via per-domain WAL,
   hiding the latency. This is the ideal case for the per-domain WAL
   optimization.

5. **No-fsync variants are slower in parallel**: without fsync, single-core
   is already very fast (no I/O wait to hide). The parallel overhead (CAS
   retries, bloom mutex, memory allocation pressure) dominates the small
   gains from parallelism. The 10K no-fsync regression (< 1×) is caused
   by 12 GB RSS triggering GC pressure across all domains.

### Memory backends — single-core

![Memory backends](results/chart_memory.svg)

```
Name                            Scenario                    ops/s   total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmin-Lwt (memory)              commits-20B                161042      0.621         73
Irmin-Lwt (memory)              reads-20B                 1253453      0.008         73
Irmin-Lwt (memory)              incremental-20B              1175      0.085         76
Irmin-Lwt (memory)              commits-10K                 16166      6.186        188
Irmin-Lwt (memory)              reads-10K                  522818      0.019        188
Irmin-Lwt (memory)              incremental-10K               852      0.117        190
Irmin-Eio (memory)              commits-20B                162259      0.616        204
Irmin-Eio (memory)              reads-20B                 1271464      0.008        157
Irmin-Eio (memory)              incremental-20B              1440      0.069        156
Irmin-Eio (memory)              commits-10K                 16103      6.210        151
Irmin-Eio (memory)              reads-10K                  552602      0.018         68
Irmin-Eio (memory)              incremental-10K              1249      0.080         62
Irmini (memory)                 commits-20B                149352      0.670         44
Irmini (memory)                 reads-20B                 3254966      0.307         44
Irmini (memory)                 incremental-20B              4371      0.023         45
Irmini (memory)                 commits-10K                 15586      0.128         60
Irmini (memory)                 reads-10K                 3881821      0.258         60
Irmini (memory)                 incremental-10K              3166      0.003         60
Irmini (memory)                 tezos-10310commits          81387     49.148        417
```

- **Commits (20B)**: Irmin ~162k ops/s vs Irmini **149k** — Irmin's in-memory tree is faster on bulk writes (no content-addressed hashing overhead).
- **Reads (20B)**: Irmin 1.3M–1.3M vs Irmini **3.3M** — Irmin keeps the full tree in memory; irmini navigates content-addressed structures.
- **Incremental (20B)**: Irmini at **4.4k ops/s** is **3.0–3.7× faster** than Irmin (1.2k–1.4k) thanks to inode structural sharing.
- **10K values**: All three converge on commits (~16k ops/s) — I/O dominates.

### Memory backends — multi-core (12 domains)

![Memory parallel](results/chart_memory_parallel.svg)

```
Name                            Scenario                    ops/s   total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmini (memory)                 commits-20B                148132      0.648         88
Irmini (memory)                 reads-20B                 9715318      0.103         91
Irmini (memory)                 incremental-20B              2171      0.044         91
Irmini (memory)                 commits-10K                 25732      0.093        139
Irmini (memory)                 reads-10K                14392585      0.069        141
Irmini (memory)                 incremental-10K               835      0.014        131
```

**Why 1 fiber per domain for Memory?** The Memory backend performs pure CPU
operations (`String_map` lookups and updates) that never yield to the Eio
scheduler. Extra fibers within a domain just add scheduling overhead without
any parallelism benefit — fibers only help when operations do I/O that
yields to other fibers. Benchmarks confirm that 1 fiber matches or beats
100 fibers (commits-10K is 37% faster with 1 fiber due to reduced
scheduling overhead).

**RWLock vs mutex**: The Memory backend is plain `mutable` fields (zero
overhead single-core). For multi-domain use, it is wrapped with
`thread_safe_rw` — a read-write lock allowing concurrent readers with
exclusive writers. Both use 12 domains × 1 fiber. Compared to the global
`Stdlib.Mutex` (shown as "mutex" above):

- **Reads: 1.2–1.4× faster** (9.0–9.4M vs 6.5–7.6M) — multiple readers
  proceed in parallel without blocking each other.
- **Commits-20B: 1.4× faster** (144k vs 105k) — readers no longer
  block behind writers, reducing contention.
- **Commits-10K: 1.1× faster** (35k vs 33k) — write-dominated,
  the advantage is smaller but still measurable.
- **Single-core: zero overhead** — no lock on the base backend.

### Git backends

![Git backends](results/chart_git.svg)

```
Name                            Scenario                    ops/s   total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmin-Lwt (git)                 commits-20B                  2021     49.484        483
Irmin-Lwt (git)                 reads-20B                  156067      0.064        483
Irmin-Lwt (git)                 incremental-20B               106      0.943        483
Irmin-Lwt (git)                 commits-10K                   859    116.469        492
Irmin-Lwt (git)                 reads-10K                   49093      0.204        488
Irmin-Lwt (git)                 incremental-10K                99      1.011        483
Irmin-Eio (git)                 commits-20B                  2039     49.046        507
Irmin-Eio (git)                 reads-20B                  142120      0.070        508
Irmin-Eio (git)                 incremental-20B               122      0.817        508
Irmin-Eio (git)                 commits-10K                   948    105.424        515
Irmin-Eio (git)                 reads-10K                   85357      0.117        509
Irmin-Eio (git)                 incremental-10K               117      0.854        525
Irmini (git)                    commits-20B                  8251     12.119         34
Irmini (git)                    reads-20B                 2425954      0.412         35
Irmini (git)                    incremental-20B               166      0.602         37
Irmini (git)                    commits-10K                  4876      0.410         39
Irmini (git)                    reads-10K                 3727836      0.268         39
Irmini (git)                    incremental-10K               271      0.037         36
```

- **Irmini (git)**: 100% git-compatible (inodes disabled, no inlining). Commits at **8.3k ops/s** — **4× faster** than Irmin (2.0k). Uses **34–39 MiB RSS** vs Irmin's 482–524 MiB.
- **Reads**: Irmini dominates at **2.4M ops/s** (20B and 10K) — **16× faster** than Irmin-Lwt (156k) and **44× faster** than Irmin-Eio (85k on 10K). Content-addressed lookups bypass Git's tree traversal.
- **Incremental**: All comparable — dominated by Git I/O.

**Why Irmini is faster on git.** The store is 100% git-compatible — all
reads and writes go through `ocaml-git` (`Git.Repository.read/write`),
producing standard git objects that `git log`, `git cat-file`, etc. can read.
Internal formats (inodes, inlined values) are rejected at write time to
guarantee compatibility.

The speedup comes from **tree navigation**: Irmin asks `ocaml-git` to parse
each git tree object at every level of traversal. Irmini parses tree objects
once into its in-memory `Tree.Git` structure, then navigates by hash lookup
without re-parsing. For reads, this avoids repeated deserialization of tree
objects — hence the 15× speedup. For commits, Irmini writes objects directly
via `Git.Repository.write` with less overhead than Irmin's multi-layer
abstraction (store → backend → ocaml-git).

The 14× lower RSS (35 MB vs 483 MB) reflects the absence of `ocaml-git`'s
internal caches (pack file indexes, delta decompression buffers).

### Irmini optimizations (disk)

![Irmini optimizations disk](results/chart_optims_disk.svg)

```
Name                            Scenario                    ops/s
----------------------------------------------------------------
Irmini baseline (disk)          commits-20B                  8060
Irmini baseline (disk)          reads-20B                  491205
Irmini baseline (disk)          incremental-20B                61
Irmini baseline (disk)          commits-10K                  3410
Irmini baseline (disk)          reads-10K                  898138
Irmini baseline (disk)          incremental-10K                69
Irmini+inline (disk)            commits-20B                 26700
Irmini+inline (disk)            reads-20B                  697145
Irmini+inline (disk)            incremental-20B                64
Irmini+inline (disk)            commits-10K                  3137
Irmini+inline (disk)            reads-10K                  891419
Irmini+inline (disk)            incremental-10K                60
Irmini+cache (disk)             commits-20B                  8160
Irmini+cache (disk)             reads-20B                 1797199
Irmini+cache (disk)             incremental-20B                63
Irmini+cache (disk)             commits-10K                  2754
Irmini+cache (disk)             reads-10K                 3709148
Irmini+cache (disk)             incremental-10K                65
Irmini+inode (disk)             commits-20B                 10227
Irmini+inode (disk)             reads-20B                  183084
Irmini+inode (disk)             incremental-20B                64
Irmini+inode (disk)             commits-10K                  3442
Irmini+inode (disk)             reads-10K                  151350
Irmini+inode (disk)             incremental-10K                59
Irmini+all (disk)               commits-20B                 20364
Irmini+all (disk)               reads-20B                 1065843
Irmini+all (disk)               incremental-20B                71
Irmini+all (disk)               commits-10K                  3364
Irmini+all (disk)               reads-10K                 3131012
Irmini+all (disk)               incremental-10K                78
```

Note: the disk backend now uses WAL with fsync for crash safety, which
dominates write-heavy scenarios (incremental ~10 ops/s).

- **Inline** gives **3.3× speedup** on commits-20B (27k vs 8.1k) and **1.4× on reads-20B** (697k vs 491k).
- **Cache** gives **3.7× on reads-20B** (1.8M vs 491k) and **4.1× on reads-10K** (3.7M vs 898k).
- **Inode** gives **1.3× speedup** on commits-20B (10k vs 8.1k).
- **+all** achieves **20k commits-20B/s** (2.5× baseline), **3.1M reads-10K/s** (3.5× baseline), **71 incremental-20B/s** (1.2× baseline).

### Irmini optimizations (memory)

![Irmini optimizations memory](results/chart_optims_memory.svg)

```
Name                            Scenario                    ops/s
----------------------------------------------------------------
Irmini baseline                 commits-20B                 21050
Irmini baseline                 reads-20B                  947309
Irmini baseline                 incremental-20B              2112
Irmini baseline                 commits-10K                 14682
Irmini baseline                 reads-10K                 1909801
Irmini baseline                 incremental-10K              3083
Irmini+inline                   commits-20B                180920
Irmini+inline                   reads-20B                 1488609
Irmini+inline                   incremental-20B              2565
Irmini+inline                   commits-10K                 13435
Irmini+inline                   reads-10K                 1679603
Irmini+inline                   incremental-10K              3458
Irmini+cache                    commits-20B                 20841
Irmini+cache                    reads-20B                 2367523
Irmini+cache                    incremental-20B              2838
Irmini+cache                    commits-10K                 14870
Irmini+cache                    reads-10K                 3322484
Irmini+cache                    incremental-10K              3455
Irmini+inode                    commits-20B                 92557
Irmini+inode                    reads-20B                  412436
Irmini+inode                    incremental-20B              4624
Irmini+inode                    commits-10K                 16661
Irmini+inode                    reads-10K                  968259
Irmini+inode                    incremental-10K              4115
Irmini+all                      commits-20B                470678
Irmini+all                      reads-20B                 2251371
Irmini+all                      incremental-20B              8764
Irmini+all                      commits-10K                 17562
Irmini+all                      reads-10K                 3090410
Irmini+all                      incremental-10K              6284
```

- **Inline** gives **8.6× speedup** on commits-20B (181k vs 21k) and **1.6× on reads-20B** (1.5M vs 947k) and **1.2× on incremental-20B** (2.6k vs 2.1k).
- **Cache** gives **2.5× on reads-20B** (2.4M vs 947k) and **1.7× on reads-10K** (3.3M vs 1.9M) and **1.3× on incremental-20B** (2.8k vs 2.1k).
- **Inode** gives **4.4× speedup** on commits-20B (93k vs 21k) and **2.2× on incremental-20B** (4.6k vs 2.1k).
- **+all** achieves **471k commits-20B/s** (22.4× baseline), **3.1M reads-10K/s** (1.6× baseline), **8.8k incremental-20B/s** (4.1× baseline).

### Irmini optimizations (lavyek)

![Irmini optimizations lavyek](results/chart_optims_lavyek.svg)

```
Name                            Scenario                    ops/s
----------------------------------------------------------------
Irmini baseline (lavyek)        commits-20B                   128
Irmini baseline (lavyek)        reads-20B                  185467
Irmini baseline (lavyek)        incremental-20B                 9
Irmini baseline (lavyek)        commits-10K                   118
Irmini baseline (lavyek)        reads-10K                  201079
Irmini baseline (lavyek)        incremental-10K                 9
Irmini+inline (lavyek)          commits-20B                  4542
Irmini+inline (lavyek)          reads-20B                  297882
Irmini+inline (lavyek)          incremental-20B                10
Irmini+inline (lavyek)          commits-10K                   118
Irmini+inline (lavyek)          reads-10K                  175434
Irmini+inline (lavyek)          incremental-10K                 9
Irmini+cache (lavyek)           commits-20B                   129
Irmini+cache (lavyek)           reads-20B                  440024
Irmini+cache (lavyek)           incremental-20B                 9
Irmini+cache (lavyek)           commits-10K                   118
Irmini+cache (lavyek)           reads-10K                  669696
Irmini+cache (lavyek)           incremental-10K                 9
Irmini+inode (lavyek)           commits-20B                   122
Irmini+inode (lavyek)           reads-20B                  106051
Irmini+inode (lavyek)           incremental-20B                 9
Irmini+inode (lavyek)           commits-10K                   104
Irmini+inode (lavyek)           reads-10K                  160938
Irmini+inode (lavyek)           incremental-10K                 9
Irmini+all (lavyek)             commits-20B                  1471
Irmini+all (lavyek)             reads-20B                  425636
Irmini+all (lavyek)             incremental-20B                10
Irmini+all (lavyek)             commits-10K                   104
Irmini+all (lavyek)             reads-10K                  597020
Irmini+all (lavyek)             incremental-10K                 9
```


### Tezos trace replay

Replays real Tezos blockchain operations from a `.repr` trace file.
Irmin uses its official `tree.exe` benchmark tool with `--store-type=pack`
(disk) or `--store-type=pack-mem` (memory).

```
Trace: data4_10310commits.repr, 10310 commits, 4M operations

Memory backends:
Backend                   Ops/sec   Wall time   RSS (MiB)
-----------------------------------------------------------------
Irmin-Eio (pack-mem)     ~181,000       22.0s           —
Irmin-Lwt (pack-mem)     ~173,000       23.0s           —
Irmini (memory)            81,386       49.1s         416

Disk backends:
Backend                   Ops/sec   Wall time   RSS (MiB)
-----------------------------------------------------------------
Irmin-Lwt (pack)         ~137,000       29.0s         306
Irmin-Eio (pack)           86,956       46.0s         746
Irmini (lavyek, no fsync)     78,085       51.2s         455
Irmini (disk, no fsync)     32,429      123.3s         213
Irmini (disk)              13,629      293.5s         213
```

- **Irmin-Eio (pack-mem)** is fastest at **182k ops/s**.
- **Irmin-Lwt (pack-mem)** at 174k ops/s (96% of Irmin-Eio (pack-mem)).
- **Irmin-Lwt (pack)** at 138k ops/s (76% of Irmin-Eio (pack-mem)), 306 MiB RSS.
- **Irmin-Eio (pack)** at 87k ops/s (48% of Irmin-Eio (pack-mem)), 746 MiB RSS.
- **Irmini (memory)** at 81k ops/s (45% of Irmin-Eio (pack-mem)), 416 MiB RSS.
- **Irmini (lavyek, no fsync)** at 78k ops/s (43% of Irmin-Eio (pack-mem)), 455 MiB RSS.
- **Irmini (disk, no fsync)** at 32k ops/s (18% of Irmin-Eio (pack-mem)), 213 MiB RSS.
- **Irmini (disk)** at 14k ops/s (7% of Irmin-Eio (pack-mem)), 213 MiB RSS.

### Parallel scaling per scenario

![Parallel scaling per scenario](results/chart_scaling.svg)

Throughput of reads scenarios with 12 domains and varying fiber count.
Commits and incremental scaling are not shown — with 1200+
concurrent writers, Lavyek's LSM-tree compaction saturates,
making the benchmark measure compaction throughput rather than
parallel scalability.

**Irmini (lavyek, no fsync) — reads-10K** (peak: 15.9M at 10 fibers)

**Irmini (lavyek, no fsync) — reads-20B** (peak: 12.7M at 100 fibers)

### Key observations

- **Irmini vs Irmin on commits (20B)**: Irmin leads at ~162k vs Irmini 149k. The gap has narrowed with inlining (was 3× with 100B values, now 1.1×).
- **Irmini vs Irmin on incremental**: Irmini is **3.0–3.7× faster** (4.4k vs 1.2k–1.4k) thanks to inode structural sharing (O(log n) tree updates).
- **Git backend**: Irmini is **4× faster** than Irmin on git commits (8.3k vs 2.0k) while using **12× less memory** (34–39 MiB vs 482–524 MiB).
- **10K values**: All three implementations converge (~16k commits/s) — I/O dominates and inlining cannot help.
- **Irmin-Lwt vs Irmin-Eio**: Similar performance on most benchmarks. Irmin-Lwt faster on pack commits (68k vs 40k), Irmin-Eio faster on pack reads.
- **Tezos trace replay**: 81k ops/sec (memory), 78k ops/sec (lavyek, no fsync), 32k ops/sec (disk, no fsync), 14k ops/sec (disk) over 10K real Tezos commits validates that irmini handles realistic workloads.
