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
  # Copy bench-eio files into a temp directory in the Irmin workspace
  BENCH_DIR="$IRMIN_EIO_DIR/_bench_tmp"
  mkdir -p "$BENCH_DIR"
  cp "$ROOT_DIR/bench-eio/"*.ml "$BENCH_DIR/"

  # Write an active dune file for the Irmin workspace
  cat > "$BENCH_DIR/dune" <<'DUNE'
(executable
 (name main)
 (libraries irmin irmin.mem irmin-pack irmin-pack.unix eio_main unix)
 (modules bench_common bench_irmin_eio bench_irmin_pack main))
DUNE

  cd "$IRMIN_EIO_DIR"
  if dune build "_bench_tmp/main.exe" 2>&1 | tail -5; then
    dune exec "_bench_tmp/main.exe" -- $ARGS
  else
    echo "Failed to build Irmin-Eio benchmark."
    echo "Make sure the Irmin-Eio workspace at $IRMIN_EIO_DIR is set up."
    echo "You can set IRMIN_EIO_DIR to point to your Irmin-Eio checkout."
  fi

  # Clean up
  rm -rf "$BENCH_DIR"
else
  echo "Irmin-Eio directory not found at $IRMIN_EIO_DIR"
  echo "Set IRMIN_EIO_DIR to your Irmin (Eio branch) checkout."
fi
