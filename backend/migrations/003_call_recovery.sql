-- Keep the offer/candidates briefly so a callee can recover a call after
-- tapping a background push. Never store audio or video content here.
alter table calls add column if not exists offer jsonb;
create table if not exists call_ice_candidates (
  id bigserial primary key,
  call_id uuid not null references calls(id) on delete cascade,
  from_user_id uuid not null references users(id) on delete cascade,
  candidate jsonb not null,
  created_at timestamptz not null default now()
);
create index if not exists call_ice_call_idx on call_ice_candidates (call_id, id);
