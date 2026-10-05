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

- **Periodic race-ID re-poll.** Marshals sometimes reset the heat mid-session (the pilot is already in the kart). `TimingClient.startRaceRefreshLoop` sends `GetLastRaceId` every 10 s; when the ID changes, the `lastRaceId` handler calls `UnsubscribeRace` on the old ID, `resetMySelfState()` (drops stale lap markers), then `SubscribeRace` on the new ID. Without this the client stays subscribed to a finished heat and never sees new Comp events.

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
