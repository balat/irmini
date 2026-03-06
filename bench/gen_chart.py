#!/usr/bin/env python3
"""Generate an SVG bar chart from benchmark results, grouped by scenario."""

import math

# --- Data (from README.md, eio branch results) ---

data = [
    # (name, scenario, ops_per_sec)
    # Irmini (no inlining)
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
    # Irmini + inlining
    ("Irmini+inline (memory)",  "commits",      549),
    ("Irmini+inline (memory)",  "reads",        9712),
    ("Irmini+inline (memory)",  "incremental",  2029),
    ("Irmini+inline (memory)",  "large-values", 1583),
    ("Irmini+inline (disk)",    "commits",      444),
    ("Irmini+inline (disk)",    "reads",        4448),
    ("Irmini+inline (disk)",    "incremental",  10),
    ("Irmini+inline (disk)",    "large-values", 91),
    ("Irmini+inline (disk)",    "concurrent",   261),
    ("Irmini+inline (lavyek)",  "commits",      485),
    ("Irmini+inline (lavyek)",  "reads",        8438),
    ("Irmini+inline (lavyek)",  "incremental",  1515),
    ("Irmini+inline (lavyek)",  "large-values", 1314),
    ("Irmini+inline (lavyek)",  "concurrent",   436529),
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
    "Irmini (memory)", "Irmini+inline (memory)",
    "Irmini (disk)", "Irmini+inline (disk)",
    "Irmini (lavyek)", "Irmini+inline (lavyek)",
    "Irmin (memory)", "Irmin-pack", "Irmin-fs", "Irmin-git",
]

colors = {
    "Irmini (memory)":          "#4e79a7",
    "Irmini+inline (memory)":   "#7eadd4",
    "Irmini (disk)":            "#59a14f",
    "Irmini+inline (disk)":     "#8ed485",
    "Irmini (lavyek)":          "#9c755f",
    "Irmini+inline (lavyek)":   "#c9a48e",
    "Irmin (memory)":           "#f28e2b",
    "Irmin-pack":               "#e15759",
    "Irmin-fs":                 "#76b7b2",
    "Irmin-git":                "#b07aa1",
}

# Build lookup
lookup = {}
for name, scenario, ops in data:
    lookup[(name, scenario)] = ops

# --- SVG generation ---

margin_left = 120
margin_right = 30
margin_top = 60
margin_bottom = 140
group_gap = 50
bar_width = 14
bar_gap = 2
scenario_label_h = 20

n_backends = len(backends)
group_width = n_backends * (bar_width + bar_gap) - bar_gap
chart_width = len(scenarios) * (group_width + group_gap) - group_gap
chart_height = 400

svg_w = margin_left + chart_width + margin_right
svg_h = margin_top + chart_height + margin_bottom

# Linear scale — compute max per scenario for independent Y axes
max_per_scenario = {}
for name, scenario, ops in data:
    max_per_scenario[scenario] = max(max_per_scenario.get(scenario, 0), ops)


def y_of_scenario(val, scenario):
    if val <= 0:
        return chart_height
    mx = max_per_scenario[scenario]
    # Add 15% headroom for labels
    frac = val / (mx * 1.15)
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

# Stripe pattern for +inline variants
for name, color in colors.items():
    if "+inline" in name:
        pid = name.replace(" ", "_").replace("(", "").replace(")", "").replace("+", "p")
        lines.append(f'<defs><pattern id="{pid}" width="4" height="4" '
                     f'patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
                     f'<rect width="4" height="4" fill="{color}"/>'
                     f'<line x1="0" y1="0" x2="0" y2="4" stroke="white" stroke-width="1" opacity="0.4"/>'
                     f'</pattern></defs>')

# Title
lines.append(f'<text x="{svg_w/2}" y="28" text-anchor="middle" font-size="16" '
             f'font-weight="bold">Benchmark comparison (ops/s, linear scale per scenario)</text>')
lines.append(f'<text x="{svg_w/2}" y="46" text-anchor="middle" font-size="11" '
             f'fill="#666">50 commits x 500 adds, depth 10, 5000 reads, 100-byte values</text>')

# Chart area
ox, oy = margin_left, margin_top

# Chart content
lines.append(f'<g transform="translate({ox},{oy})">')

# Y axis label
lines.append(f'<text x="-85" y="{chart_height/2}" text-anchor="middle" '
             f'font-size="12" fill="#333" transform="rotate(-90,-85,{chart_height/2})">'
             f'ops/s</text>')

# Bars per scenario — each scenario has its own linear Y scale
for si, scenario in enumerate(scenarios):
    gx = si * (group_width + group_gap)
    mx = max_per_scenario[scenario]
    headroom = mx * 1.15

    # Grid lines for this scenario (4 ticks)
    for i in range(1, 5):
        tick_val = headroom * i / 4
        yy = chart_height * (1 - i / 4)
        lines.append(f'<line x1="{gx}" y1="{yy:.1f}" '
                     f'x2="{gx + group_width}" y2="{yy:.1f}" '
                     f'stroke="#e0e0e0" stroke-width="0.5"/>')
        # Only label the top tick (max) for each scenario
        if i == 4:
            lines.append(f'<text x="{gx - 4:.1f}" y="{yy + 4:.1f}" '
                         f'text-anchor="end" font-size="8" fill="#999">'
                         f'{fmt_ops(int(tick_val))}</text>')

    for bi, backend in enumerate(backends):
        val = lookup.get((backend, scenario))
        if val is None:
            continue
        bx = gx + bi * (bar_width + bar_gap)
        by = y_of_scenario(val, scenario)
        bh = chart_height - by
        c = colors[backend]
        if "+inline" in backend:
            pid = backend.replace(" ", "_").replace("(", "").replace(")", "").replace("+", "p")
            fill = f'url(#{pid})'
        else:
            fill = c
        lines.append(f'<rect x="{bx:.1f}" y="{by:.1f}" width="{bar_width}" '
                     f'height="{bh:.1f}" fill="{fill}" rx="1"/>')
        # Value label on top of bar
        lines.append(f'<text x="{bx + bar_width/2:.1f}" y="{by - 3:.1f}" '
                     f'text-anchor="middle" font-size="7" fill="#333">'
                     f'{fmt_ops(val)}</text>')

    # Scenario label below
    cx = gx + group_width / 2
    lines.append(f'<text x="{cx:.1f}" y="{chart_height + 16}" text-anchor="middle" '
                 f'font-size="11" font-weight="bold" fill="#333">{scenario}</text>')

# Bottom axis line
lines.append(f'<line x1="0" y1="{chart_height}" x2="{chart_width}" '
             f'y2="{chart_height}" stroke="#333" stroke-width="1"/>')

lines.append('</g>')

# Legend — grouped: solid = base, striped = +inline
lx = ox
ly = oy + chart_height + 40
lines.append(f'<g transform="translate({lx},{ly})">')

legend_items = [
    ("Irmini (memory)", colors["Irmini (memory)"], False),
    ("Irmini (disk)", colors["Irmini (disk)"], False),
    ("Irmini (lavyek)", colors["Irmini (lavyek)"], False),
    ("Irmin (memory)", colors["Irmin (memory)"], False),
    ("Irmin-pack", colors["Irmin-pack"], False),
    ("Irmin-fs", colors["Irmin-fs"], False),
    ("Irmin-git", colors["Irmin-git"], False),
]

cols = 4
for i, (label, color, _) in enumerate(legend_items):
    col = i % cols
    row = i // cols
    x = col * 190
    y = row * 20
    lines.append(f'<rect x="{x}" y="{y}" width="12" height="12" fill="{color}" rx="2"/>')
    lines.append(f'<text x="{x+16}" y="{y+10}" font-size="10" fill="#333">{label}</text>')

# Add note about striped bars
total_rows = (len(legend_items) - 1) // cols + 1
ny = total_rows * 20 + 6
lines.append(f'<text x="0" y="{ny + 10}" font-size="9" fill="#888" font-style="italic">'
             f'Striped bars = +inlining variant (lighter shade of same color)</text>')

lines.append('</g>')

lines.append('</svg>')

svg = "\n".join(lines)
out = "bench/bench_chart.svg"
with open(out, "w") as f:
    f.write(svg)
print(f"Written to {out}")
