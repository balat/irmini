#!/usr/bin/env python3
"""Generate SVG bar charts from benchmark results, grouped by scenario."""

import glob
import math
import os
import re
import time

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
    # Irmini + inlining (30-byte values, inline_threshold=48)
    ("Irmini+inline (memory)",  "commits",      126963),
    ("Irmini+inline (memory)",  "reads",        19501),
    ("Irmini+inline (memory)",  "incremental",  2120),
    ("Irmini+inline (memory)",  "large-values", 1569),
    ("Irmini+inline (disk)",    "commits",      4637),
    ("Irmini+inline (disk)",    "reads",        4950),
    ("Irmini+inline (disk)",    "incremental",  11),
    ("Irmini+inline (disk)",    "large-values", 92),
    ("Irmini+inline (disk)",    "concurrent",   264),
    ("Irmini+inline (lavyek)",  "commits",      114270),
    ("Irmini+inline (lavyek)",  "reads",        15858),
    ("Irmini+inline (lavyek)",  "incremental",  1287),
    ("Irmini+inline (lavyek)",  "large-values", 1296),
    ("Irmini+inline (lavyek)",  "concurrent",   412492),
    # Irmini + LRU cache (100k entries, no inodes)
    ("Irmini+cache (memory)",  "commits",      512),
    ("Irmini+cache (memory)",  "reads",        13399),
    ("Irmini+cache (memory)",  "incremental",  2270),
    ("Irmini+cache (memory)",  "large-values", 1470),
    ("Irmini+cache (disk)",    "commits",      435),
    ("Irmini+cache (disk)",    "reads",        14013),
    ("Irmini+cache (disk)",    "incremental",  10),
    ("Irmini+cache (disk)",    "large-values", 94),
    ("Irmini+cache (disk)",    "concurrent",   266),
    ("Irmini+cache (lavyek)",  "commits",      471),
    ("Irmini+cache (lavyek)",  "reads",        12574),
    ("Irmini+cache (lavyek)",  "incremental",  1003),
    ("Irmini+cache (lavyek)",  "large-values", 1257),
    ("Irmini+cache (lavyek)",  "concurrent",   686252),
    # Irmini + inodes only (memory, 100-byte values, with resolved cache)
    ("Irmini+inode (memory)",  "commits",      114429),
    ("Irmini+inode (memory)",  "reads",        205271),
    ("Irmini+inode (memory)",  "incremental",  9439),
    ("Irmini+inode (memory)",  "large-values", 18381),
    # Irmini + all optimizations (inodes + Hashtbl cache + LRU cache + inlining, 100-byte values)
    ("Irmini+all (memory)",    "commits",      82255),
    ("Irmini+all (memory)",    "reads",        1481040),
    ("Irmini+all (memory)",    "incremental",  12228),
    ("Irmini+all (memory)",    "large-values", 18007),
    ("Irmini+all (lavyek)",    "commits",      66453),
    ("Irmini+all (lavyek)",    "reads",        1303429),
    ("Irmini+all (lavyek)",    "incremental",  8443),
    ("Irmini+all (lavyek)",    "large-values", 10048),
    ("Irmini+all (lavyek)",    "concurrent",   764763),
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
    "Irmini (memory)", "Irmini+inline (memory)", "Irmini+cache (memory)",
    "Irmini+inode (memory)", "Irmini+all (memory)",
    "Irmini (disk)", "Irmini+inline (disk)", "Irmini+cache (disk)",
    "Irmini (lavyek)", "Irmini+inline (lavyek)", "Irmini+cache (lavyek)",
    "Irmini+all (lavyek)",
    "Irmin (memory)", "Irmin-pack", "Irmin-fs", "Irmin-git",
]

colors = {
    "Irmini (memory)":          "#4e79a7",
    "Irmini+inline (memory)":   "#7eadd4",
    "Irmini+cache (memory)":    "#a3c4e0",
    "Irmini+inode (memory)":    "#2a5f8a",
    "Irmini+all (memory)":      "#1a3d5c",
    "Irmini (disk)":            "#59a14f",
    "Irmini+inline (disk)":     "#8ed485",
    "Irmini+cache (disk)":      "#b8e8ab",
    "Irmini (lavyek)":          "#9c755f",
    "Irmini+inline (lavyek)":   "#c9a48e",
    "Irmini+cache (lavyek)":    "#dfc4b5",
    "Irmini+all (lavyek)":      "#6b4430",
    "Irmin (memory)":           "#f28e2b",
    "Irmin-pack":               "#e15759",
    "Irmin-fs":                 "#76b7b2",
    "Irmin-git":                "#b07aa1",
}

# Build lookup
lookup = {}
for name, scenario, ops in data:
    lookup[(name, scenario)] = ops

# --- Chart layout constants ---

margin_left = 120
margin_right = 30
margin_top = 60
margin_bottom = 140
group_gap = 50
bar_width = 14
bar_gap = 2

n_backends = len(backends)
separator_gap = 8  # extra gap between Irmini and Irmin groups
# Find the index where Irmin backends start (for the separator)
irmin_start_idx = next(i for i, b in enumerate(backends) if b.startswith("Irmin ") or b.startswith("Irmin-"))
group_width = n_backends * (bar_width + bar_gap) - bar_gap + separator_gap
chart_width = len(scenarios) * (group_width + group_gap) - group_gap
chart_height = 400

svg_w = margin_left + chart_width + margin_right
svg_h = margin_top + chart_height + margin_bottom

# Precompute per-scenario max
max_per_scenario = {}
for name, scenario, ops in data:
    max_per_scenario[scenario] = max(max_per_scenario.get(scenario, 0), ops)

# Precompute per-scenario min (for log scale)
min_per_scenario = {}
for name, scenario, ops in data:
    if ops > 0:
        min_per_scenario[scenario] = min(min_per_scenario.get(scenario, ops), ops)


def fmt_ops(v):
    if v >= 1_000_000:
        return f"{v/1_000_000:.1f}M"
    if v >= 1_000:
        return f"{v/1_000:.0f}k"
    return str(v)


def pattern_id(name):
    return name.replace(" ", "_").replace("(", "").replace(")", "").replace("+", "p")


def bar_fill(backend):
    c = colors[backend]
    if "+inline" in backend or "+cache" in backend or "+inode" in backend or "+all" in backend:
        return f'url(#{pattern_id(backend)})'
    return c


def generate_chart(scale="linear"):
    """Generate an SVG chart. scale is 'linear' or 'log'."""
    is_log = scale == "log"

    # --- Y mapping functions ---
    if is_log:
        def log_min(scenario):
            # Start from one order of magnitude below the min value
            mn = min_per_scenario[scenario]
            return 10 ** (math.floor(math.log10(mn)))

        def log_max(scenario):
            mx = max_per_scenario[scenario]
            return 10 ** (math.ceil(math.log10(mx)))

        def y_of(val, scenario):
            if val <= 0:
                return chart_height
            lo = math.log10(log_min(scenario))
            hi = math.log10(log_max(scenario))
            frac = (math.log10(val) - lo) / (hi - lo)
            return chart_height * (1 - frac)
    else:
        def y_of(val, scenario):
            if val <= 0:
                return chart_height
            mx = max_per_scenario[scenario]
            frac = val / (mx * 1.15)
            return chart_height * (1 - frac)

    # --- Build SVG ---
    lines = []
    scale_label = "log" if is_log else "linear"
    lines.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{svg_w}" height="{svg_h}" '
                 f'font-family="system-ui, sans-serif" font-size="11">')

    # Background
    lines.append(f'<rect width="{svg_w}" height="{svg_h}" fill="white"/>')

    # Stripe patterns for variants
    for name, color in colors.items():
        if "+all" in name:
            pid = pattern_id(name)
            lines.append(f'<defs><pattern id="{pid}" width="4" height="4" '
                         f'patternUnits="userSpaceOnUse">'
                         f'<rect width="4" height="4" fill="{color}"/>'
                         f'<line x1="0" y1="0" x2="4" y2="4" stroke="white" stroke-width="0.8" opacity="0.5"/>'
                         f'<line x1="0" y1="4" x2="4" y2="0" stroke="white" stroke-width="0.8" opacity="0.5"/>'
                         f'</pattern></defs>')
        elif "+inode" in name:
            pid = pattern_id(name)
            lines.append(f'<defs><pattern id="{pid}" width="3" height="3" '
                         f'patternUnits="userSpaceOnUse">'
                         f'<rect width="3" height="3" fill="{color}"/>'
                         f'<circle cx="1.5" cy="1.5" r="0.8" fill="white" opacity="0.5"/>'
                         f'</pattern></defs>')
        elif "+inline" in name:
            pid = pattern_id(name)
            lines.append(f'<defs><pattern id="{pid}" width="4" height="4" '
                         f'patternUnits="userSpaceOnUse" patternTransform="rotate(45)">'
                         f'<rect width="4" height="4" fill="{color}"/>'
                         f'<line x1="0" y1="0" x2="0" y2="4" stroke="white" stroke-width="1" opacity="0.4"/>'
                         f'</pattern></defs>')
        elif "+cache" in name:
            pid = pattern_id(name)
            lines.append(f'<defs><pattern id="{pid}" width="4" height="4" '
                         f'patternUnits="userSpaceOnUse">'
                         f'<rect width="4" height="4" fill="{color}"/>'
                         f'<line x1="0" y1="2" x2="4" y2="2" stroke="white" stroke-width="1" opacity="0.5"/>'
                         f'</pattern></defs>')

    # Title
    lines.append(f'<text x="{svg_w/2}" y="28" text-anchor="middle" font-size="16" '
                 f'font-weight="bold">Benchmark comparison (ops/s, {scale_label} scale)</text>')
    lines.append(f'<text x="{svg_w/2}" y="46" text-anchor="middle" font-size="11" '
                 f'fill="#666">50 commits × 500 adds, depth 10, 5000 reads — 100-byte values (30-byte for +inline, 10 KiB for large-values)</text>')

    # Chart area
    ox, oy = margin_left, margin_top
    lines.append(f'<g transform="translate({ox},{oy})">')

    # Y axis label
    lines.append(f'<text x="-85" y="{chart_height/2}" text-anchor="middle" '
                 f'font-size="12" fill="#333" transform="rotate(-90,-85,{chart_height/2})">'
                 f'ops/s</text>')

    # Bars per scenario
    for si, scenario in enumerate(scenarios):
        gx = si * (group_width + group_gap)

        # Grid lines
        if is_log:
            lo = math.log10(log_min(scenario))
            hi = math.log10(log_max(scenario))
            # One grid line per power of 10
            for exp in range(int(lo), int(hi) + 1):
                tick_val = 10 ** exp
                frac = (exp - lo) / (hi - lo)
                yy = chart_height * (1 - frac)
                lines.append(f'<line x1="{gx}" y1="{yy:.1f}" '
                             f'x2="{gx + group_width}" y2="{yy:.1f}" '
                             f'stroke="#e0e0e0" stroke-width="0.5"/>')
                lines.append(f'<text x="{gx - 4:.1f}" y="{yy + 4:.1f}" '
                             f'text-anchor="end" font-size="8" fill="#999">'
                             f'{fmt_ops(tick_val)}</text>')
        else:
            mx = max_per_scenario[scenario]
            headroom = mx * 1.15
            for i in range(1, 5):
                tick_val = headroom * i / 4
                yy = chart_height * (1 - i / 4)
                lines.append(f'<line x1="{gx}" y1="{yy:.1f}" '
                             f'x2="{gx + group_width}" y2="{yy:.1f}" '
                             f'stroke="#e0e0e0" stroke-width="0.5"/>')
                if i == 4:
                    lines.append(f'<text x="{gx - 4:.1f}" y="{yy + 4:.1f}" '
                                 f'text-anchor="end" font-size="8" fill="#999">'
                                 f'{fmt_ops(int(tick_val))}</text>')

        for bi, backend in enumerate(backends):
            val = lookup.get((backend, scenario))
            if val is None:
                continue
            bx = gx + bi * (bar_width + bar_gap)
            if bi >= irmin_start_idx:
                bx += separator_gap
            by = y_of(val, scenario)
            bh = chart_height - by
            fill = bar_fill(backend)
            lines.append(f'<rect x="{bx:.1f}" y="{by:.1f}" width="{bar_width}" '
                         f'height="{bh:.1f}" fill="{fill}" rx="1"/>')
            # Value label on top of bar
            lines.append(f'<text x="{bx + bar_width/2:.1f}" y="{by - 3:.1f}" '
                         f'text-anchor="middle" font-size="7" fill="#333">'
                         f'{fmt_ops(val)}</text>')

        # Separator line between Irmini and Irmin groups
        sep_x = gx + irmin_start_idx * (bar_width + bar_gap) + separator_gap / 2
        lines.append(f'<line x1="{sep_x:.1f}" y1="0" x2="{sep_x:.1f}" '
                     f'y2="{chart_height}" stroke="#ccc" stroke-width="0.5" '
                     f'stroke-dasharray="3,3"/>')

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

    legend_items = [
        ("Irmini (memory)", colors["Irmini (memory)"]),
        ("Irmini (disk)", colors["Irmini (disk)"]),
        ("Irmini (lavyek)", colors["Irmini (lavyek)"]),
        ("Irmini+all (memory)", colors["Irmini+all (memory)"]),
        ("Irmini+all (lavyek)", colors["Irmini+all (lavyek)"]),
        ("Irmin (memory)", colors["Irmin (memory)"]),
        ("Irmin-pack", colors["Irmin-pack"]),
        ("Irmin-fs", colors["Irmin-fs"]),
        ("Irmin-git", colors["Irmin-git"]),
    ]

    cols = 4
    for i, (label, color) in enumerate(legend_items):
        col = i % cols
        row = i // cols
        x = col * 190
        y = row * 20
        fill = bar_fill(label)
        lines.append(f'<rect x="{x}" y="{y}" width="12" height="12" fill="{fill}" rx="2"/>')
        lines.append(f'<text x="{x+16}" y="{y+10}" font-size="10" fill="#333">{label}</text>')

    total_rows = (len(legend_items) - 1) // cols + 1
    ny = total_rows * 20 + 6
    lines.append(f'<text x="0" y="{ny + 10}" font-size="9" fill="#888" font-style="italic">'
                 f'Diagonal = +inline, horizontal = +cache, dots = +inode, cross-hatch = +all (inode+cache+inline)</text>')

    lines.append('</g>')
    lines.append('</svg>')

    return "\n".join(lines)


# --- Write both charts ---

timestamp = int(time.time())

# Remove previous chart files
for old in glob.glob("bench/bench_chart_*.svg") + glob.glob("bench/bench_chart_log_*.svg"):
    if os.path.exists(old):
        os.remove(old)

charts = {
    "linear": f"bench/bench_chart_{timestamp}.svg",
    "log": f"bench/bench_chart_log_{timestamp}.svg",
}

for scale, path in charts.items():
    svg = generate_chart(scale=scale)
    with open(path, "w") as f:
        f.write(svg)
    print(f"Written to {path}")

# Update the README references
readme = "bench/README.md"
with open(readme, "r") as f:
    content = f.read()
content = re.sub(
    r'!\[Benchmark comparison\]\(bench_chart[^)]*\)',
    f'![Benchmark comparison]({os.path.basename(charts["linear"])})',
    content,
)
content = re.sub(
    r'!\[Benchmark comparison \(log scale\)\]\(bench_chart_log[^)]*\)',
    f'![Benchmark comparison (log scale)]({os.path.basename(charts["log"])})',
    content,
)
with open(readme, "w") as f:
    f.write(content)
print(f"Updated {readme}")
