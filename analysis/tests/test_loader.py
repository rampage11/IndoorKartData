"""Sanity tests for loader on a synthetic session directory."""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pytest

from karttelemetry import loader


def _write_imu(path: Path, samples: list[tuple]) -> None:
    arr = np.zeros(len(samples), dtype=loader.IMU_DTYPE)
    field_names = ("ts_ns", "ax", "ay", "az", "gx", "gy", "gz", "qw", "qx", "qy", "qz")
    for i, s in enumerate(samples):
        for name, val in zip(field_names, s):
            arr[i][name] = val
    arr.tofile(path)


def _write_hr(path: Path, samples: list[tuple]) -> None:
    arr = np.array(samples, dtype=loader.HR_DTYPE)
    arr.tofile(path)


@pytest.fixture
def fake_session(tmp_path: Path) -> Path:
    session_dir = tmp_path / "session"
    session_dir.mkdir()

    imu_samples = [
        (1_000_000_000, 0.1, 0.2, 0.98, 0.01, -0.02, 0.03, 1.0, 0.0, 0.0, 0.0),
        (1_010_000_000, 0.11, 0.21, 0.97, 0.02, -0.01, 0.04, 1.0, 0.0, 0.0, 0.0),
    ]
    _write_imu(session_dir / "iphone_imu.bin", imu_samples)

    hr_samples = [
        (1_700_000_000_000_000_000, 72.0),
        (1_700_000_001_000_000_000, 85.5),
    ]
    _write_hr(session_dir / "heart_rate.bin", hr_samples)

    manifest = {
        "id": "test-session",
        "startedAt": "2026-10-03T18:00:00Z",
        "endedAt": "2026-10-03T18:00:01Z",
        "deviceName": "iPhone",
        "deviceModel": "iPhone15,2",
        "appVersion": "0.1.0",
        "sources": [
            {
                "kind": "iphone_imu",
                "filename": "iphone_imu.bin",
                "sampleCount": 2,
                "sampleRateHz": 100.0,
                "format": "imu_v1",
            },
            {
                "kind": "heart_rate",
                "filename": "heart_rate.bin",
                "sampleCount": 2,
                "sampleRateHz": None,
                "format": "hr_v1",
            },
        ],
    }
    (session_dir / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return session_dir


def test_imu_dtype_is_88_bytes() -> None:
    assert loader.IMU_DTYPE.itemsize == 88


def test_hr_dtype_is_16_bytes() -> None:
    assert loader.HR_DTYPE.itemsize == 16


def test_load_imu_reads_two_samples(fake_session: Path) -> None:
    imu = loader.load_imu(fake_session / "iphone_imu.bin")
    assert imu.shape == (2,)
    assert imu["ts_ns"][0] == 1_000_000_000
    assert imu["ts_ns"][1] == 1_010_000_000
    assert pytest.approx(imu["ax"][0]) == 0.1
    assert pytest.approx(imu["az"][1]) == 0.97
    assert pytest.approx(imu["qw"][0]) == 1.0


def test_load_hr(fake_session: Path) -> None:
    hr = loader.load_hr(fake_session / "heart_rate.bin")
    assert hr.shape == (2,)
    assert hr["bpm"][0] == 72.0
    assert hr["bpm"][1] == 85.5


def test_load_session_without_audio(fake_session: Path) -> None:
    session = loader.load_session(fake_session, load_audio_data=False)
    assert session["manifest"]["id"] == "test-session"
    assert session["iphone_imu"] is not None
    assert session["iphone_imu"].shape == (2,)
    assert session["heart_rate"] is not None
    assert session["heart_rate"].shape == (2,)
    assert session["watch_imu"] is None
    assert session["audio"] is None


def test_load_session_missing_file_graceful(tmp_path: Path) -> None:
    session_dir = tmp_path / "s"
    session_dir.mkdir()
    manifest = {
        "id": "x",
        "startedAt": "2026-10-03T18:00:00Z",
        "endedAt": "2026-10-03T18:00:01Z",
        "deviceName": "iPhone",
        "sources": [
            {
                "kind": "iphone_imu",
                "filename": "nope.bin",
                "sampleCount": 0,
                "sampleRateHz": 100.0,
                "format": "imu_v1",
            }
        ],
    }
    (session_dir / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    session = loader.load_session(session_dir, load_audio_data=False)
    assert session["iphone_imu"] is None
