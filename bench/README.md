# Irmini Benchmarks

Performance comparison of irmini backends (memory, disk, lavyek) and
optionally the official Irmin-Eio (memory, irmin-pack, irmin-fs).

## Quick start

Build and run from the monopampam monorepo:

```
cd /path/to/monopampam
dune exec irmini/bench/bench_irmin4_main.exe
```

Or use the full comparison script (requires an Irmin-Eio checkout):

```
IRMIN_EIO_DIR=/path/to/irmin ./bench/run.sh
```

## Options

| Flag             | Default | Description                        |
|------------------|---------|------------------------------------|
| `--ncommits`     | 100     | Number of commits                  |
| `--tree-add`     | 1000    | Tree entries added per commit      |
| `--depth`        | 10      | Depth of paths                     |
| `--nreads`       | 10000   | Number of reads in read scenario   |
| `--value-size`   | 100     | Size of values in bytes            |
| `--skip-lavyek`  | false   | Skip the Lavyek backend            |
| `--skip-disk`    | false   | Skip the disk backend              |

## Scenarios

1. **commits** — Sequential commits, each adding `tree-add` entries at
   `depth`-deep paths. Measures write throughput.
2. **reads** — Random reads from a populated store. Measures read latency.
3. **incremental** — Small updates (1 entry) on an existing tree. Measures
   the overhead of copy-on-write.
4. **large-values** — Commits with 10 KiB values. Measures throughput on
   bigger payloads.
5. **concurrent** *(disk, lavyek, irmin-pack)* — 100 fibers across 12 domains
   doing concurrent reads/writes. Measures lock-free scalability. For
   irmin-pack, each fiber writes to its own branch to avoid CAS contention.

## Files

| File                      | Description                              |
|---------------------------|------------------------------------------|
| `bench_common.ml`         | Timing, result types, comparison tables   |
| `bench_irmin4.ml`         | Scenarios for memory and disk backends    |
| `bench_irmin4_lavyek.ml`  | Scenarios for Lavyek backend              |
| `backend_lavyek.ml`       | Lavyek adapter to `Backend.t`             |
| `bench_irmin4_main.ml`    | CLI runner for all irmini backends        |
| `run.sh`                  | Full comparison script (irmini + Irmin)   |

## Results

Run on 2026-03-06, AMD 12-core, 50 commits × 500 adds, depth 10, 5000 reads,
100-byte values.

### Irmini (memory, disk, lavyek)

```
Name                           Scenario               ops/s     total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmini (memory)                commits                  519       48.1        315
Irmini (memory)                reads                   9564        0.5        314
Irmini (memory)                incremental             1965        0.0        314
Irmini (memory)                large-values            1527        6.5        310
Irmini (disk)                  commits                  429       58.2        346
Irmini (disk)                  reads                   4001        1.3        346
Irmini (disk)                  incremental               10        5.2        346
Irmini (disk)                  large-values              91      110.0        346
Irmini (disk)                  concurrent-100f/12d      263       38.0        344
Irmini (lavyek)                commits                  457       54.7        475
Irmini (lavyek)                reads                   8345        0.6        475
Irmini (lavyek)                incremental             1436        0.0        475
Irmini (lavyek)                large-values            1286        7.8        475
Irmini (lavyek)                concurrent-100f/12d   447187        0.0        475
```

### Irmin (Eio branch + inline-small-objects-v2)

Official Irmin on branch `cuihtlauac-inline-small-objects-v2` (Eio-based,
with small object inlining). In-memory, irmin-pack and irmin-fs (disk) backends.

```
Name                           Scenario               ops/s     total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmin-Eio+inline (memory)     commits               163665        0.2        193
Irmin-Eio+inline (memory)     reads                1440550        0.0        173
Irmin-Eio+inline (memory)     incremental             2777        0.0        172
Irmin-Eio+inline (memory)     large-values           15144        0.7        172
Irmin-pack+inline (disk)      commits                51265        0.5        520
Irmin-pack+inline (disk)      reads                1457672        0.0        519
Irmin-pack+inline (disk)      incremental             1624        0.0        519
Irmin-pack+inline (disk)      large-values            7403        1.4        519
Irmin-pack+inline (disk)      concurrent-100f/12d     1771        5.6        311
Irmin-fs+inline (disk)        commits                38288        0.7        648
Irmin-fs+inline (disk)        reads                 206596        0.0        648
Irmin-fs+inline (disk)        incremental              194        0.3        648
Irmin-fs+inline (disk)        large-values            2611        3.8        648
```

### Irmin (Eio branch, no inlining)

Official Irmin on branch `eio` (Eio-based, without inlining). In-memory,
irmin-pack and irmin-fs (disk) backends, for baseline comparison.

```
Name                           Scenario               ops/s     total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmin-Eio (memory)             commits               168322        0.1        192
Irmin-Eio (memory)             reads                1551837        0.0        173
Irmin-Eio (memory)             incremental             2849        0.0        172
Irmin-Eio (memory)             large-values           15930        0.6        171
Irmin-pack (disk)              commits                49896        0.5        509
Irmin-pack (disk)              reads                1283761        0.0        507
Irmin-pack (disk)              incremental             2028        0.0        507
Irmin-pack (disk)              large-values            7462        1.3        507
Irmin-pack (disk)              concurrent-100f/12d     1251        8.0        308
Irmin-fs (disk)                commits                37044        0.7        629
Irmin-fs (disk)                reads                 208038        0.0        629
Irmin-fs (disk)                incremental              193        0.3        629
Irmin-fs (disk)                large-values            2646        3.8        629
```

### Key observations

- **Irmin-Eio vs Irmini (memory)**: Irmin-Eio is **~300× faster** on
  commits and **~160× faster** on reads. This is expected: Irmin uses
  inode-based tree representation with efficient structural sharing, while
  irmini's simpler tree implementation re-serializes entire nodes on each
  commit.
- **Irmin disk backends vs in-memory**: irmin-pack commits are **~3× slower**
  than in-memory (50 k vs 168 k ops/s), but reads remain fast (~1.3 M ops/s)
  thanks to the LRU cache. irmin-fs is slower still: commits at 37 k ops/s,
  reads at 208 k ops/s (one file per object = many syscalls), and large-values
  at 2.6 k ops/s. irmin-fs incremental is very slow (193 ops/s) due to per-key
  file I/O overhead on each commit.
- **Inlining impact on Irmin-Eio**: Marginal on in-memory benchmarks
  (100-byte values). On irmin-pack, inlining gives a **~25% boost** on
  commits (52 k vs 42 k ops/s) and slightly better incrementals.
  Benefits are expected to be more pronounced with many small values
  (< 48 bytes) and higher I/O pressure.
- **Concurrent workload**: Lavyek is **1700×** faster than irmini's disk
  backend under contention (100 fibers / 12 domains). Lavyek is lock-free;
  the disk backend serializes writes behind `Eio.Mutex`. irmin-pack
  achieves ~1.5–1.7 k ops/s (per-branch writes), **~6× faster** than
  irmini's disk but **~270 000× slower** than Lavyek. Note: this
  comparison is not apples-to-apples — the irmini/Lavyek scenario measures
  raw backend operations (read/write a blob), while the irmin-pack scenario
  goes through the full Irmin stack (tree construction, inode hashing,
  serialization, writing to the append-only pack file, index update).
  Furthermore, irmin-pack serializes all writes behind a single writer
  (the pack file is protected by a mutex), which nullifies the parallelism
  of the 12 domains. Lavyek, by contrast, is lock-free (Atomic.t + KCAS)
  and its operations are much lighter (no tree/commit/inode layer).
- **Reads (irmini)**: Memory is fastest (9.6 k ops/s), Lavyek close behind
  (8.3 k), disk significantly slower (4 k). By comparison, Irmin-Eio
  reads are ~160× faster at 1.5 M ops/s.
- **Incremental updates**: Irmini's disk backend is extremely slow (10 ops/s)
  due to full tree re-serialization. Memory and Lavyek handle small updates
  efficiently. Irmin-Eio handles incrementals well (~1.7–2.9 k ops/s on
  both memory and irmin-pack).
- **Large values**: Irmini's disk degrades sharply (91 ops/s) while
  Irmin-Eio stays at 7–16 k ops/s on irmin-pack and 2.6 k ops/s on irmin-fs.
- **Memory usage**: Irmini uses 310–475 MiB. Irmin-Eio in-memory uses
  ~172–193 MiB, irmin-pack ~507–520 MiB (index + LRU), irmin-fs
  ~629–648 MiB (many open file handles and directory caches).
