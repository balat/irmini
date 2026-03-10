#!/bin/bash
# Regenerate per-optimization benchmark data for irmini.
#
# Runs 5 variants (baseline, +inline, +cache, +inode, +all) on both
# disk and memory backends, then merges results into JSON files.
#
# Usage:
#   cd /path/to/monopampam
#   ./irmini/bench/run_optims.sh
#
# Output:
#   irmini/bench/results/irmini_optims_disk.json
#   irmini/bench/results/irmini_optims_memory.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESULTS_DIR="$SCRIPT_DIR/results"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

BENCH="dune exec irmini/bench/bench_irmin4_main.exe --"
PARAMS="--ncommits 50 --tree-add 500 --depth 10 --nreads 5000 --value-size 20"
SKIP_OTHER="--skip-lavyek --skip-git"

merge_json() {
  local output="$1"
  shift
  python3 -c "
import json, sys
results = []
for f in sys.argv[1:]:
    with open(f) as fh:
        results.extend(json.load(fh))
with open('$output', 'w') as fh:
    json.dump(results, fh, indent=2)
    fh.write('\n')
print(f'Merged {len(results)} results into $output')
" "$@"
}

echo "=== Irmini optimization benchmarks (disk) ==="
echo

DISK="$PARAMS $SKIP_OTHER --skip-memory"

echo "--- Baseline (no optimizations) ---"
$BENCH $DISK --inline-threshold 0 --no-inode --name "Irmini baseline (disk)" --json "$TMPDIR/disk_baseline.json"

echo "--- +inline (inline_threshold=48) ---"
$BENCH $DISK --no-inode --name "Irmini+inline (disk)" --json "$TMPDIR/disk_inline.json"

echo "--- +cache (LRU 100000) ---"
$BENCH $DISK --inline-threshold 0 --no-inode --cache 100000 --name "Irmini+cache (disk)" --json "$TMPDIR/disk_cache.json"

echo "--- +inode (HAMT trie) ---"
$BENCH $DISK --inline-threshold 0 --name "Irmini+inode (disk)" --json "$TMPDIR/disk_inode.json"

echo "--- +all (inline + cache + inode) ---"
$BENCH $DISK --cache 100000 --name "Irmini+all (disk)" --json "$TMPDIR/disk_all.json"

merge_json "$RESULTS_DIR/irmini_optims_disk.json" "$TMPDIR"/disk_*.json

echo
echo "=== Irmini optimization benchmarks (memory) ==="
echo

MEM="$PARAMS $SKIP_OTHER --skip-disk"

echo "--- Baseline (no optimizations) ---"
$BENCH $MEM --inline-threshold 0 --no-inode --name "Irmini baseline" --json "$TMPDIR/mem_baseline.json"

echo "--- +inline (inline_threshold=48) ---"
$BENCH $MEM --no-inode --name "Irmini+inline" --json "$TMPDIR/mem_inline.json"

echo "--- +cache (LRU 100000) ---"
$BENCH $MEM --inline-threshold 0 --no-inode --cache 100000 --name "Irmini+cache" --json "$TMPDIR/mem_cache.json"

echo "--- +inode (HAMT trie) ---"
$BENCH $MEM --inline-threshold 0 --name "Irmini+inode" --json "$TMPDIR/mem_inode.json"

echo "--- +all (inline + cache + inode) ---"
$BENCH $MEM --cache 100000 --name "Irmini+all" --json "$TMPDIR/mem_all.json"

merge_json "$RESULTS_DIR/irmini_optims_memory.json" "$TMPDIR"/mem_*.json

echo
echo "Done. Regenerate charts with:"
echo "  python3 $SCRIPT_DIR/gen_chart_all.py $SCRIPT_DIR/results"
