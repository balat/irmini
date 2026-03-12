#!/bin/bash
# Master benchmark script: runs ALL irmini benchmarks and updates README.
#
# What it does:
#   1. Irmini standard benchmarks (memory, disk, git, lavyek)
#   2. Irmini optimization comparison (baseline, +inline, +cache, +inode, +all)
#   3. Tezos trace replay (sequential, all active backends)
#   4. Parallel trace replay scaling sweep (multiple fiber counts)
#   5. Irmin-Lwt and Irmin-Eio benchmarks (if IRMIN_DIR is set)
#   6. Generate SVG charts
#   7. Update bench/README.md with results
#
# Usage:
#   cd /path/to/monopampam
#   ./irmini/bench/run_bench.sh [OPTIONS]
#
# Options:
#   --skip-irmini       Skip irmini standard benchmarks
#   --skip-optims       Skip optimization comparison
#   --skip-trace        Skip trace replay
#   --skip-parallel     Skip parallel scaling sweep
#   --skip-irmin        Skip Irmin-Lwt/Eio benchmarks
#   --skip-charts       Skip chart generation
#   --skip-readme       Skip README update
#   --trace FILE        Path to .repr trace file (default: auto-detect)
#   --trace-commits N   Max commits to replay (default: 10310)
#   --parallel-fibers   Comma-separated fiber counts (default: 1,10,100,1000,10000,50000,100000)
#   --parallel-domains  Number of domains for parallel (default: 12)
#   --ncommits N        Override commit count (passed to benchmarks)
#   --tree-add N        Override tree-add (passed to benchmarks)
#   --depth N           Override depth (passed to benchmarks)
#   --nreads N          Override reads (passed to benchmarks)
#
# Environment:
#   MONOREPO_DIR  Path to monopampam monorepo (default: auto-detect)
#   IRMIN_DIR     Path to official Irmin checkout (for Irmin-Lwt/Eio benchmarks)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$SCRIPT_DIR/results"

# --- Defaults ---
SKIP_IRMINI=false
SKIP_OPTIMS=false
SKIP_TRACE=false
SKIP_PARALLEL=false
SKIP_IRMIN=false
SKIP_CHARTS=false
SKIP_README=false
TRACE_FILE=""
TRACE_COMMITS=10310
PARALLEL_FIBERS="1,10,100,1000,10000,20000,30000,40000,45000,50000,55000,60000,70000,100000"
PARALLEL_DOMAINS=12
BENCH_ARGS=""

# --- Parse args ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-irmini)    SKIP_IRMINI=true; shift ;;
    --skip-optims)    SKIP_OPTIMS=true; shift ;;
    --skip-trace)     SKIP_TRACE=true; shift ;;
    --skip-parallel)  SKIP_PARALLEL=true; shift ;;
    --skip-irmin)     SKIP_IRMIN=true; shift ;;
    --skip-charts)    SKIP_CHARTS=true; shift ;;
    --skip-readme)    SKIP_README=true; shift ;;
    --trace)          TRACE_FILE="$2"; shift 2 ;;
    --trace-commits)  TRACE_COMMITS="$2"; shift 2 ;;
    --parallel-fibers)  PARALLEL_FIBERS="$2"; shift 2 ;;
    --parallel-domains) PARALLEL_DOMAINS="$2"; shift 2 ;;
    --ncommits|--tree-add|--depth|--nreads|--value-size)
      BENCH_ARGS="$BENCH_ARGS $1 $2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Find monorepo ---
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

# --- Find trace file ---
if [ -z "$TRACE_FILE" ]; then
  for candidate in \
    "$ROOT_DIR/data4_10310commits.repr" \
    "$MONOREPO_DIR/data4_10310commits.repr" \
    "$ROOT_DIR/bench/data4_10310commits.repr" \
    "${IRMIN_DIR:-}/data4_10310commits.repr"; do
    if [ -f "$candidate" ]; then
      TRACE_FILE="$candidate"
      break
    fi
  done
fi

mkdir -p "$OUTPUT_DIR"

BENCH="dune exec irmini/bench/bench_irmin4_main.exe --"
DATE_STR=$(date +%Y-%m-%d)

echo "============================================"
echo "  Irmini Benchmark Suite"
echo "============================================"
echo "Date:       $DATE_STR"
echo "Monorepo:   $MONOREPO_DIR"
echo "Output:     $OUTPUT_DIR"
echo "Trace:      ${TRACE_FILE:-not found}"
echo ""

cd "$MONOREPO_DIR"

# ============================================================
# 1. Irmini standard benchmarks
# ============================================================
if [ "$SKIP_IRMINI" = false ]; then
  echo "========================================="
  echo "  1. Irmini standard benchmarks"
  echo "========================================="
  echo ""
  dune build irmini/bench/bench_irmin4_main.exe 2>&1 | tail -5

  # All backends in one run (value-size 20 to match README scenario names)
  $BENCH --value-size 20 $BENCH_ARGS \
    --json "$OUTPUT_DIR/irmini_inode.json"

  echo ""
fi

# ============================================================
# 2. Irmini optimization comparison
# ============================================================
if [ "$SKIP_OPTIMS" = false ]; then
  echo "========================================="
  echo "  2. Irmini optimization comparison"
  echo "========================================="
  echo ""

  OPTIM_PARAMS="--ncommits 50 --tree-add 500 --depth 10 --nreads 5000 --value-size 20"
  SKIP_OTHER="--skip-lavyek --skip-git"
  TMPDIR_OPTIMS="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_OPTIMS"' EXIT

  # --- Disk ---
  DISK="$OPTIM_PARAMS $SKIP_OTHER --skip-memory"

  echo "--- Baseline (disk) ---"
  $BENCH $DISK --inline-threshold 0 --no-inode --name "Irmini baseline (disk)" --json "$TMPDIR_OPTIMS/disk_baseline.json"
  echo "--- +inline (disk) ---"
  $BENCH $DISK --no-inode --name "Irmini+inline (disk)" --json "$TMPDIR_OPTIMS/disk_inline.json"
  echo "--- +cache (disk) ---"
  $BENCH $DISK --inline-threshold 0 --no-inode --cache 100000 --name "Irmini+cache (disk)" --json "$TMPDIR_OPTIMS/disk_cache.json"
  echo "--- +inode (disk) ---"
  $BENCH $DISK --inline-threshold 0 --name "Irmini+inode (disk)" --json "$TMPDIR_OPTIMS/disk_inode.json"
  echo "--- +all (disk) ---"
  $BENCH $DISK --cache 100000 --name "Irmini+all (disk)" --json "$TMPDIR_OPTIMS/disk_all.json"

  # Merge disk optims
  python3 -c "
import json, sys, glob
results = []
for f in sorted(glob.glob('$TMPDIR_OPTIMS/disk_*.json')):
    with open(f) as fh: results.extend(json.load(fh))
with open('$OUTPUT_DIR/irmini_optims_disk.json', 'w') as fh:
    json.dump(results, fh, indent=2); fh.write('\n')
print(f'Merged {len(results)} disk optim results')
"

  # --- Memory ---
  MEM="$OPTIM_PARAMS $SKIP_OTHER --skip-disk"

  echo "--- Baseline (memory) ---"
  $BENCH $MEM --inline-threshold 0 --no-inode --name "Irmini baseline" --json "$TMPDIR_OPTIMS/mem_baseline.json"
  echo "--- +inline (memory) ---"
  $BENCH $MEM --no-inode --name "Irmini+inline" --json "$TMPDIR_OPTIMS/mem_inline.json"
  echo "--- +cache (memory) ---"
  $BENCH $MEM --inline-threshold 0 --no-inode --cache 100000 --name "Irmini+cache" --json "$TMPDIR_OPTIMS/mem_cache.json"
  echo "--- +inode (memory) ---"
  $BENCH $MEM --inline-threshold 0 --name "Irmini+inode" --json "$TMPDIR_OPTIMS/mem_inode.json"
  echo "--- +all (memory) ---"
  $BENCH $MEM --cache 100000 --name "Irmini+all" --json "$TMPDIR_OPTIMS/mem_all.json"

  # Merge memory optims
  python3 -c "
import json, sys, glob
results = []
for f in sorted(glob.glob('$TMPDIR_OPTIMS/mem_*.json')):
    with open(f) as fh: results.extend(json.load(fh))
with open('$OUTPUT_DIR/irmini_optims_memory.json', 'w') as fh:
    json.dump(results, fh, indent=2); fh.write('\n')
print(f'Merged {len(results)} memory optim results')
"

  rm -rf "$TMPDIR_OPTIMS"
  echo ""
fi

# ============================================================
# 3. Trace replay (sequential)
# ============================================================
if [ "$SKIP_TRACE" = false ] && [ -n "$TRACE_FILE" ]; then
  echo "========================================="
  echo "  3. Trace replay (sequential)"
  echo "========================================="
  echo ""

  $BENCH --skip-git \
    --trace "$TRACE_FILE" --trace-commits "$TRACE_COMMITS" \
    --skip-disk --cache 100000 \
    --json "$OUTPUT_DIR/irmini_trace.json"

  echo ""
fi

# ============================================================
# 4. Parallel trace replay scaling
# ============================================================
if [ "$SKIP_PARALLEL" = false ] && [ -n "$TRACE_FILE" ]; then
  echo "========================================="
  echo "  4. Parallel scaling sweep"
  echo "========================================="
  echo ""

  TMPDIR_PAR="$(mktemp -d)"

  IFS=',' read -ra FIBERS_ARRAY <<< "$PARALLEL_FIBERS"
  for fibers in "${FIBERS_ARRAY[@]}"; do
    echo "--- ${PARALLEL_DOMAINS}d × ${fibers}f ---"
    $BENCH --skip-memory --skip-disk --skip-git \
      --trace "$TRACE_FILE" --trace-commits "$TRACE_COMMITS" \
      --cache 100000 \
      --parallel-domains "$PARALLEL_DOMAINS" \
      --parallel-fibers "$fibers" \
      --json "$TMPDIR_PAR/parallel_${fibers}.json"
    echo ""
  done

  # Merge parallel results (keep only parallel scenarios)
  python3 -c "
import json, glob
results = []
for f in sorted(glob.glob('$TMPDIR_PAR/parallel_*.json'), key=lambda p: int(p.split('_')[-1].split('.')[0])):
    with open(f) as fh:
        for r in json.load(fh):
            if 'parallel' in r['scenario']:
                results.append(r)
with open('$OUTPUT_DIR/irmini_parallel.json', 'w') as fh:
    json.dump(results, fh, indent=2); fh.write('\n')
print(f'Merged {len(results)} parallel results')
"

  rm -rf "$TMPDIR_PAR"
  echo ""
fi

# ============================================================
# 5. Irmin-Lwt and Irmin-Eio benchmarks (optional)
# ============================================================
if [ "$SKIP_IRMIN" = false ] && [ -n "${IRMIN_DIR:-}" ] && [ -d "${IRMIN_DIR}" ]; then
  echo "========================================="
  echo "  5. Irmin benchmarks"
  echo "========================================="
  echo ""

  run_irmin_bench() {
    local branch="$1"
    local bench_dir="$2"
    local dest_name="$3"
    local json_out="$4"
    local extra_args="${5:-}"

    echo "  Switching to branch: $branch"
    cd "$IRMIN_DIR"
    git checkout -q "$branch"

    local dest="$IRMIN_DIR/$dest_name"
    mkdir -p "$dest"
    cp "$ROOT_DIR/bench/$bench_dir/"*.ml "$dest/"

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
            repr eio_main unix)
 (preprocess (pps ppx_repr))
 (modules bench_common bench_irmin_eio bench_irmin_pack
          bench_irmin_fs bench_irmin_git trace_replay_irmin main))
DUNE
    fi

    echo "  Building..."
    if dune build "$dest_name/main.exe" 2>&1 | tail -5; then
      echo "  Running..."
      dune exec "$dest_name/main.exe" -- $BENCH_ARGS --json "$json_out" $extra_args
    else
      echo "  FAILED to build $dest_name"
    fi

    rm -rf "$dest"
    cd "$MONOREPO_DIR"
  }

  echo "--- Irmin-Lwt (main) ---"
  run_irmin_bench "main" "bench-irmin-lwt" "bench-irmin-lwt" \
    "$OUTPUT_DIR/irmin_lwt.json"

  echo "--- Irmin-Eio (cuihtlauac branch) ---"
  run_irmin_bench "cuihtlauac-inline-small-objects-v2" "bench-irmin-eio" "bench-irmin-eio" \
    "$OUTPUT_DIR/irmin_eio.json"

  # Irmin trace replay (needs trace file)
  if [ -n "$TRACE_FILE" ] && [ "$SKIP_TRACE" = false ]; then
    echo "--- Irmin trace replay ---"

    run_irmin_trace() {
      local branch="$1"
      local store_type="$2"
      local json_out="$3"

      cd "$IRMIN_DIR"
      git checkout -q "$branch"

      echo "  Building tree.exe..."
      if dune build bench/irmin-pack/tree.exe 2>&1 | tail -5; then
        echo "  Running trace replay ($store_type)..."
        dune exec bench/irmin-pack/tree.exe -- \
          --mode=trace --store-type="$store_type" \
          --ncommits-trace="$TRACE_COMMITS" \
          --empty-blobs "$TRACE_FILE" 2>&1 | tee "$json_out.log"
        # Parse irmin's output into our JSON format
        python3 -c "
import re, json, sys
log = open('$json_out.log').read()
# Irmin tree.exe outputs: 'Total duration: XXs wall, YYs cpu'
wall_m = re.search(r'Total duration:\s*([\d.]+)s\s*wall', log)
cpu_m = re.search(r'([\d.]+)s\s*cpu', log)
ops_m = re.search(r'([\d,]+)\s*ops', log)
if wall_m:
    wall = float(wall_m.group(1))
    total_ops = int(ops_m.group(1).replace(',', '')) if ops_m else 4_000_000
    ops_per_sec = total_ops / wall if wall > 0 else 0
    store = '$store_type'
    branch = '$branch'
    name = 'Irmin-Lwt' if branch == 'main' else 'Irmin-Eio'
    backend = 'pack-mem' if 'mem' in store else 'pack'
    result = [{
        'name': f'{name} ({backend})',
        'scenario': 'tezos-${TRACE_COMMITS}commits',
        'total_ops': total_ops,
        'total_time': wall,
        'ops_per_sec': ops_per_sec,
        'maxrss_kb': 0,
    }]
    with open('$json_out', 'w') as f:
        json.dump(result, f, indent=2)
    print(f'  {name} ({backend}): {ops_per_sec:.0f} ops/s')
else:
    print('  Warning: could not parse trace output', file=sys.stderr)
"
        rm -f "$json_out.log"
      else
        echo "  FAILED to build tree.exe on $branch"
      fi

      cd "$MONOREPO_DIR"
    }

    # Irmin-Lwt: pack and pack-mem
    run_irmin_trace "main" "pack" "$OUTPUT_DIR/irmin_lwt_trace_pack.json"
    run_irmin_trace "main" "pack-mem" "$OUTPUT_DIR/irmin_lwt_trace_mem.json"

    # Irmin-Eio: pack and pack-mem (using irmin's tree.exe)
    run_irmin_trace "cuihtlauac-inline-small-objects-v2" "pack" "$OUTPUT_DIR/irmin_eio_trace_pack.json"
    run_irmin_trace "cuihtlauac-inline-small-objects-v2" "pack-mem" "$OUTPUT_DIR/irmin_eio_trace_mem.json"

    # Irmin-Eio: parallel trace replay (using our bench adapter)
    if [ "$SKIP_PARALLEL" = false ]; then
      echo "--- Irmin-Eio parallel trace replay ---"
      run_irmin_bench "cuihtlauac-inline-small-objects-v2" "bench-irmin-eio" "bench-irmin-eio" \
        "$OUTPUT_DIR/irmin_eio_parallel.json" \
        "--skip-pack --skip-fs --skip-git --trace $TRACE_FILE --trace-commits $TRACE_COMMITS --trace-empty-blobs --parallel-domains $PARALLEL_DOMAINS --parallel-fibers 1"

      # Generate tezos_parallel.json combining peak irmini + irmin-eio parallel results
      python3 -c "
import json, re, os, glob

results_dir = '$OUTPUT_DIR'
entries = []

# Peak irmini parallel result
par_file = os.path.join(results_dir, 'irmini_parallel.json')
if os.path.exists(par_file):
    with open(par_file) as f:
        par_data = json.load(f)
    if par_data:
        peak = max(par_data, key=lambda r: r['ops_per_sec'])
        m = re.search(r'(\d+)d.*?(\d+)f', peak['scenario'])
        if m:
            domains, fibers = m.group(1), m.group(2)
            fib_str = f'{int(fibers)//1000}k' if int(fibers) >= 1000 else fibers
            entries.append({
                'name': f'Irmini (lavyek) {domains}d\u00d7{fib_str}f',
                'scenario': 'tezos-${TRACE_COMMITS}commits',
                'total_ops': peak['total_ops'],
                'total_time': peak['total_time'],
                'ops_per_sec': peak['ops_per_sec'],
                'maxrss_kb': peak.get('maxrss_kb', 0),
            })

# Irmin-Eio parallel result
eio_file = os.path.join(results_dir, 'irmin_eio_parallel.json')
if os.path.exists(eio_file):
    with open(eio_file) as f:
        eio_data = json.load(f)
    for r in eio_data:
        if 'parallel' in r.get('scenario', ''):
            m = re.search(r'(\d+)d.*?(\d+)f', r['scenario'])
            if m:
                domains, fibers = m.group(1), m.group(2)
                entries.append({
                    'name': f'Irmin-Eio (pack) {domains}d\u00d7{fibers}f',
                    'scenario': 'tezos-${TRACE_COMMITS}commits',
                    'total_ops': r['total_ops'],
                    'total_time': r['total_time'],
                    'ops_per_sec': r['ops_per_sec'],
                    'maxrss_kb': r.get('maxrss_kb', 0),
                })
            break

if entries:
    out = os.path.join(results_dir, 'tezos_parallel.json')
    with open(out, 'w') as f:
        json.dump(entries, f, indent=2)
        f.write('\n')
    print(f'Generated {out} with {len(entries)} entries')
"
    fi
  fi

  echo ""
fi

# ============================================================
# 6. Generate charts
# ============================================================
if [ "$SKIP_CHARTS" = false ]; then
  echo "========================================="
  echo "  6. Generating charts"
  echo "========================================="
  echo ""

  # Backend comparison charts
  if [ -f "$SCRIPT_DIR/gen_chart_all.py" ]; then
    python3 "$SCRIPT_DIR/gen_chart_all.py" "$OUTPUT_DIR"
  fi

  # Parallel scaling chart (reads data from JSON if available)
  if [ -f "$SCRIPT_DIR/gen_chart_parallel.py" ]; then
    python3 "$SCRIPT_DIR/gen_chart_parallel.py" "$OUTPUT_DIR/chart_parallel_scaling.svg" --json "$OUTPUT_DIR"
  fi

  echo ""
fi

# ============================================================
# 7. Update README
# ============================================================
if [ "$SKIP_README" = false ]; then
  echo "========================================="
  echo "  7. Updating README"
  echo "========================================="
  echo ""

  CPU_INFO=$(lscpu 2>/dev/null | grep "Model name" | sed 's/.*: *//' | head -1)
  NCORES=$(nproc 2>/dev/null || echo "?")
  MACHINE="${CPU_INFO:-$(uname -m)}, ${NCORES}-core"

  python3 "$SCRIPT_DIR/gen_readme_results.py" "$OUTPUT_DIR" \
    --readme "$SCRIPT_DIR/README.md" \
    --date "$DATE_STR" \
    --machine "$MACHINE, 100 commits x 1000 adds, depth 10, 10000 reads"

  echo ""
fi

echo "============================================"
echo "  Done!"
echo "============================================"
echo ""
echo "Results:  $OUTPUT_DIR/"
echo "README:   $SCRIPT_DIR/README.md"
echo "Charts:   $OUTPUT_DIR/chart_*.svg"
