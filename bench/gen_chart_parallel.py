#!/usr/bin/env python3
"""Generate SVG line chart for parallel trace replay scaling results.

Shows throughput (ops/s) vs fibers per domain on a log-scale x-axis,
with the sequential baseline as a reference line.

Usage: gen_chart_parallel.py <output_svg>
"""

import math
import sys


# Data: (fibers_per_domain, ops_per_sec)
DATA = [
    (1,      84_000),
    (10,     236_000),
    (100,    647_000),
    (1_000,  1_300_000),
    (10_000, 4_119_000),
    (20_000, 3_992_000),
    (30_000, 4_759_000),
    (40_000, 4_512_000),
    (45_000, 4_989_000),
    (50_000, 5_063_000),
    (55_000, 4_901_000),
    (60_000, 4_360_000),
    (70_000, 4_751_000),
    (100_000, 2_961_000),
]

SEQUENTIAL = 54_000  # sequential baseline ops/s
DOMAINS = 12


def fmt_ops(v):
    if v >= 1_000_000:
        return f"{v/1_000_000:.1f}M"
    if v >= 1_000:
        return f"{v/1_000:.0f}k"
    return str(int(v))


def fmt_fibers(v):
    if v >= 1_000:
        return f"{v//1_000}k"
    return str(v)


def generate_chart():
    # Layout
    margin_left = 90
    margin_right = 30
    margin_top = 55
    margin_bottom = 95
    chart_w = 650
    chart_h = 380
    svg_w = margin_left + chart_w + margin_right
    svg_h = margin_top + chart_h + margin_bottom

    # Log-scale X axis
    x_min_log = math.log10(DATA[0][0])  # log10(1) = 0
    x_max_log = math.log10(DATA[-1][0])  # log10(100000) = 5

    # Y axis: linear, from 0 to max * 1.15
    y_max = max(d[1] for d in DATA) * 1.15

    def x_of(fibers):
        return margin_left + (math.log10(fibers) - x_min_log) / (x_max_log - x_min_log) * chart_w

    def y_of(ops):
        return margin_top + chart_h * (1 - ops / y_max)

    lines = []
    lines.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{svg_w}" height="{svg_h}" '
                 f'font-family="system-ui, sans-serif" font-size="11">')
    lines.append(f'<rect width="{svg_w}" height="{svg_h}" fill="white"/>')

    # Title
    lines.append(f'<text x="{svg_w/2}" y="24" text-anchor="middle" font-size="16" '
                 f'font-weight="bold">Parallel Trace Replay Scaling — {DOMAINS} domains, Lavyek backend</text>')
    lines.append(f'<text x="{svg_w/2}" y="42" text-anchor="middle" font-size="11" fill="#666">'
                 f'Tezos trace: 4M ops, 10310 commits</text>')

    # Grid lines (Y axis)
    y_ticks = [0, 1_000_000, 2_000_000, 3_000_000, 4_000_000, 5_000_000]
    for tick in y_ticks:
        if tick > y_max:
            break
        yy = y_of(tick)
        lines.append(f'<line x1="{margin_left}" y1="{yy:.1f}" '
                     f'x2="{margin_left + chart_w}" y2="{yy:.1f}" '
                     f'stroke="#e8e8e8" stroke-width="0.5"/>')
        lines.append(f'<text x="{margin_left - 8}" y="{yy + 4:.1f}" '
                     f'text-anchor="end" font-size="10" fill="#666">{fmt_ops(tick)}</text>')

    # Y axis label
    lines.append(f'<text x="16" y="{margin_top + chart_h/2}" text-anchor="middle" '
                 f'font-size="12" fill="#333" transform="rotate(-90,16,{margin_top + chart_h/2})">'
                 f'Throughput (ops/s)</text>')

    # X axis grid lines
    x_ticks = [1, 10, 100, 1_000, 10_000, 100_000]
    for tick in x_ticks:
        xx = x_of(tick)
        lines.append(f'<line x1="{xx:.1f}" y1="{margin_top}" '
                     f'x2="{xx:.1f}" y2="{margin_top + chart_h}" '
                     f'stroke="#e8e8e8" stroke-width="0.5"/>')
        lines.append(f'<text x="{xx:.1f}" y="{margin_top + chart_h + 16}" '
                     f'text-anchor="middle" font-size="10" fill="#666">{fmt_fibers(tick)}</text>')

    # X axis label
    lines.append(f'<text x="{margin_left + chart_w/2}" y="{margin_top + chart_h + 34}" '
                 f'text-anchor="middle" font-size="12" fill="#333">'
                 f'Fibers per domain</text>')

    # Sequential baseline
    base_y = y_of(SEQUENTIAL)
    lines.append(f'<line x1="{margin_left}" y1="{base_y:.1f}" '
                 f'x2="{margin_left + chart_w}" y2="{base_y:.1f}" '
                 f'stroke="#e15759" stroke-width="1.5" stroke-dasharray="6,4"/>')
    lines.append(f'<text x="{margin_left + chart_w + 2}" y="{base_y + 4:.1f}" '
                 f'font-size="9" fill="#e15759">sequential ({fmt_ops(SEQUENTIAL)})</text>')

    # Data line
    color = "#59a14f"
    # Sort by fibers for the line
    sorted_data = sorted(DATA, key=lambda d: d[0])

    # Line path
    path_parts = []
    for i, (fibers, ops) in enumerate(sorted_data):
        xx = x_of(fibers)
        yy = y_of(ops)
        cmd = "M" if i == 0 else "L"
        path_parts.append(f"{cmd}{xx:.1f},{yy:.1f}")
    lines.append(f'<path d="{" ".join(path_parts)}" fill="none" '
                 f'stroke="{color}" stroke-width="2.5" stroke-linejoin="round"/>')

    # Data points + labels
    for fibers, ops in sorted_data:
        xx = x_of(fibers)
        yy = y_of(ops)
        speedup = ops / SEQUENTIAL
        lines.append(f'<circle cx="{xx:.1f}" cy="{yy:.1f}" r="4" fill="{color}" stroke="white" stroke-width="1.5"/>')

        # Label: show ops and speedup for key points only
        key_points = {1, 10, 100, 1_000, 10_000, 50_000, 100_000}
        if fibers in key_points:
            label = f"{fmt_ops(ops)} ({speedup:.0f}x)"
            # Offset labels to avoid overlap
            ly = yy - 12
            anchor = "middle"
            if fibers == 1:
                anchor = "start"
            elif fibers == 100_000:
                anchor = "end"
                ly = yy + 18
            lines.append(f'<text x="{xx:.1f}" y="{ly:.1f}" text-anchor="{anchor}" '
                         f'font-size="9" font-weight="bold" fill="#333">{label}</text>')

    # Axes
    lines.append(f'<line x1="{margin_left}" y1="{margin_top}" '
                 f'x2="{margin_left}" y2="{margin_top + chart_h}" '
                 f'stroke="#333" stroke-width="1"/>')
    lines.append(f'<line x1="{margin_left}" y1="{margin_top + chart_h}" '
                 f'x2="{margin_left + chart_w}" y2="{margin_top + chart_h}" '
                 f'stroke="#333" stroke-width="1"/>')

    # Legend
    ly = margin_top + chart_h + 52
    lines.append(f'<rect x="{margin_left}" y="{ly}" width="12" height="12" fill="{color}" rx="2"/>')
    lines.append(f'<text x="{margin_left + 16}" y="{ly + 10}" font-size="10" fill="#333">'
                 f'Irmini-parallel (lavyek) — 12 domains</text>')
    lines.append(f'<line x1="{margin_left + 260}" y1="{ly + 6}" '
                 f'x2="{margin_left + 285}" y2="{ly + 6}" '
                 f'stroke="#e15759" stroke-width="1.5" stroke-dasharray="6,4"/>')
    lines.append(f'<text x="{margin_left + 290}" y="{ly + 10}" font-size="10" fill="#333">'
                 f'Sequential baseline (54k ops/s)</text>')

    lines.append('</svg>')
    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print("Usage: gen_chart_parallel.py <output_svg>")
        sys.exit(1)

    svg = generate_chart()
    with open(sys.argv[1], "w") as f:
        f.write(svg)
    print(f"Written {sys.argv[1]}")


if __name__ == "__main__":
    main()
