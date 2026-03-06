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

```
Name                           Scenario               ops/s     total(s)   RSS(MiB)
----------------------------------------------------------------------------------
Irmin4 (memory)                commits                  519       48.1        315
Irmin4 (memory)                reads                   9564        0.5        314
Irmin4 (memory)                incremental             1965        0.0        314
Irmin4 (memory)                large-values            1527        6.5        310
Irmin4 (disk)                  commits                  429       58.2        346
Irmin4 (disk)                  reads                   4001        1.3        346
Irmin4 (disk)                  incremental               10        5.2        346
Irmin4 (disk)                  large-values              91      110.0        346
Irmin4 (disk)                  concurrent-100f/12d      263       38.0        344
Irmin4 (lavyek)                commits                  457       54.7        475
Irmin4 (lavyek)                reads                   8345        0.6        475
Irmin4 (lavyek)                incremental             1436        0.0        475
Irmin4 (lavyek)                large-values            1286        7.8        475
Irmin4 (lavyek)                concurrent-100f/12d   447187        0.0        475
```

### Key observations

- **Concurrent workload**: Lavyek is **1700×** faster than disk under
  contention (100 fibers / 12 domains). Lavyek is lock-free; the disk
  backend serializes writes behind `Eio.Mutex`.
- **Reads**: Memory is fastest (9.6 k ops/s), Lavyek close behind (8.3 k),
  disk significantly slower (4 k).
- **Commits**: All three backends are in the same ballpark (430–520 ops/s);
  the bottleneck is tree hashing, not I/O.
- **Incremental updates**: Disk is extremely slow (10 ops/s) due to full
  tree re-serialization. Memory and Lavyek handle small updates efficiently.
- **Large values**: Disk degrades sharply (91 ops/s) while memory (1.5 k)
  and Lavyek (1.3 k) remain performant.
- **Memory usage**: Lavyek uses more RSS (475 MiB) due to its internal
  LSM-tree structures.
