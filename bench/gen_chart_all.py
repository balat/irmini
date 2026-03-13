#!/usr/bin/env python3
"""Generate SVG bar charts from JSON benchmark results.

Produces three charts grouped by backend type:
  - Disk backends: irmin-lwt-{fs,pack}, irmin-eio-{fs,pack}, irmini-{disk,lavyek}
  - Memory backends: irmin-lwt-memory, irmin-eio-memory, irmini-memory
  - Git backends: irmin-lwt-git, irmin-eio-git, irmini-git

Usage: gen_chart_all.py <results_dir>

Reads all *.json files in <results_dir> and merges them.
"""

import glob
import json
import math
import os
import re
import sys


def load_results(results_dir):
    """Load and merge all JSON result files."""
    all_results = []
    for path in sorted(glob.glob(os.path.join(results_dir, "*.json"))):
        try:
            with open(path) as f:
                data = json.load(f)
            all_results.extend(data)
            print(f"  Loaded {len(data)} results from {os.path.basename(path)}")
        except (json.JSONDecodeError, IOError) as e:
            print(f"  Warning: skipping {path}: {e}")
    return all_results


def classify_backend(name, scenario=""):
    """Classify a result name into memory/disk/git/optims category."""
    n = name.lower()
    s = scenario.lower()
    # Skip parallel scaling data (handled by gen_chart_parallel.py)
    if "tezos-parallel-" in s or s == "tezos-sequential":
        return "skip"
    # Skip non-default concurrent scaling data (handled by gen_chart_concurrent.py)
    # Only keep the default (100 fibers) for the comparison charts
    if s.startswith("concurrent-") and s != "concurrent-100f/12d":
        return "skip"
    # Optimization variants go to their own chart
    if "baseline" in n or "+inline" in n or "+cache" in n or "+inode" in n or "+all" in n:
        if "(disk)" in n:
            return "optims_disk"
        if "(lavyek)" in n:
            return "optims_lavyek"
        return "optims_memory"
    elif "memory" in n or "mem" in n:
        return "memory"
    elif "git" in n:
        return "git"
    else:
        # fs, disk, pack, lavyek are all "disk" category
        return "disk"


# --- Colors for each backend name ---
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
    "Irmini (disk)":      "#6d9dc5",
    "Irmini (lavyek)":    "#59a14f",
    "Irmini (git)":       "#8bc584",
    # Tezos trace replay
    "Irmin-Lwt (pack-mem)": "#f28e2b",
    "Irmin-Eio (pack-mem)": "#e15759",
    # Parallel variants (same color as base, rendered with hatching)
    "Irmini (lavyek) 12d×50kf": "#59a14f",
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

OPTIM_ORDER_MEM = ["Irmini baseline", "Irmini+inline", "Irmini+cache", "Irmini+inode", "Irmini+all"]
OPTIM_ORDER_DISK = ["Irmini baseline (disk)", "Irmini+inline (disk)", "Irmini+cache (disk)",
                    "Irmini+inode (disk)", "Irmini+all (disk)"]
OPTIM_ORDER_LAVYEK = ["Irmini baseline (lavyek)", "Irmini+inline (lavyek)", "Irmini+cache (lavyek)",
                      "Irmini+inode (lavyek)", "Irmini+all (lavyek)"]


def family_sort_key(name):
    """Sort backends: Irmin-Lwt first, then Irmin-Eio, then Irmini."""
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
        return (1, name)
    elif "irmini" in n:
        return (2, name)
    return (3, name)


def get_color(name):
    """Get a color for a given backend name."""
    if name in COLORS:
        return COLORS[name]
    # For parallel variants, match by base backend keyword
    if is_parallel_variant(name):
        for key in ("lavyek", "pack", "disk", "memory", "fs", "git"):
            if key in name.lower():
                for cname, color in COLORS.items():
                    if key in cname.lower() and not is_parallel_variant(cname):
                        return color
    # Fallback: hash-based color
    h = hash(name) % 360
    return f"hsl({h}, 60%, 55%)"


SCENARIO_ORDER = [
    "commits-20B", "reads-20B", "incremental-20B",
    "commits-10K", "reads-10K", "incremental-10K",
    "concurrent-100f/12d",
    "tezos-10310commits",
]


def scenario_sort_key(name):
    """Sort scenarios in the canonical order from README."""
    try:
        return (0, SCENARIO_ORDER.index(name))
    except ValueError:
        return (1, name)


def fmt_ops(v):
    if v >= 1_000_000:
        return f"{v/1_000_000:.1f}M"
    if v >= 1_000:
        return f"{v/1_000:.0f}k"
    return str(int(v))


def generate_chart(title, results, backends):
    """Generate an SVG chart for a set of backends."""
    if not results:
        return None

    # Build lookup
    lookup = {}
    for r in results:
        lookup[(r["name"], r["scenario"])] = r["ops_per_sec"]

    scenarios = sorted(
        {r["scenario"] for r in results},
        key=scenario_sort_key
    )

    # Layout — target max width ~1200px for readability
    margin_left = 100
    margin_right = 30
    margin_top = 50
    n_backends = len(backends)
    n_scenarios = len(scenarios)
    max_chart_width = 1100

    # Compute bar dimensions to fit within max width
    # Start generous, shrink if needed
    bar_width = max(8, min(22, max_chart_width // max(1, n_scenarios * n_backends)))
    bar_gap = 2
    group_gap = max(20, min(50, max_chart_width // max(1, n_scenarios * 3)))

    group_width = n_backends * (bar_width + bar_gap) - bar_gap
    chart_width = n_scenarios * (group_width + group_gap) - group_gap
    chart_height = 350

    # Legend layout
    legend_col_width = 200
    legend_cols = max(1, min(4, (margin_left + chart_width + margin_right) // legend_col_width))
    legend_rows = (n_backends + legend_cols - 1) // legend_cols
    margin_bottom = 55 + legend_rows * 24

    svg_w = max(margin_left + chart_width + margin_right, legend_cols * legend_col_width + margin_left)
    svg_h = margin_top + chart_height + margin_bottom

    # Precompute per-scenario max
    max_per_scenario = {}
    for r in results:
        s = r["scenario"]
        max_per_scenario[s] = max(max_per_scenario.get(s, 0), r["ops_per_sec"])

    def y_of(val, scenario):
        if val <= 0:
            return chart_height
        mx = max_per_scenario.get(scenario, 1)
        frac = val / (mx * 1.15)
        return chart_height * (1 - frac)

    lines = []
    lines.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{svg_w}" height="{svg_h}" '
                 f'font-family="system-ui, sans-serif" font-size="14">')
    lines.append(f'<rect width="{svg_w}" height="{svg_h}" fill="white"/>')

    # Define hatching patterns for parallel variants
    lines.append('<defs>')
    for backend in backends:
        if is_parallel_variant(backend):
            pid = f"hatch-{abs(hash(backend)) % 10000}"
            color = get_color(backend)
            lines.append(
                f'<pattern id="{pid}" width="6" height="6" '
                f'patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
                f'<rect width="6" height="6" fill="{color}"/>'
                f'<line x1="0" y1="0" x2="0" y2="6" stroke="white" stroke-width="2"/>'
                f'</pattern>')
    lines.append('</defs>')

    # Title
    lines.append(f'<text x="{svg_w/2}" y="32" text-anchor="middle" font-size="20" '
                 f'font-weight="bold">{title}</text>')

    ox, oy = margin_left, margin_top
    lines.append(f'<g transform="translate({ox},{oy})">')

    # Y axis label
    lines.append(f'<text x="-75" y="{chart_height/2}" text-anchor="middle" '
                 f'font-size="14" fill="#333" transform="rotate(-90,-75,{chart_height/2})">'
                 f'ops/s</text>')

    # Bars per scenario
    for si, scenario in enumerate(scenarios):
        gx = si * (group_width + group_gap)

        # Grid lines
        mx = max_per_scenario.get(scenario, 1)
        headroom = mx * 1.15
        for i in range(1, 5):
            tick_val = headroom * i / 4
            yy = chart_height * (1 - i / 4)
            lines.append(f'<line x1="{gx}" y1="{yy:.1f}" '
                         f'x2="{gx + group_width}" y2="{yy:.1f}" '
                         f'stroke="#e0e0e0" stroke-width="0.5"/>')
            if i == 4:
                lines.append(f'<text x="{gx - 4:.1f}" y="{yy + 4:.1f}" '
                             f'text-anchor="end" font-size="10" fill="#999">'
                             f'{fmt_ops(int(tick_val))}</text>')

        for bi, backend in enumerate(backends):
            val = lookup.get((backend, scenario))
            if val is None:
                continue
            bx = gx + bi * (bar_width + bar_gap)
            by = y_of(val, scenario)
            bh = chart_height - by
            color = get_color(backend)
            if is_parallel_variant(backend):
                pid = f"hatch-{abs(hash(backend)) % 10000}"
                fill = f'url(#{pid})'
            else:
                fill = color
            lines.append(f'<rect x="{bx:.1f}" y="{by:.1f}" width="{bar_width}" '
                         f'height="{bh:.1f}" fill="{fill}" rx="1"/>')
            lines.append(f'<text x="{bx + bar_width/2:.1f}" y="{by - 3:.1f}" '
                         f'text-anchor="middle" font-size="9" fill="#333">'
                         f'{fmt_ops(val)}</text>')

        # Scenario label
        cx = gx + group_width / 2
        lines.append(f'<text x="{cx:.1f}" y="{chart_height + 18}" text-anchor="middle" '
                     f'font-size="13" font-weight="bold" fill="#333">{scenario}</text>')

    # Bottom axis
    lines.append(f'<line x1="0" y1="{chart_height}" x2="{chart_width}" '
                 f'y2="{chart_height}" stroke="#333" stroke-width="1"/>')

    lines.append('</g>')

    # Legend
    lx = ox
    ly = oy + chart_height + 40
    lines.append(f'<g transform="translate({lx},{ly})">')

    for i, backend in enumerate(backends):
        col = i % legend_cols
        row = i // legend_cols
        x = col * legend_col_width
        y = row * 24
        color = get_color(backend)
        if is_parallel_variant(backend):
            pid = f"hatch-{abs(hash(backend)) % 10000}"
            fill = f'url(#{pid})'
        else:
            fill = color
        lines.append(f'<rect x="{x}" y="{y}" width="14" height="14" fill="{fill}" rx="2"/>')
        lines.append(f'<text x="{x+18}" y="{y+12}" font-size="13" fill="#333">{backend}</text>')

    lines.append('</g>')
    lines.append('</svg>')

    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print("Usage: gen_chart_all.py <results_dir>")
        sys.exit(1)

    results_dir = sys.argv[1]

    print(f"Loading results from {results_dir}...")
    all_results = load_results(results_dir)

    if not all_results:
        print("No results found!")
        sys.exit(1)

    print(f"Total: {len(all_results)} results")

    # Group by backend type
    groups = {"memory": [], "disk": [], "git": [], "optims_disk": [], "optims_memory": [], "optims_lavyek": []}
    for r in all_results:
        cat = classify_backend(r["name"], r.get("scenario", ""))
        groups.setdefault(cat, []).append(r)

    def ordered_backends(results):
        """Get unique backend names, sorted by family then name."""
        seen = set()
        names = []
        for r in results:
            if r["name"] not in seen:
                names.append(r["name"])
                seen.add(r["name"])
        return sorted(names, key=family_sort_key)

    chart_dir = results_dir

    # Charts in order: disk, memory, git, optims_disk, optims_memory
    chart_specs = [
        ("disk", "Disk backends (fs, pack, lavyek) — ops/s comparison",
         "chart_disk.svg"),
        ("memory", "Memory backends — ops/s comparison",
         "chart_memory.svg"),
        ("git", "Git backends — ops/s comparison",
         "chart_git.svg"),
        ("optims_disk", "Irmini optimizations (disk) — ops/s comparison",
         "chart_optims_disk.svg"),
        ("optims_memory", "Irmini optimizations (memory) — ops/s comparison",
         "chart_optims_memory.svg"),
        ("optims_lavyek", "Irmini optimizations (lavyek) — ops/s comparison",
         "chart_optims_lavyek.svg"),
    ]

    for cat, title, filename in chart_specs:
        results = groups[cat]
        if not results:
            print(f"  No results for {cat}, skipping")
            continue
        backends = ordered_backends(results)
        svg = generate_chart(title, results, backends)
        if svg:
            path = os.path.join(chart_dir, filename)
            with open(path, "w") as f:
                f.write(svg)
            print(f"  Written {path} ({len(backends)} backends, {len(results)} results)")


if __name__ == "__main__":
    main()
