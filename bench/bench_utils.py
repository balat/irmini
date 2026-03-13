#!/usr/bin/env python3
"""Shared utilities for benchmark chart generation and README updates.

Provides result loading, classification, color mapping, formatting,
and scenario/backend ordering used by gen_chart_all.py, gen_readme_results.py,
and gen_chart_scaling.py.
"""

import glob
import json
import math
import os
import re
import sys


# ---------------------------------------------------------------------------
# Result loading
# ---------------------------------------------------------------------------

def load_results(results_dir):
    """Load and merge all JSON result files from a directory."""
    all_results = []
    for path in sorted(glob.glob(os.path.join(results_dir, "*.json"))):
        try:
            with open(path) as f:
                data = json.load(f)
            all_results.extend(data)
            print(f"  Loaded {len(data)} results from {os.path.basename(path)}")
        except (json.JSONDecodeError, IOError) as e:
            print(f"  Warning: skipping {path}: {e}", file=sys.stderr)
    return all_results


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

def classify_backend(name, scenario=""):
    """Classify a result into a chart category.

    Returns one of: disk, memory, git, disk_parallel, memory_parallel,
    optims_disk, optims_memory, optims_lavyek, skip.

    Note: trace replay and parallel scaling results are classified by
    backend type (disk/memory), not into separate categories. Use
    classify_for_readme() if you need trace/parallel categories.
    """
    n = name.lower()
    s = scenario.lower()

    # Skip parallel scaling data (handled by gen_chart_scaling.py)
    if "tezos-parallel-" in s or s == "tezos-sequential":
        return "skip"

    # Parallel scenario results (commits-20B-100f/12d or parallel-reads-20B-12d×100f)
    # Only classify as disk_parallel/memory_parallel if it's a standard parallel run
    # (100 fibers), not a scaling sweep (variable fiber counts → handled by scaling chart).
    m_old = re.search(r'-(\d+)f/(\d+)d$', s)
    m_new = re.search(r'-(\d+)d[×x](\d+)f$', s)
    if m_old or m_new:
        fibers = int(m_old.group(1)) if m_old else int(m_new.group(2))
        # Skip scaling sweep data (handled by gen_chart_scaling.py)
        if fibers != 100:
            return "skip"
        # Optimization variants: skip parallel (not run for optims)
        if any(x in n for x in ["baseline", "+inline", "+cache", "+inode", "+all"]):
            return "skip"
        if "memory" in n or "mem" in n:
            return "memory_parallel"
        elif "git" in n:
            return "skip"  # no parallel git benchmarks
        else:
            return "disk_parallel"

    # Parallel variant backends (e.g. "Irmini (lavyek) 12d×50kf")
    if "12d\u00d7" in name or "12d×" in name:
        if "memory" in n or "mem" in n:
            return "memory_parallel"
        else:
            return "disk_parallel"

    # Optimization variants go to their own chart
    if any(x in n for x in ["baseline", "+inline", "+cache", "+inode", "+all"]):
        if "(disk)" in n:
            return "optims_disk"
        if "(lavyek)" in n:
            return "optims_lavyek"
        return "optims_memory"

    # By backend type
    if "memory" in n or "mem" in n:
        return "memory"
    if "git" in n:
        return "git"

    # Everything else: fs, disk, pack, lavyek
    return "disk"


def classify_for_readme(name, scenario):
    """Classify a result for README generation.

    Same as classify_backend but also distinguishes trace and parallel
    scaling categories.
    """
    n = name.lower()
    s = scenario.lower()

    # Optimization variants first (before parallel check)
    if any(x in n for x in ["baseline", "+inline", "+cache", "+inode", "+all"]):
        if re.search(r'-\d+f/\d+d$', s):
            return "skip"
        if "(disk)" in n:
            return "optims_disk"
        if "(lavyek)" in n:
            return "optims_lavyek"
        return "optims_memory"

    # Parallel scenario results
    if re.search(r'-\d+f/\d+d$', s):
        if "memory" in n or "mem" in n:
            return "memory_parallel"
        elif "git" in n:
            return "skip"
        else:
            return "disk_parallel"

    # Parallel tezos variants (e.g. "Irmini (lavyek) 12d×50kf")
    if "12d\u00d7" in name or "12d×" in name:
        if "memory" in n or "mem" in n:
            return "memory_parallel"
        else:
            return "disk_parallel"

    # Parallel scaling
    if "tezos-parallel" in s:
        return "parallel"

    # Trace replay (sequential)
    if "tezos-" in s:
        return "trace"

    # By backend type
    if "memory" in n or "mem" in n:
        return "memory"
    if "git" in n:
        return "git"

    return "disk"


# ---------------------------------------------------------------------------
# Scenario and backend ordering
# ---------------------------------------------------------------------------

SCENARIO_ORDER = [
    "commits-20B", "reads-20B", "incremental-20B",
    "commits-10K", "reads-10K", "incremental-10K",
    "tezos-10310commits", "tezos",
]

BACKEND_ORDER_DISK = [
    "Irmin-Lwt (pack)", "Irmin-Lwt (fs)",
    "Irmin-Eio (pack)", "Irmin-Eio (fs)",
    "Irmini (lavyek)", "Irmini (disk)",
]

BACKEND_ORDER_MEMORY = [
    "Irmin-Lwt (memory)", "Irmin-Eio (memory)", "Irmini (memory)",
]

BACKEND_ORDER_GIT = [
    "Irmin-Lwt (git)", "Irmin-Eio (git)", "Irmini (git)",
]

BACKEND_ORDER_OPTIMS_MEMORY = [
    "Irmini baseline", "Irmini+inline", "Irmini+cache",
    "Irmini+inode", "Irmini+all",
]

BACKEND_ORDER_OPTIMS_DISK = [
    "Irmini baseline (disk)", "Irmini+inline (disk)", "Irmini+cache (disk)",
    "Irmini+inode (disk)", "Irmini+all (disk)",
]

BACKEND_ORDER_OPTIMS_LAVYEK = [
    "Irmini baseline (lavyek)", "Irmini+inline (lavyek)", "Irmini+cache (lavyek)",
    "Irmini+inode (lavyek)", "Irmini+all (lavyek)",
]

OPTIM_ORDER_MEM = BACKEND_ORDER_OPTIMS_MEMORY
OPTIM_ORDER_DISK = BACKEND_ORDER_OPTIMS_DISK
OPTIM_ORDER_LAVYEK = BACKEND_ORDER_OPTIMS_LAVYEK


def scenario_sort_key(name):
    """Sort scenarios in the canonical order."""
    try:
        return (0, SCENARIO_ORDER.index(name))
    except ValueError:
        s = name.lower()
        if "tezos" in s:
            return (2, s)
        return (3, s)


def backend_sort_key(name, order):
    """Sort key using a predefined order list."""
    if name in order:
        return (0, order.index(name))
    return (1, name)


def family_sort_key(name):
    """Sort backends: Irmin-Lwt first, then Irmin-Eio, then Irmini.
    Sequential references (seq) sort right after their parallel counterpart."""
    n = name.lower()
    if name in OPTIM_ORDER_MEM:
        return (0, OPTIM_ORDER_MEM.index(name))
    elif name in OPTIM_ORDER_DISK:
        return (0, OPTIM_ORDER_DISK.index(name))
    elif name in OPTIM_ORDER_LAVYEK:
        return (0, OPTIM_ORDER_LAVYEK.index(name))
    elif "irmin-lwt" in n:
        return (0, name)
    elif "irmin-eio" in n or "irmin-pack" in n or "irmin-fs" in n or "irmin-git" in n:
        base = (1, name.replace(" (seq)", ""))
        return (base[0], base[1], 1 if "(seq)" in name else 0)
    elif "irmini" in n:
        base = (2, name.replace(" (seq)", ""))
        return (base[0], base[1], 1 if "(seq)" in name else 0)
    return (3, name)


# ---------------------------------------------------------------------------
# Colors and visual styling
# ---------------------------------------------------------------------------

COLORS = {
    "Irmin-Lwt (memory)": "#f28e2b",
    "Irmin-Lwt (pack)":   "#f5a623",
    "Irmin-Lwt (fs)":     "#f7c96e",
    "Irmin-Lwt (git)":    "#f9dda0",
    "Irmin-Eio (memory)": "#e15759",
    "Irmin-Eio (pack)":   "#e87c7e",
    "Irmin-Eio (fs)":     "#f0a1a2",
    "Irmin-Eio (git)":    "#f5c0c1",
    "Irmini (memory)":    "#4e79a7",
    "Irmini (disk)":      "#466680",
    "Irmini (disk, no fsync)": "#6d9dc5",
    "Irmini (lavyek)":    "#2d6e2e",
    "Irmini (lavyek, fsync)":    "#2d6e2e",
    "Irmini (lavyek, no fsync)": "#59a14f",
    "Irmini (git)":       "#8bc584",
    # Tezos trace replay
    "Irmin-Lwt (pack-mem)": "#f28e2b",
    "Irmin-Eio (pack-mem)": "#e15759",
    # Parallel variants (same color as base, rendered with hatching)
    "Irmini (lavyek, no fsync) 12d×50kf": "#59a14f",
    "Irmin-Eio (pack) 12d×1f":  "#e87c7e",
    # Optimization variants (memory and disk share same colors)
    "Irmini baseline":    "#bbb",
    "Irmini+inline":      "#9c755f",
    "Irmini+cache":       "#76b7b2",
    "Irmini+inode":       "#b07aa1",
    "Irmini+all":         "#4e79a7",
    "Irmini baseline (disk)": "#bbb",
    "Irmini+inline (disk)":   "#9c755f",
    "Irmini+cache (disk)":    "#76b7b2",
    "Irmini+inode (disk)":    "#b07aa1",
    "Irmini+all (disk)":      "#4e79a7",
    "Irmini baseline (lavyek)": "#bbb",
    "Irmini+inline (lavyek)":   "#9c755f",
    "Irmini+cache (lavyek)":    "#76b7b2",
    "Irmini+inode (lavyek)":    "#b07aa1",
    "Irmini+all (lavyek)":      "#4e79a7",
}


def is_parallel_variant(name):
    """Check if a backend name is a parallel variant (shown with hatching)."""
    return "12d\u00d7" in name or "12d×" in name


def is_tezos_parallel(name):
    """Check if a parallel variant uses non-standard (tezos) parameters.
    Standard parallel uses 100f; tezos uses other counts like 50kf, 1f."""
    if not is_parallel_variant(name):
        return False
    return "×100f" not in name and "\u00d7100f" not in name


def is_seq_reference(name):
    """Check if a backend name is a sequential reference on a parallel chart."""
    return name.endswith(" (seq)")


def lighten_hex(color, factor=0.45):
    """Lighten a hex color by mixing with white."""
    if not color.startswith("#") or len(color) != 7:
        return color
    r = int(color[1:3], 16)
    g = int(color[3:5], 16)
    b = int(color[5:7], 16)
    r = int(r + (255 - r) * factor)
    g = int(g + (255 - g) * factor)
    b = int(b + (255 - b) * factor)
    return f"#{r:02x}{g:02x}{b:02x}"


def darken_hex(color, factor=0.35):
    """Darken a hex color by mixing with black."""
    if not color.startswith("#") or len(color) != 7:
        return color
    r = int(color[1:3], 16)
    g = int(color[3:5], 16)
    b = int(color[5:7], 16)
    r = int(r * (1 - factor))
    g = int(g * (1 - factor))
    b = int(b * (1 - factor))
    return f"#{r:02x}{g:02x}{b:02x}"


def get_color(name):
    """Get a color for a given backend name."""
    if name in COLORS:
        return COLORS[name]
    # Sequential reference: lighter version of base color
    if is_seq_reference(name):
        base = name.replace(" (seq)", "")
        base_color = get_color(base)
        return lighten_hex(base_color)
    # For parallel variants, first try exact base name, then keyword fallback
    if is_parallel_variant(name):
        base = re.sub(r'\s+\d+d[×x]\d+\w*f?$', '', name)
        if base in COLORS:
            return COLORS[base]
        for key in ("lavyek", "pack", "disk", "memory", "fs", "git"):
            if key in name.lower():
                for cname, color in COLORS.items():
                    if key in cname.lower() and not is_parallel_variant(cname):
                        return color
    # Fallback: hash-based color
    h = hash(name) % 360
    return f"hsl({h}, 60%, 55%)"


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

def fmt_ops(v):
    """Format ops/s for display (compact form)."""
    if v >= 1_000_000:
        return f"{v/1_000_000:.1f}M"
    if v >= 10_000:
        return f"{v/1_000:.0f}k"
    if v >= 1_000:
        return f"{v/1_000:.1f}k"
    return str(int(v))


def fmt_ops_chart(v):
    """Format ops/s for chart labels (shorter form)."""
    if v >= 1_000_000:
        return f"{v/1_000_000:.1f}M"
    if v >= 1_000:
        return f"{v/1_000:.0f}k"
    return str(int(v))


def fmt_fibers(n):
    """Format fiber count for display."""
    if n >= 1000:
        return f"{n // 1000}k"
    return str(n)


def extract_fibers(scenario):
    """Extract fiber count from scenario like 'tezos-parallel-12d×1000f'."""
    m = re.search(r'(\d+)f', scenario)
    return int(m.group(1)) if m else 0


# ---------------------------------------------------------------------------
# Parallel scenario helpers
# ---------------------------------------------------------------------------

def remap_parallel_scenarios(results, rename_backends=False):
    """Remap parallel scenario names to their base form for charting.

    Handles both old format "commits-20B-100f/12d" and new format
    "parallel-commits-20B-12d×100f".
    If rename_backends=True, also rename backends with the parallel config suffix
    (e.g. "Irmini (lavyek)" -> "Irmini (lavyek) 12d×100f") so they get hatching.
    """
    remapped = []
    for r in results:
        # Old format: commits-20B-100f/12d
        m = re.match(r'^(.+)-(\d+)f/(\d+)d$', r["scenario"])
        if m:
            new_r = {**r, "scenario": m.group(1)}
            if rename_backends:
                fibers = m.group(2)
                domains = m.group(3)
                new_r["name"] = f"{r['name']} {domains}d×{fibers}f"
            remapped.append(new_r)
            continue
        # New format: parallel-commits-20B-12d×100f
        m2 = re.match(r'^parallel-(.+)-(\d+)d[×x](\d+)f$', r["scenario"])
        if m2:
            new_r = {**r, "scenario": m2.group(1)}
            if rename_backends:
                domains = m2.group(2)
                fibers = m2.group(3)
                new_r["name"] = f"{r['name']} {domains}d×{fibers}f"
            remapped.append(new_r)
    return remapped


# ---------------------------------------------------------------------------
# Lookup helpers
# ---------------------------------------------------------------------------

def build_lookup(results):
    """Build a lookup dict: (name, scenario) -> result."""
    lookup = {}
    for r in results:
        lookup[(r["name"], r["scenario"])] = r
    return lookup


def get_sorted_scenarios(results):
    """Get unique scenarios sorted by scenario_sort_key."""
    seen = set()
    scenarios = []
    for r in results:
        if r["scenario"] not in seen:
            scenarios.append(r["scenario"])
            seen.add(r["scenario"])
    return sorted(scenarios, key=scenario_sort_key)


def get_sorted_backends(results, order):
    """Get unique backend names sorted by the given order."""
    seen = set()
    names = []
    for r in results:
        if r["name"] not in seen:
            names.append(r["name"])
            seen.add(r["name"])
    return sorted(names, key=lambda n: backend_sort_key(n, order))


def ordered_backends(results):
    """Get unique backend names, sorted by family then name."""
    seen = set()
    names = []
    for r in results:
        if r["name"] not in seen:
            names.append(r["name"])
            seen.add(r["name"])
    return sorted(names, key=family_sort_key)
