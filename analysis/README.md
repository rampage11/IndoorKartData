# karttelemetry

Mac-side analysis tools for indoor karting telemetry sessions produced by the
iOS/watchOS recorder app.

## Install

With [uv](https://docs.astral.sh/uv/) (recommended):

```
cd analysis
uv sync
```

Or with pip (editable):

```
cd analysis
pip install -e .
```

Dev extras (pytest):

```
pip install -e '.[dev]'
```

## Usage

Point the inspector at a session directory pulled from the iPhone:

```
uv run python -m karttelemetry.inspect /path/to/session_dir
```

Or, after `pip install -e .`:

```
python -m karttelemetry.inspect /path/to/session_dir
```

It prints a short summary and writes `summary.png` into the session directory.

## Session layout

Each session dir contains `manifest.json`, `iphone_imu.bin`, `iphone_audio.wav`,
optionally `watch_imu.bin` and `heart_rate.bin`. See the project top-level docs
for byte-level layout.

## Tests

```
python -m pytest analysis/tests/
```
