-- Initial schema for IndoorKart telemetry backend.
-- Scope: profiles, tracks, sessions, session_sources + storage bucket.
-- All user-owning tables have RLS enabled.

create extension if not exists pgcrypto;

-- Private schema holds security-definer helpers that must not be callable
-- directly by anon/authenticated roles.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;


-- ---------------------------------------------------------------------------
-- profiles: one row per auth user. Row id matches auth.users.id.
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles enable row level security;


-- ---------------------------------------------------------------------------
-- tracks: catalog of indoor karting venues. Seeded by service_role.
-- ---------------------------------------------------------------------------
create table if not exists public.tracks (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  city text,
  country text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.tracks enable row level security;


-- ---------------------------------------------------------------------------
-- sessions: one telemetry recording. id comes from the client (UUID in
-- SessionManifest), so we do not default it here.
-- ---------------------------------------------------------------------------
create table if not exists public.sessions (
  id uuid primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  track_id uuid references public.tracks (id) on delete set null,
  started_at timestamptz not null,
  ended_at timestamptz,
  device_name text not null,
  device_model text not null,
  app_version text not null,
  visibility text not null default 'private'
    check (visibility in ('private', 'track_public')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sessions_ended_after_started
    check (ended_at is null or ended_at >= started_at)
);

alter table public.sessions enable row level security;

-- Indexes for RLS filters and typical queries.
create index if not exists sessions_user_id_idx on public.sessions (user_id);
create index if not exists sessions_track_id_idx on public.sessions (track_id);
create index if not exists sessions_started_at_idx on public.sessions (started_at desc);


-- ---------------------------------------------------------------------------
-- session_sources: per-stream metadata (one row per bin/wav file).
-- ---------------------------------------------------------------------------
create table if not exists public.session_sources (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references public.sessions (id) on delete cascade,
  kind text not null
    check (kind in ('iphone_imu', 'iphone_audio', 'watch_imu', 'heart_rate')),
  filename text not null,
  sample_count bigint,
  sample_rate_hz double precision,
  format text not null,
  storage_path text not null,
  byte_size bigint,
  created_at timestamptz not null default now(),
  unique (session_id, kind)
);

alter table public.session_sources enable row level security;

create index if not exists session_sources_session_id_idx
  on public.session_sources (session_id);


-- ---------------------------------------------------------------------------
-- updated_at trigger (shared helper).
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists set_updated_at on public.profiles;
create trigger set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.tracks;
create trigger set_updated_at
  before update on public.tracks
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.sessions;
create trigger set_updated_at
  before update on public.sessions
  for each row execute function public.set_updated_at();


-- ---------------------------------------------------------------------------
-- Auto-create a profile row when a new auth user signs up.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', null))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ---------------------------------------------------------------------------
-- Helper: does the calling user own at least one session on the given track?
-- Used by the track_public share policy to let pilots who raced on the same
-- track compare each other's sessions.
--
-- SECURITY DEFINER bypasses RLS; the body is restricted to a single
-- auth.uid()-scoped existence check so no data leaks.
-- ---------------------------------------------------------------------------
create or replace function private.user_has_session_on_track(target_track_id uuid)
returns boolean
language sql
security definer
stable
set search_path = ''
as $$
  select exists (
    select 1
    from public.sessions s
    where s.track_id = target_track_id
      and s.user_id = (select auth.uid())
  );
$$;

revoke execute on function private.user_has_session_on_track(uuid)
  from public, anon, authenticated, service_role;
grant execute on function private.user_has_session_on_track(uuid)
  to authenticated;


-- ---------------------------------------------------------------------------
-- RLS policies: profiles.
-- Owner-only read/update. Insert is handled by the handle_new_user trigger,
-- but we also allow authenticated users to insert their own row defensively.
-- ---------------------------------------------------------------------------
drop policy if exists profiles_select_own on public.profiles;
create policy profiles_select_own on public.profiles
  for select to authenticated
  using (id = (select auth.uid()));

drop policy if exists profiles_insert_own on public.profiles;
create policy profiles_insert_own on public.profiles
  for insert to authenticated
  with check (id = (select auth.uid()));

drop policy if exists profiles_update_own on public.profiles;
create policy profiles_update_own on public.profiles
  for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));


-- ---------------------------------------------------------------------------
-- RLS policies: tracks. Public catalog, read-only for authenticated users.
-- Writes only via service_role (bypasses RLS entirely).
-- ---------------------------------------------------------------------------
drop policy if exists tracks_select_all on public.tracks;
create policy tracks_select_all on public.tracks
  for select to authenticated
  using (true);


-- ---------------------------------------------------------------------------
-- RLS policies: sessions.
-- Owner: full CRUD. Other authenticated users: SELECT only when
-- visibility='track_public' and they themselves have a session on the same
-- track (reciprocity requirement for the compare-pilots feature).
-- ---------------------------------------------------------------------------
drop policy if exists sessions_select_own on public.sessions;
create policy sessions_select_own on public.sessions
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists sessions_select_shared on public.sessions;
create policy sessions_select_shared on public.sessions
  for select to authenticated
  using (
    visibility = 'track_public'
    and track_id is not null
    and (select private.user_has_session_on_track(track_id))
  );

drop policy if exists sessions_insert_own on public.sessions;
create policy sessions_insert_own on public.sessions
  for insert to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists sessions_update_own on public.sessions;
create policy sessions_update_own on public.sessions
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists sessions_delete_own on public.sessions;
create policy sessions_delete_own on public.sessions
  for delete to authenticated
  using (user_id = (select auth.uid()));


-- ---------------------------------------------------------------------------
-- RLS policies: session_sources. Access mirrors the parent session.
-- ---------------------------------------------------------------------------
drop policy if exists session_sources_select_own on public.session_sources;
create policy session_sources_select_own on public.session_sources
  for select to authenticated
  using (
    exists (
      select 1 from public.sessions s
      where s.id = session_sources.session_id
        and s.user_id = (select auth.uid())
    )
  );

drop policy if exists session_sources_select_shared on public.session_sources;
create policy session_sources_select_shared on public.session_sources
  for select to authenticated
  using (
    exists (
      select 1 from public.sessions s
      where s.id = session_sources.session_id
        and s.visibility = 'track_public'
        and s.track_id is not null
        and (select private.user_has_session_on_track(s.track_id))
    )
  );

drop policy if exists session_sources_insert_own on public.session_sources;
create policy session_sources_insert_own on public.session_sources
  for insert to authenticated
  with check (
    exists (
      select 1 from public.sessions s
      where s.id = session_sources.session_id
        and s.user_id = (select auth.uid())
    )
  );

drop policy if exists session_sources_update_own on public.session_sources;
create policy session_sources_update_own on public.session_sources
  for update to authenticated
  using (
    exists (
      select 1 from public.sessions s
      where s.id = session_sources.session_id
        and s.user_id = (select auth.uid())
    )
  )
  with check (
    exists (
      select 1 from public.sessions s
      where s.id = session_sources.session_id
        and s.user_id = (select auth.uid())
    )
  );

drop policy if exists session_sources_delete_own on public.session_sources;
create policy session_sources_delete_own on public.session_sources
  for delete to authenticated
  using (
    exists (
      select 1 from public.sessions s
      where s.id = session_sources.session_id
        and s.user_id = (select auth.uid())
    )
  );


-- ---------------------------------------------------------------------------
-- Storage: session-files bucket.
-- Files are stored under <user_id>/<session_id>/<filename>. The RLS policies
-- below rely on that layout (first path segment == auth.uid()).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('session-files', 'session-files', false)
on conflict (id) do nothing;

drop policy if exists session_files_select_own on storage.objects;
create policy session_files_select_own on storage.objects
  for select to authenticated
  using (
    bucket_id = 'session-files'
    and owner = (select auth.uid())
  );

drop policy if exists session_files_insert_own on storage.objects;
create policy session_files_insert_own on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'session-files'
    and owner = (select auth.uid())
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

drop policy if exists session_files_update_own on storage.objects;
create policy session_files_update_own on storage.objects
  for update to authenticated
  using (
    bucket_id = 'session-files'
    and owner = (select auth.uid())
  )
  with check (
    bucket_id = 'session-files'
    and owner = (select auth.uid())
  );

drop policy if exists session_files_delete_own on storage.objects;
create policy session_files_delete_own on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'session-files'
    and owner = (select auth.uid())
  );

-- TODO(share): mirror the track_public SELECT policy on storage.objects once
-- the compare-pilots feature actually needs cross-user file reads. For now
-- metadata rows (session_sources) are shared but blobs stay owner-only.
