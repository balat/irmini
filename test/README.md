# Irmini Test Suite

## Multicore Safety

Irmini is designed to be multicore-safe from the ground up. Here is a summary
of the changes made to ensure domain-safety across all components:

### Tree (`lib/tree.ml`)
- **Atomic lazy state**: `node_record` uses `Atomic.t` for lazy loading, so
  concurrent reads from multiple domains never see partially-initialised
  nodes.
- **Single-writer pattern**: concurrent reads are safe; concurrent writes to
  the *same* tree value require external synchronisation (in practice each
  fiber owns its own tree).

### Link (`lib/link.ml`)
- **Atomic state**: link values use `Atomic.t` for their internal state,
  making concurrent reads from multiple domains safe.

### Memory backend (`lib/backend.ml — Memory`)
- Backend is **plain mutable** (not inherently thread-safe).
- **`thread_safe_rw` wrapper**: provides a read-write lock — concurrent
  readers, exclusive writer. Use `Backend.thread_safe_rw (Memory.create_sha1 ())`
  for multi-domain access.
- Earlier iterations tried lock-free CAS (`Atomic.t`) directly, but the
  read-write lock gives better performance for read-heavy workloads.

### Disk backend (`lib/backend.ml — Disk`)
- **Lock-free reads**: index stored as `Atomic.t`, reads use positional
  `pread` — no lock needed.
- **Serialised writes**: WAL append protected by `Eio.Mutex`, with parallel
  `pwrite` and CAS index update.
- **Per-domain WAL**: parallel fsync across domains to avoid contention.
- **Race-safe refs**: `save_ref` handles concurrent `mkdir` safely.
- Safe for concurrent access from multiple fibers and domains without
  additional wrapping.

### Lavyek backend (`lib-lavyek/`)
- **Mutex on `test_and_set_ref`** to prevent TOCTOU races.

### Backend combinators (`lib/backend.ml`)
- **`cached`**: not thread-safe — apply *before* the thread-safety wrapper.
- **`thread_safe`**: exclusive `Stdlib.Mutex` (for non-yielding backends).
- **`thread_safe_rw`**: read-write lock (concurrent readers, exclusive
  writer, for non-yielding backends).
- **`Disk`**: already domain-safe, no wrapper needed.

---

## Test Overview

**148 tests** in the main suite, plus **33 cross-implementation tests** for
Irmin-Eio and **26 for Irmin-Lwt**.

### How to Run

```bash
# Irmini tests (from monopampam monorepo)
dune exec irmini/test/test.exe

# Run a specific test group
dune exec irmini/test/test.exe -- test -e 'Tree'
dune exec irmini/test/test.exe -- test -e 'Concurrency'

# STM tests (QCheck property-based)
# Requires pinned packages — see "STM Tests" section below
dune exec irmini/test/test_stm.exe

# Cross-implementation tests (all three)
./test/run_tests.sh

# Only Irmin-Eio or Irmin-Lwt
./test/run_tests.sh --skip-lwt --skip-irmini
./test/run_tests.sh --skip-eio --skip-irmini

# Performance regression (slow — ~10s)
dune exec irmini/test/test.exe -- test -e 'Perf'

# Update perf baselines
PERF_UPDATE_BASELINE=1 dune exec irmini/test/test.exe -- test -e 'Perf'
```

---

## Irmini Tests (148 tests)

### Tree (29 tests) — `test_tree.ml`

Basic operations:
- empty, add/find, remove, overwrite, nested

Querying:
- mem, mem_tree, list, list nested, find_tree, add_tree

Large trees:
- flat (1000), deep (50 levels), wide+deep (10k), remove half

Persistence:
- roundtrip (commit + checkout + find)

Fold:
- fold contents, fold trees, fold with `force:false` (lazy)

Concrete:
- `to_concrete` / `of_concrete` roundtrip, empty concrete

Equality:
- same, different, structural equality, empty equality

Shallow / Pruned:
- shallow tree (hash-only, re-loadable via `of_hash`)
- pruned tree (no data, no backend)

Cache:
- clear (purge + lazy reload), clear with depth

### Store (9 tests) — `test_store.ml`

- commit, branches, diff
- multiple branches, checkout
- commit chain + ancestry (`is_ancestor`, `commits_between`)
- merge base
- update branch (CAS atomic)
- diff no change

### Backend (11 tests) — `test_backend.ml`

Memory:
- read/write, refs, test_and_set

Disk:
- read/write, persistence (close + reopen), refs, write_batch

WAL recovery:
- recovery after close without flush (50 objects)
- recovery after write_batch without flush
- flush clears WAL, subsequent writes go to new WAL

### Codec (19 tests) — `test_codec.ml`

Git format (11 tests):
- empty node, add/find, add node entry, remove, list sorted
- overwrite, serialisation roundtrip, hash deterministic
- inlining, commit roundtrip, hash hex roundtrip

MST format (8 tests):
- empty node, add/find, multiple entries, remove
- serialisation roundtrip, hash deterministic
- commit roundtrip, hash hex roundtrip

### Concurrency (11 tests) — `test_concurrency.ml`

Memory backend (with `thread_safe_rw`):
- concurrent reads, concurrent read+write, concurrent refs

Disk backend (lock-free):
- concurrent reads, concurrent writes
- concurrent read+write, concurrent write_batch

Store level:
- concurrent commits (1 per domain, own branch)
- concurrent same-key updates (last writer wins)
- concurrent CAS head (exactly one wins)
- concurrent multi-commit (10 commits per domain)

### Git Interop (18 tests) — `test_git_interop.ml`

Original (3):
- init git, write/read object, write/read ref

Irmini → git (6):
- blob, tree (nested), commit chain (3 commits + `git log`)
- multi-branch, large repo (500 files), binary blob

git → Irmini (4):
- blob, nested tree, history (3 commits), multi-branch

Round-trips (5):
- irmini→git→irmini (hash match), git→irmini→git (add file)
- large nested (200 files), empty tree, diff readable by git

### Proof (7 tests) — `test_proof.ml`

- produce/verify, blinded nodes, MST proofs
- large tree proof, verify wrong path, missing key, multi access

### Inode (14 tests) — `test_inode.ml`

- empty, single entry, below/above threshold
- find all (100), find missing
- roundtrip small (10), roundtrip large (200)
- update add/remove/add+remove
- structural sharing, deterministic, large scale (1000)

### LRU (10 tests) — `test_lru.ml`

- create, add/find, add updates existing
- eviction, find promotes, capacity one
- clear, mem, eviction order, add promotes

### Hash (4 tests) — `test_hash.ml`

- sha1, sha256, roundtrip, MST depth

### Link (8 tests) — `test_link.ml`

- v/get, is_val, equal, address, pp, read/write, is_open, tree

### Commit (5 tests) — `test_commit.ml`

- fields, committer, parents, hash, serialisation

### Subtree (2 tests) — `test_subtree.ml`

- split, status

### Perf Regression (1 test) — `test_perf.ml`

Runs 5 micro-benchmarks and compares against stored baselines:
- memory-commits (100 commits × 200 adds)
- memory-reads (100k reads from 1000-entry tree)
- memory-incremental (200 single-entry updates)
- disk-commits (50 commits × 100 adds, no fsync)
- lru-throughput (500k lookups in 10k-entry cache)

Fails if any benchmark regresses more than 20% (configurable via
`PERF_THRESHOLD`). Baselines stored in `test/perf_baselines.json`,
updated with `PERF_UPDATE_BASELINE=1`.

### STM Tests — `test_stm.ml`

QCheck state-machine tests for:
- Memory backend (sequential + parallel with domain manager)
- Disk backend (sequential + parallel with Eio domain manager)
- Lavyek backend (sequential + parallel with Eio domain manager)

**Prerequisites**: STM tests require `qcheck-stm` and `qcheck-stm-eio` with
Eio support, which are not yet released on opam. Pin them from the `eio`
branch:

```bash
opam pin qcheck-stm.0.11 git+https://github.com/lyrm/multicoretests.git#eio
opam pin qcheck-stm-eio.0.11 git+https://github.com/lyrm/multicoretests.git#eio
opam pin qcheck-multicoretests-util.0.11 git+https://github.com/lyrm/multicoretests.git#eio
```

---

## Cross-Implementation Tests

These test the same scenarios against official Irmin (Lwt and Eio branches) to
verify behavioral equivalence. They must be built from the Irmin workspace due
to library name conflicts.

### Irmin-Eio (33 tests) — `test-irmin-eio/`

**Branch**: `cuihtlauac-inline-small-objects-v2`
**Backend**: `Irmin_mem` (sequential) + `irmin-pack` (concurrent)

Tree (16 tests):
- empty, add/find, remove, overwrite, nested
- mem, mem_tree, list, list nested, find_tree, add_tree
- large flat (1000), deep (50), wide+deep (10k), remove half
- persistence roundtrip

Store (10 tests):
- commit, branches, multi-commit (10), checkout, large tree (500)
- multiple branches, commit chain + ancestry, LCA, diff, diff no change

Concurrent — irmin-pack (7 tests):
- concurrent reads, read+write, writes, refs
- concurrent multi-commit (10 per domain)
- concurrent same-key updates (20 writes per domain)
- concurrent commits simple (1 per domain)

**Semantic differences from Irmini**:
- `mem_tree` on a contents leaf returns `true` in Irmin (contents are
  trivial trees), `false` in Irmini.
- Irmin's `set_tree_exn` has bounded CAS retries (13 attempts), so
  concurrent writes to the *same* branch fail under high contention.
  Each concurrent test uses per-domain branches.

### Irmin-Lwt (26 tests) — `test-irmin-lwt/`

**Branch**: `main`
**Backend**: `Irmin_mem`
**No multicore tests** (Lwt is single-threaded).

Tree (16 tests): same scenarios as Irmin-Eio (with `Lwt.t` monad).

Store (10 tests): same scenarios as Irmin-Eio (with `Lwt.t` monad).

---

## What Is Not Tested (and Why)

### Not transposable from Irmin

These Irmin features have no equivalent in Irmini's API:

| Irmin feature | Reason |
|---|---|
| **Merge** (3-way merge) | Irmini has no merge operation |
| **Watches** (reactive notifications) | Not implemented |
| **Slice** (export/import) | Not implemented |
| **Graph iteration** | No graph API |
| **Store cloning** | No clone API |
| **GC / multi-volume** | irmin-pack specific |
| **Snapshots** | irmin-pack specific |
| **Store upgrades** | irmin-pack specific |

### Not tested in Irmin-Eio / Irmin-Lwt

These are Irmini-specific internals with no Irmin equivalent:

| Irmini test | Reason |
|---|---|
| Backend (11 tests) | Record-based backend API is Irmini-specific |
| Codec (19 tests) | Internal serialisation format |
| Hash (4 tests) | Internal hash module |
| Link (8 tests) | Internal lazy link module |
| Inode (14 tests) | Internal structural sharing |
| LRU (10 tests) | Internal cache module |
| Proof (7 tests) | Irmini proof implementation |
| Git interop (18 tests) | Irmini's custom git backend |
| Commit (5 tests) | Internal commit module |
| Subtree (2 tests) | Internal subtree module |
| Perf regression (1 test) | Irmini-specific benchmarks |
| STM (3 suites) | Irmini backend-specific |
| Concurrent CAS head | Irmin has no explicit CAS on branches |
| Concurrent write_batch | Irmin has no write_batch API |
