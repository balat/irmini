#!/usr/bin/env python3
"""Generate SVG line chart for parallel scenario scaling results.

Shows throughput (ops/s) vs number of fibers on a log-scale x-axis,
with separate lines for each (backend, scenario) combination.
Reads from irmini_scaling.json and irmini_inode.json (for standard parallel).

Usage: gen_chart_scaling.py <output_svg> --json <results_dir>
"""

import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
from bench_utils import load_results, COLORS, fmt_ops_chart as fmt_ops, fmt_fibers

# Only show these backends in scaling chart
SCALING_BACKENDS = {"Irmini (lavyek)", "Irmini (lavyek, no fsync)", "Irmini (memory)", "Irmini (disk)", "Irmin-Eio (pack)"}

# Dash patterns per base scenario
DASHES = {
    "commits-20B": "",
    "reads-20B": "8,4",
    "incremental-20B": "3,3",
    "commits-10K": "12,4,3,4",
    "reads-10K": "6,3,2,3",
    "incremental-10K": "2,2",
}


def load_scaling_series(results_dir):
    """Load parallel scaling data from irmini_scaling.json only.

    Returns dict: (backend_name, base_scenario) -> [(fibers, ops_per_sec, domains)]
    """
    scaling_file = os.path.join(results_dir, "irmini_scaling.json")
    if not os.path.exists(scaling_file):
        print(f"Error: {scaling_file} not found")
        return {}
    import json
    with open(scaling_file) as f:
        all_results = json.load(f)
    print(f"  Loaded {len(all_results)} results from irmini_scaling.json")

    series = {}
    for r in all_results:
        s = r["scenario"]
        m = re.match(r'^(.+)-(\d+)f/(\d+)d$', s)
        if not m:
            continue
        name = r["name"]
        if name not in SCALING_BACKENDS:
            continue
        base = m.group(1)
        fibers = int(m.group(2))
        domains = int(m.group(3))
        key = (name, base)
        if key not in series:
            series[key] = []
        series[key].append((fibers, int(r["ops_per_sec"]), domains))

    return series


def compute_y_ticks(y_max):
    """Choose nice Y-axis tick values for a given max."""
    if y_max > 5_000_000:
        step = 2_000_000
    elif y_max > 1_000_000:
        step = 1_000_000
    elif y_max > 500_000:
        step = 200_000
    elif y_max > 100_000:
        step = 50_000
    elif y_max > 10_000:
        step = 5_000
    else:
        step = 1_000
    return [v for v in range(0, int(y_max) + step, step) if v <= y_max]


# Scenario categories and their display config
SCENARIO_CATS = ["reads", "commits", "incremental"]
SCENARIO_TITLES = {"reads": "Reads", "commits": "Commits", "incremental": "Incremental"}
# Line style per value size within each facet
SIZE_STYLES = {
    "20B": {"dash": "", "label": "20 B values"},
    "10K": {"dash": "6,3", "label": "10 KB values"},
}


def generate_chart(series):
    # Group series by scenario category: "reads" -> {(backend, "20B"): [...], ...}
    facets = {}
    for (name, base), data in series.items():
        for cat in SCENARIO_CATS:
            if base.startswith(cat + "-"):
                size = base[len(cat) + 1:]  # "20B" or "10K"
                facets.setdefault(cat, {})[name, size] = data
                break

    active_cats = [c for c in SCENARIO_CATS if c in facets]
    if not active_cats:
        return None

    # Detect domains from first data point
    first_data = next(iter(next(iter(facets.values())).values()))
    domains = first_data[0][2]

    # Global X range (shared across facets)
    all_fibers = []
    for cat_data in facets.values():
        for data in cat_data.values():
            all_fibers.extend(p[0] for p in data)
    x_min_log = math.log10(max(1, min(all_fibers)))
    x_max_log = math.log10(max(all_fibers))

    # Layout
    n_facets = len(active_cats)
    facet_w = 220
    facet_h = 260
    gap = 40
    y_label_w = 60
    margin_left = 30
    margin_right = 20
    margin_top = 50
    margin_bottom = 80

    total_w = margin_left + n_facets * (y_label_w + facet_w) + (n_facets - 1) * gap + margin_right
    total_h = margin_top + facet_h + margin_bottom

    lines = []
    lines.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{total_w}" height="{total_h}" '
                 f'font-family="system-ui, sans-serif" font-size="11">')
    lines.append(f'<rect width="{total_w}" height="{total_h}" fill="white"/>')

    lines.append(f'<text x="{total_w/2}" y="22" text-anchor="middle" font-size="15" '
                 f'font-weight="bold">Parallel Scenario Scaling — {domains} domains</text>')
    lines.append(f'<text x="{total_w/2}" y="38" text-anchor="middle" font-size="11" fill="#666">'
                 f'Throughput vs fiber count (log scale)</text>')

    seen_backends = set()

    for fi, cat in enumerate(active_cats):
        cat_series = facets[cat]
        ox = margin_left + fi * (y_label_w + facet_w + gap) + y_label_w
        oy = margin_top

        # Per-facet Y range
        cat_ops = [p[1] for data in cat_series.values() for p in data]
        y_max = max(cat_ops) * 1.15

        def x_of(fibers):
            return ox + (math.log10(max(1, fibers)) - x_min_log) / (x_max_log - x_min_log) * facet_w

        def y_of(ops):
            return oy + facet_h * (1 - ops / y_max)

        # Facet title
        lines.append(f'<text x="{ox + facet_w/2}" y="{oy - 8}" text-anchor="middle" '
                     f'font-size="13" font-weight="bold" fill="#333">'
                     f'{SCENARIO_TITLES.get(cat, cat)}</text>')

        # Y grid + labels
        for tick in compute_y_ticks(y_max):
            yy = y_of(tick)
            lines.append(f'<line x1="{ox}" y1="{yy:.1f}" x2="{ox + facet_w}" y2="{yy:.1f}" '
                         f'stroke="#e8e8e8" stroke-width="0.5"/>')
            lines.append(f'<text x="{ox - 6}" y="{yy + 4:.1f}" text-anchor="end" '
                         f'font-size="9" fill="#666">{fmt_ops(tick)}</text>')

        # X grid + labels
        x_ticks = [v for v in [1, 10, 100, 1_000, 10_000, 100_000]
                   if x_min_log <= math.log10(max(1, v)) <= x_max_log]
        for tick in x_ticks:
            xx = x_of(tick)
            lines.append(f'<line x1="{xx:.1f}" y1="{oy}" x2="{xx:.1f}" y2="{oy + facet_h}" '
                         f'stroke="#e8e8e8" stroke-width="0.5"/>')
            lines.append(f'<text x="{xx:.1f}" y="{oy + facet_h + 14}" text-anchor="middle" '
                         f'font-size="9" fill="#666">{fmt_fibers(tick)}</text>')

        # X axis label (only on middle facet)
        if fi == n_facets // 2:
            lines.append(f'<text x="{ox + facet_w/2}" y="{oy + facet_h + 30}" '
                         f'text-anchor="middle" font-size="11" fill="#333">Fibers</text>')

        # Draw lines for this facet
        for (name, size), data in sorted(cat_series.items()):
            seen_backends.add(name)
            color = COLORS.get(name, "#999")
            dash = SIZE_STYLES.get(size, {}).get("dash", "")
            sorted_data = sorted(data, key=lambda d: d[0])

            path_parts = []
            for i, (fibers, ops, _) in enumerate(sorted_data):
                xx = x_of(fibers)
                yy = y_of(ops)
                cmd = "M" if i == 0 else "L"
                path_parts.append(f"{cmd}{xx:.1f},{yy:.1f}")

            dash_attr = f' stroke-dasharray="{dash}"' if dash else ''
            lines.append(f'<path d="{" ".join(path_parts)}" fill="none" '
                         f'stroke="{color}" stroke-width="2" stroke-linejoin="round"'
                         f'{dash_attr}/>')

            for fibers, ops, _ in sorted_data:
                xx = x_of(fibers)
                yy = y_of(ops)
                lines.append(f'<circle cx="{xx:.1f}" cy="{yy:.1f}" r="2.5" '
                             f'fill="{color}" stroke="white" stroke-width="1"/>')

            # Label at peak
            peak = max(sorted_data, key=lambda d: d[1])
            xx = x_of(peak[0])
            yy = y_of(peak[1])
            lines.append(f'<text x="{xx:.1f}" y="{yy - 8:.1f}" text-anchor="middle" '
                         f'font-size="8" font-weight="bold" fill="{color}">'
                         f'{fmt_ops(peak[1])}</text>')

        # Axes
        lines.append(f'<line x1="{ox}" y1="{oy}" x2="{ox}" y2="{oy + facet_h}" '
                     f'stroke="#333" stroke-width="1"/>')
        lines.append(f'<line x1="{ox}" y1="{oy + facet_h}" '
                     f'x2="{ox + facet_w}" y2="{oy + facet_h}" '
                     f'stroke="#333" stroke-width="1"/>')

    # Legend
    ly = margin_top + facet_h + 44
    lx = margin_left + y_label_w

    # Backend colors
    for name in sorted(seen_backends):
        color = COLORS.get(name, "#999")
        lines.append(f'<rect x="{lx}" y="{ly}" width="10" height="10" fill="{color}" rx="2"/>')
        lines.append(f'<text x="{lx + 14}" y="{ly + 9}" font-size="10" fill="#333">{name}</text>')
        lx += 160

    # Value size line styles
    lx += 30
    for size in ["20B", "10K"]:
        style = SIZE_STYLES[size]
        dash = style["dash"]
        dash_attr = f' stroke-dasharray="{dash}"' if dash else ''
        lines.append(f'<line x1="{lx}" y1="{ly + 5}" x2="{lx + 24}" y2="{ly + 5}" '
                     f'stroke="#333" stroke-width="2"{dash_attr}/>')
        lines.append(f'<text x="{lx + 28}" y="{ly + 9}" font-size="10" fill="#333">'
                     f'{style["label"]}</text>')
        lx += 120

    lines.append('</svg>')
    return "\n".join(lines)


def main():
    args = sys.argv[1:]
    if not args:
        print("Usage: gen_chart_scaling.py <output_svg> --json <results_dir>")
        sys.exit(1)

    output_svg = args[0]
    results_dir = None
    if "--json" in args:
        idx = args.index("--json")
        if idx + 1 < len(args):
            results_dir = args[idx + 1]

    if not results_dir:
        print("Error: --json <results_dir> required")
        sys.exit(1)

    series = load_scaling_series(results_dir)
    if not series:
        print("No parallel scaling data found")
        sys.exit(1)

    svg = generate_chart(series)
    if svg:
        with open(output_svg, "w") as f:
            f.write(svg)
        total = sum(len(d) for d in series.values())
        print(f"Written {output_svg} ({total} data points, {len(series)} series)")


if __name__ == "__main__":
    main()
