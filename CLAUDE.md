# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Indoor karting telemetry recorder: iOS app + Apple Watch companion that captures a race session (IMU, audio, heart rate, steering estimate, live lap times from RaceMann timing system) and writes a self-contained session directory for offline analysis on Mac via Python.

Russian-speaking project — UI labels, voice announcements, and most comments are in Russian; keep that convention when editing.

## Build system (xcodegen → Xcode)

The Xcode project is **generated** from `project.yml` by [xcodegen](https://github.com/yonaskolb/XcodeGen). `*.xcodeproj`, `Info.plist`, and `*.entitlements` files are **gitignored** — they come from the generator.

**After ANY of: adding/removing source files, editing project.yml, cloning fresh:**
```sh
xcodegen generate
```

Verifying a build (iPhone target builds its embedded Watch dependency too):
```sh
xcodebuild -project IndoorKartData.xcodeproj -scheme IndoorKartData \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

Watch-only build (requires watchOS platform runtime installed in Xcode → Settings → Components):
```sh
xcodebuild -project IndoorKartData.xcodeproj -scheme IndoorKartDataWatch \
  -destination 'generic/platform=watchOS' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -10
```

**SourceKit noise:** every edit triggers "Cannot find type X" diagnostics for files that reference other targets' sources (e.g. `Shared/` compiling on Watch cross-references iPhone-only symbols). These are false positives from the indexer — ignore them if `xcodebuild` says `** BUILD SUCCEEDED **`.

## Mac-side Python analysis

```sh
cd analysis
python3 -m pytest tests/            # run unit tests
python3 -m karttelemetry.inspect /path/to/session_dir   # analyse one session
```

Produces `summary.png` (2×3 grid: iPhone G-force / rotation / audio spectrogram; Watch G-force / rotation / heart rate) and prints lap times when `timing.json` is present.

### CLI entry-points used by katahub backend

All scripts accept `--zip SESSION.zip` and auto-detect kart number from `timing.kartNumber` (top-level field):

- `python3 katahub_render.py --zip SESSION.zip` → session analysis JSON on stdout (v2: trajectory + per-lap times + corner metrics + Otsu phase cut + grip_ratio + recommendations + delta vs reference). Called by Go backend as subprocess via `PYTHON_ANALYSER_PATH` env.
- `python3 laps_compare.py --zip SESSION.zip --best N --other M --out FILE.html` → two-lap compare HTML. Has an **align gate**: DTW residual rms > 0.5 rad/s → exit **4** → backend returns HTTP 422. Phase labels in Russian: `тормоз / сброс/лёгкий трейл / газ / ровно` (NOT the old `brake/lift/accel/cruise`). Brake threshold is session-wide Otsu `cut_g` (clamped `[-0.55, -0.40]`), NOT the removed `-0.25` constant.
- `python3 build_template.py --zip SESSION.zip --track NAME [--lap N]` → admin op; produces **3 files** `tracks/{NAME}/{tmpl.npy, track.npz, features.npy}` (template wz @ 100 Hz / track geometry @ 50 Hz / DTW features). Not per-session; rebuild only when you want a new reference session or track. The old `build_track_template.py` script is deprecated — v2 pipeline requires all three files.

**`lap31_standalone.py`** is the core processor: `process_lap(lap_number, samples=None, timing=None, kart_number='72', sf_offset_override=None, cut_g=None)`. `cut_g` is session-wide Otsu from `compute_session_phase_cut(samples)`; both `laps_compare.py` and `katahub_render.py` compute it once per session and pass to each lap.

**v2 pipeline modules** (`analysis/karttelemetry/`):
- `track_template.py` — `TrackTemplate` dataclass + `load_track_template()` + constants `CORN` (T1..T11 windows in template seconds), `CUTS_S` (6 sector cuts), `SECTOR_CORNERS` (which corners each sector contains), Russian phase labels.
- `corner_metrics.py` — `add_frame()` (θ grid-search per session, expect `corr > 0.9`), `lap_metrics()` producing per-corner `{vmin, alat_pk, wz_pk, amin, brake_len, brake_on, lift_len, slip, hf, dur}`. `otsu_threshold()` for brake-cut selection.
- `recommender.py` — rule-based (NOT LLM): 5 pattern rules + potential + trend. Output sorted by estimated time loss, max 4 items. Each includes raw numbers so the pilot can push back.

## High-level architecture

Three code roots feed into two Apple targets, plus a Mac-side analysis package:

```
Shared/                        → linked into BOTH iOS and watchOS targets
IndoorKartData/                → iOS-only
IndoorKartDataWatch/           → watchOS-only
analysis/                      → Mac Python package (no Apple build involvement)
supabase/                      → SQL schema + stub, NOT wired to the iOS client yet
```

### Runtime data flow during a race

1. **Watch** (if used): user sets kart number via Digital Crown picker, taps Start. `WatchRecordingController` opens `HKWorkoutSession` (keeps sensors warm), starts `WatchIMURecorder` writing `watch_imu.bin` and `HeartRateRecorder` writing `heart_rate.bin`. The IMU recorder's `onLiveSample` callback integrates `rotationRate.x` (with bias calibration + dead zone) and 20× per second ships a steering angle to iPhone via `WatchConnection`.
2. **iPhone** `RecordingController` reacts to the Watch's `watchStart` command, creates the session directory under `Documents/sessions/<timestamp>_<id>/`, starts `IMURecorder` (CoreMotion @ 100 Hz, writes `iphone_imu.bin`) and `AudioRecorder` (AVAudioEngine → WAV PCM16 44.1 kHz mono → `iphone_audio.wav`). If the kart number is set, it also connects `TimingClient` (SignalR to RaceMann).
3. **TimingClient** subscribes to the current race, filters `Comp` events by kart number, publishes `lastLapMs`. It also tracks **chaser gap** — on our Comp it stashes `(ourRaceTime, pos, lap)`, and the next incoming Comp with `pos == ourPos + 1` computes `chaserGapMs = theirTime - ourTime`. `TimingRecorder` persists every lap (including `chaserGapMs`) and flag change to `timing.json`. `RecordingController` forwards every new lap to the Watch (big display) and to `VoiceAnnouncer` (two TTS phrases: lap time `"<sec> и <tenths>"` truncated — not rounded; then a few seconds later `"плюс <sec> и <tenths>"` when the chaser crosses).
4. **Stop** finalizes files; Watch transfers its binaries via `WCSession.transferFile`. iPhone's `appendWatchSourcesFromDisk` always scans the directory when writing `manifest.json` — so late-arriving transfers still make it into the manifest.
5. **Export**: `SessionArchive` (Transferable) uses `NSFileCoordinator(.forUploading)` to zip the session dir on demand for `ShareLink` → AirDrop/Files/iCloud. `UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace` make sessions visible in Finder (iPhone over USB) and iOS Files app.

### `Shared/` is the contract layer

- `SessionTypes.swift` — `SessionManifest`, `DataSourceKind`, `DataSourceEntry`. Codable JSON model shared across iOS/watchOS/Python.
- `BinaryFormats.swift` — `IMUSampleBinary` is **88 bytes** per sample (1×UInt64 + 10×Double, natural 8-byte alignment, no trailing padding — verified via `MemoryLayout.size`). `HeartRateSampleBinary` is 16 bytes. The Python loader asserts `IMU_DTYPE.itemsize == 88` — do not change the Swift struct without updating `analysis/karttelemetry/loader.py`.
- `SessionStorage.swift` — directory layout and manifest IO; singleton.
- `WatchConnection.swift` — WCSession wrapper + delegate protocol. Both `RecordingController` (iOS) and `WatchRecordingController` (watchOS) conform. Messages: `start`/`stop`/`watchStart`/`watchStop` for session sync; `steering` for 20 Hz live angle; `lastLap` for timing push to Watch. Kart number syncs eagerly via `updateApplicationContext`.
- `RecordingController.swift` — iOS-side orchestrator wrapped in `#if os(iOS)` for most content (the class itself compiles on Watch but is unused there).

### Important architectural decisions (non-obvious)

- **AppDelegate pattern, not `@StateObject` in ContentView.** `UIApplicationDelegateAdaptor(AppDelegate.self)` on iOS and `WKApplicationDelegateAdaptor(WatchAppDelegate.self)` on Watch own `RecordingController` / `WatchRecordingController` as properties. SwiftUI `@StateObject` on a tab view does not reliably initialize on background-launch (e.g. when iPhone is woken by an incoming WCSession message), leaving the WatchConnection delegate nil. `AppDelegate.application(_:didFinishLaunchingWithOptions:)` fires on every launch including background wake, so the WCSession delegate is always wired before any message is dispatched.

- **Watch app is `WKRunsIndependentlyOfCompanionApp: true`.** With this flag false, direct Xcode deploy to the Watch via the `IndoorKartDataWatch` scheme fails with `MIInstaller "Delta patch submitted for application that's just a placeholder"` because iOS reserves the slot for companion sync. Standalone mode lets us deploy from Xcode and still pair via `WKCompanionAppBundleIdentifier`.

- **SignalR 2.x client needs explicit WS-handshake wait.** `URLSessionWebSocketTask.resume()` does not block for the HTTP upgrade. If `/signalr/start` is called before the server has registered the WebSocket, it returns HTTP 400. `SignalRClient` uses a custom `URLSession` (cannot attach delegates to `.shared`), conforms to `URLSessionWebSocketDelegate`, and awaits `didOpenWithProtocol` via a `CheckedContinuation` before calling start.

- **SignalR tokens must be fully percent-encoded.** The connectionToken is base64 and often contains `+` / `/`. `URLQueryItem` leaves these literal (RFC 3986 permits it in query), but the .NET SignalR server interprets `+` as space and rejects the token. `SignalRClient.encodeQuery` manually percent-encodes with `+/=&?#` removed from the allowed set.

- **Audio is optional, IMU is mandatory.** AVAudioEngine's `startIO` frequently fails when the app is cold-launched in background (iOS does not grant microphone from a non-foreground start). `AudioRecorder.start` retries 4× with 250 ms gaps; if it still fails, `RecordingController` sets `lastError = "Аудио не стартовало: ..."` and continues the session **without** audio. The empty `iphone_audio.wav` is deleted, and the manifest omits the audio source.

- **Manifest is rebuilt from disk on every write.** Watch IMU + heart-rate files arrive via `transferFile` asynchronously, often **after** iPhone has already stopped recording and written the manifest. `appendWatchSourcesFromDisk` scans the session dir for `watch_imu.bin`, `heart_rate.bin`, and `timing.json`; both the initial `writeManifest` call and the post-arrival `appendWatchSourceToExistingManifest` run it so the manifest is always consistent with what's physically on disk. The Mac-side loader independently scans by filename rather than trusting `manifest.sources`, as belt-and-suspenders.

- **Steering integration bias calibration.** `WatchRecordingController.integrateAndMaybeSendSteering` collects the first ~100 samples (~1 s) of `rotationRate.x` at session start as the gyro zero-bias, subtracts it from subsequent samples, and applies a 0.02 rad/s dead zone. Without this, holding the wheel still produces visible drift as the integrator sums gyro noise.

- **Kart-number matching for timing.** The MIKS track labels competitors `"KINDER 29"` / `"super sport 55"` rather than the generic `"KART N"` the agent originally reverse-engineered. `TimingClient.isOurKart` splits `fn` on spaces and matches the **last token** (plus the usual `rn`/`nn` string-or-int-equal checks).

- **TimingClient race-ID handling, two subtle bugs now defended:**
  - **`GetLastRaceId` response comes via `{I,R}` invocation result, NOT the `lastRaceId` hub push.** SignalR 2.x returns our RPC answer in the `{I,R}` envelope; some servers never push `lastRaceId` separately. `SignalRClient` tracks pending invocations by id→method so `onInvocationResult` can route the result; `TimingClient.processNewRaceID` is the single code path consuming both the hub push and the invocation result. Previously only the hub push was handled → client stayed subscribed to a finished heat forever.
  - **URLSessionWebSocketTask can become an iOS-BG zombie:** writes return success, server-sent keep-alives (`{}` every 2–3 s) keep `lastMessageAt` fresh, but our outbound `SubscribeRace` never actually reaches the server. The watchdog in `TimingClient.startWatchdogLoop` runs every 3 s and uses a 5-rung escalation (all thresholds collected in a `Thresholds` struct for tuning): (1) `!isConnected` → immediate reconnect, (2) WS silence > 25 s → hard reconnect, (3) `SubscribeRace` ack > 10 s overdue → hard reconnect (catches the zombie case), (4) Comp silence > 20 s → soft re-subscribe (cooldown 15 s), (5) Comp silence > 60 s → hard reconnect. Reconnect runs in a detached Task so cancellation of the watchdog's own task doesn't abort it.
  - Catchup-artifact filter: Comp with `lastLapMs` outside `[10 000, 180 000]` is dropped (server sometimes emits "time since our last known subscription" as lap time after a reconnect — observed 1 564 445 ms = 26 min on real data). Dedup on `lapNumber` alone.

- **Overtaking leaves a signal in the data.** Any lap where the pilot is passed by (or passes) another kart shows up as a `lapMs` degradation plus a `position` jump on that lap. The chaser gap also collapses or inverts in sync. When writing post-session analysis, treat these laps as outliers for best-lap metrics but keep them as a labeled dataset for driver-skill scoring. This is why `timing.json` stores per-lap `position` and `chaserGapMs` alongside `lapMs`.

- **Debug-overlay counters on RecordScreen.** `TimingClient` publishes `heartbeatCount`, `compCount`, `compMineCount`, and `lastCompKartSeen`. The overlay shows them live during a session — if `hb > 0` but `comp == 0`, no race is active; if `comp > 0` but `мой == 0`, the kart-number filter is wrong (compare against `виден:` to see the format the server actually sends). Keep this overlay — it has already saved multi-session debugging on-site.

## Deployment / signing

- Signing team is **not** set in `project.yml` — open Xcode Signing & Capabilities, pick your team on both `IndoorKartData` and `IndoorKartDataWatch` targets. If `com.indoorkartdata.app` is taken, rename both bundle IDs (Watch must keep the `.watchkitapp` suffix matching iPhone, and the Watch Info.plist `WKCompanionAppBundleIdentifier` must match the new iPhone bundle — edit via project.yml, not Xcode UI, since Info.plist is generated).
- iPhone needs Developer Mode on; Watch needs Developer Mode on (toggled from the Watch itself, not the iPhone Watch app).
- Direct Watch deploy: switch the Xcode scheme to `IndoorKartDataWatch` and destination to the paired Watch. Deploying the `IndoorKartData` scheme to iPhone also pushes the embedded Watch binary via companion sync, but that path has been flaky — direct Watch deploy is more reliable.

## When session files land on Mac

Expected layout (see `Shared/SessionTypes.swift` and `analysis/karttelemetry/loader.py`):

```
2026-10-04T18-22-58_EDFB53D0/
├── manifest.json            # session metadata + sources list
├── iphone_imu.bin           # 88 bytes/sample × 100 Hz
├── iphone_audio.wav         # PCM16 mono 44.1 kHz (optional)
├── watch_imu.bin            # 88 bytes/sample × 100 Hz (optional)
├── heart_rate.bin           # 16 bytes/sample, variable rate (optional)
└── timing.json              # lap/flag ground truth from RaceMann (optional)
```

## katahub cloud backend (separate repo at `~/Developer/katahub`)

Go API + Python subprocess, deployed to Yandex Cloud VM `mike@93.77.183.135` at `kart.katahub.ru`. Serves the admin dashboard, ingests session zips from iOS, runs AI verdict + full pipeline render + on-demand lap compare.

**Repo layout:**
```
katahub/
├── backend/
│   ├── cmd/api/             # Go main
│   ├── internal/{api,sessions,pipeline,live,ai,db}
│   ├── analysis/            # Python mirror of indoorKartdata/analysis
│   ├── web/                 # admin dashboard (index.html, session.html)
│   ├── Dockerfile           # multi-stage: Go build → python:3.12-slim runtime
│   └── docker-compose.yml
└── deploy/deploy.sh         # rsyncs backend/ to VM, docker compose build+up
```

- **Go is not installed locally.** Validate backend changes via Docker: `docker run --rm -v /Users/mike/Developer/katahub/backend:/src -w /src golang:1.23-alpine go vet ./...` — zero cost, catches compile errors.
- **Python scripts live in two places.** `indoorKartdata/analysis/` is authoritative; `katahub/backend/analysis/` is the mirror shipped in the Docker image. **After editing a script, copy it to the mirror** before `deploy.sh`, otherwise the prod container keeps running the old version.
- Deploy: `cd ~/Developer/katahub/deploy && bash deploy.sh` — idempotent, rsyncs backend, rebuilds Docker image on VM, restarts api container, probes `/healthz`. Postgres volume is **not** touched unless `--purge-data`.
- Session storage on VM: `/data/sessions/{uuid}/payload.zip` + cached compare HTMLs rendered on-demand (`compare_{N}_vs_{M}.html`) next to the zip.

### iOS ↔ katahub integration

- `IndoorKartData/Backend/KatahubClient.swift` — POSTs session zip to `/sessions/` on Stop + after every Watch-file arrival (manifest rebuild → re-upload).
- `IndoorKartData/Backend/KatahubLiveStream.swift` — holds TWO WebSockets to katahub for the duration of the recording:
  - `/live/{id}/publish` (JSON text): derived telemetry @ 10 Hz (`kind="telemetry"`) and semantic events (`timing.lap`).
  - `/live/{id}/watch-imu` (binary, Wave 2): raw Watch IMU batched @ 1 Hz, each batch = 8-byte header (`'IM'` magic + version + count:uint32) + N × 88-byte `IMUSampleBinary`. iPhone opens this WS lazily on first batch arrival.
- Watch → iPhone forwarding: `WatchIMURecorder` accumulates 1 s of samples and calls `WatchConnection.sendImuBatch(Data)` → `WCSession.sendMessageData` (not JSON). iPhone's `didReceiveMessageData` delegate calls `KatahubLiveStream.publishWatchImuBatch`.

### Live event kinds (SSE `/live/{id}/subscribe`)

| kind | source | payload | consumer action |
|---|---|---|---|
| `telemetry` | iPhone @ 10 Hz | `{aLong, aLat, ah, yawRateDeg, phase, lap}` | debug feed |
| `timing.lap` | iPhone on new Comp event | `{lapNumber, lapMs, wallTime, position, chaserGapMs}` | **backend hook (Wave 2):** slices Watch IMU ring buffer → writes `laps/N.bin` → runs `laps_compare.py` against current best → publishes `compare.done` |
| `render.done` | backend after Python render | `{ok:true}` | dashboard `loadAnalysis()` |
| `analysis.done` | backend after AI verdict | `{verdict, model, lapCount, bestLapSec}` | dashboard `loadAnalysis()` |
| `compare.done` | backend after `laps_compare.py` finishes — **now fires PER LAP during a session** (Wave 2) and also once post-upload | `{best, other, source?}` (`source:"live"` for Wave-2 per-lap) | dashboard reloads compare iframe with cache-bust |

### v2 analysis pipeline (post-upload render)

`katahub_render.py` runs the full v2 spec and returns a single JSON consumed by `session.html`. Three gates must pass before any output:
- **Session gate**: `RMS(wz_f) > 0.6` AND `|∫wz dt|/2π ≥ 1` lap — else `{status:"no_driving"}`.
- **Direction sign**: `∑wz·dt > 0` on MIKS; if < 0 the quaternion is inverted → `conj` applied and all world-frame vectors recomputed.
- **Timing match**: IMU lap count vs RaceMann ±1, durations within ±0.3 s — else `timing_mismatch` warning, timing dropped, pipeline falls back to IMU-only lap boundaries.

Per-lap gate: NCC with template ≥ 0.6 AND DTW residual ≤ 0.5. Failing laps are tagged `valid:false` in `per_lap_times[]` — rendered on the dashboard at 50 % opacity and excluded from medians and the compare dropdown.

Keys the render JSON exposes (consumed by `session.html`):
- `phase_cut` — session-wide Otsu brake threshold (always visible under "Карт и держак")
- `invalid_laps_count`
- `theta_deg`, `theta_corr` (should be > 0.9 — if lower, suspect wrist pose or quaternion sign)
- `corner_table[]` — per corner: `{best, median}` for vmin / alat_pk / amin / brake_len / slip + `delta_s` (loss to best lap on this corner)
- `sector_table[]` — per sector: `{best, median, sigma_ms, n}`
- `grip_ratio` — `median(alat_pk) / reference_median(alat_pk)` (close to 1 = kart grips like reference; < 0.9 = slippery kart)
- `delta_vs_reference` — `(1 − grip_ratio) · Σ corner_time · 0.5` seconds attributed to car vs driver on best-lap delta
- `potential_s` — sum of 10th-percentile sector times from valid laps (what the pilot's own driving could already deliver)
- `trend_s` — mean(first 10 valid laps) − mean(last 10 valid laps). Positive = tiring; negative = still improving
- `recommendations[]` — up to 4 rule-based cards, sorted by estimated time loss, each with raw supporting numbers (slip, amin, vmin) so the pilot can push back

### Compare endpoint contract

`GET /sessions/{id}/compare?best=N&other=M[&force=1]` — on-demand lap compare HTML. Backend subprocesses `laps_compare.py` with the stored zip, caches result to disk, serves `text/html`. In-process lock dedupes parallel requests on the same `(id, N, M)`.
- HTTP 400: equal or non-positive lap numbers.
- HTTP 404: no `payload.zip` for this session.
- **HTTP 422: align gate failed** (DTW residual > 0.5 rad/s between the two laps — Python exit 4, mapped to `pipeline.ErrAlignGateFailed`). Dashboard shows an orange "круг не прошёл align gate" message.
- HTTP 500: anything else from the Python subprocess.

`runPipeline` (post-upload) auto-triggers `BuildCompare(best, lastLap)` in a background goroutine and publishes `compare.done` when ready. Dashboard SSE handler reloads the iframe automatically. This means **every session upload yields a best-vs-last compare without user action**.

### Wave 2: live per-lap compare (fires during the race)

Flow on each `timing.lap`:
1. **Refine bounds**: `live.RefineBoundary(wallTime ± 2s, template, ringBuffer)` searches a 4s window of accumulated Watch IMU `wz` for the best normalized cross-correlation match against the pre-built track template's tail+head window (last 5 s of previous lap + first 5 s of next lap, @ 50 Hz). Reduces RaceMann wall-time noise (±1 s) to ±0.1 s precision.
2. **Slice**: cut `[t_start, t_end]` from the 120 s ring buffer (`live.Accumulator`), write to `/data/sessions/{id}/laps/N.bin` (88-byte-per-sample IMU format, same as `watch_imu.bin`).
3. **Gate**: NCC of lap wz against full template must be ≥ 0.6, otherwise skip (lap was almost certainly a pit lap / sched-out / overtake-noise).
4. **Best lap persistence**: if new lap is faster, copy to `/data/sessions/{id}/laps/best.bin`. Lives outside the ring buffer's 120 s eviction window.
5. **Build compare**: `pipeline.BuildCompareFromLiveLaps` concatenates saved `laps/*.bin` into a synthetic session zip (minimal `timing.json` with just the passes we've seen so far, plus manifest), then delegates to the same `BuildCompare` used post-upload. This avoids duplicating `laps_compare.py` logic — the Python side sees "a session with K laps" and runs normally.
6. **Publish** `compare.done` with `source:"live"`. Dashboard SSE handler reloads the iframe.

Track template is loaded ONCE at process start from `/app/tracks/<ACTIVE_TRACK>/` (env `TRACKS_DIR`, `ACTIVE_TRACK`, defaults `/app/tracks` + `miks`). Directory contains three files:
- `tmpl.npy` — reference `wz_f` @ 100 Hz (one representative lap, used by `find_peaks` NCC alignment)
- `track.npz` — `x, y, v, wz` @ 50 Hz (geometry for the dashboard map + visual references)
- `features.npy` — DTW features `[wz/1.2, 0.5·z(|a_h|)]` @ 50 Hz, precomputed from the template to avoid runtime recompute

Build with the admin op:
```sh
python3 analysis/build_template.py --zip SESSION.zip --track miks [--lap N]
```
This writes all three files into `analysis/tracks/<NAME>/` and `katahub/backend/tracks/<NAME>/`. Rebuild only when you want a new reference session or a different track; **never** per-session or per-request. If a file is missing, the backend logs a warning and the live-mode just degrades to no boundary refinement (slice width = raw `wallTime - lapMs`) — laps still write and compare still runs.

Replay harness (demo without a real race):
```sh
# Terminal A: start local stack
cd ~/Developer/katahub/backend && docker compose up

# Terminal B: upload a dummy session to get a UUID, then replay
curl -s http://127.0.0.1:8080/sessions -XPOST --data-binary @/tmp/test_session.zip
# → {"id":"...uuid...","status":"uploaded",...}
python3 analysis/replay_live.py \
    --zip /tmp/test_session.zip \
    --session-id <uuid> \
    --host http://127.0.0.1:8080 \
    --speed 20
# Watch https://127.0.0.1/admin/session.html?id=<uuid> — compare iframe
# reloads every ~2 simulated laps as `compare.done` fires.
```
