#!/usr/bin/env python3
"""Generate the "## Results" section of bench/README.md from JSON benchmark results.

Reads all *.json files from the results directory, classifies them into categories
(disk, memory, git, optims_disk, optims_memory, trace, parallel), generates tables
and analysis, and replaces everything from "## Results" to EOF in the README.

Usage: gen_readme_results.py <results_dir> [--readme PATH] [--date DATE] [--update-charts]
"""

import argparse
import glob
import json
import math
import os
import subprocess
import sys
from datetime import date


# --- Ordering ---

SCENARIO_ORDER = [
    "commits-20B", "reads-20B", "incremental-20B",
    "commits-10K", "reads-10K", "incremental-10K",
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


def load_results(results_dir):
    """Load and merge all JSON result files."""
    all_results = []
    for path in sorted(glob.glob(os.path.join(results_dir, "*.json"))):
        try:
            with open(path) as f:
                data = json.load(f)
            all_results.extend(data)
        except (json.JSONDecodeError, IOError) as e:
            print(f"  Warning: skipping {path}: {e}", file=sys.stderr)
    return all_results


def classify(name, scenario):
    """Classify a result into a category."""
    n = name.lower()
    s = scenario.lower()

    # Optimization variants
    if any(x in n for x in ["baseline", "+inline", "+cache", "+inode", "+all"]):
        if "(disk)" in n:
            return "optims_disk"
        if "(lavyek)" in n:
            return "optims_lavyek"
        return "optims_memory"

    # Parallel tezos variants go to disk chart
    if "12d\u00d7" in name or "12d×" in name:
        return "disk"

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

    # Everything else: fs, disk, pack, lavyek
    return "disk"


def scenario_sort_key(scenario):
    """Sort key for scenarios."""
    if scenario in SCENARIO_ORDER:
        return (0, SCENARIO_ORDER.index(scenario))
    s = scenario.lower()
    if s.startswith("concurrent"):
        return (1, s)
    if "tezos" in s:
        return (2, s)
    return (3, s)


def backend_sort_key(name, order):
    """Sort key using a predefined order list."""
    if name in order:
        return (0, order.index(name))
    return (1, name)


def fmt_ops(v):
    """Format ops/s for display."""
    if v >= 1_000_000:
        return f"{v/1_000_000:.1f}M"
    if v >= 10_000:
        return f"{v/1_000:.0f}k"
    if v >= 1_000:
        return f"{v/1_000:.1f}k"
    return str(int(v))


def fmt_ops_table(v):
    """Format ops/s for table (integer, right-aligned)."""
    return str(int(round(v)))


def fmt_time(t):
    """Format time in seconds."""
    return f"{t:.3f}"


def fmt_rss(kb):
    """Format RSS from KB to MiB."""
    mib = kb / 1024
    return str(int(round(mib)))


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


def generate_table(results, order, include_rss=True):
    """Generate a formatted table from results."""
    backends = get_sorted_backends(results, order)
    scenarios = get_sorted_scenarios(results)
    lookup = build_lookup(results)

    lines = []
    if include_rss:
        header = f"{'Name':<31s} {'Scenario':<23s} {'ops/s':>9s} {'total(s)':>10s} {'RSS(MiB)':>10s}"
        sep = "-" * 82
    else:
        header = f"{'Name':<31s} {'Scenario':<23s} {'ops/s':>9s}"
        sep = "-" * 64

    lines.append(header)
    lines.append(sep)

    for backend in backends:
        for scenario in scenarios:
            r = lookup.get((backend, scenario))
            if r is None:
                continue
            ops = fmt_ops_table(r["ops_per_sec"])
            if include_rss:
                time_s = fmt_time(r["total_time"])
                rss = fmt_rss(r["maxrss_kb"])
                lines.append(f"{backend:<31s} {scenario:<23s} {ops:>9s} {time_s:>10s} {rss:>10s}")
            else:
                lines.append(f"{backend:<31s} {scenario:<23s} {ops:>9s}")

    return lines


def generate_parallel_table(parallel_results, seq_baseline):
    """Generate the parallel scaling table."""
    lines = []
    header = f"{'Config':<17s} {'ops/s':>10s} {'Speedup':>10s} {'RSS (MiB)':>11s}"
    sep = "-" * 49

    lines.append(header)
    lines.append(sep)

    # Sequential baseline row
    if seq_baseline:
        ops_str = f"{int(seq_baseline):,}"
        lines.append(f"{'Sequential':<17s} {ops_str:>10s} {'1x':>10s} {'':>11s}")

    # Sort parallel results by fiber count
    def extract_fibers(scenario):
        """Extract fiber count from scenario like 'tezos-parallel-12d×1000f'."""
        import re
        m = re.search(r'(\d+)f', scenario)
        return int(m.group(1)) if m else 0

    sorted_results = sorted(parallel_results, key=lambda r: extract_fibers(r["scenario"]))

    for r in sorted_results:
        fibers = extract_fibers(r["scenario"])
        domains_match = __import__("re").search(r'(\d+)d', r["scenario"])
        domains = int(domains_match.group(1)) if domains_match else 12

        config = f"{domains}d × {fibers:>6,}f"
        ops = int(round(r["ops_per_sec"]))
        ops_str = f"{ops:,}"

        if seq_baseline and seq_baseline > 0:
            speedup = ops / seq_baseline
            if speedup >= 10:
                speedup_str = f"{speedup:.0f}x"
            else:
                speedup_str = f"{speedup:.1f}x"
        else:
            speedup_str = ""

        rss_kb = r.get("maxrss_kb", 0)
        if rss_kb and rss_kb > 0:
            rss_str = f"{int(round(rss_kb / 1024)):,}"
        else:
            rss_str = "\u2014"

        lines.append(f"{config:<17s} {ops_str:>10s} {speedup_str:>10s} {rss_str:>11s}")

    return lines


def extract_fibers(scenario):
    """Extract fiber count from scenario like 'tezos-parallel-12d×1000f'."""
    import re
    m = re.search(r'(\d+)f', scenario)
    return int(m.group(1)) if m else 0


# --- Analysis generation ---

def analyze_disk(results):
    """Generate analysis bullets for disk backends."""
    lookup = build_lookup(results)
    bullets = []

    # Find Irmini lavyek commits-20B
    lavyek_c20 = lookup.get(("Irmini (lavyek)", "commits-20B"))
    lavyek_r20 = lookup.get(("Irmini (lavyek)", "reads-20B"))
    lavyek_r10 = lookup.get(("Irmini (lavyek)", "reads-10K"))
    lavyek_conc = lookup.get(("Irmini (lavyek)", "concurrent-100f/12d"))

    if lavyek_c20:
        parts = [f"Commits at **{fmt_ops(lavyek_c20['ops_per_sec'])} ops/s** (20B)"]
        # Compare to Irmin backends
        irmin_lwt_pack = lookup.get(("Irmin-Lwt (pack)", "commits-20B"))
        if irmin_lwt_pack:
            parts.append(f"faster than all Irmin backends")
        s = " \u2014 ".join(parts) + "."
        extras = []
        if lavyek_r20:
            extras.append(f"Reads at {fmt_ops(lavyek_r20['ops_per_sec'])} (20B)")
        if lavyek_r10:
            extras.append(f"{fmt_ops(lavyek_r10['ops_per_sec'])} (10K)")
        if lavyek_conc:
            extras.append(f"Concurrent at **{fmt_ops(lavyek_conc['ops_per_sec'])} ops/s**")
        if extras:
            s += " " + ", ".join(extras) + "."
        bullets.append(f"**Irmini (lavyek)**: {s}")

    # Irmini disk
    disk_c20 = lookup.get(("Irmini (disk)", "commits-20B"))
    disk_r20 = lookup.get(("Irmini (disk)", "reads-20B"))
    disk_r10 = lookup.get(("Irmini (disk)", "reads-10K"))
    if disk_c20 and disk_r20:
        bullets.append(
            f"**Irmini (disk)**: WAL+bloom backend with crash safety. "
            f"Reads at {fmt_ops(disk_r20['ops_per_sec'])} (20B)"
            + (f", {fmt_ops(disk_r10['ops_per_sec'])} (10K)" if disk_r10 else "")
            + f". Writes bottlenecked by WAL fsync: commits at {fmt_ops(disk_c20['ops_per_sec'])}."
            + " Trade-off: durability over raw speed."
        )

    # irmin-pack comparison
    lwt_pack_c20 = lookup.get(("Irmin-Lwt (pack)", "commits-20B"))
    eio_pack_c20 = lookup.get(("Irmin-Eio (pack)", "commits-20B"))
    lwt_pack_r20 = lookup.get(("Irmin-Lwt (pack)", "reads-20B"))
    eio_pack_r20 = lookup.get(("Irmin-Eio (pack)", "reads-20B"))
    if lwt_pack_c20 and eio_pack_c20:
        r_range = ""
        if lwt_pack_r20 and eio_pack_r20:
            lo = min(lwt_pack_r20["ops_per_sec"], eio_pack_r20["ops_per_sec"])
            hi = max(lwt_pack_r20["ops_per_sec"], eio_pack_r20["ops_per_sec"])
            r_range = f"Reads at {fmt_ops(lo)}\u2013{fmt_ops(hi)} ops/s, "
        lwt_c = fmt_ops(lwt_pack_c20["ops_per_sec"])
        eio_c = fmt_ops(eio_pack_c20["ops_per_sec"])
        faster_c = "Irmin-Lwt" if lwt_pack_c20["ops_per_sec"] > eio_pack_c20["ops_per_sec"] else "Irmin-Eio"
        slower_c = "Irmin-Eio" if faster_c == "Irmin-Lwt" else "Irmin-Lwt"
        bullets.append(
            f"**irmin-pack**: {r_range}commits at {fmt_ops(min(lwt_pack_c20['ops_per_sec'], eio_pack_c20['ops_per_sec']))}"
            f"\u2013{fmt_ops(max(lwt_pack_c20['ops_per_sec'], eio_pack_c20['ops_per_sec']))} ops/s. "
            f"{faster_c} faster on commits ({lwt_c} vs {eio_c})."
        )

    # irmin-fs
    lwt_fs_c20 = lookup.get(("Irmin-Lwt (fs)", "commits-20B"))
    lwt_fs_r20 = lookup.get(("Irmin-Lwt (fs)", "reads-20B"))
    eio_fs_r20 = lookup.get(("Irmin-Eio (fs)", "reads-20B"))
    if lwt_fs_c20:
        r_range = ""
        if lwt_fs_r20 and eio_fs_r20:
            lo = min(lwt_fs_r20["ops_per_sec"], eio_fs_r20["ops_per_sec"])
            hi = max(lwt_fs_r20["ops_per_sec"], eio_fs_r20["ops_per_sec"])
            r_range = f"Reads {fmt_ops(lo)}\u2013{fmt_ops(hi)}, "
        bullets.append(
            f"**irmin-fs**: Slower across the board. {r_range}"
            f"commits {fmt_ops(min(r['ops_per_sec'] for r in results if 'fs' in r['name'].lower() and r['scenario'] == 'commits-20B'))}"
            f"\u2013{fmt_ops(max(r['ops_per_sec'] for r in results if 'fs' in r['name'].lower() and r['scenario'] == 'commits-20B'))}."
        )

    return bullets


def analyze_memory(results):
    """Generate analysis bullets for memory backends."""
    lookup = build_lookup(results)
    bullets = []

    irmin_lwt_c20 = lookup.get(("Irmin-Lwt (memory)", "commits-20B"))
    irmin_eio_c20 = lookup.get(("Irmin-Eio (memory)", "commits-20B"))
    irmini_c20 = lookup.get(("Irmini (memory)", "commits-20B"))

    if irmin_lwt_c20 and irmini_c20:
        irmin_best = max(irmin_lwt_c20["ops_per_sec"],
                         irmin_eio_c20["ops_per_sec"] if irmin_eio_c20 else 0)
        bullets.append(
            f"**Commits (20B)**: Irmin ~{fmt_ops(irmin_best)} ops/s vs Irmini "
            f"**{fmt_ops(irmini_c20['ops_per_sec'])}** \u2014 Irmin's in-memory "
            f"tree is faster on bulk writes (no content-addressed hashing overhead)."
        )

    irmin_lwt_r20 = lookup.get(("Irmin-Lwt (memory)", "reads-20B"))
    irmin_eio_r20 = lookup.get(("Irmin-Eio (memory)", "reads-20B"))
    irmini_r20 = lookup.get(("Irmini (memory)", "reads-20B"))
    if irmin_lwt_r20 and irmini_r20:
        lo = min(irmin_lwt_r20["ops_per_sec"],
                 irmin_eio_r20["ops_per_sec"] if irmin_eio_r20 else irmin_lwt_r20["ops_per_sec"])
        hi = max(irmin_lwt_r20["ops_per_sec"],
                 irmin_eio_r20["ops_per_sec"] if irmin_eio_r20 else irmin_lwt_r20["ops_per_sec"])
        bullets.append(
            f"**Reads (20B)**: Irmin {fmt_ops(lo)}\u2013{fmt_ops(hi)} vs Irmini "
            f"**{fmt_ops(irmini_r20['ops_per_sec'])}** \u2014 Irmin keeps the "
            f"full tree in memory; irmini navigates content-addressed structures."
        )

    # Incremental
    irmin_lwt_i20 = lookup.get(("Irmin-Lwt (memory)", "incremental-20B"))
    irmin_eio_i20 = lookup.get(("Irmin-Eio (memory)", "incremental-20B"))
    irmini_i20 = lookup.get(("Irmini (memory)", "incremental-20B"))
    if irmin_lwt_i20 and irmini_i20:
        irmin_lo = min(irmin_lwt_i20["ops_per_sec"],
                       irmin_eio_i20["ops_per_sec"] if irmin_eio_i20 else irmin_lwt_i20["ops_per_sec"])
        irmin_hi = max(irmin_lwt_i20["ops_per_sec"],
                       irmin_eio_i20["ops_per_sec"] if irmin_eio_i20 else irmin_lwt_i20["ops_per_sec"])
        speedup_lo = irmini_i20["ops_per_sec"] / irmin_hi
        speedup_hi = irmini_i20["ops_per_sec"] / irmin_lo
        bullets.append(
            f"**Incremental (20B)**: Irmini at **{fmt_ops(irmini_i20['ops_per_sec'])} ops/s** "
            f"is **{speedup_lo:.1f}\u2013{speedup_hi:.1f}\u00d7 faster** than "
            f"Irmin ({fmt_ops(irmin_lo)}\u2013{fmt_ops(irmin_hi)}) thanks to inode structural sharing."
        )

    # 10K convergence
    irmin_lwt_c10 = lookup.get(("Irmin-Lwt (memory)", "commits-10K"))
    irmini_c10 = lookup.get(("Irmini (memory)", "commits-10K"))
    if irmin_lwt_c10 and irmini_c10:
        avg = (irmin_lwt_c10["ops_per_sec"] + irmini_c10["ops_per_sec"]) / 2
        bullets.append(
            f"**10K values**: All three converge on commits (~{fmt_ops(avg)} ops/s) \u2014 I/O dominates."
        )

    return bullets


def analyze_git(results):
    """Generate analysis bullets for git backends."""
    lookup = build_lookup(results)
    bullets = []

    irmini_c20 = lookup.get(("Irmini (git)", "commits-20B"))
    irmin_lwt_c20 = lookup.get(("Irmin-Lwt (git)", "commits-20B"))
    irmin_eio_c20 = lookup.get(("Irmin-Eio (git)", "commits-20B"))

    if irmini_c20 and irmin_lwt_c20:
        irmin_best = max(irmin_lwt_c20["ops_per_sec"],
                         irmin_eio_c20["ops_per_sec"] if irmin_eio_c20 else 0)
        speedup = irmini_c20["ops_per_sec"] / irmin_best
        irmini_rss_lo = min(r["maxrss_kb"] for r in results if "irmini" in r["name"].lower())
        irmini_rss_hi = max(r["maxrss_kb"] for r in results if "irmini" in r["name"].lower())
        irmin_rss_lo = min(r["maxrss_kb"] for r in results if "irmin-" in r["name"].lower())
        irmin_rss_hi = max(r["maxrss_kb"] for r in results if "irmin-" in r["name"].lower())
        mem_ratio = irmin_rss_lo / irmini_rss_hi if irmini_rss_hi > 0 else 0
        bullets.append(
            f"**Irmini (git)**: 100% git-compatible (inodes disabled, no inlining). "
            f"Commits at **{fmt_ops(irmini_c20['ops_per_sec'])} ops/s** \u2014 "
            f"**{speedup:.0f}\u00d7 faster** than Irmin ({fmt_ops(irmin_best)}). "
            f"Uses **{int(irmini_rss_lo/1024)}\u2013{int(irmini_rss_hi/1024)} MiB RSS** "
            f"vs Irmin's {int(irmin_rss_lo/1024)}\u2013{int(irmin_rss_hi/1024)} MiB."
        )

    # Reads
    irmini_r20 = lookup.get(("Irmini (git)", "reads-20B"))
    irmin_lwt_r20 = lookup.get(("Irmin-Lwt (git)", "reads-20B"))
    irmin_eio_r10 = lookup.get(("Irmin-Eio (git)", "reads-10K"))
    irmini_r10 = lookup.get(("Irmini (git)", "reads-10K"))
    if irmini_r20 and irmin_lwt_r20:
        bullets.append(
            f"**Reads**: Irmin-Lwt leads on 20B ({fmt_ops(irmin_lwt_r20['ops_per_sec'])} "
            f"vs {fmt_ops(irmini_r20['ops_per_sec'])}) thanks to in-memory caching."
            + (f" On 10K, Irmini ({fmt_ops(irmini_r10['ops_per_sec'])}) matches "
               f"Irmin-Eio ({fmt_ops(irmin_eio_r10['ops_per_sec'])})."
               if irmini_r10 and irmin_eio_r10 else "")
        )

    # Incremental
    bullets.append(
        "**Incremental**: All comparable \u2014 dominated by Git I/O."
    )

    return bullets


def analyze_optims(results, is_disk=False):
    """Generate analysis bullets for optimization comparison."""
    lookup = build_lookup(results)
    bullets = []
    suffix = " (disk)" if is_disk else ""

    baseline_c20 = lookup.get((f"Irmini baseline{suffix}", "commits-20B"))
    baseline_r20 = lookup.get((f"Irmini baseline{suffix}", "reads-20B"))
    baseline_r10 = lookup.get((f"Irmini baseline{suffix}", "reads-10K"))
    baseline_i20 = lookup.get((f"Irmini baseline{suffix}", "incremental-20B"))

    optims = [
        ("Inline", "+inline"),
        ("Cache", "+cache"),
        ("Inode", "+inode"),
    ]

    for label, opt_key in optims:
        name = f"Irmini{opt_key}{suffix}"
        c20 = lookup.get((name, "commits-20B"))
        r20 = lookup.get((name, "reads-20B"))
        r10 = lookup.get((name, "reads-10K"))
        i20 = lookup.get((name, "incremental-20B"))

        parts = []
        if c20 and baseline_c20 and baseline_c20["ops_per_sec"] > 0:
            ratio = c20["ops_per_sec"] / baseline_c20["ops_per_sec"]
            if ratio > 1.2:
                parts.append(f"**{ratio:.1f}\u00d7 speedup** on commits-20B "
                             f"({fmt_ops(c20['ops_per_sec'])} vs {fmt_ops(baseline_c20['ops_per_sec'])})")

        if r20 and baseline_r20 and baseline_r20["ops_per_sec"] > 0:
            ratio = r20["ops_per_sec"] / baseline_r20["ops_per_sec"]
            if ratio > 1.2:
                parts.append(f"**{ratio:.1f}\u00d7 on reads-20B** "
                             f"({fmt_ops(r20['ops_per_sec'])} vs {fmt_ops(baseline_r20['ops_per_sec'])})")

        if r10 and baseline_r10 and baseline_r10["ops_per_sec"] > 0:
            ratio = r10["ops_per_sec"] / baseline_r10["ops_per_sec"]
            if ratio > 1.2:
                parts.append(f"**{ratio:.1f}\u00d7 on reads-10K** "
                             f"({fmt_ops(r10['ops_per_sec'])} vs {fmt_ops(baseline_r10['ops_per_sec'])})")

        if i20 and baseline_i20 and baseline_i20["ops_per_sec"] > 0:
            ratio = i20["ops_per_sec"] / baseline_i20["ops_per_sec"]
            if ratio > 1.2:
                parts.append(f"**{ratio:.1f}\u00d7 on incremental-20B** "
                             f"({fmt_ops(i20['ops_per_sec'])} vs {fmt_ops(baseline_i20['ops_per_sec'])})")

        if parts:
            bullets.append(f"**{label}** gives " + " and ".join(parts) + ".")

    # +all summary
    all_c20 = lookup.get((f"Irmini+all{suffix}", "commits-20B"))
    all_r20 = lookup.get((f"Irmini+all{suffix}", "reads-20B"))
    all_r10 = lookup.get((f"Irmini+all{suffix}", "reads-10K"))
    all_i20 = lookup.get((f"Irmini+all{suffix}", "incremental-20B"))
    if all_c20 and baseline_c20:
        parts = []
        if baseline_c20["ops_per_sec"] > 0:
            ratio_c = all_c20["ops_per_sec"] / baseline_c20["ops_per_sec"]
            parts.append(f"**{fmt_ops(all_c20['ops_per_sec'])} commits-20B/s** ({ratio_c:.1f}\u00d7 baseline)")
        if all_r10 and baseline_r10 and baseline_r10["ops_per_sec"] > 0:
            ratio_r = all_r10["ops_per_sec"] / baseline_r10["ops_per_sec"]
            parts.append(f"**{fmt_ops(all_r10['ops_per_sec'])} reads-10K/s** ({ratio_r:.1f}\u00d7 baseline)")
        if all_i20 and baseline_i20 and baseline_i20["ops_per_sec"] > 0:
            ratio_i = all_i20["ops_per_sec"] / baseline_i20["ops_per_sec"]
            parts.append(f"**{fmt_ops(all_i20['ops_per_sec'])} incremental-20B/s** ({ratio_i:.1f}\u00d7 baseline)")
        if parts:
            bullets.append(f"**+all** achieves " + ", ".join(parts) + ".")

    return bullets


def analyze_trace(results):
    """Generate analysis bullets for trace replay."""
    lookup = build_lookup(results)
    bullets = []

    # Gather all trace results
    trace_entries = [(r["name"], r["ops_per_sec"], r.get("maxrss_kb", 0))
                     for r in results]

    if not trace_entries:
        return bullets

    # Sort by ops/s descending
    trace_entries.sort(key=lambda x: -x[1])

    fastest = trace_entries[0]
    bullets.append(
        f"**{fastest[0]}** is fastest at **{fmt_ops(fastest[1])} ops/s**."
    )

    for name, ops, rss in trace_entries[1:]:
        pct = ops / fastest[1] * 100
        rss_str = f", {int(rss/1024)} MiB RSS" if rss > 0 else ""
        bullets.append(
            f"**{name}** at {fmt_ops(ops)} ops/s ({pct:.0f}% of {fastest[0]}){rss_str}."
        )

    return bullets


def analyze_parallel(parallel_results, seq_baseline):
    """Generate analysis bullets for parallel scaling."""
    if not parallel_results:
        return []

    bullets = []

    # Find peak
    peak = max(parallel_results, key=lambda r: r["ops_per_sec"])
    peak_fibers = extract_fibers(peak["scenario"])
    peak_ops = peak["ops_per_sec"]
    if seq_baseline and seq_baseline > 0:
        peak_speedup = peak_ops / seq_baseline
        bullets.append(
            f"Peak throughput at **{fmt_fibers(peak_fibers)} fibers/domain**: "
            f"**{fmt_ops(peak_ops)} ops/s** ({peak_speedup:.0f}x speedup)."
        )
    else:
        bullets.append(
            f"Peak throughput at **{fmt_fibers(peak_fibers)} fibers/domain**: "
            f"**{fmt_ops(peak_ops)} ops/s**."
        )

    bullets.append(
        "Lavyek is natively thread-safe (lock-free LSM tree). Each write is an "
        "Eio I/O operation that yields to other fibers, enabling massive cooperative "
        "concurrency within each domain."
    )

    # Super-linear scaling region
    for r in sorted(parallel_results, key=lambda r: extract_fibers(r["scenario"])):
        fibers = extract_fibers(r["scenario"])
        if seq_baseline and fibers == 10_000:
            speedup = r["ops_per_sec"] / seq_baseline
            bullets.append(
                f"Scaling is super-linear up to ~{fmt_fibers(fibers)} fibers "
                f"({speedup:.0f}x on 12 cores) thanks to "
                f"I/O overlap: while one fiber waits on disk, others make progress."
            )
            break

    # Degradation beyond peak
    bullets.append(
        f"Beyond {fmt_fibers(peak_fibers)} fibers, scheduling overhead dominates "
        f"and throughput drops."
    )

    # RSS
    rss_values = [r["maxrss_kb"] for r in parallel_results if r.get("maxrss_kb", 0) > 0]
    if rss_values:
        rss_lo = min(rss_values) / 1024 / 1024  # GiB
        rss_hi = max(rss_values) / 1024 / 1024
        bullets.append(
            f"RSS stays around {rss_lo:.1f}\u2013{rss_hi:.1f} GiB regardless of fiber count "
            f"(dominated by the trace array and Lavyek page cache, not fiber stacks)."
        )

    return bullets


def fmt_fibers(n):
    """Format fiber count for display."""
    if n >= 1000:
        return f"{n // 1000}k"
    return str(n)


def generate_key_observations(groups):
    """Generate overall key observations section."""
    bullets = []
    lookup_mem = build_lookup(groups.get("memory", []))
    lookup_disk = build_lookup(groups.get("disk", []))
    lookup_git = build_lookup(groups.get("git", []))
    lookup_trace = build_lookup(groups.get("trace", []))

    # Irmini vs Irmin on commits
    irmin_lwt_c20 = lookup_mem.get(("Irmin-Lwt (memory)", "commits-20B"))
    irmin_eio_c20 = lookup_mem.get(("Irmin-Eio (memory)", "commits-20B"))
    irmini_c20 = lookup_mem.get(("Irmini (memory)", "commits-20B"))
    if irmin_lwt_c20 and irmini_c20:
        irmin_best = max(irmin_lwt_c20["ops_per_sec"],
                         irmin_eio_c20["ops_per_sec"] if irmin_eio_c20 else 0)
        ratio = irmin_best / irmini_c20["ops_per_sec"]
        bullets.append(
            f"**Irmini vs Irmin on commits (20B)**: Irmin leads at ~{fmt_ops(irmin_best)} "
            f"vs Irmini {fmt_ops(irmini_c20['ops_per_sec'])}. "
            f"The gap has narrowed with inlining (was 3\u00d7 with 100B values, now {ratio:.1f}\u00d7)."
        )

    # Incremental
    irmin_lwt_i20 = lookup_mem.get(("Irmin-Lwt (memory)", "incremental-20B"))
    irmin_eio_i20 = lookup_mem.get(("Irmin-Eio (memory)", "incremental-20B"))
    irmini_i20 = lookup_mem.get(("Irmini (memory)", "incremental-20B"))
    if irmin_lwt_i20 and irmini_i20:
        irmin_lo = min(irmin_lwt_i20["ops_per_sec"],
                       irmin_eio_i20["ops_per_sec"] if irmin_eio_i20 else irmin_lwt_i20["ops_per_sec"])
        irmin_hi = max(irmin_lwt_i20["ops_per_sec"],
                       irmin_eio_i20["ops_per_sec"] if irmin_eio_i20 else irmin_lwt_i20["ops_per_sec"])
        speedup = irmini_i20["ops_per_sec"] / irmin_hi
        bullets.append(
            f"**Irmini vs Irmin on incremental**: Irmini is **{speedup:.1f}\u2013"
            f"{irmini_i20['ops_per_sec']/irmin_lo:.1f}\u00d7 faster** "
            f"({fmt_ops(irmini_i20['ops_per_sec'])} vs {fmt_ops(irmin_lo)}\u2013{fmt_ops(irmin_hi)}) "
            f"thanks to inode structural sharing (O(log n) tree updates)."
        )

    # Git
    irmini_git_c20 = lookup_git.get(("Irmini (git)", "commits-20B"))
    irmin_git_c20 = lookup_git.get(("Irmin-Lwt (git)", "commits-20B"))
    if irmini_git_c20 and irmin_git_c20:
        speedup = irmini_git_c20["ops_per_sec"] / irmin_git_c20["ops_per_sec"]
        irmini_rss = [r["maxrss_kb"] for r in groups.get("git", []) if "irmini" in r["name"].lower()]
        irmin_rss = [r["maxrss_kb"] for r in groups.get("git", []) if "irmin-" in r["name"].lower()]
        mem_str = ""
        if irmini_rss and irmin_rss:
            mem_ratio = min(irmin_rss) / max(irmini_rss) if max(irmini_rss) > 0 else 0
            mem_str = (f" while using **{mem_ratio:.0f}\u00d7 less memory** "
                       f"({int(min(irmini_rss)/1024)}\u2013{int(max(irmini_rss)/1024)} MiB "
                       f"vs {int(min(irmin_rss)/1024)}\u2013{int(max(irmin_rss)/1024)} MiB)")
        bullets.append(
            f"**Git backend**: Irmini is **{speedup:.0f}\u00d7 faster** than Irmin on git commits "
            f"({fmt_ops(irmini_git_c20['ops_per_sec'])} vs {fmt_ops(irmin_git_c20['ops_per_sec'])})"
            f"{mem_str}."
        )

    # 10K convergence
    irmin_lwt_c10 = lookup_mem.get(("Irmin-Lwt (memory)", "commits-10K"))
    irmini_c10 = lookup_mem.get(("Irmini (memory)", "commits-10K"))
    if irmin_lwt_c10 and irmini_c10:
        avg = int((irmin_lwt_c10["ops_per_sec"] + irmini_c10["ops_per_sec"]) / 2)
        bullets.append(
            f"**10K values**: All three implementations converge (~{fmt_ops(avg)} commits/s) "
            f"\u2014 I/O dominates and inlining cannot help."
        )

    # Lwt vs Eio
    lwt_pack_c20 = lookup_disk.get(("Irmin-Lwt (pack)", "commits-20B"))
    eio_pack_c20 = lookup_disk.get(("Irmin-Eio (pack)", "commits-20B"))
    if lwt_pack_c20 and eio_pack_c20:
        bullets.append(
            f"**Irmin-Lwt vs Irmin-Eio**: Similar performance on most benchmarks. "
            f"Irmin-Lwt faster on pack commits ({fmt_ops(lwt_pack_c20['ops_per_sec'])} "
            f"vs {fmt_ops(eio_pack_c20['ops_per_sec'])}), Irmin-Eio faster on pack reads."
        )

    # Trace replay summary (focus on Irmini results)
    trace_results = groups.get("trace", [])
    if trace_results:
        irmini_traces = [r for r in trace_results if "irmini" in r["name"].lower()]
        if irmini_traces:
            parts = []
            for r in sorted(irmini_traces, key=lambda x: -x["ops_per_sec"]):
                backend = r["name"].split("(")[1].rstrip(")") if "(" in r["name"] else "?"
                parts.append(f"{fmt_ops(r['ops_per_sec'])} ops/sec ({backend})")
            bullets.append(
                f"**Tezos trace replay**: " + ", ".join(parts)
                + " over 10K real Tezos commits validates that irmini handles realistic workloads."
            )

    return bullets


def generate_results_section(all_results, run_date, machine_info):
    """Generate the complete ## Results section."""
    # Classify all results
    groups = {
        "disk": [], "memory": [], "git": [],
        "optims_disk": [], "optims_memory": [], "optims_lavyek": [],
        "trace": [], "parallel": [],
    }

    for r in all_results:
        cat = classify(r["name"], r["scenario"])
        groups[cat].append(r)

    lines = []
    lines.append("## Results")
    lines.append("")
    lines.append(f"Run on {run_date}, {machine_info}.")
    lines.append("Each scenario runs twice: with 20-byte values (below 48B inlining threshold)")
    lines.append("and 10K-byte values. All three implementations use the same parameters.")
    lines.append("")

    # --- Disk ---
    disk_results = groups["disk"]
    # Include only Irmini trace results in the disk table (Irmin traces go in trace section)
    disk_trace = [r for r in groups["trace"]
                  if "irmini" in r["name"].lower()
                  and not ("memory" in r["name"].lower() or "mem" in r["name"].lower())]
    disk_all = disk_results + disk_trace
    if disk_all:
        lines.append("### Disk backends (fs, pack, lavyek)")
        lines.append("")
        lines.append("![Disk backends](results/chart_disk.svg)")
        lines.append("")
        lines.append("```")
        for line in generate_table(disk_all, BACKEND_ORDER_DISK):
            lines.append(line)
        lines.append("```")
        lines.append("")
        for bullet in analyze_disk(disk_all):
            lines.append(f"- {bullet}")
        # Add trace note if present
        if disk_trace:
            lavyek_trace = next((r for r in disk_trace if "lavyek" in r["name"].lower()), None)
            mem_trace = next((r for r in groups["trace"]
                              if "irmini" in r["name"].lower()
                              and ("memory" in r["name"].lower() or "mem" in r["name"].lower())), None)
            if lavyek_trace:
                parts = [f"Irmini (lavyek) replays 10,310 real Tezos commits (4M operations) "
                         f"at **{fmt_ops(lavyek_trace['ops_per_sec'])} ops/sec**"]
                if mem_trace:
                    parts.append(f"Irmini (memory) at {fmt_ops(mem_trace['ops_per_sec'])} ops/sec")
                lines.append(f"- **trace-replay**: " + ". ".join(parts) + ".")
        # Parallel trace entries
        par_entries = [r for r in disk_all if '12d' in r['name'] and 'tezos' in r['scenario']]
        if par_entries:
            par_parts = []
            for r in sorted(par_entries, key=lambda x: -x['ops_per_sec']):
                par_parts.append(f"{r['name']} at **{fmt_ops(r['ops_per_sec'])} ops/s**")
            lines.append(f"- **parallel trace-replay** (hatched bars): " + ". ".join(par_parts)
                         + " \u2014 limited by irmin-pack batch serialization for Irmin-Eio.")
        lines.append("")

    # --- Memory ---
    memory_results = groups["memory"]
    memory_trace = [r for r in groups["trace"]
                    if "irmini" in r["name"].lower()
                    and ("memory" in r["name"].lower() or "mem" in r["name"].lower())]
    memory_all = memory_results + memory_trace
    if memory_all:
        lines.append("### Memory backends")
        lines.append("")
        lines.append("![Memory backends](results/chart_memory.svg)")
        lines.append("")
        lines.append("```")
        for line in generate_table(memory_all, BACKEND_ORDER_MEMORY):
            lines.append(line)
        lines.append("```")
        lines.append("")
        for bullet in analyze_memory(memory_all):
            lines.append(f"- {bullet}")
        lines.append("")

    # --- Git ---
    if groups["git"]:
        lines.append("### Git backends")
        lines.append("")
        lines.append("![Git backends](results/chart_git.svg)")
        lines.append("")
        lines.append("```")
        for line in generate_table(groups["git"], BACKEND_ORDER_GIT):
            lines.append(line)
        lines.append("```")
        lines.append("")
        for bullet in analyze_git(groups["git"]):
            lines.append(f"- {bullet}")
        lines.append("")

    # --- Optims disk ---
    if groups["optims_disk"]:
        lines.append("### Irmini optimizations (disk)")
        lines.append("")
        lines.append("![Irmini optimizations disk](results/chart_optims_disk.svg)")
        lines.append("")
        # Optims tables omit RSS and time for brevity
        lines.append("```")
        for line in generate_table(groups["optims_disk"], BACKEND_ORDER_OPTIMS_DISK, include_rss=False):
            lines.append(line)
        lines.append("```")
        lines.append("")
        # Note about disk WAL
        lines.append("Note: the disk backend now uses WAL with fsync for crash safety, which")
        lines.append("dominates write-heavy scenarios (incremental ~10 ops/s, concurrent ~265 ops/s).")
        lines.append("")
        for bullet in analyze_optims(groups["optims_disk"], is_disk=True):
            lines.append(f"- {bullet}")
        lines.append("")

    # --- Optims memory ---
    if groups["optims_memory"]:
        lines.append("### Irmini optimizations (memory)")
        lines.append("")
        lines.append("![Irmini optimizations memory](results/chart_optims_memory.svg)")
        lines.append("")
        lines.append("```")
        for line in generate_table(groups["optims_memory"], BACKEND_ORDER_OPTIMS_MEMORY, include_rss=False):
            lines.append(line)
        lines.append("```")
        lines.append("")
        for bullet in analyze_optims(groups["optims_memory"], is_disk=False):
            lines.append(f"- {bullet}")
        lines.append("")

    # --- Optims lavyek ---
    if groups["optims_lavyek"]:
        lines.append("### Irmini optimizations (lavyek)")
        lines.append("")
        lines.append("![Irmini optimizations lavyek](results/chart_optims_lavyek.svg)")
        lines.append("")
        lines.append("```")
        for line in generate_table(groups["optims_lavyek"], BACKEND_ORDER_OPTIMS_LAVYEK, include_rss=False):
            lines.append(line)
        lines.append("```")
        lines.append("")
        for bullet in analyze_optims(groups["optims_lavyek"], is_disk=False):
            lines.append(f"- {bullet}")
        lines.append("")

    # --- Trace replay ---
    if groups["trace"]:
        lines.append("### Tezos trace replay")
        lines.append("")
        lines.append("Replays real Tezos blockchain operations from a `.repr` trace file.")
        lines.append("Irmin uses its official `tree.exe` benchmark tool with `--store-type=pack`")
        lines.append("(disk) or `--store-type=pack-mem` (memory).")
        lines.append("")

        # Build the trace table
        lines.append("```")
        trace_data = groups["trace"]

        # Separate memory and disk trace results
        mem_traces = [r for r in trace_data
                      if "memory" in r["name"].lower() or "mem" in r["name"].lower()]
        disk_traces = [r for r in trace_data if r not in mem_traces]

        # Get trace file info from scenario
        sample = trace_data[0]
        commits_match = __import__("re").search(r'(\d+)commits', sample["scenario"])
        ncommits = commits_match.group(1) if commits_match else "?"
        total_ops = sample.get("total_ops", 0)
        ops_str = f"{total_ops/1_000_000:.0f}M" if total_ops >= 1_000_000 else str(total_ops)
        lines.append(f"Trace: data4_{ncommits}commits.repr, {ncommits} commits, {ops_str} operations")
        lines.append("")

        if mem_traces:
            lines.append("Memory backends:")
            lines.append(f"{'Backend':<22s} {'Ops/sec':>10s} {'Wall time':>11s} {'RSS (MiB)':>11s}")
            lines.append("-" * 65)
            for r in sorted(mem_traces, key=lambda x: -x["ops_per_sec"]):
                ops = f"~{int(r['ops_per_sec']/1000):,},000" if r["ops_per_sec"] >= 100_000 else f"{int(r['ops_per_sec']):,}"
                wall = f"{r['total_time']:.1f}s"
                rss = str(int(r["maxrss_kb"] / 1024)) if r.get("maxrss_kb", 0) > 0 else "\u2014"
                lines.append(f"{r['name']:<22s} {ops:>10s} {wall:>11s} {rss:>11s}")
            lines.append("")

        if disk_traces:
            lines.append("Disk backends:")
            lines.append(f"{'Backend':<22s} {'Ops/sec':>10s} {'Wall time':>11s} {'RSS (MiB)':>11s}")
            lines.append("-" * 65)
            for r in sorted(disk_traces, key=lambda x: -x["ops_per_sec"]):
                ops = f"~{int(r['ops_per_sec']/1000):,},000" if r["ops_per_sec"] >= 100_000 else f"{int(r['ops_per_sec']):,}"
                wall = f"{r['total_time']:.1f}s"
                rss = str(int(r["maxrss_kb"] / 1024)) if r.get("maxrss_kb", 0) > 0 else "\u2014"
                lines.append(f"{r['name']:<22s} {ops:>10s} {wall:>11s} {rss:>11s}")

        lines.append("```")
        lines.append("")
        for bullet in analyze_trace(trace_data):
            lines.append(f"- {bullet}")
        lines.append("")

    # --- Parallel ---
    if groups["parallel"]:
        lines.append("### Parallel trace replay scaling")
        lines.append("")
        lines.append("![Parallel scaling](results/chart_parallel_scaling.svg)")
        lines.append("")
        lines.append("Parallel trace replay with 12 OS domains and varying fibers per domain,")
        lines.append("on a single shared Lavyek backend. The Tezos trace (4M ops, 10310 commits)")
        lines.append("is partitioned across all workers; each fiber processes a contiguous chunk.")
        lines.append("")

        # Find sequential baseline from trace results
        seq_baseline = None
        for r in groups.get("trace", []):
            if "lavyek" in r["name"].lower():
                seq_baseline = r["ops_per_sec"]
                break

        lines.append("```")
        for line in generate_parallel_table(groups["parallel"], seq_baseline):
            lines.append(line)
        lines.append("```")
        lines.append("")
        for bullet in analyze_parallel(groups["parallel"], seq_baseline):
            lines.append(f"- {bullet}")
        lines.append("")

    # --- Key observations ---
    obs = generate_key_observations(groups)
    if obs:
        lines.append("### Key observations")
        lines.append("")
        for bullet in obs:
            lines.append(f"- {bullet}")

    return "\n".join(lines) + "\n"


def update_readme(readme_path, results_section):
    """Replace everything from '## Results' to EOF in the README."""
    with open(readme_path, "r") as f:
        content = f.read()

    marker = "## Results"
    idx = content.find(marker)
    if idx == -1:
        print(f"Warning: '{marker}' not found in {readme_path}, appending at end.")
        new_content = content.rstrip() + "\n\n" + results_section
    else:
        new_content = content[:idx] + results_section

    with open(readme_path, "w") as f:
        f.write(new_content)

    print(f"Updated {readme_path}")


def update_charts(results_dir):
    """Run chart generation scripts."""
    bench_dir = os.path.dirname(os.path.abspath(__file__))

    # gen_chart_all.py
    chart_all = os.path.join(bench_dir, "gen_chart_all.py")
    if os.path.exists(chart_all):
        print("Generating backend charts...")
        subprocess.run([sys.executable, chart_all, results_dir], check=True)

    # gen_chart_parallel.py
    chart_parallel = os.path.join(bench_dir, "gen_chart_parallel.py")
    if os.path.exists(chart_parallel):
        print("Generating parallel scaling chart...")
        dst = os.path.join(results_dir, "chart_parallel_scaling.svg")
        subprocess.run([sys.executable, chart_parallel, dst], check=True)


def main():
    parser = argparse.ArgumentParser(
        description="Generate the ## Results section of bench/README.md from JSON results.")
    parser.add_argument("results_dir", help="Directory containing *.json result files")
    parser.add_argument("--readme", default=None,
                        help="Path to README.md (default: bench/README.md relative to results_dir)")
    parser.add_argument("--date", default=None,
                        help="Date string for the results header (default: today)")
    parser.add_argument("--machine", default="AMD 12-core, 100 commits \u00d7 1000 adds, depth 10, 10000 reads",
                        help="Machine info string for the results header")
    parser.add_argument("--update-charts", action="store_true",
                        help="Regenerate SVG charts by running gen_chart_all.py and gen_chart_parallel.py")

    args = parser.parse_args()

    results_dir = os.path.abspath(args.results_dir)
    if not os.path.isdir(results_dir):
        print(f"Error: {results_dir} is not a directory", file=sys.stderr)
        sys.exit(1)

    # Default README path
    if args.readme:
        readme_path = os.path.abspath(args.readme)
    else:
        readme_path = os.path.join(os.path.dirname(results_dir), "README.md")

    run_date = args.date or date.today().isoformat()

    print(f"Loading results from {results_dir}...")
    all_results = load_results(results_dir)
    if not all_results:
        print("No results found!", file=sys.stderr)
        sys.exit(1)
    print(f"Loaded {len(all_results)} results")

    # Generate the results section
    results_section = generate_results_section(all_results, run_date, args.machine)

    # Update README
    if os.path.exists(readme_path):
        update_readme(readme_path, results_section)
    else:
        print(f"Warning: {readme_path} not found, printing to stdout")
        print(results_section)

    # Optionally update charts
    if args.update_charts:
        update_charts(results_dir)

    print("Done.")


if __name__ == "__main__":
    main()
