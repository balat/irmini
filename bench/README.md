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
| **LRU cache** — O(1) doubly-linked-list cache at backend level, avoids repeated deserialization | `b6e855f`, `1421b0a`, `17622d1` | reads-20B: **1.4×** (disk) |
| **Resolved-child cache** — Hashtbl cache in tree navigation, avoids re-traversing already-resolved subtrees | `cf1fda2`, `1a09cb4` | reads: measurable improvement on deep trees |
| **Write batching** — `Store.commit` accumulates all objects in a pending list, writes them in a single `write_batch` call | `b1b2e73` | disk: **1 fsync per commit** instead of per object |
| **Dirty check** — skip unmodified subtrees in `write_tree` | `30eeaae` | incremental: avoids re-serializing unchanged nodes |
| **Map/Set children** — replace list-based tree children with `Map`/`Set` for O(log n) lookups | `59de7b3` | tree operations faster on wide nodes |

### Disk backend — single-core

| Optimization | Commit | Impact |
|---|---|---|
| **Lock-free reads** — `Atomic.get` on index + positional `pread`, zero locks | `35fbbf5` | reads: **5–10×** faster in parallel, zero overhead single-core |
| **Lock-free writes** — `Atomic.fetch_and_add` for offset reservation, parallel `pwrite`, CAS index updates | `35fbbf5` | enables true multi-core write parallelism |
| **Per-domain WAL** — each domain gets its own WAL file, eliminating the single `wal_mutex` bottleneck | `9789a4f` | parallel fsync no longer serialized across domains |
| **O_APPEND fix** — remove `O_APPEND` flag that caused `pwrite` to ignore offsets on Linux | `2e6d020` | fixed data corruption in no-fsync mode |
| **Configurable fsync** — `?use_fsync` parameter to disable WAL fsync for benchmarking | `fd4f2e3` | no-fsync: commits-20B **2.5×** faster |

### Multi-core safety (all backends)

| Fix | Commit | Scope |
|---|---|---|
| **Tree `node_record` domain-safe** — `Atomic.t` for mutable tree node fields | `3ef3eb1` | All backends |
| **Link domain-safe** — `Atomic.t` for link resolution cache | `308110b` | All backends |
| **Memory read-write lock** — concurrent readers, exclusive writers (replaces global mutex) | `6e1738c` | Memory |
| **Lavyek ref mutex** — protect `test_and_set_ref` against TOCTOU race | `6d4a0bc` | Lavyek |
| **save_ref mkdirs** — `mkdirs ~exists_ok:true` to handle concurrent `mkdir` | `e0e16bb` | Disk |

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

Run on 2025-03-14, AMD Ryzen 9 7950X, 32-core, 100 commits x 1000 adds, depth 10, 1000000 reads.
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
Irmini (disk)                   commits-20B                 24954      4.007         40
Irmini (disk)                   reads-20B                 3160218      0.316         48
Irmini (disk)                   incremental-20B                73      1.376         46
Irmini (disk)                   commits-10K                  4511     22.169         97
Irmini (disk)                   reads-10K                 3079794      0.325        110
Irmini (disk)                   incremental-10K                69      1.450        110
Irmini (disk)                   tezos-10310commits          13410    298.285       9751
Irmini (disk, no fsync)         commits-20B                 93321      1.072        445
Irmini (disk, no fsync)         reads-20B                 3155121      0.317        453
Irmini (disk, no fsync)         incremental-20B               613      0.163        441
Irmini (disk, no fsync)         commits-10K                 12436      8.041      10738
Irmini (disk, no fsync)         reads-10K                 2680275      0.373      10012
Irmini (disk, no fsync)         incremental-10K               544      0.184      10023
Irmini (disk, no fsync)         tezos-10310commits          32784    122.011       9751
Irmini (lavyek, fsync)          commits-20B                   376    265.860        284
Irmini (lavyek, fsync)          reads-20B                 3661705      0.273        284
Irmini (lavyek, fsync)          incremental-20B                 9     10.823        279
Irmini (lavyek, fsync)          commits-10K                    83   1206.079        362
Irmini (lavyek, fsync)          reads-10K                 3422723      0.292        342
Irmini (lavyek, fsync)          incremental-10K                 6     15.739        279
Irmini (lavyek, no fsync)       commits-20B                136840      0.731        654
Irmini (lavyek, no fsync)       reads-20B                 3476097      0.288        517
Irmini (lavyek, no fsync)       incremental-20B              3362      0.030        532
Irmini (lavyek, no fsync)       commits-10K                  8137     12.290      11618
Irmini (lavyek, no fsync)       reads-10K                 3179013      0.315      11601
Irmini (lavyek, no fsync)       incremental-10K               645      0.155      11790
Irmini (lavyek, no fsync)       tezos-10310commits         135035     29.622        714
```

- **Irmini (disk)**: WAL+bloom backend with crash safety. Reads at 3.2M (20B), 3.1M (10K). Writes bottlenecked by WAL fsync: commits at 25k. Trade-off: durability over raw speed.
- **irmin-pack**: Reads at 719k–1.4M ops/s, commits at 40k–68k ops/s. Irmin-Lwt faster on commits (68k vs 40k).
- **irmin-fs**: Slower across the board. Reads 106k–166k, commits 376–190k.
- **trace-replay**: Irmini (lavyek) replays 10,310 real Tezos commits (4M operations) at **135k ops/sec**. Irmini (memory) at 142k ops/sec.

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
Irmin-Eio (pack) 12d×1f         tezos-10310commits         205337     19.500          0
Irmini (disk) 12d×100f          commits-20B                 86210     13.920        491
Irmini (disk) 12d×100f          reads-20B                 4445372      0.225        607
Irmini (disk) 12d×100f          incremental-20B              1010      1.188        563
Irmini (disk) 12d×100f          commits-10K                  1577    760.725      12147
Irmini (disk) 12d×100f          reads-10K                 2604685      0.384      10048
Irmini (disk) 12d×100f          incremental-10K               979      1.226       9957
Irmini (disk, no fsync) 12d×100f commits-20B                 98595     12.171        460
Irmini (disk, no fsync) 12d×100f reads-20B                 4133978      0.242        560
Irmini (disk, no fsync) 12d×100f incremental-20B              2237      0.537        508
Irmini (disk, no fsync) 12d×100f commits-10K                  1560    769.052      12823
Irmini (disk, no fsync) 12d×100f reads-10K                 1347898      0.742      11321
Irmini (disk, no fsync) 12d×100f incremental-10K              2125      0.565      11323
Irmini (lavyek, no fsync) 12d×100f commits-20B                246195      4.874        511
Irmini (lavyek, no fsync) 12d×100f reads-20B                11538873      0.087        512
Irmini (lavyek, no fsync) 12d×100f incremental-20B              5557      0.216        532
Irmini (lavyek, no fsync) 12d×100f commits-10K                  6459    185.796      11456
Irmini (lavyek, no fsync) 12d×100f reads-10K                 6762508      0.148      11635
Irmini (lavyek, no fsync) 12d×100f incremental-10K               899      1.335      11649
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
| reads-20B | 1.4× | 1.3× | **3.3×** |
| reads-10K | 0.8× | 0.5× | 2.1× |
| commits-20B | **3.5×** | 1.1× | 1.8× |
| commits-10K | 0.3× | 0.1× | 0.8× |
| incremental-20B | **13.8×** | **3.6×** | 1.7× |
| incremental-10K | **14.2×** | **3.9×** | 1.4× |

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
Irmini (memory)                 commits-20B                154615      0.647         81
Irmini (memory)                 reads-20B                 3569311      0.280         84
Irmini (memory)                 incremental-20B              4649      0.022         86
Irmini (memory)                 commits-10K                 15832      6.316        250
Irmini (memory)                 reads-10K                 3209211      0.312        253
Irmini (memory)                 incremental-10K              3527      0.028        246
Irmini (memory)                 tezos-10310commits         142217     28.126        586
```

- **Commits (20B)**: Irmin ~162k ops/s vs Irmini **155k** — Irmin's in-memory tree is faster on bulk writes (no content-addressed hashing overhead).
- **Reads (20B)**: Irmin 1.3M–1.3M vs Irmini **3.6M** — Irmin keeps the full tree in memory; irmini navigates content-addressed structures.
- **Incremental (20B)**: Irmini at **4.6k ops/s** is **3.2–4.0× faster** than Irmin (1.2k–1.4k) thanks to inode structural sharing.
- **10K values**: All three converge on commits (~16k ops/s) — I/O dominates.

### Memory backends — multi-core (12 domains)

![Memory parallel](results/chart_memory_parallel.svg)

```
Name                            Scenario                    ops/s   total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmini (memory, mutex)          commits-20B                105316      0.912         83
Irmini (memory, mutex)          reads-20B                 7646567      0.131         86
Irmini (memory, mutex)          incremental-20B              1817      0.053         89
Irmini (memory, mutex)          commits-10K                 32702      2.936        445
Irmini (memory, mutex)          reads-10K                 6481267      0.154        263
Irmini (memory, mutex)          incremental-10K              1912      0.050        264
Irmini (memory)                 commits-20B                143592      0.669         81
Irmini (memory)                 reads-20B                 9391912      0.106         84
Irmini (memory)                 incremental-20B              2129      0.045         86
Irmini (memory)                 commits-10K                 34566      2.777        476
Irmini (memory)                 reads-10K                 9024999      0.111        253
Irmini (memory)                 incremental-10K              2202      0.044        254
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
Irmini (git)                    commits-20B                  8514     11.746        131
Irmini (git)                    reads-20B                 1427751      0.007        107
Irmini (git)                    incremental-20B               321      0.311        106
Irmini (git)                    commits-10K                  5591     17.887        104
Irmini (git)                    reads-10K                 1381796      0.007         64
Irmini (git)                    incremental-10K               265      0.377         49
```

- **Irmini (git)**: 100% git-compatible (inodes disabled, no inlining). Commits at **8.5k ops/s** — **4× faster** than Irmin (2.0k). Uses **49–131 MiB RSS** vs Irmin's 482–524 MiB.
- **Reads**: Irmini dominates at **1.4M ops/s** (20B and 10K) — **9× faster** than Irmin-Lwt (156k) and **16× faster** than Irmin-Eio (85k on 10K). Content-addressed lookups bypass Git's tree traversal.
- **Incremental**: All comparable — dominated by Git I/O.

### Irmini optimizations (disk)

![Irmini optimizations disk](results/chart_optims_disk.svg)

```
Name                            Scenario                    ops/s
----------------------------------------------------------------
Irmini baseline (disk)          commits-20B                 12233
Irmini baseline (disk)          reads-20B                  401992
Irmini baseline (disk)          incremental-20B                66
Irmini baseline (disk)          commits-10K                  8121
Irmini baseline (disk)          reads-10K                 1301447
Irmini baseline (disk)          incremental-10K                88
Irmini+inline (disk)            commits-20B                 26940
Irmini+inline (disk)            reads-20B                 1218283
Irmini+inline (disk)            incremental-20B                76
Irmini+inline (disk)            commits-10K                  8162
Irmini+inline (disk)            reads-10K                 1814302
Irmini+inline (disk)            incremental-10K                67
Irmini+cache (disk)             commits-20B                 12253
Irmini+cache (disk)             reads-20B                  553894
Irmini+cache (disk)             incremental-20B                67
Irmini+cache (disk)             commits-10K                  8234
Irmini+cache (disk)             reads-10K                 1000645
Irmini+cache (disk)             incremental-10K                67
Irmini+inode (disk)             commits-20B                 19604
Irmini+inode (disk)             reads-20B                  952212
Irmini+inode (disk)             incremental-20B                74
Irmini+inode (disk)             commits-10K                 10729
Irmini+inode (disk)             reads-10K                 1475828
Irmini+inode (disk)             incremental-10K                74
Irmini+all (disk)               commits-20B                 21267
Irmini+all (disk)               reads-20B                 1691524
Irmini+all (disk)               incremental-20B                79
Irmini+all (disk)               commits-10K                 11211
Irmini+all (disk)               reads-10K                  396857
Irmini+all (disk)               incremental-10K                69
```

Note: the disk backend now uses WAL with fsync for crash safety, which
dominates write-heavy scenarios (incremental ~10 ops/s).

- **Inline** gives **2.2× speedup** on commits-20B (27k vs 12k) and **3.0× on reads-20B** (1.2M vs 402k) and **1.4× on reads-10K** (1.8M vs 1.3M).
- **Cache** gives **1.4× on reads-20B** (554k vs 402k).
- **Inode** gives **1.6× speedup** on commits-20B (20k vs 12k) and **2.4× on reads-20B** (952k vs 402k).
- **+all** achieves **21k commits-20B/s** (1.7× baseline), **397k reads-10K/s** (0.3× baseline), **78 incremental-20B/s** (1.2× baseline).

### Irmini optimizations (memory)

![Irmini optimizations memory](results/chart_optims_memory.svg)

```
Name                            Scenario                    ops/s
----------------------------------------------------------------
Irmini baseline                 commits-20B                 21081
Irmini baseline                 reads-20B                 1893933
Irmini baseline                 incremental-20B              3104
Irmini baseline                 commits-10K                 10976
Irmini baseline                 reads-10K                 1903906
Irmini baseline                 incremental-10K              2708
Irmini+inline                   commits-20B                191405
Irmini+inline                   reads-20B                 1112370
Irmini+inline                   incremental-20B              3877
Irmini+inline                   commits-10K                 10944
Irmini+inline                   reads-10K                 1918536
Irmini+inline                   incremental-10K              2543
Irmini+cache                    commits-20B                 20845
Irmini+cache                    reads-20B                 1848362
Irmini+cache                    incremental-20B              3242
Irmini+cache                    commits-10K                 10770
Irmini+cache                    reads-10K                 1826151
Irmini+cache                    incremental-10K              2649
Irmini+inode                    commits-20B                 84430
Irmini+inode                    reads-20B                 1379342
Irmini+inode                    incremental-20B              7360
Irmini+inode                    commits-10K                 16996
Irmini+inode                    reads-10K                 1373650
Irmini+inode                    incremental-10K              5297
Irmini+all                      commits-20B                465620
Irmini+all                      reads-20B                 1703617
Irmini+all                      incremental-20B              7942
Irmini+all                      commits-10K                 17395
Irmini+all                      reads-10K                 1405692
Irmini+all                      incremental-10K              5163
```

- **Inline** gives **9.1× speedup** on commits-20B (191k vs 21k) and **1.2× on incremental-20B** (3.9k vs 3.1k).
- **Inode** gives **4.0× speedup** on commits-20B (84k vs 21k) and **2.4× on incremental-20B** (7.4k vs 3.1k).
- **+all** achieves **466k commits-20B/s** (22.1× baseline), **1.4M reads-10K/s** (0.7× baseline), **7.9k incremental-20B/s** (2.6× baseline).

### Irmini optimizations (lavyek)

![Irmini optimizations lavyek](results/chart_optims_lavyek.svg)

```
Name                            Scenario                    ops/s
----------------------------------------------------------------
Irmini baseline (lavyek)        commits-20B                 20048
Irmini baseline (lavyek)        reads-20B                 1774991
Irmini baseline (lavyek)        incremental-20B              2230
Irmini baseline (lavyek)        commits-10K                  7157
Irmini baseline (lavyek)        reads-10K                 1931257
Irmini baseline (lavyek)        incremental-10K              1520
Irmini+inline (lavyek)          commits-20B                177907
Irmini+inline (lavyek)          reads-20B                 1279766
Irmini+inline (lavyek)          incremental-20B              2442
Irmini+inline (lavyek)          commits-10K                  7115
Irmini+inline (lavyek)          reads-10K                 1950839
Irmini+inline (lavyek)          incremental-10K              1575
Irmini+cache (lavyek)           commits-20B                 19796
Irmini+cache (lavyek)           reads-20B                 1602592
Irmini+cache (lavyek)           incremental-20B              2218
Irmini+cache (lavyek)           commits-10K                  7304
Irmini+cache (lavyek)           reads-10K                 1754352
Irmini+cache (lavyek)           incremental-10K              1448
Irmini+inode (lavyek)           commits-20B                 80225
Irmini+inode (lavyek)           reads-20B                 1507441
Irmini+inode (lavyek)           incremental-20B              5374
Irmini+inode (lavyek)           commits-10K                  9798
Irmini+inode (lavyek)           reads-10K                 1538065
Irmini+inode (lavyek)           incremental-10K              3533
Irmini+all (lavyek)             commits-20B                360844
Irmini+all (lavyek)             reads-20B                 1687441
Irmini+all (lavyek)             incremental-20B              5756
Irmini+all (lavyek)             commits-10K                  9491
Irmini+all (lavyek)             reads-10K                 1387280
Irmini+all (lavyek)             incremental-10K              3288
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
Irmini (memory)          ~142,000       28.1s         585
Irmin-Lwt (pack-mem)     ~130,000       30.6s           —
Irmin-Eio (pack-mem)       83,160       48.1s           —

Disk backends:
Backend                   Ops/sec   Wall time   RSS (MiB)
-----------------------------------------------------------------
Irmin-Lwt (pack)         ~135,000       29.6s         306
Irmini (lavyek, no fsync)   ~135,000       29.6s         713
Irmin-Eio (pack)           83,022       48.2s         746
Irmini (disk, no fsync)     32,783      122.0s        9751
Irmini (disk)              13,410      298.3s        9751
```

- **Irmini (memory)** is fastest at **142k ops/s**.
- **Irmin-Lwt (pack)** at 135k ops/s (95% of Irmini (memory)), 306 MiB RSS.
- **Irmini (lavyek, no fsync)** at 135k ops/s (95% of Irmini (memory)), 713 MiB RSS.
- **Irmin-Lwt (pack-mem)** at 131k ops/s (92% of Irmini (memory)).
- **Irmin-Eio (pack-mem)** at 83k ops/s (58% of Irmini (memory)).
- **Irmin-Eio (pack)** at 83k ops/s (58% of Irmini (memory)), 746 MiB RSS.
- **Irmini (disk, no fsync)** at 33k ops/s (23% of Irmini (memory)), 9751 MiB RSS.
- **Irmini (disk)** at 13k ops/s (9% of Irmini (memory)), 9751 MiB RSS.

### Parallel scaling per scenario

![Parallel scaling per scenario](results/chart_scaling.svg)

Throughput of commits, reads, and incremental scenarios with 12 domains and varying fiber count.

**Irmini (lavyek, no fsync) — commits-10K** (peak: 20k at 120 fibers)

**Irmini (lavyek, no fsync) — commits-20B** (peak: 277k at 1200 fibers)

**Irmini (lavyek, no fsync) — incremental-10K** (peak: 4.4k at 12000 fibers)

**Irmini (lavyek, no fsync) — incremental-20B** (peak: 6.2k at 12000 fibers)

**Irmini (lavyek, no fsync) — reads-10K** (peak: 10.3M at 600 fibers)

**Irmini (lavyek, no fsync) — reads-20B** (peak: 12.2M at 600 fibers)

### Key observations

- **Irmini vs Irmin on commits (20B)**: Irmin leads at ~162k vs Irmini 155k. The gap has narrowed with inlining (was 3× with 100B values, now 1.0×).
- **Irmini vs Irmin on incremental**: Irmini is **3.2–4.0× faster** (4.6k vs 1.2k–1.4k) thanks to inode structural sharing (O(log n) tree updates).
- **Git backend**: Irmini is **4× faster** than Irmin on git commits (8.5k vs 2.0k) while using **4× less memory** (49–131 MiB vs 482–524 MiB).
- **10K values**: All three implementations converge (~16k commits/s) — I/O dominates and inlining cannot help.
- **Irmin-Lwt vs Irmin-Eio**: Similar performance on most benchmarks. Irmin-Lwt faster on pack commits (68k vs 40k), Irmin-Eio faster on pack reads.
- **Tezos trace replay**: 142k ops/sec (memory), 135k ops/sec (lavyek, no fsync), 33k ops/sec (disk, no fsync), 13k ops/sec (disk) over 10K real Tezos commits validates that irmini handles realistic workloads.
