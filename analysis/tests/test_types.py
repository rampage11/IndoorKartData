"""Санитарные тесты для core-типов pipeline."""

from __future__ import annotations

import numpy as np

from karttelemetry.types import (
    ClockSync,
    CornerMetrics,
    CornerSegment,
    LapCoordinate,
    LapDelta,
)


def test_lap_coordinate_basic() -> None:
    t = np.array([0, 10, 20, 30], dtype=np.int64) * 1_000_000
    s = np.array([0.0, 0.33, 0.66, 1.0])
    lc = LapCoordinate(lap_id=1, t_ns=t, s=s)
    assert lc.lap_id == 1
    assert lc.s[-1] == 1.0
    assert lc.distance_m is None


def test_corner_segment_literal_direction() -> None:
    c = CornerSegment(corner_id=3, direction="left", entry_s=0.2, turn_in_s=0.22,
                      apex_s=0.25, exit_s=0.3)
    assert c.direction == "left"
    assert c.braking_start_s is None


def test_corner_metrics_defaults_confidence_one() -> None:
    m = CornerMetrics(corner_id=1)
    assert m.confidence == 1.0
    assert m.braking_duration_s is None


def test_lap_delta_sign() -> None:
    d = LapDelta(corner_id=4, delta_s=0.21, confidence=0.9)
    assert d.delta_s > 0  # positive = lost time


def test_clock_sync_identity_is_identity() -> None:
    sync = ClockSync(source="iphone")
    t = np.array([0, 1_000_000_000, 2_000_000_000], dtype=np.int64)
    out = sync.apply(t)
    assert np.array_equal(out, t)


def test_clock_sync_offset_only() -> None:
    sync = ClockSync(source="watch", offset_ns=500_000_000)  # +0.5 sec
    t = np.array([1_000_000_000], dtype=np.int64)
    out = sync.apply(t)
    assert out[0] == 1_500_000_000


def test_clock_sync_drift_scales_time() -> None:
    # 1000 ppm = 0.1% быстрее реального
    sync = ClockSync(source="audio", drift_ppm=1000.0)
    t = np.array([1_000_000_000], dtype=np.int64)
    out = sync.apply(t)
    # 1сек * 1.001 ≈ 1.001 сек; допускаем ошибку float64 truncation до 1мс.
    assert abs(int(out[0]) - 1_001_000_000) < 1_000_000
