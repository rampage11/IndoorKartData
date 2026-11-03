"""End-to-end симуляция MIKS-сессии через katahub.

Что делает:
1. Берёт существующую сессию (MIKS kart 72) из `/tmp/all_sessions/sessions/`
2. Присваивает ей новый UUID (чтобы не конфликтовать с ранее загруженной)
3. Открывает WS к kart.katahub.ru/live/<id>/publish
4. В хронологическом порядке стримит:
   - IMU telemetry @ 2 Гц (a_lat, a_long, |a_h|, yaw rate) — downsampled из watch_imu.bin
   - lap-события из timing.json (точно когда wall-time круга наступает)
5. После "финиша" зипует сессию (с подменой manifest.id) и шлёт POST /sessions
6. Поллит /sessions/<id>/analysis пока вердикт не появится
7. Выводит финальный разбор

Скорость x40 по умолчанию (480-секундная запись → 12 сек замена) — можно
переключить флагом --speed. --speed 1 = реальное время.

Usage: python3 simulate_session.py [--speed 40]
"""
import argparse
import json
import io
import time
import uuid
import zipfile
import datetime as dt
import sys
from pathlib import Path

import numpy as np
import urllib.request
import websocket  # pip install websocket-client

sys.path.insert(0, str(Path(__file__).parent))
from karttelemetry import loader

SOURCE_IPHONE = Path("/tmp/all_sessions/sessions/2026-10-05T19-21-26_35951FED")
SOURCE_WATCH = Path("/tmp/all_sessions/sessions/2026-10-05T19-13-41_2D5D4AAF")
KATAHUB = "https://kart.katahub.ru"


def eprint(*a, **k):
    print(*a, file=sys.stderr, flush=True, **k)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--speed", type=float, default=40.0, help="replay speed (1=real-time)")
    parser.add_argument("--duration-cap", type=float, default=30.0, help="cap wall-time of replay")
    args = parser.parse_args()

    # Готовим артефакты сессии: читаем manifest + timing + файлы, присваиваем новый UUID.
    sid = uuid.uuid4()
    eprint(f"[sim] new session id: {sid}")

    old_manifest = json.loads((SOURCE_IPHONE / "manifest.json").read_text())
    old_manifest["id"] = str(sid).upper()
    old_manifest["trackName"] = "MIKS"
    manifest_bytes = json.dumps(old_manifest, ensure_ascii=False).encode()

    timing_bytes = (SOURCE_IPHONE / "timing.json").read_bytes()
    timing = json.loads(timing_bytes)
    iphone_imu_bytes = (SOURCE_IPHONE / "iphone_imu.bin").read_bytes()
    audio_bytes = (SOURCE_IPHONE / "iphone_audio.wav").read_bytes() if (SOURCE_IPHONE / "iphone_audio.wav").exists() else None
    watch_imu_bytes = (SOURCE_WATCH / "watch_imu.bin").read_bytes()
    hr_bytes = (SOURCE_WATCH / "heart_rate.bin").read_bytes() if (SOURCE_WATCH / "heart_rate.bin").exists() else None
    eprint(f"[sim] loaded: iphone_imu {len(iphone_imu_bytes)/1024/1024:.1f}MB, watch_imu {len(watch_imu_bytes)/1024/1024:.1f}MB")

    # Собираем сортированные события для replay.
    watch_samples = np.frombuffer(watch_imu_bytes, dtype=loader.IMU_DTYPE)
    w_t0_ns = int(watch_samples["ts_ns"][0])
    w_dur = (int(watch_samples["ts_ns"][-1]) - w_t0_ns) / 1e9
    eprint(f"[sim] watch IMU window: {w_dur:.1f}s, {len(watch_samples)} samples")

    # Lap events from timing: отсортировали allPasses нашего карта по wallTime.
    our_passes = [p for p in timing["allPasses"] if p.get("kartNumber") == "72" and p.get("lapNumber")]
    our_passes.sort(key=lambda p: p["wallTime"])
    eprint(f"[sim] {len(our_passes)} lap passes for kart 72")

    # Baseline wall-time: берём ts первого Watch IMU как t0 эмуляции.
    sim_t0 = dt.datetime.fromtimestamp(w_t0_ns / 1e9, tz=dt.timezone.utc)

    # Строим слияемый поток событий.
    events = []  # (sim_offset_s, kind, payload)
    # Downsample Watch IMU до 10 Гц для живой траектории на dashboard.
    step = int(100 / 10)  # 100 Гц → каждый 10-й
    import math
    for i in range(0, len(watch_samples), step):
        s = watch_samples[i]
        off = (int(s["ts_ns"]) - w_t0_ns) / 1e9
        if off > args.duration_cap * args.speed:
            break
        aLat = float(s["ax"])
        aLong = float(s["ay"])
        ah = (aLat**2 + aLong**2) ** 0.5
        wz = float(s["gz"])
        yawRateDeg = wz * 180 / math.pi
        # yaw из quaternion
        qw, qx, qy, qz = float(s["qw"]), float(s["qx"]), float(s["qy"]), float(s["qz"])
        yawRad = math.atan2(2 * (qw * qz + qx * qy), 1 - 2 * (qy * qy + qz * qz))
        # phase classification (same thresholds as iOS)
        if aLong < -0.25:
            phase = "brake"
        elif aLong < -0.08:
            phase = "lift"
        elif aLong > 0.20:
            phase = "accel"
        else:
            phase = "cruise"
        wzExp = aLat * 9.81 / max(5.0, ah * 9.81 + 1.0)
        excess = abs(wz) - abs(wzExp)
        slip = excess if (excess > 0.28 and (wz > 0) == (aLat > 0)) else None
        payload = {
            "aLat": aLat, "aLong": aLong, "ah": ah,
            "yawRateDeg": yawRateDeg, "yawRad": yawRad,
            "phase": phase,
        }
        if slip is not None:
            payload["slip"] = slip
        events.append((off, "telemetry", payload))

    # Lap events — в оффсетах от sim_t0
    for p in our_passes:
        pw = dt.datetime.fromisoformat(p["wallTime"].replace("Z", "+00:00"))
        off = (pw - sim_t0).total_seconds()
        if off < 0 or off > args.duration_cap * args.speed:
            continue
        payload = {
            "lap": p["lapNumber"],
            "lapTimeMs": p.get("lastLapMs"),
            "position": p.get("position"),
        }
        events.append((off, "lap", payload))

    events.sort(key=lambda e: e[0])
    eprint(f"[sim] {len(events)} events queued (horizon {args.duration_cap * args.speed:.0f}s source → {args.duration_cap:.0f}s wall)")

    # WS подключение.
    ws_url = KATAHUB.replace("https://", "wss://") + f"/live/{sid}/publish"
    eprint(f"[sim] connecting WS: {ws_url}")
    ws = websocket.create_connection(ws_url, timeout=5)
    eprint("[sim] WS connected")

    # Replay loop
    start_wall = time.monotonic()
    sent_tel = 0
    sent_lap = 0
    for off, kind, payload in events:
        target_wall = start_wall + off / args.speed
        now = time.monotonic()
        if target_wall > now:
            time.sleep(min(target_wall - now, 0.5))
        wall_ns = int(time.time() * 1e9)
        msg = json.dumps({"kind": kind, "wallNs": wall_ns, "payload": payload})
        try:
            ws.send(msg)
        except Exception as e:
            eprint(f"[sim] WS send failed: {e}")
            break
        if kind == "telemetry":
            sent_tel += 1
        else:
            sent_lap += 1
            eprint(f"[sim]   lap {payload.get('lap')} t={payload.get('lapTimeMs')}ms pos={payload.get('position')}")

    eprint(f"[sim] replay done: {sent_tel} telemetry + {sent_lap} lap events")
    try:
        ws.close()
    except Exception:
        pass

    # Zip up session with new id and upload.
    eprint("[sim] zipping session for upload...")
    buf = io.BytesIO()
    base = f"{sim_t0.strftime('%Y-%m-%dT%H-%M-%S')}_{str(sid)[:8].upper()}"
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr(f"{base}/manifest.json", manifest_bytes)
        z.writestr(f"{base}/timing.json", timing_bytes)
        z.writestr(f"{base}/iphone_imu.bin", iphone_imu_bytes)
        if audio_bytes:
            z.writestr(f"{base}/iphone_audio.wav", audio_bytes)
        z.writestr(f"{base}/watch_imu.bin", watch_imu_bytes)
        if hr_bytes:
            z.writestr(f"{base}/heart_rate.bin", hr_bytes)
    zip_data = buf.getvalue()
    eprint(f"[sim] zip size: {len(zip_data)/1024/1024:.1f} MB")

    req = urllib.request.Request(
        f"{KATAHUB}/sessions",
        data=zip_data,
        headers={"Content-Type": "application/zip"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        body = resp.read().decode()
    eprint(f"[sim] upload HTTP {resp.status}")
    uploaded = json.loads(body)
    assert uploaded["id"].lower() == str(sid), f"id mismatch: {uploaded['id']} vs {sid}"
    eprint(f"[sim] uploaded session {uploaded['id']}, kart={uploaded.get('kart')}, track={uploaded.get('track')}")

    # Пулим /analysis до готовности вердикта.
    eprint("[sim] waiting for pipeline…")
    for attempt in range(30):
        time.sleep(1)
        try:
            with urllib.request.urlopen(f"{KATAHUB}/sessions/{sid}/analysis", timeout=5) as r:
                a = json.loads(r.read())
            if a.get("verdict"):
                eprint(f"[sim] analysis ready after {attempt + 1}s")
                print("\n==================== РЕЗУЛЬТАТ ====================")
                print(f"Admin UI: {KATAHUB}/admin/session.html?id={sid}")
                print(f"Session:  {KATAHUB}/sessions/{sid}")
                print(f"Model:    {a.get('model')}")
                print(f"Laps:     {len(a.get('laps', []))}")
                if a["laps"]:
                    best = min(l["ms"] for l in a["laps"])
                    med = sorted(l["ms"] for l in a["laps"])[len(a["laps"]) // 2]
                    print(f"Best lap: {best / 1000:.3f}s")
                    print(f"Median:   {med / 1000:.3f}s")
                print()
                print("ВЕРДИКТ:")
                print(f"  {a['verdict']}")
                facts = a.get("facts")
                if isinstance(facts, dict):
                    f = facts
                elif isinstance(facts, str):
                    f = json.loads(facts)
                else:
                    f = {}
                if f.get("evidence"):
                    print("\nEVIDENCE:")
                    for e in f["evidence"]:
                        print(f"  - {e['claim']} (conf {e['confidence']:.2f}): {', '.join(e['refs'])}")
                if f.get("leaderBestSec"):
                    print(f"\nLeader best:  {f['leaderBestSec']:.3f}s")
                return
        except Exception as e:
            eprint(f"[sim] poll {attempt + 1}: {e}")
    eprint("[sim] timeout: no verdict after 30s")


if __name__ == "__main__":
    main()
