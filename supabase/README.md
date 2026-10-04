# Supabase backend (IndoorKart)

Design artifacts only. Nothing in this directory connects to a live project yet.

## Layout

- `migrations/20261003_000001_init.sql` — initial schema (profiles, tracks, sessions, session_sources) + RLS + `session-files` storage bucket.
- `seed.sql` — a few example indoor tracks for local dev.

## Local setup

Install the Supabase CLI, then from the repo root:

```sh
supabase init          # one-time: writes supabase/config.toml
supabase start         # boots local Postgres + GoTrue + Storage in Docker
supabase db reset      # applies all migrations and seed.sql fresh
```

After `supabase start`, note the printed values:

- `API URL`      — e.g. `http://127.0.0.1:54321`
- `anon key`     — public JWT for the iOS client
- `service_role` — do NOT ship this; use only for seeding/admin.

## iOS client config

Add to `IndoorKartData/Info.plist` (or an xcconfig) the two keys the client reads:

```xml
<key>SUPABASE_URL</key><string>http://127.0.0.1:54321</string>
<key>SUPABASE_ANON_KEY</key><string>eyJhbGciOi...</string>
```

If either key is missing, `SupabaseClient` runs in offline mode and all methods throw `.notConfigured`.

## Applying migrations to a hosted project

```sh
supabase link --project-ref <ref>
supabase db push
```

Seed data is for local dev only; insert real tracks via the dashboard or a separate SQL script.
