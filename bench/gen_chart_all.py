#!/usr/bin/env python3
"""Generate SVG bar charts from JSON benchmark results.

Produces three charts grouped by backend type:
  - Memory backends: irmin-lwt-memory, irmin-eio-memory, irmini-thomas-memory, irmini-memory
  - Disk backends: irmin-lwt-{fs,pack}, irmin-eio-{fs,pack}, irmini-thomas-{fs,disk},
                   irmini-{fs,disk,lavyek}
  - Git backends: irmin-lwt-git, irmin-eio-git, irmini-thomas-git(?), irmini-git(?)

Usage: gen_chart_all.py <results_dir> [timestamp]

Reads all *.json files in <results_dir> and merges them.
"""

import glob
import json
import math
import os
import re
import sys
import time


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


def classify_backend(name):
    """Classify a result name into memory/disk/git category."""
    n = name.lower()
    if "memory" in n or "mem" in n:
        return "memory"
    elif "git" in n:
        return "git"
    else:
        # fs, disk, pack, lavyek are all "disk" category
        return "disk"


# --- Colors for each implementation family ---
FAMILY_COLORS = {
    # irmin-lwt (main branch)
    "Irmin-Lwt": "#f28e2b",
    # irmin-eio (cuihtlauac branch)
    "Irmin-Eio": "#e15759",
    # irmini-thomas (original, no optimizations)
    "Irmini-thomas": "#76b7b2",
    # irmini (inode branch, all optimizations)
    "Irmini": "#4e79a7",
}

# Shade variants within families
VARIANT_SHADES = {
    "memory": 0,
    "fs": 1,
    "disk": 1,
    "pack": 2,
    "git": 3,
    "lavyek": 4,
}


def name_to_family(name):
    """Map a result name to its implementation family."""
    n = name.lower()
    if "irmini-thomas" in n or "irmini-thomas" in n:
        return "Irmini-thomas"
    elif "irmini" in n:
        return "Irmini"
    elif "irmin-lwt" in n or "irmin-lwt" in n:
        return "Irmin-Lwt"
    elif "irmin-eio" in n or "irmin-eio" in n or "irmin-pack" in n or "irmin-fs" in n or "irmin-git" in n:
        return "Irmin-Eio"
    elif "irmin" in n:
        return "Irmin-Lwt"  # fallback
    return "Irmini"


def get_color(name):
    """Get a color for a given result name."""
    family = name_to_family(name)
    base = FAMILY_COLORS.get(family, "#888888")
    # Adjust brightness based on variant
    n = name.lower()
    shade = 0
    for key, val in VARIANT_SHADES.items():
        if key in n:
            shade = val
            break
    # Lighten/darken based on shade
    # Parse hex
    r, g, b = int(base[1:3], 16), int(base[3:5], 16), int(base[5:7], 16)
    factor = 1.0 + shade * 0.15
    r = min(255, int(r * factor))
    g = min(255, int(g * factor))
    b = min(255, int(b * factor))
    return f"#{r:02x}{g:02x}{b:02x}"


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

    scenarios = []
    seen = set()
    for r in results:
        if r["scenario"] not in seen:
            scenarios.append(r["scenario"])
            seen.add(r["scenario"])

    # Layout
    margin_left = 120
    margin_right = 30
    margin_top = 60
    margin_bottom = 120
    group_gap = 50
    bar_width = max(8, min(20, 200 // max(1, len(backends))))
    bar_gap = 2

    n_backends = len(backends)
    group_width = n_backends * (bar_width + bar_gap) - bar_gap
    chart_width = len(scenarios) * (group_width + group_gap) - group_gap
    chart_height = 400

    svg_w = margin_left + chart_width + margin_right
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
                 f'font-family="system-ui, sans-serif" font-size="11">')
    lines.append(f'<rect width="{svg_w}" height="{svg_h}" fill="white"/>')

    # Title
    lines.append(f'<text x="{svg_w/2}" y="28" text-anchor="middle" font-size="16" '
                 f'font-weight="bold">{title}</text>')

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
                             f'text-anchor="end" font-size="8" fill="#999">'
                             f'{fmt_ops(int(tick_val))}</text>')

        for bi, backend in enumerate(backends):
            val = lookup.get((backend, scenario))
            if val is None:
                continue
            bx = gx + bi * (bar_width + bar_gap)
            by = y_of(val, scenario)
            bh = chart_height - by
            color = get_color(backend)
            lines.append(f'<rect x="{bx:.1f}" y="{by:.1f}" width="{bar_width}" '
                         f'height="{bh:.1f}" fill="{color}" rx="1"/>')
            lines.append(f'<text x="{bx + bar_width/2:.1f}" y="{by - 3:.1f}" '
                         f'text-anchor="middle" font-size="7" fill="#333">'
                         f'{fmt_ops(val)}</text>')

        # Scenario label
        cx = gx + group_width / 2
        lines.append(f'<text x="{cx:.1f}" y="{chart_height + 16}" text-anchor="middle" '
                     f'font-size="11" font-weight="bold" fill="#333">{scenario}</text>')

    # Bottom axis
    lines.append(f'<line x1="0" y1="{chart_height}" x2="{chart_width}" '
                 f'y2="{chart_height}" stroke="#333" stroke-width="1"/>')

    lines.append('</g>')

    # Legend
    lx = ox
    ly = oy + chart_height + 40
    lines.append(f'<g transform="translate({lx},{ly})">')

    cols = min(4, len(backends))
    for i, backend in enumerate(backends):
        col = i % cols
        row = i // cols
        x = col * 220
        y = row * 18
        color = get_color(backend)
        lines.append(f'<rect x="{x}" y="{y}" width="12" height="12" fill="{color}" rx="2"/>')
        lines.append(f'<text x="{x+16}" y="{y+10}" font-size="10" fill="#333">{backend}</text>')

    lines.append('</g>')
    lines.append('</svg>')

    return "\n".join(lines)


def main():
    if len(sys.argv) < 2:
        print("Usage: gen_chart_all.py <results_dir> [timestamp]")
        sys.exit(1)

    results_dir = sys.argv[1]
    timestamp = sys.argv[2] if len(sys.argv) > 2 else str(int(time.time()))

    print(f"Loading results from {results_dir}...")
    all_results = load_results(results_dir)

    if not all_results:
        print("No results found!")
        sys.exit(1)

    print(f"Total: {len(all_results)} results")

    # Group by backend type
    groups = {"memory": [], "disk": [], "git": []}
    for r in all_results:
        cat = classify_backend(r["name"])
        groups[cat].append(r)

    # Get ordered backend names for each group
    def ordered_backends(results):
        seen = []
        for r in results:
            if r["name"] not in seen:
                seen.append(r["name"])
        return seen

    chart_dir = os.path.dirname(results_dir) if not os.path.isabs(results_dir) else results_dir
    # Write charts next to the results
    chart_dir = results_dir

    charts = {
        "memory": {
            "title": "Memory backends — ops/s comparison",
            "file": f"chart_memory_{timestamp}.svg",
        },
        "disk": {
            "title": "Disk backends (fs, pack, lavyek) — ops/s comparison",
            "file": f"chart_disk_{timestamp}.svg",
        },
        "git": {
            "title": "Git backends — ops/s comparison",
            "file": f"chart_git_{timestamp}.svg",
        },
    }

    for cat, info in charts.items():
        results = groups[cat]
        if not results:
            print(f"  No results for {cat}, skipping")
            continue
        backends = ordered_backends(results)
        svg = generate_chart(info["title"], results, backends)
        if svg:
            path = os.path.join(chart_dir, info["file"])
            with open(path, "w") as f:
                f.write(svg)
            print(f"  Written {path} ({len(backends)} backends, {len(results)} results)")


if __name__ == "__main__":
    main()
