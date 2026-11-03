"""Прогон NCC+DTW детектора на MIKS-данных и сравнение с ground truth."""
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from karttelemetry import loader
from karttelemetry.lap_detector import detect_laps, validate_against_timing

ROOT = Path("/tmp/all_sessions/sessions")
WATCH_IMU = ROOT / "2026-10-05T19-13-41_2D5D4AAF" / "watch_imu.bin"
TIMING = ROOT / "2026-10-05T19-21-26_35951FED" / "timing.json"

print(f"loading watch IMU: {WATCH_IMU}")
samples = np.fromfile(WATCH_IMU, dtype=loader.IMU_DTYPE)
print(f"  {len(samples)} samples, {(samples['ts_ns'][-1] - samples['ts_ns'][0]) / 1e9:.1f} sec")

print("running NCC+DTW lap detector…")
# Watch quat yaw в MIKS-данных накапливается в + направлении (14 turns за 10 кругов).
result = detect_laps(samples, direction_sign=1.0, fs=100.0)
print(f"  coarse boundaries: {len(result['coarse_boundaries_idx'])}")
print(f"  refined boundaries: {len(result['boundaries_idx'])}")
if result['lap_times_s']:
    print(f"  detected lap times (s): median={np.median(result['lap_times_s']):.3f}, min={min(result['lap_times_s']):.3f}, max={max(result['lap_times_s']):.3f}")

# Ground truth из timing.json
print(f"\nloading timing: {TIMING}")
timing = json.loads(TIMING.read_text())
import datetime as dt


def parse_iso(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


our = [p for p in timing["allPasses"] if p.get("kartNumber") == "72" and p.get("lapNumber") and p.get("lastLapMs")]
seen = {}
for p in our:
    ln = p["lapNumber"]
    if ln not in seen:
        seen[ln] = p
laps_sorted = sorted(seen.values(), key=lambda p: p["lapNumber"])
print(f"  timing has {len(laps_sorted)} laps for kart 72")

# Границы кругов в wall ns, затем offset от первой Watch IMU записи
watch_t0_ns = int(samples["ts_ns"][0])
# Watch IMU timestamps already in wall ns per our MIKS data analysis.
truth_s = []
for p in laps_sorted:
    end_ns = int(parse_iso(p["wallTime"]).timestamp() * 1e9)
    if end_ns < watch_t0_ns:
        continue
    truth_s.append((end_ns - watch_t0_ns) / 1e9)
print(f"  {len(truth_s)} laps within Watch IMU coverage")

# Watch IMU t0 ≠ RaceMann wall time directly (нет shake-sync между iPhone и
# Watch в MIKS записи). Поэтому абсолютные времена не сравниваем —
# сравниваем только РАСПРЕДЕЛЕНИЯ длительностей кругов. Если median и
# диапазон совпадают, детектор работает.

if result["lap_times_s"] and len(laps_sorted) > 1:
    truth_durations = sorted([p["lastLapMs"] / 1000 for p in laps_sorted if p.get("lastLapMs")])
    detected = sorted(result["lap_times_s"])
    print(f"\nLap duration comparison (sorted, ignoring absolute offset):")
    print(f"  detected n={len(detected)}, truth n={len(truth_durations)}")
    print(f"  detected: min={min(detected):.3f}  med={np.median(detected):.3f}  max={max(detected):.3f}")
    print(f"  truth:    min={min(truth_durations):.3f}  med={np.median(truth_durations):.3f}  max={max(truth_durations):.3f}")

    # Сопоставим пары (отсортированные) и возьмём ошибки.
    n = min(len(detected), len(truth_durations))
    if n >= 3:
        # Берём только "нормальные" круги (без обгонов и питов — очень длинных).
        truth_clean = [x for x in truth_durations if x < 60]
        detected_clean = [x for x in detected if x < 60]
        n2 = min(len(detected_clean), len(truth_clean))
        errs_ms = [abs(detected_clean[i] - truth_clean[i]) * 1000 for i in range(n2)]
        print(f"  sorted-pair errors (ms): mean={np.mean(errs_ms):.0f}, median={np.median(errs_ms):.0f}, max={np.max(errs_ms):.0f}")

    # Сравним best lap
    print(f"  best lap: detected={min(detected):.3f}s, truth={min(truth_durations):.3f}s, diff={1000*(min(detected)-min(truth_durations)):+.0f}ms")
