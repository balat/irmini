#!/bin/bash
# Cross-implementation test runner.
#
# Runs the same test scenarios across:
#   1. Irmini (current repo — always runs)
#   2. Irmin-Eio (cuihtlauac-inline-small-objects-v2 branch — with multicore)
#   3. Irmin-Lwt (main branch — without multicore)
#
# Prerequisites:
#   - Irmini monorepo (monopampam) with irmini checked out
#   - Irmin workspace at IRMIN_DIR
#
# Usage: ./test/run_tests.sh [--skip-lwt] [--skip-eio] [--skip-irmini]
#
# Environment:
#   MONOREPO_DIR  Path to monopampam monorepo (default: auto-detect)
#   IRMIN_DIR     Path to official Irmin checkout (default: ~/prog/tarides/irmin)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
IRMIN_DIR="${IRMIN_DIR:-/home/balat/tarides/irmin}"

# Parse flags
SKIP_LWT=false
SKIP_EIO=false
SKIP_IRMINI=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-lwt) SKIP_LWT=true; shift ;;
    --skip-eio) SKIP_EIO=true; shift ;;
    --skip-irmini) SKIP_IRMINI=true; shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
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

PASS=0
FAIL=0

# --- Helper: run Irmin tests in the Irmin workspace -----------------------

run_irmin_tests() {
  local branch="$1"
  local test_src_dir="$2"  # test/test-irmin-lwt or test/test-irmin-eio
  local dest_name="$3"     # directory name in irmin workspace
  local impl_name="$4"     # display name

  echo ""
  echo "=== $impl_name ==="
  echo "  Switching to branch: $branch"
  cd "$IRMIN_DIR"
  git checkout -q "$branch"

  # Copy test files
  local dest="$IRMIN_DIR/$dest_name"
  mkdir -p "$dest"
  cp "$ROOT_DIR/test/$test_src_dir/"*.ml "$dest/"

  # Write dune file (uncommented version)
  if [ "$test_src_dir" = "test-irmin-lwt" ]; then
    cat > "$dest/dune" <<'DUNE'
(executable
 (name main)
 (libraries irmin irmin.mem alcotest lwt lwt.unix unix)
 (modules test_irmin_lwt main))
DUNE
  else
    cat > "$dest/dune" <<'DUNE'
(executable
 (name main)
 (libraries irmin irmin.mem alcotest eio_main unix)
 (modules test_irmin_eio main))
DUNE
  fi

  echo "  Building..."
  if ! dune build "$dest_name/main.exe" 2>&1; then
    echo "  BUILD FAILED"
    FAIL=$((FAIL + 1))
    rm -rf "$dest"
    cd "$ROOT_DIR"
    return
  fi

  echo "  Running tests..."
  if dune exec "$dest_name/main.exe" 2>&1; then
    echo "  PASS: $impl_name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $impl_name"
    FAIL=$((FAIL + 1))
  fi

  # Clean up
  rm -rf "$dest"
  cd "$ROOT_DIR"
}

# --- 1. Irmini tests (always available) ------------------------------------

if [ "$SKIP_IRMINI" = false ]; then
  echo ""
  echo "=== Irmini ==="
  echo "  Building..."
  cd "$MONOREPO_DIR"
  if ! dune build irmini/test/test.exe 2>&1; then
    echo "  BUILD FAILED"
    FAIL=$((FAIL + 1))
  else
    echo "  Running tests..."
    if dune exec irmini/test/test.exe 2>&1; then
      echo "  PASS: Irmini"
      PASS=$((PASS + 1))
    else
      echo "  FAIL: Irmini"
      FAIL=$((FAIL + 1))
    fi
  fi
  cd "$ROOT_DIR"
fi

# --- 2. Irmin-Eio tests ---------------------------------------------------

if [ "$SKIP_EIO" = false ]; then
  if [ ! -d "$IRMIN_DIR" ]; then
    echo "WARNING: Irmin directory not found at $IRMIN_DIR, skipping Irmin-Eio"
  else
    # Save current branch to restore later
    IRMIN_ORIG_BRANCH="$(cd "$IRMIN_DIR" && git rev-parse --abbrev-ref HEAD)"
    run_irmin_tests \
      "cuihtlauac-inline-small-objects-v2" \
      "test-irmin-eio" \
      "test-irmin-eio" \
      "Irmin-Eio (cuihtlauac)"
    # Restore original branch
    cd "$IRMIN_DIR"
    git checkout -q "$IRMIN_ORIG_BRANCH"
    cd "$ROOT_DIR"
  fi
fi

# --- 3. Irmin-Lwt tests ---------------------------------------------------

if [ "$SKIP_LWT" = false ]; then
  if [ ! -d "$IRMIN_DIR" ]; then
    echo "WARNING: Irmin directory not found at $IRMIN_DIR, skipping Irmin-Lwt"
  else
    IRMIN_ORIG_BRANCH="$(cd "$IRMIN_DIR" && git rev-parse --abbrev-ref HEAD)"
    run_irmin_tests \
      "main" \
      "test-irmin-lwt" \
      "test-irmin-lwt" \
      "Irmin-Lwt (main)"
    # Restore original branch
    cd "$IRMIN_DIR"
    git checkout -q "$IRMIN_ORIG_BRANCH"
    cd "$ROOT_DIR"
  fi
fi

# --- Summary ---------------------------------------------------------------

echo ""
echo "=============================="
echo "  Results: $PASS passed, $FAIL failed"
echo "=============================="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
