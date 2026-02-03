# irmin

Content-addressable storage for OCaml.

## Overview

Irmin provides lazy reads, delayed writes, and multiple tree formats with
bidirectional Git compatibility. One functor, used once.

## Design Principles

1. **One functor, used once.** The `Make` functor takes a format. Pre-instantiated as `Git` and `Mst`.
2. **One module, one concern.** Hash operations in `Hash`. Node encoding in `Format`. Storage in `Backend`.
3. **Explicit is better than implicit.** No magic, no hidden state.
4. **Consistent error handling.** All fallible operations return `result`.

## Features

- **Phantom-typed hashes**: SHA-1 and SHA-256 can't be mixed
- **Lazy reads**: Nodes loaded on-demand from backend
- **Delayed writes**: Changes accumulate until flush
- **Multiple formats**: Git trees and ATProto MST
- **Typed paths**: Schema module for type-safe tree access

## Installation

```
opam install irmin
```

## Usage

```ocaml
(* Open a Git repository *)
let backend = Irmin.Backend.git (fs / "myrepo") in
let tree = Irmin.Git.Tree.empty backend in

(* Add content - writes are delayed *)
let tree = Irmin.Git.Tree.add tree ["src"; "main.ml"] "let () = ()" in

(* Flush to backend and get root hash *)
let root = Irmin.Git.Tree.flush tree in

(* Create a commit *)
let _commit = Irmin.Git.commit backend
  ~tree:root
  ~parents:[]
  ~author:"me"
  ~message:"init"
```

## Tree Formats

| Module | Hash | Format |
|--------|------|--------|
| `Irmin.Git` | SHA-1 | Git object format |
| `Irmin.Mst` | SHA-256 | ATProto DAG-CBOR MST |

## References

- [Git Internals](https://git-scm.com/book/en/v2/Git-Internals-Git-Objects)
- [AT Protocol Repository Spec](https://atproto.com/specs/repository)

## License

ISC License. See [LICENSE.md](LICENSE.md) for details.
