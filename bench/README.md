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

### Irmin (Eio branch + inline-small-objects-v2, in-memory)

Official Irmin on branch `cuihtlauac-inline-small-objects-v2` (Eio-based,
with small object inlining). In-memory backend only.

```
Name                           Scenario               ops/s     total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmin-Eio+inline (memory)     commits               169489        0.1        167
Irmin-Eio+inline (memory)     reads                1583234        0.0        149
Irmin-Eio+inline (memory)     incremental             2771        0.0        148
Irmin-Eio+inline (memory)     large-values           16188        0.6        147
```

### Irmin (Eio branch, no inlining, in-memory)

Official Irmin on branch `eio` (Eio-based, without inlining). In-memory
backend only, for baseline comparison.

```
Name                           Scenario               ops/s     total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmin-Eio (memory)             commits               169262        0.1        170
Irmin-Eio (memory)             reads                1534689        0.0        152
Irmin-Eio (memory)             incremental             2809        0.0        151
Irmin-Eio (memory)             large-values           15687        0.6        150
```

### Key observations

- **Irmin-Eio vs Irmini (memory)**: Irmin-Eio is **~300× faster** on
  commits and **~160× faster** on reads. This is expected: Irmin uses
  inode-based tree representation with efficient structural sharing, while
  irmini's simpler tree implementation re-serializes entire nodes on each
  commit.
- **Inlining impact on Irmin-Eio**: Marginal on these benchmarks (100-byte
  values, in-memory backend). Inlining benefits show up on disk I/O-bound
  workloads with many small values (< 48 bytes).
- **Concurrent workload**: Lavyek is **1700×** faster than irmini's disk
  backend under contention (100 fibers / 12 domains). Lavyek is lock-free;
  the disk backend serializes writes behind `Eio.Mutex`.
- **Reads (irmini)**: Memory is fastest (9.6 k ops/s), Lavyek close behind
  (8.3 k), disk significantly slower (4 k).
- **Incremental updates**: Irmini's disk backend is extremely slow (10 ops/s)
  due to full tree re-serialization. Memory and Lavyek handle small updates
  efficiently. Irmin-Eio handles incrementals well (~2.8 k ops/s).
- **Large values**: Irmini's disk degrades sharply (91 ops/s) while
  Irmin-Eio stays at 16 k ops/s.
- **Memory usage**: Irmini uses more RSS (310–475 MiB) than Irmin-Eio
  (147–170 MiB), reflecting the less efficient tree representation.
