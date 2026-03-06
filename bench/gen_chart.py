#!/usr/bin/env python3
"""Generate an SVG bar chart from benchmark results, grouped by scenario."""

import math

# --- Data (from README.md, eio branch results) ---

data = [
    # (name, scenario, ops_per_sec)
    # Irmini
    ("Irmini (memory)",   "commits",      519),
    ("Irmini (memory)",   "reads",        9564),
    ("Irmini (memory)",   "incremental",  1965),
    ("Irmini (memory)",   "large-values", 1527),
    ("Irmini (disk)",     "commits",      429),
    ("Irmini (disk)",     "reads",        4001),
    ("Irmini (disk)",     "incremental",  10),
    ("Irmini (disk)",     "large-values", 91),
    ("Irmini (disk)",     "concurrent",   263),
    ("Irmini (lavyek)",   "commits",      457),
    ("Irmini (lavyek)",   "reads",        8345),
    ("Irmini (lavyek)",   "incremental",  1436),
    ("Irmini (lavyek)",   "large-values", 1286),
    ("Irmini (lavyek)",   "concurrent",   447187),
    # Irmin-Eio (eio branch)
    ("Irmin (memory)",    "commits",      158192),
    ("Irmin (memory)",    "reads",        1348477),
    ("Irmin (memory)",    "incremental",  2870),
    ("Irmin (memory)",    "large-values", 14836),
    ("Irmin-pack",        "commits",      46304),
    ("Irmin-pack",        "reads",        1416803),
    ("Irmin-pack",        "incremental",  2030),
    ("Irmin-pack",        "large-values", 7613),
    ("Irmin-pack",        "concurrent",   1612),
    ("Irmin-fs",          "commits",      36907),
    ("Irmin-fs",          "reads",        200104),
    ("Irmin-fs",          "incremental",  196),
    ("Irmin-fs",          "large-values", 2683),
    ("Irmin-git",         "commits",      2164),
    ("Irmin-git",         "reads",        145247),
    ("Irmin-git",         "incremental",  161),
    ("Irmin-git",         "large-values", 1585),
]

scenarios = ["commits", "reads", "incremental", "large-values", "concurrent"]
backends = [
    "Irmini (memory)", "Irmini (disk)", "Irmini (lavyek)",
    "Irmin (memory)", "Irmin-pack", "Irmin-fs", "Irmin-git",
]

colors = {
    "Irmini (memory)":  "#4e79a7",
    "Irmini (disk)":    "#59a14f",
    "Irmini (lavyek)":  "#9c755f",
    "Irmin (memory)":   "#f28e2b",
    "Irmin-pack":       "#e15759",
    "Irmin-fs":         "#76b7b2",
    "Irmin-git":        "#b07aa1",
}

# Build lookup
lookup = {}
for name, scenario, ops in data:
    lookup[(name, scenario)] = ops

# --- SVG generation ---

margin_left = 120
margin_right = 30
margin_top = 60
margin_bottom = 120
group_gap = 50
bar_width = 18
bar_gap = 2
scenario_label_h = 20

n_backends = len(backends)
group_width = n_backends * (bar_width + bar_gap) - bar_gap
chart_width = len(scenarios) * (group_width + group_gap) - group_gap
chart_height = 400

svg_w = margin_left + chart_width + margin_right
svg_h = margin_top + chart_height + margin_bottom

# Use log scale since values span 6 orders of magnitude
min_val = 1
max_val = 2_000_000
log_min = math.log10(min_val)
log_max = math.log10(max_val)


def y_of(val):
    if val <= 0:
        return chart_height
    lv = math.log10(max(val, min_val))
    frac = (lv - log_min) / (log_max - log_min)
    return chart_height * (1 - frac)


def fmt_ops(v):
    if v >= 1_000_000:
        return f"{v/1_000_000:.0f}M"
    if v >= 1_000:
        return f"{v/1_000:.0f}k"
    return str(v)


lines = []
lines.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{svg_w}" height="{svg_h}" '
             f'font-family="system-ui, sans-serif" font-size="11">')

# Background
lines.append(f'<rect width="{svg_w}" height="{svg_h}" fill="white"/>')

# Title
lines.append(f'<text x="{svg_w/2}" y="28" text-anchor="middle" font-size="16" '
             f'font-weight="bold">Benchmark comparison (ops/s, log scale)</text>')
lines.append(f'<text x="{svg_w/2}" y="46" text-anchor="middle" font-size="11" '
             f'fill="#666">50 commits x 500 adds, depth 10, 5000 reads, 100-byte values</text>')

# Chart area
ox, oy = margin_left, margin_top

# Grid lines (log scale)
lines.append(f'<g transform="translate({ox},{oy})">')
for exp in range(0, 7):
    val = 10 ** exp
    if val > max_val:
        break
    yy = y_of(val)
    lines.append(f'<line x1="0" y1="{yy:.1f}" x2="{chart_width}" y2="{yy:.1f}" '
                 f'stroke="#e0e0e0" stroke-width="1"/>')
    lines.append(f'<text x="-8" y="{yy + 4:.1f}" text-anchor="end" font-size="10" '
                 f'fill="#666">{fmt_ops(val)}</text>')

# Y axis label
lines.append(f'<text x="-85" y="{chart_height/2}" text-anchor="middle" '
             f'font-size="12" fill="#333" transform="rotate(-90,-85,{chart_height/2})">'
             f'ops/s</text>')

# Bars per scenario
for si, scenario in enumerate(scenarios):
    gx = si * (group_width + group_gap)
    for bi, backend in enumerate(backends):
        val = lookup.get((backend, scenario))
        if val is None:
            continue
        bx = gx + bi * (bar_width + bar_gap)
        by = y_of(val)
        bh = chart_height - by
        c = colors[backend]
        lines.append(f'<rect x="{bx:.1f}" y="{by:.1f}" width="{bar_width}" '
                     f'height="{bh:.1f}" fill="{c}" rx="1"/>')
        # Value label on top of bar
        lines.append(f'<text x="{bx + bar_width/2:.1f}" y="{by - 3:.1f}" '
                     f'text-anchor="middle" font-size="8" fill="#333">'
                     f'{fmt_ops(val)}</text>')

    # Scenario label below
    cx = gx + group_width / 2
    lines.append(f'<text x="{cx:.1f}" y="{chart_height + 16}" text-anchor="middle" '
                 f'font-size="11" font-weight="bold" fill="#333">{scenario}</text>')

# Bottom axis line
lines.append(f'<line x1="0" y1="{chart_height}" x2="{chart_width}" '
             f'y2="{chart_height}" stroke="#333" stroke-width="1"/>')

lines.append('</g>')

# Legend
lx = ox
ly = oy + chart_height + 40
lines.append(f'<g transform="translate({lx},{ly})">')
cols = 4
for i, backend in enumerate(backends):
    col = i % cols
    row = i // cols
    x = col * 180
    y = row * 20
    c = colors[backend]
    lines.append(f'<rect x="{x}" y="{y}" width="12" height="12" fill="{c}" rx="2"/>')
    lines.append(f'<text x="{x+16}" y="{y+10}" font-size="10" fill="#333">{backend}</text>')
lines.append('</g>')

lines.append('</svg>')

svg = "\n".join(lines)
out = "bench/bench_chart.svg"
with open(out, "w") as f:
    f.write(svg)
print(f"Written to {out}")
