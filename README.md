# Irmin 4.0

Content-addressable storage for OCaml.

## Architecture

```
┌─────────────────────────────────────────┐
│  Link API (typed, schema-driven)        │  ← User-facing, type-safe
│  - Typed paths with encode/decode       │
│  - get/set with 'a leaf accessors       │
└────────────────┬────────────────────────┘
                 │ compiles to
┌────────────────▼────────────────────────┐
│  Tree API (lazy reads, delayed writes)  │  ← Staging area
│  - Nodes loaded on-demand               │
│  - Writes accumulate until flush        │
│  - Like Git's index/staging             │
└────────────────┬────────────────────────┘
                 │ compiles to
┌────────────────▼────────────────────────┐
│  KV/Backend (raw content-addressed)     │  ← Storage
│  - read/write by hash                   │
│  - refs for mutable pointers            │
│  - Memory, Disk, Lavyek, Git backends   │
└─────────────────────────────────────────┘
```

## Design Principles

1. **One functor, used once.** The `Make` functor takes a format. Pre-instantiated as `Git` and `Mst`.
2. **One module, one concern.** Hash in `Hash`. Node encoding in `Codec`. Storage in `Backend`.
3. **Explicit is better than implicit.** No magic, no hidden state.
4. **Consistent error handling.** All fallible operations return `result`.

## Features

- **Phantom-typed hashes**: SHA-1 and SHA-256 can't be mixed
- **Lazy reads**: Nodes loaded on-demand from backend
- **Delayed writes**: Changes accumulate until flush
- **Multiple formats**: Git trees and ATProto MST
- **Subtree operations**: For monorepo workflows (replaces git subtree shelling)

## Usage

```ocaml
(* Create a memory backend *)
let backend = Irmin.Backend.Memory.create_sha1 () in
let store = Irmin.Store.Git.create ~backend in

(* Get an empty tree *)
let tree = Irmin.Store.Git.tree store () in

(* Add content - writes are delayed *)
let tree = Irmin.Tree.Git.add tree ["src"; "main.ml"] "let () = ()" in

(* Commit - this flushes the tree to backend *)
let commit = Irmin.Store.Git.commit store ~tree ~parents:[]
  ~author:"me" ~message:"init" in

(* Set branch head *)
Irmin.Store.Git.set_head store ~branch:"main" commit
```

## Backends

Backends are records of functions (not functors), making them composable:

| Backend | Storage | Persistence | Notes |
|---------|---------|-------------|-------|
| `Backend.Memory` | In-memory hash table | No | Tests, ephemeral stores |
| `Backend.Disk` | Append-only file + WAL + bloom | Yes | Crash-safe, per-write fsync |
| `Backend_lavyek` | LSM tree (WAL + SST + compaction) | Yes | High-throughput writes |
| `Git_interop` | Git loose objects + pack files | Yes | Git compatibility |

Backend combinators:

```ocaml
(* LRU cache — default 100,000 entries *)
let backend = Irmin.Backend.cached ~capacity:200_000 backend

(* Read-only wrapper *)
let backend = Irmin.Backend.readonly backend

(* Layered — reads check upper first, writes go to upper only *)
let backend = Irmin.Backend.layered ~upper ~lower
```

## Optimizations

| Optimization | Effect | Typical gain |
|-------------|--------|-------------|
| **Inline** | Small values (≤ 48B) stored in parent node | Fewer objects, less I/O |
| **Cache** | LRU cache on backend reads/writes | ~10× reads |
| **Inode** | HAMT-based tree splitting (32-way) | ~3× commits on wide dirs |

These optimizations can be combined. See [bench/README.md](bench/README.md) for
detailed performance results.

## Tree Formats

| Module | Hash | Format |
|--------|------|--------|
| `Irmin.*.Git` | SHA-1 | Git object format |
| `Irmin.*.Mst` | SHA-256 | ATProto DAG-CBOR MST |

## Module Structure

```
Irmin
├── Hash          # Phantom-typed SHA-1/SHA-256
├── Codec   # Format.S signature + Git/Mst implementations
├── Backend       # KV storage (Memory, Disk, cached, layered, readonly)
├── Tree          # Lazy tree with delayed writes + inode support
├── Commit        # Commit operations
├── Store         # High-level API (tree + commits + branches)
├── Proof         # Merkle proofs
├── Subtree       # Monorepo subtree operations
└── Git_interop   # Git repository I/O
```

## Benchmarks

See [bench/README.md](bench/README.md) for performance comparisons across backends
and optimizations, including Tezos trace replay against irmin-lwt and irmin-eio.

## References

- [Git Internals](https://git-scm.com/book/en/v2/Git-Internals-Git-Objects)
- [AT Protocol Repository Spec](https://atproto.com/specs/repository)
- [Irmin Architecture](https://irmin.org/tutorial/architecture/)
