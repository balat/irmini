# Irmini Benchmarks

Performance comparison of irmini backends (memory, disk, lavyek) and
optionally the official Irmin-Eio (memory, irmin-pack).

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
5. **concurrent** *(disk and lavyek only)* — 100 fibers across 12 domains
   doing concurrent reads/writes. Measures lock-free scalability.

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
with small object inlining). In-memory and irmin-pack (disk) backends.

```
Name                           Scenario               ops/s     total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmin-Eio+inline (memory)     commits               167387        0.1        191
Irmin-Eio+inline (memory)     reads                1626582        0.0        172
Irmin-Eio+inline (memory)     incremental             2896        0.0        171
Irmin-Eio+inline (memory)     large-values           16053        0.6        170
Irmin-pack+inline (disk)      commits                52114        0.5        411
Irmin-pack+inline (disk)      reads                1351345        0.0        392
Irmin-pack+inline (disk)      incremental             1974        0.0        392
Irmin-pack+inline (disk)      large-values            8950        1.1        392
```

### Irmin (Eio branch, no inlining)

Official Irmin on branch `eio` (Eio-based, without inlining). In-memory
and irmin-pack (disk) backends, for baseline comparison.

```
Name                           Scenario               ops/s     total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmin-Eio (memory)             commits               167735        0.1        191
Irmin-Eio (memory)             reads                1528648        0.0        172
Irmin-Eio (memory)             incremental             2721        0.0        171
Irmin-Eio (memory)             large-values           15408        0.6        170
Irmin-pack (disk)              commits                41507        0.6        410
Irmin-pack (disk)              reads                1570312        0.0        390
Irmin-pack (disk)              incremental             1725        0.0        390
Irmin-pack (disk)              large-values            8702        1.1        390
```

### Key observations

- **Irmin-Eio vs Irmini (memory)**: Irmin-Eio is **~300× faster** on
  commits and **~160× faster** on reads. This is expected: Irmin uses
  inode-based tree representation with efficient structural sharing, while
  irmini's simpler tree implementation re-serializes entire nodes on each
  commit.
- **Irmin-pack (disk) vs Irmin-Eio (memory)**: irmin-pack commits are
  **~4× slower** than in-memory (42–52 k vs 167 k ops/s), but reads are
  equally fast (~1.5 M ops/s) thanks to the LRU cache. Large-values
  throughput drops ~2× on disk (8.7–9.0 k vs 15–16 k ops/s).
- **Inlining impact on Irmin-Eio**: Marginal on in-memory benchmarks
  (100-byte values). On irmin-pack, inlining gives a **~25% boost** on
  commits (52 k vs 42 k ops/s) and slightly better incrementals.
  Benefits are expected to be more pronounced with many small values
  (< 48 bytes) and higher I/O pressure.
- **Concurrent workload**: Lavyek is **1700×** faster than irmini's disk
  backend under contention (100 fibers / 12 domains). Lavyek is lock-free;
  the disk backend serializes writes behind `Eio.Mutex`.
- **Reads (irmini)**: Memory is fastest (9.6 k ops/s), Lavyek close behind
  (8.3 k), disk significantly slower (4 k). By comparison, Irmin-Eio
  reads are ~160× faster at 1.5 M ops/s.
- **Incremental updates**: Irmini's disk backend is extremely slow (10 ops/s)
  due to full tree re-serialization. Memory and Lavyek handle small updates
  efficiently. Irmin-Eio handles incrementals well (~1.7–2.9 k ops/s on
  both memory and irmin-pack).
- **Large values**: Irmini's disk degrades sharply (91 ops/s) while
  Irmin-Eio stays at 9–16 k ops/s across backends.
- **Memory usage**: Irmini uses more RSS (310–475 MiB) than Irmin-Eio
  (170–411 MiB). irmin-pack uses ~390–411 MiB due to the index and LRU.
