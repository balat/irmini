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
SCALING_BACKENDS = {"Irmini (lavyek)", "Irmini (memory)", "Irmini (disk)", "Irmin-Eio (pack)"}

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
    """Load parallel scaling data from JSON files.

    Returns dict: (backend_name, base_scenario) -> [(fibers, ops_per_sec, domains)]
    """
    all_results = load_results(results_dir)

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


def generate_chart(series):
    margin_left = 90
    margin_right = 30
    margin_top = 55
    margin_bottom = 120
    chart_w = 700
    chart_h = 380
    svg_w = margin_left + chart_w + margin_right
    svg_h = margin_top + chart_h + margin_bottom

    all_points = []
    for data in series.values():
        all_points.extend(data)

    if not all_points:
        return None

    all_fibers = [p[0] for p in all_points]
    all_ops = [p[1] for p in all_points]
    domains = all_points[0][2]

    x_min_log = math.log10(max(1, min(all_fibers)))
    x_max_log = math.log10(max(all_fibers))
    y_max = max(all_ops) * 1.15

    def x_of(fibers):
        return margin_left + (math.log10(max(1, fibers)) - x_min_log) / (x_max_log - x_min_log) * chart_w

    def y_of(ops):
        return margin_top + chart_h * (1 - ops / y_max)

    lines = []
    lines.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{svg_w}" height="{svg_h}" '
                 f'font-family="system-ui, sans-serif" font-size="11">')
    lines.append(f'<rect width="{svg_w}" height="{svg_h}" fill="white"/>')

    lines.append(f'<text x="{svg_w/2}" y="24" text-anchor="middle" font-size="16" '
                 f'font-weight="bold">Parallel Scenario Scaling — {domains} domains</text>')
    lines.append(f'<text x="{svg_w/2}" y="42" text-anchor="middle" font-size="11" fill="#666">'
                 f'Commits and reads throughput, varying fiber count</text>')

    # Y axis grid
    if y_max > 5_000_000:
        y_ticks = list(range(0, int(y_max) + 1_000_000, 2_000_000))
    elif y_max > 1_000_000:
        y_ticks = list(range(0, int(y_max) + 500_000, 500_000))
    elif y_max > 100_000:
        y_ticks = list(range(0, int(y_max) + 100_000, 100_000))
    else:
        y_ticks = list(range(0, int(y_max) + 50_000, 50_000))

    for tick in y_ticks:
        if tick > y_max:
            break
        yy = y_of(tick)
        lines.append(f'<line x1="{margin_left}" y1="{yy:.1f}" '
                     f'x2="{margin_left + chart_w}" y2="{yy:.1f}" '
                     f'stroke="#e8e8e8" stroke-width="0.5"/>')
        lines.append(f'<text x="{margin_left - 8}" y="{yy + 4:.1f}" '
                     f'text-anchor="end" font-size="10" fill="#666">{fmt_ops(tick)}</text>')

    lines.append(f'<text x="16" y="{margin_top + chart_h/2}" text-anchor="middle" '
                 f'font-size="12" fill="#333" transform="rotate(-90,16,{margin_top + chart_h/2})">'
                 f'Throughput (ops/s)</text>')

    # X axis grid
    x_ticks = [v for v in [1, 10, 100, 1_000, 10_000, 100_000]
               if x_min_log <= math.log10(max(1, v)) <= x_max_log]
    for tick in x_ticks:
        xx = x_of(tick)
        lines.append(f'<line x1="{xx:.1f}" y1="{margin_top}" '
                     f'x2="{xx:.1f}" y2="{margin_top + chart_h}" '
                     f'stroke="#e8e8e8" stroke-width="0.5"/>')
        lines.append(f'<text x="{xx:.1f}" y="{margin_top + chart_h + 16}" '
                     f'text-anchor="middle" font-size="10" fill="#666">{fmt_fibers(tick)}</text>')

    lines.append(f'<text x="{margin_left + chart_w/2}" y="{margin_top + chart_h + 34}" '
                 f'text-anchor="middle" font-size="12" fill="#333">'
                 f'Number of fibers</text>')

    # Draw each series
    for (name, base), data in sorted(series.items()):
        color = COLORS.get(name, "#999")
        dash = DASHES.get(base, "")
        sorted_data = sorted(data, key=lambda d: d[0])

        path_parts = []
        for i, (fibers, ops, _) in enumerate(sorted_data):
            xx = x_of(fibers)
            yy = y_of(ops)
            cmd = "M" if i == 0 else "L"
            path_parts.append(f"{cmd}{xx:.1f},{yy:.1f}")

        dash_attr = f' stroke-dasharray="{dash}"' if dash else ''
        lines.append(f'<path d="{" ".join(path_parts)}" fill="none" '
                     f'stroke="{color}" stroke-width="2.5" stroke-linejoin="round"'
                     f'{dash_attr}/>')

        for fibers, ops, _ in sorted_data:
            xx = x_of(fibers)
            yy = y_of(ops)
            lines.append(f'<circle cx="{xx:.1f}" cy="{yy:.1f}" r="3" '
                         f'fill="{color}" stroke="white" stroke-width="1.5"/>')

        # Label at peak
        peak = max(sorted_data, key=lambda d: d[1])
        xx = x_of(peak[0])
        yy = y_of(peak[1])
        lines.append(f'<text x="{xx:.1f}" y="{yy - 10:.1f}" text-anchor="middle" '
                     f'font-size="9" font-weight="bold" fill="{color}">'
                     f'{fmt_ops(peak[1])}</text>')

    # Axes
    lines.append(f'<line x1="{margin_left}" y1="{margin_top}" '
                 f'x2="{margin_left}" y2="{margin_top + chart_h}" '
                 f'stroke="#333" stroke-width="1"/>')
    lines.append(f'<line x1="{margin_left}" y1="{margin_top + chart_h}" '
                 f'x2="{margin_left + chart_w}" y2="{margin_top + chart_h}" '
                 f'stroke="#333" stroke-width="1"/>')

    # Legend: 2 columns — backends (color) and scenarios (dash)
    ly = margin_top + chart_h + 52
    lx = margin_left

    # Backend colors
    seen_backends = sorted({name for (name, _) in series.keys()})
    for name in seen_backends:
        color = COLORS.get(name, "#999")
        lines.append(f'<rect x="{lx}" y="{ly}" width="12" height="12" fill="{color}" rx="2"/>')
        lines.append(f'<text x="{lx + 16}" y="{ly + 10}" font-size="10" fill="#333">{name}</text>')
        lx += 180

    # Scenario dash patterns
    ly += 24
    lx = margin_left
    seen_scenarios = sorted({base for (_, base) in series.keys()})
    for base in seen_scenarios:
        dash = DASHES.get(base, "")
        dash_attr = f' stroke-dasharray="{dash}"' if dash else ''
        lines.append(f'<line x1="{lx}" y1="{ly + 6}" x2="{lx + 30}" y2="{ly + 6}" '
                     f'stroke="#333" stroke-width="2"{dash_attr}/>')
        lines.append(f'<text x="{lx + 36}" y="{ly + 10}" font-size="10" fill="#333">{base}</text>')
        lx += 160

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
