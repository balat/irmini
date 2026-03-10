#!/bin/bash
# Regenerate per-optimization benchmark data for irmini.
#
# Runs 5 variants (baseline, +inline, +cache, +inode, +all) on the memory
# backend only, then merges results into a single JSON file.
#
# Usage:
#   cd /path/to/monopampam
#   ./irmini/bench/run_optims.sh [output.json]
#
# Default output: irmini/bench/results/irmini_optims.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${1:-$SCRIPT_DIR/results/irmini_optims.json}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

BENCH="dune exec irmini/bench/bench_irmin4_main.exe --"
COMMON="--ncommits 50 --tree-add 500 --depth 10 --nreads 5000 --value-size 100 --skip-disk --skip-lavyek --skip-git"

echo "=== Irmini optimization benchmarks ==="
echo "Output: $OUTPUT"
echo

echo "--- Baseline (no optimizations) ---"
$BENCH $COMMON --inline-threshold 0 --no-inode --name "Irmini baseline" --json "$TMPDIR/baseline.json"

echo "--- +inline (inline_threshold=48) ---"
$BENCH $COMMON --no-inode --name "Irmini+inline" --json "$TMPDIR/inline.json"

echo "--- +cache (LRU 100000) ---"
$BENCH $COMMON --inline-threshold 0 --no-inode --cache 100000 --name "Irmini+cache" --json "$TMPDIR/cache.json"

echo "--- +inode (HAMT trie) ---"
$BENCH $COMMON --inline-threshold 0 --name "Irmini+inode" --json "$TMPDIR/inode.json"

echo "--- +all (inline + cache + inode) ---"
$BENCH $COMMON --cache 100000 --name "Irmini+all" --json "$TMPDIR/all.json"

# Merge JSON arrays
python3 -c "
import json, glob, sys
results = []
for f in sorted(glob.glob('$TMPDIR/*.json')):
    with open(f) as fh:
        results.extend(json.load(fh))
with open('$OUTPUT', 'w') as fh:
    json.dump(results, fh, indent=2)
    fh.write('\n')
print(f'Merged {len(results)} results into $OUTPUT')
"

echo
echo "Done. Regenerate charts with:"
echo "  python3 $SCRIPT_DIR/gen_chart_all.py $SCRIPT_DIR/results"
