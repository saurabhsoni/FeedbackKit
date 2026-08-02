-- FeedbackKit — "start implementing this" + user-visible status
--
-- Delta migration for projects that already ran an earlier setup.sql.
-- Idempotent: safe to re-run. New projects get all of this from setup.sql,
-- which carries the same statements.
--
-- What this adds, in one line: the app may now ask for a report to be worked
-- on, and may read *its own* reports back to show progress — without gaining
-- the ability to read anyone else's row or write a single triage column.

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------

alter table public.feedback
  -- The only new column the app is allowed to write: the toggle.
  add column if not exists implement_requested boolean not null default false,

  -- Everything below is owned by the runner on the developer's machine. The
  -- app cannot write any of it (no column grant), exactly like status/notes.
  add column if not exists work_state text
    check (work_state in ('queued', 'needs_approval', 'working',
                          'implemented', 'failed', 'declined')),

  -- One sentence the runner writes for the *reporter* to read, e.g.
  -- "Added a Clear button to the note sheet." Distinct from `notes`, which
  -- stays private triage and is never returned to a client.
  add column if not exists work_note text check (char_length(work_note) <= 500),

  add column if not exists work_branch text check (char_length(work_branch) <= 200),
  add column if not exists work_commit text check (char_length(work_commit) <= 64),
  add column if not exists work_error   text check (char_length(work_error) <= 2000),
  add column if not exists work_attempts smallint not null default 0,
  add column if not exists work_started_at timestamptz,
  add column if not exists work_updated_at timestamptz,

  -- The build number that first contains the fix. The client compares this
  -- against its own CFBundleVersion to decide "implemented" vs "live for you",
  -- which is why no separate `shipped` state is needed — and why this keeps
  -- working unchanged if the app later ships via TestFlight or the App Store.
  add column if not exists fixed_in_build text check (char_length(fixed_in_build) <= 20),
  add column if not exists installed_at timestamptz;

-- The runner's claim query. Partial index so it stays tiny.
create index if not exists feedback_work_queue_idx
  on public.feedback (created_at)
  where implement_requested and work_state in ('queued', 'needs_approval');

-- ---------------------------------------------------------------------------
-- 2. Let the app set the toggle — and only the toggle
-- ---------------------------------------------------------------------------
--
-- Grants are additive per column, so this widens the existing insert grant by
-- exactly one column and leaves the rest of the security model untouched.

grant insert (implement_requested) on public.feedback to anon;

-- The app cannot write `work_state`, so the queue entry is created server-side
-- from the toggle. A client that omits the toggle is simply not queued.
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
-- 3. Read-back: one function, scoped to one install, returning safe columns
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
-- 4. Triage view — surface the new columns for the developer
-- ---------------------------------------------------------------------------

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
grant select on public.feedback_inbox to service_role;
