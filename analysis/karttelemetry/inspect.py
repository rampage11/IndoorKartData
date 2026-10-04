"""CLI entry point: summarise a session dir and emit summary.png."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

from . import loader


def _format_size(nbytes: int) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if nbytes < 1024:
            return f"{nbytes:.1f} {unit}"
        nbytes /= 1024  # type: ignore[assignment]
    return f"{nbytes:.1f} TiB"


def _print_summary(session_dir: Path, session: dict[str, Any]) -> None:
    manifest = session["manifest"]
    sid = manifest.get("id", "?")
    started = manifest.get("startedAt", "?")
    ended = manifest.get("endedAt", "?")
    device = manifest.get("deviceModel") or manifest.get("deviceName") or "?"

    print(f"session: {sid}")
    print(f"device:  {device}")
    print(f"started: {started}")
    print(f"ended:   {ended}")
    print(f"path:    {session_dir}")
    print("sources:")
    for src in manifest.get("sources", []):
        filename = src.get("filename", "?")
        kind = src.get("kind", "?")
        count = src.get("sampleCount")
        rate = src.get("sampleRateHz")
        fpath = session_dir / filename
        size = fpath.stat().st_size if fpath.exists() else 0
        present = "ok" if fpath.exists() else "missing"
        rate_s = f"{rate:g} Hz" if rate else "variable"
        print(
            f"  - {kind:<12} {filename:<24} {present:<7} "
            f"{_format_size(size):>10}  samples={count}  rate={rate_s}"
        )

    if session.get("_errors"):
        print("warnings:")
        for e in session["_errors"]:
            print(f"  - {e}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="karttelemetry.inspect",
        description="Summarise a session directory and emit summary.png.",
    )
    parser.add_argument("session_dir", type=Path, help="Path to session directory")
    parser.add_argument(
        "--no-audio",
        action="store_true",
        help="Skip loading audio (useful for quick summaries).",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Output image path (defaults to <session_dir>/summary.png).",
    )
    args = parser.parse_args(argv)

    session_dir: Path = args.session_dir
    if not session_dir.is_dir():
        print(f"error: not a directory: {session_dir}", file=sys.stderr)
        return 2
    if not (session_dir / "manifest.json").exists():
        print(f"error: manifest.json not found in {session_dir}", file=sys.stderr)
        return 2

    session = loader.load_session(session_dir, load_audio_data=not args.no_audio)
    _print_summary(session_dir, session)

    # Импортируем plots лениво, чтобы импорт модуля не тянул matplotlib.
    from . import plots

    fig = plots.summary_figure(session)
    out_path = args.output or (session_dir / "summary.png")
    fig.savefig(out_path, dpi=120)
    # Закрываем фигуру явно, чтобы освободить ресурсы (важно для CLI).
    import matplotlib.pyplot as plt

    plt.close(fig)

    print(f"wrote {out_path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
