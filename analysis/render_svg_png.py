"""Генерирует два SVG (лучший круг + секторная карта) из katahub analysis
JSON, конвертирует в PNG — для визуального сравнения с reference-картинками
от web-Claude. Стиль максимально близок к mksvg.py / mksvg2.py из reference.
"""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path


PHASE_COLOR = {"brake": "#E24B4A", "lift": "#EF9F27", "accel": "#1D9E75", "cruise": "#B4B2A9"}
PHASE_WIDTH = {"brake": 9, "lift": 7, "accel": 6, "cruise": 4}
SECTOR_COLORS = ["#888780", "#7F77DD", "#D85A30", "#EF9F27", "#1D9E75"]


def world_to_svg(x: float, y: float, bounds: dict, size: tuple[int, int], pad: int) -> tuple[float, float]:
    w = size[0] - 2 * pad
    h = size[1] - 2 * pad
    bx = bounds["max_x"] - bounds["min_x"]
    by = bounds["max_y"] - bounds["min_y"]
    scale = min(w / bx, h / by)
    cx = pad + (w - bx * scale) / 2 + (x - bounds["min_x"]) * scale
    cy = pad + h - ((y - bounds["min_y"]) * scale + (h - by * scale) / 2)
    return (cx, cy)


def tangent_normal(path: list[tuple[float, float]], i: int) -> tuple[float, float, float, float]:
    """Returns (tx, ty, nx, ny) — unit tangent + normal (90° CCW)."""
    j = (i + 5) % len(path)
    k = (i - 5) % len(path)
    tx, ty = path[j][0] - path[k][0], path[j][1] - path[k][1]
    L = math.hypot(tx, ty) or 1.0
    tx, ty = tx / L, ty / L
    nx, ny = -ty, tx
    return tx, ty, nx, ny


def render_best_lap_svg(analysis: dict, out_svg: Path, out_png: Path) -> None:
    bl = analysis["best_lap"]
    track = analysis.get("track", {"trajectory": bl["trajectory"]})
    bounds = analysis["track_bounds"]
    size = (680, 560)
    pad = 60

    svg_pts_bl = [world_to_svg(p["x"], p["y"], bounds, size, pad) for p in bl["trajectory"]]
    svg_pts_tr = [world_to_svg(p["x"], p["y"], bounds, size, pad) for p in track["trajectory"]]

    parts = [
        f'<svg viewBox="0 0 {size[0]} {size[1]}" xmlns="http://www.w3.org/2000/svg">',
        '<rect width="100%" height="100%" fill="#F6F5F0"/>',
        '<text x="40" y="30" font-family="system-ui" font-size="14" font-weight="500" fill="#2C2C2A">Где тормозишь и где скользишь · лучший круг</text>',
    ]

    # Pavement background — толстая серая закольцованная полоса по template.
    d_pav = "M " + " L ".join(f"{sx:.1f} {sy:.1f}" for sx, sy in svg_pts_tr) + " Z"
    parts.append(f'<path d="{d_pav}" stroke="#D3D1C7" stroke-width="22" fill="none" stroke-linejoin="round" stroke-linecap="round" opacity="0.55"/>')

    # Phase overlay — цветные сегменты best lap, с группировкой по фазе.
    phases = [p["phase"] for p in bl["trajectory"]]
    N = len(phases)
    i0 = 0
    for i in range(1, N + 1):
        if i == N or phases[i] != phases[i0]:
            seg = svg_pts_bl[i0: min(i + 1, N)]
            if len(seg) >= 2:
                d = "M " + " L ".join(f"{sx:.1f} {sy:.1f}" for sx, sy in seg)
                color = PHASE_COLOR.get(phases[i0], "#B4B2A9")
                width = PHASE_WIDTH.get(phases[i0], 4)
                parts.append(f'<path d="{d}" stroke="{color}" stroke-width="{width}" fill="none" stroke-linejoin="round" stroke-linecap="round"/>')
            i0 = i

    # Slip markers.
    for s in bl.get("slips", []):
        sx, sy = world_to_svg(s["x"], s["y"], bounds, size, pad)
        r = 6 + max(0, (s.get("strength", 0.28) - 0.28)) * 22
        parts.append(f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="{r:.1f}" fill="none" stroke="#534AB7" stroke-width="2"/>')
        parts.append(f'<circle cx="{sx:.1f}" cy="{sy:.1f}" r="2.5" fill="#534AB7"/>')

    # Corner labels + apex speeds.
    for c in bl.get("corners", []):
        cx, cy = world_to_svg(c["apex_x"], c["apex_y"], bounds, size, pad)
        # нормаль к траектории для подписи — найти ближайшую точку best lap
        best_i = min(range(len(svg_pts_bl)), key=lambda k: (svg_pts_bl[k][0] - cx) ** 2 + (svg_pts_bl[k][1] - cy) ** 2)
        tx, ty, nx, ny = tangent_normal(svg_pts_bl, best_i)
        sign = 1 if c.get("direction", 1) > 0 else -1
        lx, ly = cx + nx * 24 * sign, cy + ny * 24 * sign
        parts.append(f'<text x="{lx:.1f}" y="{ly:.1f}" font-family="system-ui" font-size="11" fill="#888780" text-anchor="middle">{c["name"]}</text>')
        parts.append(f'<text x="{lx:.1f}" y="{(ly + 13):.1f}" font-family="system-ui" font-size="13" font-weight="700" fill="#2C2C2A" text-anchor="middle">{int(round(c.get("apex_speed_kmh", 0)))}</text>')

    # Start/finish tick.
    sx0, sy0 = svg_pts_bl[0]
    _, _, nx, ny = tangent_normal(svg_pts_bl, 0)
    parts.append(f'<line x1="{sx0 + nx * 16:.1f}" y1="{sy0 + ny * 16:.1f}" x2="{sx0 - nx * 16:.1f}" y2="{sy0 - ny * 16:.1f}" stroke="#2C2C2A" stroke-width="3"/>')
    parts.append(f'<text x="{sx0:.1f}" y="{sy0 + 28:.1f}" font-family="system-ui" font-size="10" fill="#888780" text-anchor="middle">старт / финиш</text>')

    # Legend.
    lx, ly = 500, 60
    parts.append(f'<text x="{lx}" y="{ly}" font-family="system-ui" font-size="14" font-weight="500" fill="#2C2C2A">Круг {bl.get("number", "—")} · {bl.get("time_s", 0):.3f}</text>')
    for k, (phase, label) in enumerate([("brake", "Торможение (> 0.25 g)"), ("lift", "Сброс газа"), ("accel", "Разгон"), ("cruise", "Качение / равномерно")]):
        yy = ly + 30 + k * 24
        color = PHASE_COLOR[phase]
        width = PHASE_WIDTH[phase]
        parts.append(f'<line x1="{lx}" y1="{yy}" x2="{lx + 28}" y2="{yy}" stroke="{color}" stroke-width="{width}" stroke-linecap="round"/>')
        parts.append(f'<text x="{lx + 38}" y="{yy + 4}" font-family="system-ui" font-size="12" fill="#5F5E5A">{label}</text>')
    yy = ly + 30 + 4 * 24 + 10
    parts.append(f'<circle cx="{lx + 14}" cy="{yy}" r="9" fill="none" stroke="#534AB7" stroke-width="2"/>')
    parts.append(f'<circle cx="{lx + 14}" cy="{yy}" r="2.5" fill="#534AB7"/>')
    parts.append(f'<text x="{lx + 38}" y="{yy + 4}" font-family="system-ui" font-size="12" fill="#5F5E5A">Проскальзывание</text>')

    parts.append('</svg>')
    svg = "\n".join(parts)
    out_svg.write_text(svg)

    import cairosvg
    cairosvg.svg2png(bytestring=svg.encode(), write_to=str(out_png), output_width=1360)
    print(f"wrote {out_svg} + {out_png}")


def render_sectors_svg(analysis: dict, out_svg: Path, out_png: Path) -> None:
    bl = analysis["best_lap"]
    track = analysis.get("track", {"trajectory": bl["trajectory"]})
    sectors = analysis.get("sectors", [])
    bounds = analysis["track_bounds"]
    size = (680, 560)
    pad = 60

    svg_pts_tr = [world_to_svg(p["x"], p["y"], bounds, size, pad) for p in track["trajectory"]]
    N = len(svg_pts_tr)

    parts = [
        f'<svg viewBox="0 0 {size[0]} {size[1]}" xmlns="http://www.w3.org/2000/svg">',
        '<rect width="100%" height="100%" fill="#F6F5F0"/>',
        f'<text x="40" y="30" font-family="system-ui" font-size="14" font-weight="500" fill="#2C2C2A">Трасса по данным часов · карт {analysis.get("kart_number", "—")}</text>',
    ]
    # Pavement.
    d_pav = "M " + " L ".join(f"{sx:.1f} {sy:.1f}" for sx, sy in svg_pts_tr) + " Z"
    parts.append(f'<path d="{d_pav}" stroke="#D3D1C7" stroke-width="22" fill="none" stroke-linejoin="round" stroke-linecap="round" opacity="0.55"/>')

    # Sector overlay — равномерное разбиение по индексу трека (fallback).
    nSec = len(sectors) or 1
    for idx, sec in enumerate(sectors):
        start = idx * N // nSec
        end = (idx + 1) * N // nSec
        seg = svg_pts_tr[start:end + 1]
        if len(seg) < 2:
            continue
        color = SECTOR_COLORS[idx % len(SECTOR_COLORS)]
        d = "M " + " L ".join(f"{sx:.1f} {sy:.1f}" for sx, sy in seg)
        parts.append(f'<path d="{d}" stroke="{color}" stroke-width="9" fill="none" stroke-linejoin="round" stroke-linecap="round"/>')
        # Sector badge at midpoint.
        mid = seg[len(seg) // 2]
        parts.append(f'<circle cx="{mid[0]:.1f}" cy="{mid[1]:.1f}" r="12" fill="{color}"/>')
        parts.append(f'<text x="{mid[0]:.1f}" y="{(mid[1] + 4):.1f}" fill="white" font-weight="500" font-size="12" text-anchor="middle" font-family="system-ui">{sec["name"]}</text>')

    # Corner labels.
    for c in bl.get("corners", []):
        cx, cy = world_to_svg(c["apex_x"], c["apex_y"], bounds, size, pad)
        parts.append(f'<text x="{cx:.1f}" y="{cy:.1f}" font-family="system-ui" font-size="11" fill="#888780" text-anchor="middle">{c["name"]}</text>')

    # Start/finish tick.
    sx0, sy0 = svg_pts_tr[0]
    _, _, nx, ny = tangent_normal(svg_pts_tr, 0)
    parts.append(f'<line x1="{sx0 + nx * 16:.1f}" y1="{sy0 + ny * 16:.1f}" x2="{sx0 - nx * 16:.1f}" y2="{sy0 - ny * 16:.1f}" stroke="#2C2C2A" stroke-width="3"/>')
    parts.append(f'<text x="{(sx0 - 14):.1f}" y="{(sy0 + 32):.1f}" font-family="system-ui" font-size="10" fill="#888780" text-anchor="end">старт / финиш</text>')

    # Legend.
    lx, ly = 500, 60
    parts.append(f'<text x="{lx}" y="{ly}" font-family="system-ui" font-size="14" font-weight="500" fill="#2C2C2A">Секторы, с</text>')
    parts.append(f'<text x="{lx + 120}" y="{(ly + 24)}" font-family="system-ui" font-size="11" fill="#888780" text-anchor="end">медиана</text>')
    parts.append(f'<text x="{lx + 170}" y="{(ly + 24)}" font-family="system-ui" font-size="11" fill="#888780" text-anchor="end">лучш.</text>')
    for k, sec in enumerate(sectors):
        yy = ly + 52 + k * 36
        color = SECTOR_COLORS[k % len(SECTOR_COLORS)]
        parts.append(f'<circle cx="{lx + 10}" cy="{yy - 5}" r="10" fill="{color}"/>')
        parts.append(f'<text x="{lx + 10}" y="{yy}" fill="white" font-weight="500" font-size="12" text-anchor="middle" font-family="system-ui">{sec["name"]}</text>')
        corners_str = "–".join(sec.get("corners", []))
        parts.append(f'<text x="{lx + 26}" y="{(yy + 14)}" font-family="system-ui" font-size="11" fill="#888780">{corners_str}</text>')
        parts.append(f'<text x="{lx + 120}" y="{yy}" font-family="system-ui" font-size="13" fill="#2C2C2A" text-anchor="end">{sec.get("median_s", 0):.2f}</text>')
        parts.append(f'<text x="{lx + 170}" y="{yy}" font-family="system-ui" font-size="13" fill="#2C2C2A" text-anchor="end">{sec.get("best_s", 0):.2f}</text>')

    yy = ly + 52 + len(sectors) * 36 + 20
    parts.append(f'<text x="{lx}" y="{yy}" font-family="system-ui" font-size="12" fill="#888780">Длина круга ≈{analysis.get("quality", {}).get("lap_length_m", 300):.0f} м</text>')
    parts.append(f'<text x="{lx}" y="{(yy + 18)}" font-family="system-ui" font-size="12" fill="#888780">Восстановлено по IMU часов,</text>')
    parts.append(f'<text x="{lx}" y="{(yy + 36)}" font-family="system-ui" font-size="12" fill="#888780">закольцовано (замыкание {analysis.get("quality", {}).get("trajectory_closure_m", 0):.1f}м)</text>')

    parts.append('</svg>')
    svg = "\n".join(parts)
    out_svg.write_text(svg)
    import cairosvg
    cairosvg.svg2png(bytestring=svg.encode(), write_to=str(out_png), output_width=1360)
    print(f"wrote {out_svg} + {out_png}")


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--analysis", required=True, help="path to analysis JSON")
    ap.add_argument("--outdir", default="/tmp/katahub_render")
    args = ap.parse_args()

    analysis = json.loads(Path(args.analysis).read_text())
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    render_best_lap_svg(analysis, outdir / "lap_best.svg", outdir / "lap_best.png")
    render_sectors_svg(analysis, outdir / "track_sectors.svg", outdir / "track_sectors.png")


if __name__ == "__main__":
    main()
