#!/bin/bash
# Irmin benchmark comparison script.
#
# Runs Irmini benchmarks (memory, disk, lavyek) and Irmin-Eio benchmarks
# (memory, irmin-pack), then displays results for comparison.
#
# Prerequisites:
#   - Irmini: build within monopampam monorepo
#   - Irmin-Eio: official Irmin checkout on the eio branch
#   - Lavyek: symlinked or available in the monorepo
#
# Usage: ./bench/run.sh [--ncommits N] [--tree-add N] [--depth N]
#                       [--nreads N] [--value-size N]
#
# Environment:
#   MONOREPO_DIR  Path to monopampam monorepo (default: auto-detect)
#   IRMIN_EIO_DIR Path to official Irmin (eio branch) checkout

set -euo pipefail

ARGS="${@:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
IRMIN_EIO_DIR="${IRMIN_EIO_DIR:-/home/balat/prog/tarides/irmin}"

# Try to find monorepo
if [ -n "${MONOREPO_DIR:-}" ]; then
  :
elif [ -d "$ROOT_DIR/../monopampam" ]; then
  MONOREPO_DIR="$(cd "$ROOT_DIR/../monopampam" && pwd)"
elif [ -L "$ROOT_DIR" ]; then
  # We might be a symlink inside monopampam
  REAL_DIR="$(readlink -f "$ROOT_DIR")"
  MONOREPO_DIR="$(dirname "$REAL_DIR")"
else
  MONOREPO_DIR="$ROOT_DIR"
fi

echo "=== Irmin Performance Comparison ==="
echo "Monorepo: $MONOREPO_DIR"
echo "Irmin-Eio: $IRMIN_EIO_DIR"
echo ""

# --- Part 1: Irmini benchmarks ---
echo "Building Irmini benchmarks..."
cd "$MONOREPO_DIR"
dune build irmini/bench/bench_irmin4_main.exe 2>&1 | tail -5

echo ""
echo "========================================="
echo "  Irmini Benchmarks (memory/disk/lavyek)"
echo "========================================="
echo ""
dune exec irmini/bench/bench_irmin4_main.exe -- $ARGS

# --- Part 2: Irmin-Eio benchmarks ---
echo ""
echo "========================================="
echo "  Irmin-Eio Benchmarks (memory/pack)"
echo "========================================="
echo ""

if [ -d "$IRMIN_EIO_DIR" ]; then
  # Copy bench-eio files into the Irmin workspace
  BENCH_DIR="$IRMIN_EIO_DIR/bench-irmini"
  mkdir -p "$BENCH_DIR"
  cp "$ROOT_DIR/bench-eio/bench_common.ml" "$BENCH_DIR/"
  cp "$ROOT_DIR/bench-eio/bench_irmin_eio.ml" "$BENCH_DIR/"

  # Write a simplified main.ml (memory-only, avoids irmin-pack dep issues)
  cat > "$BENCH_DIR/main.ml" <<'OCAML'
let () =
  let ncommits = ref 100 in
  let tree_add = ref 1000 in
  let depth = ref 10 in
  let nreads = ref 10_000 in
  let value_size = ref 100 in
  Arg.parse
    [ ("--ncommits", Arg.Set_int ncommits, "Number of commits (default: 100)");
      ("--tree-add", Arg.Set_int tree_add, "Tree entries added per commit (default: 1000)");
      ("--depth", Arg.Set_int depth, "Depth of paths (default: 10)");
      ("--nreads", Arg.Set_int nreads, "Number of reads in read phase (default: 10000)");
      ("--value-size", Arg.Set_int value_size, "Size of values in bytes (default: 100)") ]
    (fun _ -> ()) "bench_irmin_eio";
  let conf : Bench_common.config =
    { ncommits = !ncommits; tree_add = !tree_add; depth = !depth;
      nreads = !nreads; value_size = !value_size }
  in
  Format.printf "Configuration: %d commits, %d adds/commit, depth %d, %d reads, %d-byte values@.@."
    conf.ncommits conf.tree_add conf.depth conf.nreads conf.value_size;
  Eio_main.run @@ fun _env ->
  Format.printf "--- Irmin-Eio (memory) ---@.@.";
  let rs = Bench_irmin_eio.run_all_mem conf in
  List.iter (fun r -> Format.printf "%a@.@." Bench_common.pp_result r) rs;
  Bench_common.pp_comparison Format.std_formatter rs
OCAML

  # Write dune file
  cat > "$BENCH_DIR/dune" <<'DUNE'
(executable
 (name main)
 (libraries irmin irmin.mem eio_main unix)
 (modules bench_common bench_irmin_eio main))
DUNE

  cd "$IRMIN_EIO_DIR"
  if dune build "bench-irmini/main.exe" 2>&1 | tail -5; then
    dune exec "bench-irmini/main.exe" -- $ARGS
  else
    echo "Failed to build Irmin-Eio benchmark."
    echo "Make sure the Irmin-Eio workspace at $IRMIN_EIO_DIR is set up."
    echo "You can set IRMIN_EIO_DIR to point to your Irmin-Eio checkout."
  fi

  # Clean up
  rm -rf "$BENCH_DIR"
  cd "$MONOREPO_DIR"
else
  echo "Irmin-Eio directory not found at $IRMIN_EIO_DIR"
  echo "Set IRMIN_EIO_DIR to your Irmin (Eio branch) checkout."
fi
