-- Local-dev seed data. Idempotent via on conflict.
-- Fixed UUIDs so clients can hardcode them in dev.

insert into public.tracks (id, name, city, country, metadata) values
  (
    '00000000-0000-0000-0000-000000000001'::uuid,
    'Nebula Speedway',
    'Berlin',
    'DE',
    jsonb_build_object('length_m', 480, 'surface', 'rubberized_asphalt')
  ),
  (
    '00000000-0000-0000-0000-000000000002'::uuid,
    'Kart Arena Riga',
    'Riga',
    'LV',
    jsonb_build_object('length_m', 520, 'surface', 'concrete')
  ),
  (
    '00000000-0000-0000-0000-000000000003'::uuid,
    'Apex Indoor Karting',
    'Amsterdam',
    'NL',
    jsonb_build_object('length_m', 610, 'surface', 'rubberized_asphalt')
  )
on conflict (id) do nothing;
