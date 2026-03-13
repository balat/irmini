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
    # Parallel scenario results (commits-20B-100f/12d etc.)
    if re.search(r'-\d+f/\d+d$', s):
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


def is_tezos_parallel(name):
    """Check if a parallel variant uses non-standard (tezos) parameters.
    Standard parallel uses 100f; tezos uses other counts like 50kf, 1f."""
    if not is_parallel_variant(name):
        return False
    return "×100f" not in name and "\u00d7100f" not in name

OPTIM_ORDER_MEM = ["Irmini baseline", "Irmini+inline", "Irmini+cache", "Irmini+inode", "Irmini+all"]
OPTIM_ORDER_DISK = ["Irmini baseline (disk)", "Irmini+inline (disk)", "Irmini+cache (disk)",
                    "Irmini+inode (disk)", "Irmini+all (disk)"]
OPTIM_ORDER_LAVYEK = ["Irmini baseline (lavyek)", "Irmini+inline (lavyek)", "Irmini+cache (lavyek)",
                      "Irmini+inode (lavyek)", "Irmini+all (lavyek)"]


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
        # Sort (seq) right after the parallel variant
        base = (1, name.replace(" (seq)", ""))
        return (base[0], base[1], 1 if "(seq)" in name else 0)
    elif "irmini" in n:
        base = (2, name.replace(" (seq)", ""))
        return (base[0], base[1], 1 if "(seq)" in name else 0)
    return (3, name)


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


def is_seq_reference(name):
    """Check if a backend name is a sequential reference on a parallel chart."""
    return name.endswith(" (seq)")


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


SCENARIO_ORDER = [
    "commits-20B", "reads-20B", "incremental-20B",
    "commits-10K", "reads-10K", "incremental-10K",
    "tezos-10310commits", "tezos",
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


def generate_chart(title, results, backends, compact=False):
    """Generate an SVG chart for a set of backends.

    When compact=True, use smaller fonts (for charts with many backends).
    """
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

    # Auto-enable compact mode when many backends
    if len(backends) > 8:
        compact = True

    # Font sizes
    title_font = 16 if compact else 20
    label_font = 10 if compact else 13
    value_font = 7 if compact else 9
    legend_font = 10 if compact else 13
    axis_font = 11 if compact else 14
    tick_font = 8 if compact else 10

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
    legend_col_width = 180 if compact else 200
    legend_row_height = 18 if compact else 24
    legend_cols = max(1, min(4, (margin_left + chart_width + margin_right) // legend_col_width))
    legend_rows = (n_backends + legend_cols - 1) // legend_cols
    margin_bottom = 55 + legend_rows * legend_row_height

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
                 f'font-family="system-ui, sans-serif" font-size="{axis_font}">')
    lines.append(f'<rect width="{svg_w}" height="{svg_h}" fill="white"/>')

    # Define hatching patterns for parallel variants
    # Standard parallel (100f): 45° diagonal lines
    # Tezos parallel (other fiber counts): cross-hatch (45° + 135°)
    lines.append('<defs>')
    for backend in backends:
        if is_parallel_variant(backend):
            pid = f"hatch-{abs(hash(backend)) % 10000}"
            color = get_color(backend)
            if is_tezos_parallel(backend):
                lines.append(
                    f'<pattern id="{pid}" width="8" height="8" '
                    f'patternUnits="userSpaceOnUse">'
                    f'<rect width="8" height="8" fill="{color}"/>'
                    f'<line x1="0" y1="0" x2="8" y2="8" stroke="white" stroke-width="1.5"/>'
                    f'<line x1="8" y1="0" x2="0" y2="8" stroke="white" stroke-width="1.5"/>'
                    f'</pattern>')
            else:
                lines.append(
                    f'<pattern id="{pid}" width="6" height="6" '
                    f'patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
                    f'<rect width="6" height="6" fill="{color}"/>'
                    f'<line x1="0" y1="0" x2="0" y2="6" stroke="white" stroke-width="2"/>'
                    f'</pattern>')
    lines.append('</defs>')

    # Title
    lines.append(f'<text x="{svg_w/2}" y="32" text-anchor="middle" font-size="{title_font}" '
                 f'font-weight="bold">{title}</text>')

    ox, oy = margin_left, margin_top
    lines.append(f'<g transform="translate({ox},{oy})">')

    # Y axis label
    lines.append(f'<text x="-75" y="{chart_height/2}" text-anchor="middle" '
                 f'font-size="{axis_font}" fill="#333" transform="rotate(-90,-75,{chart_height/2})">'
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
                             f'text-anchor="end" font-size="{tick_font}" fill="#999">'
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
                         f'text-anchor="middle" font-size="{value_font}" fill="#333">'
                         f'{fmt_ops(val)}</text>')

        # Scenario label
        cx = gx + group_width / 2
        lines.append(f'<text x="{cx:.1f}" y="{chart_height + 18}" text-anchor="middle" '
                     f'font-size="{label_font}" font-weight="bold" fill="#333">{scenario}</text>')

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
        y = row * legend_row_height
        color = get_color(backend)
        if is_parallel_variant(backend):
            pid = f"hatch-{abs(hash(backend)) % 10000}"
            fill = f'url(#{pid})'
        else:
            fill = color
        lines.append(f'<rect x="{x}" y="{y}" width="14" height="14" fill="{fill}" rx="2"/>')
        lines.append(f'<text x="{x+18}" y="{y+12}" font-size="{legend_font}" fill="#333">{backend}</text>')

    lines.append('</g>')
    lines.append('</svg>')

    return "\n".join(lines)


def generate_speedup_chart(title, parallel_results, sequential_results):
    """Generate a speedup chart: ratio of parallel/sequential ops/s per scenario per backend.

    Only includes Irmini and Irmin-Eio backends (domain-safe).
    """
    # Build sequential lookup: (name, base_scenario) -> ops_per_sec
    seq_lookup = {}
    for r in sequential_results:
        seq_lookup[(r["name"], r["scenario"])] = r["ops_per_sec"]

    # Build speedup data: match parallel scenario to sequential base
    # e.g. "commits-20B-12f/12d" -> base "commits-20B"
    speedup_data = []  # list of (base_scenario, name, speedup)
    for r in parallel_results:
        m = re.match(r'^(.+)-\d+f/\d+d$', r["scenario"])
        if not m:
            continue
        base_scenario = m.group(1)
        seq_val = seq_lookup.get((r["name"], base_scenario))
        if seq_val and seq_val > 0:
            speedup = r["ops_per_sec"] / seq_val
            speedup_data.append((base_scenario, r["name"], speedup))

    if not speedup_data:
        return None

    # Get unique scenarios and backends
    scenarios = sorted({s for s, _, _ in speedup_data}, key=scenario_sort_key)
    backends = sorted({n for _, n, _ in speedup_data}, key=family_sort_key)
    lookup = {(s, n): sp for s, n, sp in speedup_data}

    # Layout
    margin_left = 100
    margin_right = 30
    margin_top = 50
    n_backends = len(backends)
    n_scenarios = len(scenarios)
    bar_width = max(8, min(22, 1100 // max(1, n_scenarios * n_backends)))
    bar_gap = 2
    group_gap = max(20, min(50, 1100 // max(1, n_scenarios * 3)))
    group_width = n_backends * (bar_width + bar_gap) - bar_gap
    chart_width = n_scenarios * (group_width + group_gap) - group_gap
    chart_height = 350

    legend_col_width = 200
    legend_cols = max(1, min(4, (margin_left + chart_width + margin_right) // legend_col_width))
    legend_rows = (n_backends + legend_cols - 1) // legend_cols
    margin_bottom = 55 + legend_rows * 24

    svg_w = max(margin_left + chart_width + margin_right, legend_cols * legend_col_width + margin_left)
    svg_h = margin_top + chart_height + margin_bottom

    max_speedup = max((sp for _, _, sp in speedup_data), default=1) * 1.15

    def y_of(val):
        if val <= 0:
            return chart_height
        return chart_height * (1 - val / max_speedup)

    lines = []
    lines.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{svg_w}" height="{svg_h}" '
                 f'font-family="system-ui, sans-serif" font-size="14">')
    lines.append(f'<rect width="{svg_w}" height="{svg_h}" fill="white"/>')
    lines.append(f'<text x="{svg_w/2}" y="32" text-anchor="middle" font-size="20" '
                 f'font-weight="bold">{title}</text>')

    ox, oy = margin_left, margin_top
    lines.append(f'<g transform="translate({ox},{oy})">')

    # Y axis label
    lines.append(f'<text x="-75" y="{chart_height/2}" text-anchor="middle" '
                 f'font-size="14" fill="#333" transform="rotate(-90,-75,{chart_height/2})">'
                 f'speedup (×)</text>')

    # Horizontal reference line at 1×
    y1 = y_of(1.0)
    lines.append(f'<line x1="0" y1="{y1:.1f}" x2="{chart_width}" y2="{y1:.1f}" '
                 f'stroke="#999" stroke-width="1" stroke-dasharray="4,4"/>')
    lines.append(f'<text x="-4" y="{y1+4:.1f}" text-anchor="end" font-size="10" fill="#999">1×</text>')

    # Grid lines
    for tick in range(2, int(max_speedup) + 1, max(1, int(max_speedup) // 5)):
        yy = y_of(tick)
        if yy > 0:
            lines.append(f'<line x1="0" y1="{yy:.1f}" x2="{chart_width}" y2="{yy:.1f}" '
                         f'stroke="#e0e0e0" stroke-width="0.5"/>')
            lines.append(f'<text x="-4" y="{yy+4:.1f}" text-anchor="end" font-size="10" '
                         f'fill="#999">{tick}×</text>')

    for si, scenario in enumerate(scenarios):
        gx = si * (group_width + group_gap)
        for bi, backend in enumerate(backends):
            val = lookup.get((scenario, backend))
            if val is None:
                continue
            bx = gx + bi * (bar_width + bar_gap)
            by = y_of(val)
            bh = chart_height - by
            color = get_color(backend)
            lines.append(f'<rect x="{bx:.1f}" y="{by:.1f}" width="{bar_width}" '
                         f'height="{bh:.1f}" fill="{color}" rx="1"/>')
            lines.append(f'<text x="{bx + bar_width/2:.1f}" y="{by - 3:.1f}" '
                         f'text-anchor="middle" font-size="9" fill="#333">'
                         f'{val:.1f}×</text>')

        cx = gx + group_width / 2
        lines.append(f'<text x="{cx:.1f}" y="{chart_height + 18}" text-anchor="middle" '
                     f'font-size="13" font-weight="bold" fill="#333">{scenario}</text>')

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
        lines.append(f'<rect x="{x}" y="{y}" width="14" height="14" fill="{color}" rx="2"/>')
        lines.append(f'<text x="{x+18}" y="{y+12}" font-size="13" fill="#333">{backend}</text>')
    lines.append('</g>')
    lines.append('</svg>')

    return "\n".join(lines)


def remap_parallel_scenarios(results, rename_backends=False):
    """Remap parallel scenario names to their base form for charting.

    e.g. "commits-20B-100f/12d" -> "commits-20B"
    If rename_backends=True, also rename backends with the parallel config suffix
    (e.g. "Irmini (lavyek)" -> "Irmini (lavyek) 12d×100f") so they get hatching.
    """
    remapped = []
    for r in results:
        m = re.match(r'^(.+)-(\d+)f/(\d+)d$', r["scenario"])
        if m:
            new_r = {**r, "scenario": m.group(1)}
            if rename_backends:
                fibers = m.group(2)
                domains = m.group(3)
                new_r["name"] = f"{r['name']} {domains}d×{fibers}f"
            remapped.append(new_r)
    return remapped


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
    groups = {"memory": [], "disk": [], "git": [], "optims_disk": [],
              "optims_memory": [], "optims_lavyek": [],
              "disk_parallel": [], "memory_parallel": []}
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
        ("disk", "Disk backends — single-core",
         "chart_disk.svg"),
        ("memory", "Memory backends — single-core",
         "chart_memory.svg"),
        ("git", "Git backends — single-core",
         "chart_git.svg"),
        ("optims_disk", "Irmini optimizations (disk)",
         "chart_optims_disk.svg"),
        ("optims_memory", "Irmini optimizations (memory)",
         "chart_optims_memory.svg"),
        ("optims_lavyek", "Irmini optimizations (lavyek)",
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

    # Parallel charts: remap scenario names, include sequential reference
    parallel_specs = [
        ("disk_parallel", "disk", "Disk backends — multi-core (100 fibers, 12 domains)",
         "chart_disk_parallel.svg"),
        ("memory_parallel", "memory", "Memory backends — multi-core (100 fibers, 12 domains)",
         "chart_memory_parallel.svg"),
    ]

    for cat, seq_cat, title, filename in parallel_specs:
        raw = groups.get(cat, [])
        if not raw:
            print(f"  No results for {cat}, skipping")
            continue
        # Only keep the main parallel config (100f/12d) and tezos parallel entries
        main_par = [r for r in raw
                    if re.search(r'-100f/\d+d$', r["scenario"])
                    or not re.search(r'-\d+f/\d+d$', r["scenario"])]
        remapped = remap_parallel_scenarios(main_par, rename_backends=True)
        # Include tezos parallel data as-is (already has parallel config in name)
        tezos_par = [r for r in main_par if not re.search(r'-\d+f/\d+d$', r["scenario"])]
        remapped.extend(tezos_par)
        # Build set of (base_backend, scenario) pairs that have parallel data
        par_pairs = set()
        par_base_backends = set()
        for r in remapped:
            base = re.sub(r'\s+\d+d[×x]\d+\w*f?$', '', r["name"])
            par_pairs.add((base, r["scenario"]))
            par_base_backends.add(base)
        # Add sequential reference for comparison (only where parallel exists)
        seq_seen = set()
        seq_ref = []
        for r in groups.get(seq_cat, []):
            key = (r["name"], r["scenario"])
            if key in par_pairs and key not in seq_seen:
                seq_seen.add(key)
                seq_ref.append({**r, "name": r["name"] + " (seq)"})
        all_par = remapped + seq_ref
        backends = ordered_backends(all_par)
        svg = generate_chart(title, all_par, backends)
        if svg:
            path = os.path.join(chart_dir, filename)
            with open(path, "w") as f:
                f.write(svg)
            print(f"  Written {path} ({len(backends)} backends, {len(all_par)} results)")

    # Speedup chart: parallel vs sequential
    par_results = groups.get("disk_parallel", []) + groups.get("memory_parallel", [])
    seq_results = groups["disk"] + groups["memory"]
    if par_results:
        svg = generate_speedup_chart(
            "Parallel speedup (vs sequential)", par_results, seq_results)
        if svg:
            path = os.path.join(chart_dir, "chart_speedup.svg")
            with open(path, "w") as f:
                f.write(svg)
            print(f"  Written {path} ({len(par_results)} parallel results)")


if __name__ == "__main__":
    main()
