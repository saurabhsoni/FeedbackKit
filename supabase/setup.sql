-- FeedbackKit — Supabase setup
--
-- Run this ONCE per Supabase project, in the SQL Editor.
-- It is idempotent: re-running it is safe.
--
-- The security model, in one line: the key shipped inside the app can INSERT
-- feedback and nothing else. It cannot read a single row back, cannot delete,
-- and cannot touch the triage columns. That property is enforced by three
-- independent layers (RLS default-deny, column-level grants, and PostgREST
-- returning no body), so no single mistake exposes the data.

-- ---------------------------------------------------------------------------
-- 1. Table
-- ---------------------------------------------------------------------------

create table if not exists public.feedback (
  id           uuid primary key default gen_random_uuid(),

  -- Which app sent this. A slug pattern rather than a fixed IN-list so a new
  -- app never needs a schema migration — it just picks a new slug.
  app_id       text not null check (app_id ~ '^[a-z0-9][a-z0-9._-]{1,39}$'),
  app_version  text not null check (char_length(app_version) <= 20),
  build_number text          check (char_length(build_number) <= 20),

  -- What the person actually said.
  body         text not null check (char_length(body) between 1 and 4000),
  category     text not null default 'general'
                 check (category in ('bug', 'idea', 'general')),

  -- Storage paths, e.g. {'myeverythingapp/<uuid>.jpg'}. Not URLs — the bucket
  -- is private, so these are resolved with the secret key at read time.
  screenshots  text[] not null default '{}'
                 check (coalesce(array_length(screenshots, 1), 0) <= 5),

  -- Who sent it. `reporter` is a display name the person types once;
  -- `device_id` is a random per-install UUID, NOT any Apple-provided device
  -- identifier — it exists only to group one person's reports together.
  reporter     text          check (char_length(reporter) <= 80),
  device_id    text          check (char_length(device_id) <= 64),

  -- Device/environment context, e.g.
  -- {"model":"iPhone14,3","os":"26.4.1","locale":"en_IN","screen":"1284x2778"}
  device       jsonb not null default '{}'::jsonb
                 check (pg_column_size(device) <= 2048),

  -- Triage. The app CANNOT write these — see the column grants below.
  status       text not null default 'new'
                 check (status in ('new', 'triaged', 'in_progress', 'done', 'wontfix')),
  priority     smallint check (priority between 0 and 3),
  notes        text,

  created_at   timestamptz not null default now()
);

create index if not exists feedback_app_created_idx
  on public.feedback (app_id, created_at desc);

create index if not exists feedback_new_idx
  on public.feedback (created_at desc) where status = 'new';

-- ---------------------------------------------------------------------------
-- 2. Row-level security — insert-only for the key that ships in the app
-- ---------------------------------------------------------------------------

alter table public.feedback enable row level security;

-- Start from zero rather than trusting Supabase's defaults.
revoke all on public.feedback from anon, authenticated;

-- The app may set ONLY these columns. `status`, `priority`, `notes`, `id` and
-- `created_at` are simply unreachable from a client — a malicious client cannot
-- mark its own report "done" or backdate it.
grant insert (app_id, app_version, build_number, body, category,
              screenshots, reporter, device_id, device)
  on public.feedback to anon;

drop policy if exists "app can insert feedback" on public.feedback;
create policy "app can insert feedback"
  on public.feedback for insert to anon with check (true);

-- No SELECT / UPDATE / DELETE policy exists, and RLS denies by default, so all
-- three are refused. This is the line that makes the shipped key safe.

-- Belt and braces: any table added to this schema later is not auto-exposed.
alter default privileges for role postgres in schema public
  revoke select, insert, update, delete on tables from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Screenshot storage — a private, write-only bucket
-- ---------------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('feedback-shots', 'feedback-shots', false, 5242880,
        array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do update set
  public             = false,
  file_size_limit    = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- `public = false` governs READS only. A private bucket still accepts an
-- anonymous INSERT when a policy allows it — which is exactly the asymmetry we
-- want: the app can upload, but nobody can browse or download without the
-- secret key.
drop policy if exists "app can upload screenshots" on storage.objects;
create policy "app can upload screenshots"
  on storage.objects for insert to anon
  with check (
    bucket_id = 'feedback-shots'
    -- First path segment must be a valid app slug, matching the table's rule.
    and (storage.foldername(name))[1] ~ '^[a-z0-9][a-z0-9._-]{1,39}$'
  );

-- Again: no SELECT policy, so the app cannot list or download anything.

-- ---------------------------------------------------------------------------
-- 4. Convenience view for triage (readable only with the secret key)
-- ---------------------------------------------------------------------------

create or replace view public.feedback_inbox as
  select id, created_at, app_id, category, status, priority,
         coalesce(reporter, 'anonymous') as reporter,
         body,
         device ->> 'model'  as device_model,
         device ->> 'os'     as os_version,
         app_version, build_number, screenshots, notes
  from public.feedback
  order by created_at desc;

revoke all on public.feedback_inbox from anon, authenticated;
