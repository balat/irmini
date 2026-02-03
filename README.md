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
│  - Memory, Git, Pack implementations    │
└─────────────────────────────────────────┘
```

## Design Principles

1. **One functor, used once.** The `Make` functor takes a format. Pre-instantiated as `Git` and `Mst`.
2. **One module, one concern.** Hash in `Hash`. Node encoding in `Tree_format`. Storage in `Backend`.
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

## Tree Formats

| Module | Hash | Format |
|--------|------|--------|
| `Irmin.*.Git` | SHA-1 | Git object format |
| `Irmin.*.Mst` | SHA-256 | ATProto DAG-CBOR MST |

## Module Structure

```
Irmin
├── Hash          # Phantom-typed SHA-1/SHA-256
├── Tree_format   # Format.S signature + Git/Mst implementations
├── Backend       # KV storage (Memory, Git, layered, cached)
├── Tree          # Lazy tree with delayed writes
├── Commit        # Commit operations
├── Store         # High-level API (tree + commits + branches)
├── Subtree       # Monorepo subtree operations
└── Git_interop   # Git repository I/O
```

## References

- [Git Internals](https://git-scm.com/book/en/v2/Git-Internals-Git-Objects)
- [AT Protocol Repository Spec](https://atproto.com/specs/repository)
- [Irmin Architecture](https://irmin.org/tutorial/architecture/)
