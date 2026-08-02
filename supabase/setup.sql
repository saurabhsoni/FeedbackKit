-- FeedbackKit — Supabase setup
--
-- Run this ONCE per Supabase project, in the SQL Editor.
-- It is idempotent: re-running it is safe, and re-running it after a package
-- update is how an existing project picks up new columns.
--
-- The security model, in one line: the key shipped inside the app can INSERT
-- feedback and read back only the reports it sent itself.
--
-- It still cannot SELECT this table — not one row — cannot delete, and cannot
-- write a single triage column. The insert side is enforced by three
-- independent layers (RLS default-deny, column-level grants, and PostgREST
-- returning no body), so no single mistake exposes the data.
--
-- The read side is exactly one security-definer function,
-- `feedback_for_install(p_app_id, p_device_id)`. It returns only rows whose
-- `device_id` equals a full-length install ID the caller supplies, and only a
-- safe subset of columns — never `notes`, never `reporter`, never `device`,
-- never the screenshot paths, and never another install's rows.
--
-- Why a function rather than an RLS SELECT policy: the shipped key carries no
-- JWT, so a policy has no trusted claim to scope on. `using (device_id = <a
-- value the client supplied>)` is scoped by the caller, which is not scoped at
-- all — any caller could read every row by changing a query parameter. A
-- function takes the install ID as an argument and does the filtering *inside*,
-- where the caller cannot reach it. Knowing an install ID therefore lets you
-- read that install's own reports and nothing else: the same capability model
-- as an unguessable share link.

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

  -- "Start implementing this" — the one column below that the app may write,
  -- and a request rather than a claim: the queue entry it implies is created
  -- server-side by the trigger in section 3.
  implement_requested boolean not null default false,

  -- Everything from here down is owned by the runner on the developer's
  -- machine. The app has no column grant on any of it, exactly like the triage
  -- columns above.
  work_state          text
                        check (work_state in ('queued', 'needs_approval', 'working',
                                              'implemented', 'failed', 'declined')),

  -- One sentence the runner writes for the *reporter* to read, e.g. "Added a
  -- Clear button to the note sheet." Distinct from `notes`, which stays private
  -- triage and is never returned to a client.
  work_note           text check (char_length(work_note) <= 500),

  work_branch         text check (char_length(work_branch) <= 200),
  work_commit         text check (char_length(work_commit) <= 64),
  work_error          text check (char_length(work_error) <= 2000),
  work_attempts       smallint not null default 0,
  work_started_at     timestamptz,
  work_updated_at     timestamptz,

  -- The build number that first contains the fix. The client compares this
  -- against its own CFBundleVersion to decide "implemented" vs "live for you",
  -- which is why no separate `shipped` state is needed — and why this keeps
  -- working unchanged if the app later ships via TestFlight or the App Store.
  fixed_in_build      text check (char_length(fixed_in_build) <= 20),
  installed_at        timestamptz,

  created_at   timestamptz not null default now()
);

-- On a project that already has the table, the block above does nothing at
-- all — `if not exists` skips the whole statement, columns included. So every
-- column added after the first release is repeated here, where re-running this
-- file actually applies it. Same names, same constraints as above; if you add a
-- column, add it in both places or existing projects silently miss it.
alter table public.feedback
  add column if not exists implement_requested boolean not null default false,
  add column if not exists work_state text
    check (work_state in ('queued', 'needs_approval', 'working',
                          'implemented', 'failed', 'declined')),
  add column if not exists work_note text check (char_length(work_note) <= 500),
  add column if not exists work_branch text check (char_length(work_branch) <= 200),
  add column if not exists work_commit text check (char_length(work_commit) <= 64),
  add column if not exists work_error   text check (char_length(work_error) <= 2000),
  add column if not exists work_attempts smallint not null default 0,
  add column if not exists work_started_at timestamptz,
  add column if not exists work_updated_at timestamptz,
  add column if not exists fixed_in_build text check (char_length(fixed_in_build) <= 20),
  add column if not exists installed_at timestamptz;

create index if not exists feedback_app_created_idx
  on public.feedback (app_id, created_at desc);

create index if not exists feedback_new_idx
  on public.feedback (created_at desc) where status = 'new';

-- The runner's claim query. Partial index so it stays tiny — it only ever
-- indexes the handful of rows actually waiting to be worked on.
create index if not exists feedback_work_queue_idx
  on public.feedback (created_at)
  where implement_requested and work_state in ('queued', 'needs_approval');

-- ---------------------------------------------------------------------------
-- 2. Row-level security — insert-only for the key that ships in the app
-- ---------------------------------------------------------------------------

alter table public.feedback enable row level security;

-- Start from zero rather than trusting Supabase's defaults.
revoke all on public.feedback from anon, authenticated;

-- The app may set ONLY these columns. `status`, `priority`, `notes`, `id`,
-- `created_at` and every `work_*` column are simply unreachable from a client —
-- a malicious client cannot mark its own report "done" or backdate it.
--
-- `implement_requested` is the single exception, and it is safe precisely
-- because it is a *request*: the app can ask for work to be done, but cannot
-- claim any was done. Grants are additive per column, so re-running this widens
-- an older project's grant by that one column and leaves the rest alone.
grant insert (app_id, app_version, build_number, body, category,
              screenshots, reporter, device_id, device, implement_requested)
  on public.feedback to anon;

drop policy if exists "app can insert feedback" on public.feedback;
create policy "app can insert feedback"
  on public.feedback for insert to anon with check (true);

-- No SELECT / UPDATE / DELETE policy exists, and RLS denies by default, so all
-- three are refused. This is the line that makes the shipped key safe. Read-back
-- does not go through the table at all — see section 4.

-- Belt and braces: any table added to this schema later is not auto-exposed.
alter default privileges for role postgres in schema public
  revoke select, insert, update, delete on tables from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. The toggle becomes a queue entry, server-side
-- ---------------------------------------------------------------------------
--
-- The app cannot write `work_state`, so it cannot enqueue itself. It sets the
-- boolean and the database decides what that means, which keeps the lifecycle
-- column entirely in the developer's hands. A client that omits the toggle —
-- including an older build that has never heard of it — is simply not queued.

create or replace function public.feedback_queue_on_insert()
returns trigger
language plpgsql
as $$
begin
  if new.implement_requested and new.work_state is null then
    new.work_state      := 'queued';
    new.work_updated_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists feedback_queue_on_insert on public.feedback;
create trigger feedback_queue_on_insert
  before insert on public.feedback
  for each row execute function public.feedback_queue_on_insert();

-- ---------------------------------------------------------------------------
-- 4. Read-back: one function, scoped to one install, returning safe columns
-- ---------------------------------------------------------------------------
--
-- Why a security-definer function and not an RLS SELECT policy: with the
-- shipped key there is no JWT, so a policy has no trusted claim to scope on.
-- `using (device_id = current_setting(...))` would be scoped by a value the
-- client itself supplies, i.e. not scoped at all — any caller could read every
-- row by changing a query parameter. A function takes the install ID as an
-- argument and does the filtering *inside*, where the caller cannot reach it.
--
-- The install ID is a random v4 UUID held in the app's keychain (see
-- FeedbackIdentity). Knowing one lets you read that install's own reports and
-- nothing else — the same capability model as an unguessable share link.
--
-- Note what is NOT returned: `notes` (private triage), `reporter`, `device`,
-- `device_id`, other installs' rows, and the screenshot paths (the bucket
-- stays unreadable by the app — only a count is exposed).

create or replace function public.feedback_for_install(
  p_app_id    text,
  p_device_id text
)
returns table (
  id                  uuid,
  created_at          timestamptz,
  category            text,
  body                text,
  screenshot_count    int,
  state               text,
  detail              text,
  fixed_in_build      text,
  implement_requested boolean
)
language sql
security definer
stable
set search_path = public
as $$
  select
    f.id,
    f.created_at,
    f.category,
    f.body,
    coalesce(array_length(f.screenshots, 1), 0)::int as screenshot_count,

    -- One user-facing state, derived here so every app renders the same
    -- vocabulary and no client has to know about work_state vs status.
    -- `implemented` is upgraded to "live for you" on the client, by comparing
    -- fixed_in_build against the running build.
    case
      when f.work_state = 'working'                     then 'working'
      when f.work_state in ('queued', 'needs_approval') then 'queued'
      when f.work_state = 'implemented'                 then 'implemented'
      when f.work_state = 'failed'                      then 'failed'
      when f.work_state = 'declined'                    then 'not_planned'
      when f.status     = 'wontfix'                     then 'not_planned'
      when f.status     = 'done'                        then 'implemented'
      when f.status     = 'in_progress'                 then 'working'
      else 'received'
    end as state,

    f.work_note as detail,
    f.fixed_in_build,
    f.implement_requested
  from public.feedback f
  where f.app_id = p_app_id
    and f.device_id is not null
    and f.device_id = p_device_id
    -- Refuse to answer for anything that isn't a full-length install ID, so a
    -- short or empty argument can never become a wildcard by accident.
    and char_length(p_device_id) >= 32
  order by f.created_at desc
  limit 100;
$$;

-- Postgres grants EXECUTE to PUBLIC on new functions by default. Start from
-- zero and hand it back to exactly one role.
revoke all on function public.feedback_for_install(text, text) from public;
grant execute on function public.feedback_for_install(text, text) to anon;

-- ---------------------------------------------------------------------------
-- 5. Screenshot storage — a private, write-only bucket
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

-- Again: no SELECT policy, so the app cannot list or download anything. This is
-- why the read-back in section 4 returns a screenshot *count* and not paths —
-- paths would be useless to a client that cannot fetch them, and would leak the
-- bucket's layout for nothing.

-- ---------------------------------------------------------------------------
-- 6. Convenience view for triage (readable only with the secret key)
-- ---------------------------------------------------------------------------
--
-- Carries the work columns as well, so one query answers both "what came in"
-- and "what is the runner doing about it".

create or replace view public.feedback_inbox as
  select id, created_at, app_id, category, status, priority,
         coalesce(reporter, 'anonymous') as reporter,
         body,
         device ->> 'model'  as device_model,
         device ->> 'os'     as os_version,
         app_version, build_number, screenshots, notes,
         implement_requested, work_state, work_note, work_branch, work_commit,
         work_error, work_attempts, work_started_at, work_updated_at,
         fixed_in_build, installed_at
  from public.feedback
  order by created_at desc;

revoke all on public.feedback_inbox from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Explicit grants for the secret key (service_role)
-- ---------------------------------------------------------------------------
--
-- Supabase normally auto-grants service_role full access to the public
-- schema. If you unchecked "Automatically expose new tables" when creating
-- the project (recommended — see README), that blocks service_role too, not
-- just anon/authenticated. Without this block, reading feedback back with the
-- secret key 403s with "permission denied for table feedback" even though the
-- key is correct — confirmed against a live project on 2026-07-29.
--
-- `update` is what lets both the developer and the runner write the triage and
-- `work_*` columns; nothing else in this file can write them.

grant select, update on public.feedback to service_role;
grant select on public.feedback_inbox to service_role;
grant select on storage.objects to service_role;
