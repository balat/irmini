#!/bin/bash
# Full Irmin benchmark comparison script.
#
# Runs benchmarks across all implementations and backends:
#   Part 1: Backend comparison
#     - irmin-lwt (main branch): memory, fs, git, pack
#     - irmin-eio (cuihtlauac branch): memory, fs, git, pack
#     - irmini-thomas (main branch): memory, fs, git (original, no optimizations)
#     - irmini (current branch): memory, disk, git, lavyek
#   Part 2: Irmini optimization impact (each optimization independently)
#
# Prerequisites:
#   - Irmini monorepo (monopampam) with irmini checked out
#   - Irmin workspace at IRMIN_DIR
#
# Usage: ./bench/run_all.sh [--ncommits N] [--tree-add N] [--depth N]
#                            [--nreads N] [--value-size N]
#                            [--skip-lwt] [--skip-eio] [--skip-thomas]
#                            [--skip-irmini] [--part2]
#
# Environment:
#   MONOREPO_DIR  Path to monopampam monorepo (default: auto-detect)
#   IRMIN_DIR     Path to official Irmin checkout (default: ~/prog/tarides/irmin)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
IRMIN_DIR="${IRMIN_DIR:-/home/balat/prog/tarides/irmin}"
OUTPUT_DIR="$ROOT_DIR/bench/results"

# Parse our flags, pass rest to benchmarks
BENCH_ARGS=""
SKIP_LWT=false
SKIP_EIO=false
SKIP_THOMAS=false
SKIP_IRMINI=false
RUN_PART2=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-lwt) SKIP_LWT=true; shift ;;
    --skip-eio) SKIP_EIO=true; shift ;;
    --skip-thomas) SKIP_THOMAS=true; shift ;;
    --skip-irmini) SKIP_IRMINI=true; shift ;;
    --part2) RUN_PART2=true; shift ;;
    *) BENCH_ARGS="$BENCH_ARGS $1"; shift ;;
  esac
done

# Try to find monorepo
if [ -n "${MONOREPO_DIR:-}" ]; then
  :
elif [ -d "$ROOT_DIR/../monopampam" ]; then
  MONOREPO_DIR="$(cd "$ROOT_DIR/../monopampam" && pwd)"
elif [ -L "$ROOT_DIR" ]; then
  REAL_DIR="$(readlink -f "$ROOT_DIR")"
  MONOREPO_DIR="$(dirname "$REAL_DIR")"
else
  MONOREPO_DIR="$ROOT_DIR"
fi

mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

echo "=== Full Irmin Performance Comparison ==="
echo "Monorepo:  $MONOREPO_DIR"
echo "Irmin:     $IRMIN_DIR"
echo "Output:    $OUTPUT_DIR"
echo "Timestamp: $TIMESTAMP"
echo ""

# Helper: copy bench files into irmin workspace, build, run, clean up
run_irmin_bench() {
  local branch="$1"
  local bench_dir="$2"  # bench/bench-irmin-lwt or bench/bench-irmin-eio
  local dest_name="$3"  # directory name in irmin workspace
  local json_out="$4"
  local extra_args="${5:-}"

  echo "  Switching to branch: $branch"
  cd "$IRMIN_DIR"
  git checkout -q "$branch"

  # Copy bench files
  local dest="$IRMIN_DIR/$dest_name"
  mkdir -p "$dest"
  cp "$ROOT_DIR/bench/$bench_dir/"*.ml "$dest/"

  # Write dune file (uncommented version)
  if [ "$bench_dir" = "bench-irmin-lwt" ]; then
    cat > "$dest/dune" <<'DUNE'
(executable
 (name main)
 (libraries irmin irmin.mem irmin-pack irmin-pack.unix
            irmin-fs irmin-fs.unix
            irmin-git irmin-git.unix
            lwt lwt.unix
            unix)
 (modules bench_common bench_irmin_lwt bench_irmin_mem
          bench_irmin_pack bench_irmin_fs bench_irmin_git main))
DUNE
  else
    cat > "$dest/dune" <<'DUNE'
(executable
 (name main)
 (libraries irmin irmin.mem irmin-pack irmin-pack.unix
            irmin-fs irmin-fs.unix
            irmin-git irmin-git.unix lwt_eio
            eio_main unix)
 (modules bench_common bench_irmin_eio bench_irmin_pack
          bench_irmin_fs bench_irmin_git main))
DUNE
  fi

  echo "  Building..."
  if dune build "$dest_name/main.exe" 2>&1 | tail -5; then
    echo "  Running..."
    dune exec "$dest_name/main.exe" -- $BENCH_ARGS --json "$json_out" $extra_args
  else
    echo "  FAILED to build $dest_name"
  fi

  # Clean up
  rm -rf "$dest"
  cd "$MONOREPO_DIR"
}

# ============================================================
# Part 1: Backend comparison
# ============================================================

echo "========================================="
echo "  Part 1: Backend Comparison"
echo "========================================="
echo ""

# --- irmin-lwt (main branch) ---
if [ "$SKIP_LWT" = false ]; then
  echo "--- irmin-lwt (main branch) ---"
  run_irmin_bench "main" "bench-irmin-lwt" "bench-irmin-lwt" \
    "$OUTPUT_DIR/irmin_lwt_${TIMESTAMP}.json"
  echo ""
fi

# --- irmin-eio (cuihtlauac branch) ---
if [ "$SKIP_EIO" = false ]; then
  echo "--- irmin-eio (cuihtlauac branch) ---"
  run_irmin_bench "cuihtlauac-inline-small-objects-v2" "bench-irmin-eio" "bench-irmin-eio" \
    "$OUTPUT_DIR/irmin_eio_${TIMESTAMP}.json"
  echo ""
fi

# --- irmini-thomas (main branch, no optimizations) ---
if [ "$SKIP_THOMAS" = false ]; then
  echo "--- irmini-thomas (main branch) ---"
  cd "$MONOREPO_DIR"

  # Save current branch
  IRMINI_BRANCH=$(cd "$ROOT_DIR" && git branch --show-current)

  # Checkout main for irmini
  cd "$ROOT_DIR"
  git stash -q 2>/dev/null || true
  git checkout -q main

  cd "$MONOREPO_DIR"
  echo "  Building irmini (main)..."
  dune build irmini/bench/bench_irmin4_main.exe 2>&1 | tail -5
  echo "  Running..."
  dune exec irmini/bench/bench_irmin4_main.exe -- $BENCH_ARGS \
    --skip-lavyek \
    --json "$OUTPUT_DIR/irmini_thomas_${TIMESTAMP}.json"

  # Restore branch
  cd "$ROOT_DIR"
  git checkout -q "$IRMINI_BRANCH"
  git stash pop -q 2>/dev/null || true
  cd "$MONOREPO_DIR"
  echo ""
fi

# --- irmini (current branch, all optimizations) ---
if [ "$SKIP_IRMINI" = false ]; then
  IRMINI_BRANCH=$(cd "$ROOT_DIR" && git branch --show-current)
  echo "--- irmini ($IRMINI_BRANCH branch) ---"
  cd "$MONOREPO_DIR"

  echo "  Building irmini ($IRMINI_BRANCH)..."
  dune build irmini/bench/bench_irmin4_main.exe 2>&1 | tail -5
  echo "  Running..."
  dune exec irmini/bench/bench_irmin4_main.exe -- $BENCH_ARGS \
    --json "$OUTPUT_DIR/irmini_inode_${TIMESTAMP}.json"

  cd "$MONOREPO_DIR"
  echo ""
fi

# ============================================================
# Part 2: Irmini optimization impact (optional)
# ============================================================

if [ "$RUN_PART2" = true ]; then
  echo "========================================="
  echo "  Part 2: Irmini Optimization Impact"
  echo "========================================="
  echo ""
  echo "(TODO: Run irmini with each optimization toggled independently)"
  echo "  - baseline (main branch)"
  echo "  - + inodes only"
  echo "  - + resolved-child cache only"
  echo "  - + inlining only"
  echo "  - all optimizations (inode branch)"
fi

# ============================================================
# Generate charts
# ============================================================

echo ""
echo "========================================="
echo "  Generating Charts"
echo "========================================="
echo ""

if [ -f "$SCRIPT_DIR/gen_chart_all.py" ]; then
  python3 "$SCRIPT_DIR/gen_chart_all.py" "$OUTPUT_DIR" "$TIMESTAMP"
else
  echo "Chart generator not found: $SCRIPT_DIR/gen_chart_all.py"
  echo "JSON results are in $OUTPUT_DIR/"
fi

echo ""
echo "=== Done ==="
