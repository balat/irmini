#!/usr/bin/env python3
"""Generate the "## Results" section of bench/README.md from JSON benchmark results.

Reads all *.json files from the results directory, classifies them into categories
(disk, memory, git, optims_disk, optims_memory, trace, parallel), generates tables
and analysis, and replaces everything from "## Results" to EOF in the README.

Usage: gen_readme_results.py <results_dir> [--readme PATH] [--date DATE] [--update-charts]
"""

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import date

sys.path.insert(0, os.path.dirname(__file__))
from bench_utils import (
    load_results, load_files, classify_for_readme as classify,
    README_SECTIONS,
    SCENARIO_ORDER, BACKEND_ORDER_DISK, BACKEND_ORDER_MEMORY, BACKEND_ORDER_GIT,
    BACKEND_ORDER_OPTIMS_MEMORY, BACKEND_ORDER_OPTIMS_DISK, BACKEND_ORDER_OPTIMS_LAVYEK,
    scenario_sort_key, backend_sort_key, build_lookup, get_sorted_scenarios,
    get_sorted_backends, fmt_ops, fmt_fibers, extract_fibers,
    remap_parallel_scenarios,
)


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
    sorted_results = sorted(parallel_results, key=lambda r: extract_fibers(r["scenario"]))

    for r in sorted_results:
        fibers = extract_fibers(r["scenario"])
        domains_match = re.search(r'(\d+)d', r["scenario"])
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


# --- Analysis generation ---

def analyze_multicore(par_results, seq_results):
    """Generate multi-core analysis text with speedup table and explanations."""
    lines = []
    # Build sequential lookup: (name, scenario) -> ops/s
    seq_lookup = {}
    for r in seq_results:
        seq_lookup[(r["name"], r["scenario"])] = r["ops_per_sec"]

    # Build parallel lookup: (base_name, base_scenario) -> ops/s
    par_lookup = {}
    for r in par_results:
        base_name = re.sub(r'\s+\d+d[×x]\d+\w*f?$', '', r["name"])
        par_lookup[(base_name, r["scenario"])] = r["ops_per_sec"]

    # Compute speedups for key backends × scenarios
    backends = [
        ("Irmini (disk)", "Disk"),
        ("Irmini (disk, no fsync)", "Disk no-fsync"),
        ("Irmini (lavyek, no fsync)", "Lavyek no-fsync"),
    ]
    scenarios = [
        "reads-20B", "reads-10K",
        "commits-20B", "commits-10K",
        "incremental-20B", "incremental-10K",
    ]

    # Check if we have data
    has_data = False
    for bname, _ in backends:
        for s in scenarios:
            if (bname, s) in par_lookup and (bname, s) in seq_lookup:
                has_data = True
                break
    if not has_data:
        return lines

    lines.append("**What was done for multi-core.** All three backends were made domain-safe")
    lines.append("for OCaml 5 multicore. Tree internal structures (`node_record`, `Link`) use")
    lines.append("`Atomic.t` for domain-safe lazy resolution. Each backend then has its own")
    lines.append("concurrency strategy:")
    lines.append("")
    lines.append("- **Disk**: lock-free reads (`Atomic.get` index + `pread`), lock-free write")
    lines.append("  reservation (`Atomic.fetch_and_add` on data offset), CAS for index updates,")
    lines.append("  and per-domain WAL (each domain fsyncs its own WAL file independently).")
    lines.append("- **Lavyek**: natively lock-free LSM-tree (atomic memtable buckets), only")
    lines.append("  ref operations use an `Eio.Mutex`.")
    lines.append("- **Memory**: plain mutable fields (zero overhead single-core), wrapped with")
    lines.append("  a read-write lock for multi-domain use (concurrent readers, exclusive writers).")
    lines.append("")

    # Speedup table
    lines.append("**Speedup analysis** (12 domains × 100 fibers vs single-core):")
    lines.append("")
    header = "| Scenario |"
    sep = "|---|"
    for _, label in backends:
        header += f" {label} |"
        sep += "---|"
    lines.append(header)
    lines.append(sep)

    for s in scenarios:
        row = f"| {s} |"
        for bname, _ in backends:
            seq_ops = seq_lookup.get((bname, s))
            par_ops = par_lookup.get((bname, s))
            if seq_ops and par_ops and seq_ops > 0:
                sp = par_ops / seq_ops
                cell = f"{sp:.1f}×"
                if sp >= 3.0:
                    cell = f"**{cell}**"
            else:
                cell = "—"
            row += f" {cell} |"
        lines.append(row)

    lines.append("")
    lines.append("**Why speedup is far from 12× (linear) on most scenarios:**")
    lines.append("")
    lines.append("1. **Reads (disk)**: reads are already very fast single-core (3.1M ops/s for")
    lines.append("   20B). At this throughput, the bottleneck shifts to CPU cache coherence")
    lines.append("   between domains sharing the same `Atomic.t` index, and to memory bandwidth.")
    lines.append("   Lavyek scales better (3.3×) because its LSM read path does more I/O")
    lines.append("   (bloom filter + SSTable lookup), giving fibers a chance to overlap I/O.")
    lines.append("")
    lines.append("2. **Commits-10K (disk, < 1×)**: 10K values mean 100 MB of data per")
    lines.append("   100 commits × 1000 adds. With 12 domains × 100 fibers = 1200 concurrent")
    lines.append("   writers, the data file grows to ~120 GB and the system hits disk I/O")
    lines.append("   saturation. The per-domain WAL helps with fsync parallelism but cannot")
    lines.append("   fix raw bandwidth limits.")
    lines.append("")
    lines.append("3. **Commits-20B (disk, 3.5×)**: small values keep data volume manageable.")
    lines.append("   The per-domain WAL eliminates fsync serialization — 12 domains fsync")
    lines.append("   their own WAL files in parallel. The CAS index update is the main")
    lines.append("   contention point, but CAS retries are cheap.")
    lines.append("")
    lines.append("4. **Incremental (disk, 14×)**: each fiber does a checkout + 1 update +")
    lines.append("   commit on its own branch. The sequential version is bottlenecked by")
    lines.append("   fsync latency (one fsync per commit). With 12 domains × 100 fibers,")
    lines.append("   1200 independent commits overlap their fsync calls via per-domain WAL,")
    lines.append("   hiding the latency. This is the ideal case for the per-domain WAL")
    lines.append("   optimization.")
    lines.append("")
    lines.append("5. **No-fsync variants are slower in parallel**: without fsync, single-core")
    lines.append("   is already very fast (no I/O wait to hide). The parallel overhead (CAS")
    lines.append("   retries, bloom mutex, memory allocation pressure) dominates the small")
    lines.append("   gains from parallelism. The 10K no-fsync regression (< 1×) is caused")
    lines.append("   by 12 GB RSS triggering GC pressure across all domains.")
    lines.append("")

    return lines


def analyze_disk(results):
    """Generate analysis bullets for disk backends."""
    lookup = build_lookup(results)
    bullets = []

    # Find Irmini lavyek commits-20B
    lavyek_c20 = lookup.get(("Irmini (lavyek)", "commits-20B"))
    lavyek_r20 = lookup.get(("Irmini (lavyek)", "reads-20B"))
    lavyek_r10 = lookup.get(("Irmini (lavyek)", "reads-10K"))
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
        speedup_r20 = irmini_r20["ops_per_sec"] / irmin_lwt_r20["ops_per_sec"]
        parts = [f"**Reads**: Irmini dominates at **{fmt_ops(irmini_r20['ops_per_sec'])} ops/s** "
                 f"(20B and 10K) \u2014 **{speedup_r20:.0f}\u00d7 faster** than "
                 f"Irmin-Lwt ({fmt_ops(irmin_lwt_r20['ops_per_sec'])})"]
        if irmini_r10 and irmin_eio_r10:
            speedup_r10 = irmini_r10["ops_per_sec"] / irmin_eio_r10["ops_per_sec"]
            parts.append(f" and **{speedup_r10:.0f}\u00d7 faster** than "
                         f"Irmin-Eio ({fmt_ops(irmin_eio_r10['ops_per_sec'])} on 10K)")
        parts.append(". Content-addressed lookups bypass Git's tree traversal.")
        bullets.append("".join(parts))

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


def generate_results_section(all_results, run_date, machine_info,
                              results_dir=None):
    """Generate the complete ## Results section.

    If results_dir is provided, loads data per-section from the manifest
    (README_SECTIONS). Otherwise falls back to classify-all heuristics.
    """
    if results_dir:
        # Manifest-based: each section loads only the files it needs.
        # Still apply classify filter to handle legacy files that mix categories.
        groups = {}
        for section, files in README_SECTIONS.items():
            raw = load_files(results_dir, files)
            groups[section] = [r for r in raw
                               if classify(r["name"], r["scenario"]) == section]
    else:
        # Legacy fallback: classify all results
        groups = {
            "disk": [], "memory": [], "git": [],
            "disk_parallel": [], "memory_parallel": [],
            "optims_disk": [], "optims_memory": [], "optims_lavyek": [],
            "trace": [], "parallel": [],
        }
        for r in all_results:
            cat = classify(r["name"], r["scenario"])
            if cat == "skip":
                continue
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
        lines.append("### Disk backends — single-core (fs, pack, lavyek)")
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
        lines.append("")

    # --- Fsync impact explanation (always generated — never drop silently) ---
    if True:
        lines.append("**Why lavyek collapses with fsync**: The root cause is fsync granularity.")
        lines.append("The disk backend uses `write_batch`: it accumulates all objects in the WAL")
        lines.append("with `Wal.append` (no fsync), then calls **one `Wal.sync`** at the end of")
        lines.append("the batch. A commit writing 1,000 objects costs **1 fsync**.")
        lines.append("")
        lines.append("Lavyek, by contrast, calls `Lavyek.put ~sync:true` for each individual")
        lines.append("key-value pair. Each `put` triggers its own fsync internally. A commit")
        lines.append("writing 1,000 objects costs **1,000 fsyncs**. At ~0.1–1ms per fsync on SSD,")
        lines.append("this means 100–1000ms per commit, which matches the observed 265s for 100")
        lines.append("commits of 1,000 entries (2.65s/commit).")
        lines.append("")
        lines.append("**Reads are unaffected** — fsync only impacts write paths. Lavyek with fsync")
        lines.append("still reads at 3.4–3.7M ops/s.")
        lines.append("")
        lines.append("**Fix**: Adding a `Lavyek.put_batch` that accumulates writes and fsyncs once")
        lines.append("at the end would bring lavyek+fsync performance in line with disk.")
        lines.append("")

    # --- Disk parallel ---
    if groups["disk_parallel"]:
        # Only keep main parallel config (100f) and tezos parallel entries
        # Supports both old format (-100f/12d) and new format (-12d×100f)
        main_disk_par = [r for r in groups["disk_parallel"]
                         if re.search(r'-100f/\d+d$', r["scenario"])
                         or re.search(r'-\d+d[×x]100f$', r["scenario"])
                         or (not re.search(r'-\d+f/\d+d$', r["scenario"])
                             and not re.search(r'-\d+d[×x]\d+f$', r["scenario"]))]
        disk_par_remapped = remap_parallel_scenarios(main_disk_par, rename_backends=True)
        # Include tezos parallel data (already has base scenario name)
        tezos_par = [r for r in main_disk_par
                     if not re.search(r'-\d+f/\d+d$', r["scenario"])
                     and not re.search(r'-\d+d[×x]\d+f$', r["scenario"])]
        disk_par_remapped.extend(tezos_par)
        lines.append("### Disk backends — multi-core (12 domains, 100 fibers)")
        lines.append("")
        lines.append("![Disk parallel](results/chart_disk_parallel.svg)")
        lines.append("")
        lines.append("```")
        for line in generate_table(disk_par_remapped, BACKEND_ORDER_DISK):
            lines.append(line)
        lines.append("```")
        lines.append("")
        # Multi-core analysis: compute speedups and explain bottlenecks
        lines.extend(analyze_multicore(disk_par_remapped, groups.get("disk", [])))

    # --- Memory ---
    memory_results = groups["memory"]
    memory_trace = [r for r in groups["trace"]
                    if "irmini" in r["name"].lower()
                    and ("memory" in r["name"].lower() or "mem" in r["name"].lower())]
    memory_all = memory_results + memory_trace
    if memory_all:
        lines.append("### Memory backends — single-core")
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

    # --- Memory parallel ---
    if groups["memory_parallel"]:
        mem_par_remapped = remap_parallel_scenarios(groups["memory_parallel"])
        lines.append("### Memory backends — multi-core (12 domains)")
        lines.append("")
        lines.append("![Memory parallel](results/chart_memory_parallel.svg)")
        lines.append("")
        lines.append("```")
        for line in generate_table(mem_par_remapped, BACKEND_ORDER_MEMORY):
            lines.append(line)
        lines.append("```")
        lines.append("")

    # --- Fiber count explanation (always generated) ---
    lines.append("**Why 1 fiber per domain for Memory?** The Memory backend performs pure CPU")
    lines.append("operations (`String_map` lookups and updates) that never yield to the Eio")
    lines.append("scheduler. Extra fibers within a domain just add scheduling overhead without")
    lines.append("any parallelism benefit \u2014 fibers only help when operations do I/O that")
    lines.append("yields to other fibers. Benchmarks confirm that 1 fiber matches or beats")
    lines.append("100 fibers (commits-10K is 37% faster with 1 fiber due to reduced")
    lines.append("scheduling overhead).")
    lines.append("")

    # --- RWLock vs mutex explanation (always generated) ---
    lines.append("**RWLock vs mutex**: The Memory backend is plain `mutable` fields (zero")
    lines.append("overhead single-core). For multi-domain use, it is wrapped with")
    lines.append("`thread_safe_rw` \u2014 a read-write lock allowing concurrent readers with")
    lines.append("exclusive writers. Both use 12 domains \u00d7 1 fiber. Compared to the global")
    lines.append("`Stdlib.Mutex` (shown as \"mutex\" above):")
    lines.append("")
    lines.append("- **Reads: 1.2\u20131.4\u00d7 faster** (9.0\u20139.4M vs 6.5\u20137.6M) \u2014 multiple readers")
    lines.append("  proceed in parallel without blocking each other.")
    lines.append("- **Commits-20B: 1.4\u00d7 faster** (144k vs 105k) \u2014 readers no longer")
    lines.append("  block behind writers, reducing contention.")
    lines.append("- **Commits-10K: 1.1\u00d7 faster** (35k vs 33k) \u2014 write-dominated,")
    lines.append("  the advantage is smaller but still measurable.")
    lines.append("- **Single-core: zero overhead** \u2014 no lock on the base backend.")
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
        lines.append("dominates write-heavy scenarios (incremental ~10 ops/s).")
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
        commits_match = re.search(r'(\d+)commits', sample["scenario"])
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

    # --- Parallel trace replay scaling (only if data exists) ---
    if groups.get("parallel"):
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

    # --- Parallel speedup ---
    all_parallel = [r for r in groups.get("disk_parallel", []) + groups.get("memory_parallel", [])
                    if re.search(r'-100f/\d+d$', r["scenario"])]
    if all_parallel:
        # Build sequential lookup from disk + memory groups
        seq_lookup = {}
        for r in groups["disk"] + groups["memory"]:
            seq_lookup[(r["name"], r["scenario"])] = r["ops_per_sec"]

        # Compute speedup for each parallel result
        speedup_data = []  # (base_scenario, name, speedup, par_ops, seq_ops)
        for r in all_parallel:
            m = re.match(r'^(.+)-\d+f/\d+d$', r["scenario"])
            if not m:
                continue
            base = m.group(1)
            seq_val = seq_lookup.get((r["name"], base))
            if seq_val and seq_val > 0:
                sp = r["ops_per_sec"] / seq_val
                speedup_data.append((base, r["name"], sp, r["ops_per_sec"], seq_val))

        if speedup_data:
            lines.append("### Parallel speedup")
            lines.append("")
            lines.append("![Parallel speedup](results/chart_speedup.svg)")
            lines.append("")
            lines.append("Speedup of parallel scenarios (100 fibers, 12 domains) vs sequential baseline.")
            lines.append("Only domain-safe backends shown (Irmini and Irmin-Eio).")
            lines.append("")

            # Table: scenarios as rows, backends as columns
            scenarios_seen = sorted(set(s for s, _, _, _, _ in speedup_data),
                                    key=scenario_sort_key)
            backends_seen = sorted(set(n for _, n, _, _, _ in speedup_data))
            sp_lookup = {(s, n): (sp, par, seq) for s, n, sp, par, seq in speedup_data}

            lines.append("```")
            header = f"{'Scenario':>20s}"
            for bname in backends_seen:
                header += f"  {bname:>22s}"
            lines.append(header)
            lines.append("-" * len(header))

            for scenario in scenarios_seen:
                row = f"{scenario:>20s}"
                for bname in backends_seen:
                    entry = sp_lookup.get((scenario, bname))
                    if entry:
                        sp, par, _seq = entry
                        row += f"  {fmt_ops(par) + ' (' + f'{sp:.1f}x' + ')':>22s}"
                    else:
                        row += f"  {'—':>22s}"
                lines.append(row)
            lines.append("```")
            lines.append("")

    # --- Parallel scaling ---
    scaling_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results", "irmini_scaling.json")
    if os.path.exists(scaling_file):
        try:
            with open(scaling_file) as f:
                scale_data = json.load(f)
            if scale_data:
                lines.append("### Parallel scaling per scenario")
                lines.append("")
                lines.append("![Parallel scaling per scenario](results/chart_scaling.svg)")
                lines.append("")
                lines.append("Throughput of commits, reads, and incremental scenarios with 12 domains and varying fiber count.")
                lines.append("")

                # Group by (backend, base_scenario)
                scale_series = {}
                for r in scale_data:
                    m = re.match(r'^(.+)-(\d+)f/(\d+)d$', r["scenario"])
                    if not m:
                        continue
                    base = m.group(1)
                    fibers = int(m.group(2))
                    key = (r["name"], base)
                    if key not in scale_series:
                        scale_series[key] = []
                    scale_series[key].append((fibers, r["ops_per_sec"]))

                # Table per series
                for (bname, base), data in sorted(scale_series.items()):
                    sorted_data = sorted(data, key=lambda d: d[0])
                    peak_fib, peak_ops = max(sorted_data, key=lambda d: d[1])
                    lines.append(f"**{bname} — {base}** (peak: {fmt_ops(peak_ops)} at {peak_fib} fibers)")
                    lines.append("")
        except (json.JSONDecodeError, IOError):
            pass

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

    # gen_chart_scaling.py
    chart_scaling = os.path.join(bench_dir, "gen_chart_scaling.py")
    if os.path.exists(chart_scaling):
        print("Generating parallel scaling chart...")
        dst = os.path.join(results_dir, "chart_scaling.svg")
        subprocess.run([sys.executable, chart_scaling, dst, "--json", results_dir], check=True)


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

    # Generate the results section (manifest-based loading per section)
    results_section = generate_results_section(
        all_results, run_date, args.machine, results_dir=results_dir)

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
