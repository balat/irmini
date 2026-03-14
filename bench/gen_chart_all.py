#!/usr/bin/env python3
"""Generate SVG bar charts from JSON benchmark results.

Produces charts grouped by backend type:
  - Disk/Memory/Git backends (single-core and multi-core)
  - Optimization comparisons (disk, memory, lavyek)
  - Parallel speedup ratios

Usage: gen_chart_all.py <results_dir>
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(__file__))
from bench_utils import (
    load_files, classify_backend, CHART_SOURCES,
    family_sort_key, scenario_sort_key, ordered_backends,
    is_parallel_variant, is_tezos_parallel,
    get_color, fmt_ops_chart as fmt_ops,
    remap_parallel_scenarios,
)


def generate_chart(title, results, backends, compact=False):
    """Generate an SVG bar chart for a set of backends.

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

    # Layout
    margin_left = 100
    margin_right = 30
    margin_top = 50
    n_backends = len(backends)
    n_scenarios = len(scenarios)
    max_chart_width = 1100

    bar_width = max(8, min(22, max_chart_width // max(1, n_scenarios * n_backends)))
    bar_gap = 2
    group_gap = max(20, min(50, max_chart_width // max(1, n_scenarios * 3)))

    group_width = n_backends * (bar_width + bar_gap) - bar_gap
    chart_width = n_scenarios * (group_width + group_gap) - group_gap
    chart_height = 350

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
    # Simple diagonal lines for standard parallel, cross-hatch for tezos (50k fibers)
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
    """Generate a speedup chart: ratio of parallel/sequential ops/s."""
    # Build sequential lookup
    seq_lookup = {}
    for r in sequential_results:
        seq_lookup[(r["name"], r["scenario"])] = r["ops_per_sec"]

    # Build speedup data
    speedup_data = []
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


def main():
    if len(sys.argv) < 2:
        print("Usage: gen_chart_all.py <results_dir>")
        sys.exit(1)

    results_dir = sys.argv[1]
    chart_dir = results_dir

    # Load results per chart from manifest, then classify to filter
    def load_chart(chart_name):
        """Load and filter results for a chart using its manifest sources."""
        source_files = CHART_SOURCES.get(chart_name, [])
        return load_files(results_dir, source_files)

    # Group all loaded data by classify_backend — same logic as before
    # but loading from manifests instead of all *.json files
    all_chart_files = set()
    for files in CHART_SOURCES.values():
        all_chart_files.update(files)
    all_results = load_files(results_dir, sorted(all_chart_files))

    groups = {"memory": [], "disk": [], "git": [], "optims_disk": [],
              "optims_memory": [], "optims_lavyek": [],
              "disk_parallel": [], "memory_parallel": []}
    for r in all_results:
        cat = classify_backend(r["name"], r.get("scenario", ""))
        groups.setdefault(cat, []).append(r)

    # Sequential charts
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
        ("disk_parallel", "disk", "Disk backends — multi-core (12 domains)",
         "chart_disk_parallel.svg"),
        ("memory_parallel", "memory", "Memory backends — multi-core (12 domains)",
         "chart_memory_parallel.svg"),
    ]

    for cat, seq_cat, title, filename in parallel_specs:
        raw = groups.get(cat, [])
        if not raw:
            print(f"  No results for {cat}, skipping")
            continue
        # Remap parallel scenarios to base names (e.g. parallel-reads-20B-12d×100f -> reads-20B)
        # and rename backends with parallel config suffix for hatching
        remapped = remap_parallel_scenarios(raw, rename_backends=True)
        # Include entries already identified by backend name (e.g. tezos parallel)
        # that remap_parallel_scenarios doesn't handle
        remapped_scenarios = {id(r) for r in raw
                              if re.search(r'-\d+f/\d+d$', r["scenario"])
                              or re.search(r'-\d+d[×x]\d+f$', r["scenario"])}
        tezos_par = [r for r in raw if id(r) not in remapped_scenarios]
        remapped.extend(tezos_par)
        # Build set of (base_backend, scenario) pairs that have parallel data
        par_pairs = set()
        for r in remapped:
            base = re.sub(r'\s+\d+d[×x]\d+\w*f?$', '', r["name"])
            par_pairs.add((base, r["scenario"]))
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
