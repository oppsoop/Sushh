-- WorldFriends initial schema
-- All identifiers are app-generated UUID v4 strings.

create table if not exists schema_migrations (
  version text primary key,
  applied_at timestamptz not null default now()
);

create table if not exists users (
  id uuid primary key,
  email text not null,
  email_verified_at timestamptz,
  password_hash text,
  google_sub text,
  display_name text not null default '',
  username text,
  username_changed_at timestamptz,
  avatar_media_id uuid,
  bio text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_seen_at timestamptz,
  deleted_at timestamptz
);
create unique index if not exists users_email_key on users (lower(email));
create unique index if not exists users_username_key on users (username) where username is not null;
create unique index if not exists users_google_sub_key on users (google_sub) where google_sub is not null;

-- Usernames that were released stay blocked for a cool-down period (90 days).
create table if not exists username_history (
  id bigserial primary key,
  username text not null,
  user_id uuid not null,
  released_at timestamptz not null default now()
);
create index if not exists username_history_username_idx on username_history (username, released_at desc);

create table if not exists email_tokens (
  id uuid primary key,
  user_id uuid not null references users(id) on delete cascade,
  token_hash text not null unique,
  purpose text not null check (purpose in ('verify_email', 'reset_password')),
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists email_tokens_user_idx on email_tokens (user_id, purpose);

create table if not exists refresh_tokens (
  id uuid primary key,
  user_id uuid not null references users(id) on delete cascade,
  token_hash text not null unique,
  family_id uuid not null,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  replaced_by uuid,
  user_agent text,
  created_at timestamptz not null default now(),
  last_used_at timestamptz
);
create index if not exists refresh_tokens_user_idx on refresh_tokens (user_id);
create index if not exists refresh_tokens_family_idx on refresh_tokens (family_id);

create table if not exists media (
  id uuid primary key,
  owner_id uuid not null references users(id) on delete cascade,
  kind text not null check (kind in ('image', 'video', 'audio', 'file')),
  mime text not null,
  bytes bigint not null default 0,
  width int,
  height int,
  duration_ms int,
  storage_key text not null,
  thumb_key text,
  original_name text,
  waveform text,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists media_owner_idx on media (owner_id, created_at desc);

create table if not exists conversations (
  id uuid primary key,
  kind text not null check (kind in ('direct', 'group')),
  pair_key text unique,
  title text,
  created_by uuid references users(id) on delete set null,
  created_at timestamptz not null default now(),
  last_message_at timestamptz not null default now()
);
create index if not exists conversations_last_message_idx on conversations (last_message_at desc);

create table if not exists conversation_members (
  conversation_id uuid not null references conversations(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  role text not null default 'member',
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  last_read_at timestamptz,
  last_read_message_id uuid,
  muted boolean not null default false,
  primary key (conversation_id, user_id)
);
create index if not exists conversation_members_user_idx on conversation_members (user_id);

create table if not exists messages (
  id uuid primary key,
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_id uuid not null references users(id) on delete cascade,
  client_id text not null,
  kind text not null default 'text' check (kind in ('text', 'image', 'video', 'audio', 'file', 'call', 'system')),
  body text,
  media_id uuid references media(id) on delete set null,
  reply_to_id uuid,
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  deleted_at timestamptz,
  -- Idempotency guard: one row per (conversation, sender, client generated id).
  unique (conversation_id, sender_id, client_id)
);
create index if not exists messages_conversation_idx on messages (conversation_id, created_at desc, id desc);
create index if not exists messages_media_idx on messages (media_id);

create table if not exists message_receipts (
  message_id uuid not null references messages(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  delivered_at timestamptz,
  read_at timestamptz,
  primary key (message_id, user_id)
);
create index if not exists message_receipts_user_idx on message_receipts (user_id);

create table if not exists stories (
  id uuid primary key,
  user_id uuid not null references users(id) on delete cascade,
  media_id uuid references media(id) on delete set null,
  caption text not null default '',
  background_color text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  deleted_at timestamptz
);
create index if not exists stories_user_idx on stories (user_id, created_at desc);
create index if not exists stories_expiry_idx on stories (expires_at);

create table if not exists story_views (
  story_id uuid not null references stories(id) on delete cascade,
  viewer_id uuid not null references users(id) on delete cascade,
  viewed_at timestamptz not null default now(),
  primary key (story_id, viewer_id)
);

create table if not exists posts (
  id uuid primary key,
  user_id uuid not null references users(id) on delete cascade,
  body text not null default '',
  media_id uuid references media(id) on delete set null,
  visibility text not null default 'friends' check (visibility in ('public', 'friends', 'private')),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists posts_user_idx on posts (user_id, created_at desc);
create index if not exists posts_created_idx on posts (created_at desc);

create table if not exists post_likes (
  post_id uuid not null references posts(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table if not exists comments (
  id uuid primary key,
  post_id uuid not null references posts(id) on delete cascade,
  user_id uuid not null references users(id) on delete cascade,
  body text not null,
  parent_id uuid references comments(id) on delete cascade,
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);
create index if not exists comments_post_idx on comments (post_id, created_at);

create table if not exists follows (
  follower_id uuid not null references users(id) on delete cascade,
  following_id uuid not null references users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, following_id),
  check (follower_id <> following_id)
);

create table if not exists friendships (
  user_a uuid not null references users(id) on delete cascade,
  user_b uuid not null references users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_a, user_b),
  check (user_a < user_b)
);

create table if not exists friend_requests (
  id uuid primary key,
  from_user_id uuid not null references users(id) on delete cascade,
  to_user_id uuid not null references users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'cancelled')),
  message text,
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  check (from_user_id <> to_user_id)
);
create unique index if not exists friend_requests_pending_key
  on friend_requests (from_user_id, to_user_id) where status = 'pending';
create index if not exists friend_requests_to_idx on friend_requests (to_user_id, status, created_at desc);

create table if not exists blocks (
  blocker_id uuid not null references users(id) on delete cascade,
  blocked_id uuid not null references users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);

create table if not exists reports (
  id uuid primary key,
  reporter_id uuid not null references users(id) on delete cascade,
  target_type text not null check (target_type in ('user', 'post', 'comment', 'message', 'story')),
  target_id uuid not null,
  reason text not null,
  details text,
  status text not null default 'open' check (status in ('open', 'reviewing', 'actioned', 'dismissed')),
  created_at timestamptz not null default now()
);
create index if not exists reports_status_idx on reports (status, created_at desc);

create table if not exists devices (
  id uuid primary key,
  user_id uuid not null references users(id) on delete cascade,
  fcm_token text not null unique,
  platform text not null default 'android',
  app_version text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index if not exists devices_user_idx on devices (user_id);

create table if not exists notifications (
  id uuid primary key,
  user_id uuid not null references users(id) on delete cascade,
  kind text not null,
  actor_id uuid references users(id) on delete set null,
  entity_type text,
  entity_id uuid,
  data jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on notifications (user_id, created_at desc);

create table if not exists calls (
  id uuid primary key,
  conversation_id uuid references conversations(id) on delete set null,
  caller_id uuid not null references users(id) on delete cascade,
  callee_id uuid not null references users(id) on delete cascade,
  kind text not null check (kind in ('audio', 'video')),
  status text not null default 'ringing' check (status in ('ringing', 'answered', 'declined', 'missed', 'ended', 'failed')),
  created_at timestamptz not null default now(),
  answered_at timestamptz,
  ended_at timestamptz,
  ended_reason text
);
create index if not exists calls_callee_idx on calls (callee_id, created_at desc);

create table if not exists feedback (
  id uuid primary key,
  user_id uuid references users(id) on delete set null,
  message text not null,
  device_info jsonb not null default '{}'::jsonb,
  app_version text,
  screenshot_media_id uuid references media(id) on delete set null,
  created_at timestamptz not null default now()
);

create table if not exists analytics_events (
  id bigserial primary key,
  user_id uuid references users(id) on delete set null,
  anon_id text,
  name text not null,
  props jsonb not null default '{}'::jsonb,
  app_version text,
  platform text,
  created_at timestamptz not null default now()
);
create index if not exists analytics_events_name_idx on analytics_events (name, created_at desc);

create table if not exists beta_invites (
  id uuid primary key,
  code text not null unique,
  email text,
  note text,
  max_uses int not null default 1,
  used_count int not null default 0,
  created_at timestamptz not null default now(),
  expires_at timestamptz,
  revoked_at timestamptz
);
create index if not exists beta_invites_email_idx on beta_invites (lower(email));

create table if not exists push_log (
  id bigserial primary key,
  user_id uuid,
  device_id uuid,
  title text,
  body text,
  ok boolean not null default false,
  error text,
  created_at timestamptz not null default now()
);
