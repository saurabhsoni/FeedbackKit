-- FeedbackKit 1.2.0 — titles, severity, account identity, clarification
--
-- Delta migration for projects that already ran an earlier setup.sql.
-- Idempotent: safe to re-run. New projects get all of this from setup.sql,
-- which carries every statement below word for word — the only difference is
-- that setup.sql folds these ADD COLUMNs into the one big ALTER TABLE that also
-- carries the pre-1.2.0 columns.
--
-- What this adds, in one line: reports gain a one-line title and a severity, a
-- person is now recognised by their *account* as well as by their install, and
-- a report that came back "we don't understand this" can be replaced by a
-- clearer one — none of which gives the shipped key a single new thing it can
-- read or claim.
--
-- Two things here are what a careless rewrite gets wrong, and neither of them
-- fails at the point of the mistake, so both are spelled out where they appear:
-- re-adding the `work_state` CHECK by name (section 1), and dropping BOTH old
-- signatures of `feedback_for_install` before creating the new one (section 5).

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------

alter table public.feedback
  -- NOT the person's words: a one-line summary the runner writes so the inbox,
  -- a status notification and a commit message have something short to show.
  -- The app has no insert grant on it — a client-written title would land in
  -- the developer's inbox and in the reporter's own notifications, so it stays
  -- server-side like every other derived value.
  add column if not exists title text check (char_length(title) <= 80),

  -- How bad it is, from the reporter: 1 = most severe, 3 = least. The *words*
  -- shown for each number depend on the category (see `severity_label` in the
  -- view, section 6); the number is what the runner's queue orders on.
  -- Deliberately no column DEFAULT — the before-insert trigger in section 4
  -- fills in 2. A DEFAULT would only apply when the column is omitted
  -- entirely, and PostgREST sends an explicit null for any key present in the
  -- JSON body, so a client that posts `"severity": null` would slip past it.
  add column if not exists severity smallint check (severity between 1 and 3),

  -- The host app's own stable account ID, which is what lets someone still see
  -- their reports after reinstalling or on a second device; null for apps that
  -- have no accounts. It is also a read capability (section 5), so it must be
  -- opaque — Sign in with Apple's `userID`, a random account UUID — and never
  -- an email address, a username or a sequential integer. Length cap only; no
  -- format check, because every host app has a different one.
  add column if not exists user_id text check (char_length(user_id) <= 128),

  -- The clarification chain, and the one place where the two directions of a
  -- relationship are deliberately in different hands. When a report comes back
  -- `unclear` and the reporter rewrites it, the NEW row carries
  -- `clarifies` = the old row's ID (the app may write this), and the
  -- after-insert trigger writes the OLD row's `superseded_by` and flips it to
  -- `work_state = 'superseded'` (the app may NOT write either). If a client
  -- could write `superseded_by` directly it could retire a stranger's report;
  -- because it can only *point at* one, the trigger gets to check ownership
  -- first. See section 4.
  --
  -- `clarifies` carries a real foreign key so it cannot dangle. `superseded_by`
  -- deliberately does not: it is written by the trigger from `new.id`, so it is
  -- a real row by construction, and a second self-FK would only add an ON
  -- DELETE rule to reason about.
  add column if not exists clarifies uuid references public.feedback(id),
  add column if not exists superseded_by uuid;

-- `work_state` gains 'unclear' (the classifier could not tell what to build and
-- has asked the reporter a question, which is in `work_note`) and 'superseded'
-- (a later report clarified this one; `superseded_by` points at the
-- replacement).
--
-- This is the statement that silently does nothing if you write it the obvious
-- way. `add column if not exists work_state text check (...)` — which is how
-- setup.sql carries this column — skips the ENTIRE clause when the column is
-- already there, inline CHECK included. The constraint would keep its old,
-- narrower definition and an insert of 'unclear' would keep failing with a
-- violation that reads like a client bug.
--
-- So drop the constraint by name and re-add it. Postgres names an inline column
-- check `<table>_<column>_check`, which is where `feedback_work_state_check`
-- comes from — the same name whether the column arrived via CREATE TABLE or via
-- ALTER TABLE, so this reaches every project. Drop-then-add is what makes it
-- idempotent (ADD CONSTRAINT has no IF NOT EXISTS).
alter table public.feedback
  drop constraint if exists feedback_work_state_check;
alter table public.feedback
  add constraint feedback_work_state_check
  check (work_state is null or work_state in
         ('queued', 'needs_approval', 'working', 'implemented', 'failed',
          'declined', 'unclear', 'superseded'));

-- Rows that predate `severity` have none, and `order by severity asc` puts
-- NULLs *last* in Postgres — so without this, every report sent before 1.2.0
-- would sort behind every report sent after it in the runner's queue. 2 is the
-- same middle value the before-insert trigger fills in from now on. Idempotent:
-- matches nothing on a second run.
update public.feedback set severity = 2 where severity is null;

-- The waiting rows in the order the runner actually claims them since 1.2.0:
-- most severe first, oldest first within a severity. Kept alongside the
-- existing `feedback_work_queue_idx` rather than replacing it, because an index
-- on (severity, created_at) cannot produce created_at order on its own, and the
-- plain created_at scan is still what "what came in first" wants.
create index if not exists feedback_work_queue_severity_idx
  on public.feedback (severity, created_at)
  where implement_requested and work_state in ('queued', 'needs_approval');

-- The title backfill pass: "give me up to 20 rows that still have no title".
-- The partial predicate is the whole point — the index holds only untitled
-- rows, so it shrinks back to nothing as fast as the pass drains it. A
-- single-column key is scannable in either direction, so this serves oldest-
-- first and newest-first equally.
create index if not exists feedback_untitled_idx
  on public.feedback (created_at) where title is null;

-- ---------------------------------------------------------------------------
-- 2. Widen what the app may write — by exactly three columns
-- ---------------------------------------------------------------------------
--
-- Grants are additive per column, so re-issuing the whole list is idempotent
-- and states the intended end state in one place instead of leaving it implied
-- by whatever earlier migrations happened to run. `title` and `superseded_by`
-- are conspicuously absent and must stay that way: both are things the server
-- concludes, not things a client gets to assert.
--
-- Why each of the writable ones is safe to hand a client:
--
--   implement_requested — a *request*, not a claim. The app can ask for work
--     to be done but cannot claim any was done; section 4 turns the boolean
--     into a queue entry server-side.
--   severity            — the reporter's own opinion of how bad it is. Worst
--     case a client marks everything 1, which reorders that client's own
--     reports in a queue the developer still starts, stops and overrides by
--     hand. Exactly as abusable as typing "URGENT" into `body`.
--   user_id             — an opaque account ID the app already holds. It only
--     ever *widens read-back to rows carrying the same ID*, and reading by
--     account ID already requires knowing that ID (section 5), so writing one
--     grants nothing that knowing one didn't. It is not a login: nothing here
--     treats it as proof of anything.
--   clarifies           — a pointer at an existing row, foreign-key checked so
--     it cannot dangle. Pointing is harmless; the consequence of pointing is
--     decided by the after-insert trigger, which supersedes the target only
--     when it belongs to the same reporter. See section 4.
grant insert (app_id, app_version, build_number, body, category,
              screenshots, reporter, device_id, device, implement_requested,
              severity, user_id, clarifies)
  on public.feedback to anon;

-- ---------------------------------------------------------------------------
-- 3. Who may start work without being asked — the actor allowlist
-- ---------------------------------------------------------------------------
--
-- The single source of truth for "may this person's implement request start
-- without the developer saying yes first". A request from anyone not listed
-- here still lands in the queue, as `needs_approval`.
--
-- `actor` holds a `user_id` when the app has accounts and a `device_id` when it
-- doesn't — one column rather than two nullable ones, because the question is
-- always the same ("is this identity trusted for this app") and the answer
-- never depends on which kind of identity it is. The primary key is what makes
-- the lookup in `feedback_capabilities` a single index probe; it needs no
-- other index.
--
-- The runner's legacy `runner.json → trustedDevices` list is still honoured as
-- a fallback, but this table is the primary and the only one a client can ask
-- about.
create table if not exists public.feedback_actors (
  app_id         text not null,
  actor          text not null,   -- user_id when the app has accounts, else device_id
  auto_implement boolean not null default false,
  label          text,            -- human note, e.g. "Saurabh — iPhone 13 Pro Max"
  created_at     timestamptz not null default now(),
  primary key (app_id, actor)
);

-- Same posture as `feedback`: nothing for the shipped key, everything for the
-- secret one. A client never reads this table directly — it asks
-- `feedback_capabilities` (section 5), which answers one boolean about an
-- identity the caller already has and nothing about anyone else.
--
-- RLS on top of the revoke is belt and braces, same as on `feedback`: if a
-- future "expose your tables" toggle hands anon a blanket grant, default-deny
-- RLS still refuses. service_role carries BYPASSRLS in Supabase, so the runner
-- and the developer are unaffected.
alter table public.feedback_actors enable row level security;
revoke all on public.feedback_actors from anon, authenticated;
grant select, insert, update, delete on public.feedback_actors to service_role;

-- ---------------------------------------------------------------------------
-- 4. Insert triggers — what the database decides for itself
-- ---------------------------------------------------------------------------
--
-- The single before-insert trigger becomes two, because they need two different
-- privilege levels and two different times. The BEFORE one only edits the row
-- being inserted, so it needs nothing special. The AFTER one writes to a
-- *different* row, which the inserting client has no grant for at all — so it
-- has to be SECURITY DEFINER, which is exactly why its WHERE clause is
-- load-bearing. Keeping them apart keeps the privileged code down to five lines
-- you can read in one go.

-- BEFORE INSERT: fill in what the client didn't send.
--
-- The app cannot write `work_state`, so it cannot enqueue itself. It sets the
-- boolean and the database decides what that means, which keeps the lifecycle
-- column entirely in the developer's hands. A client that omits the toggle —
-- including an older build that has never heard of it — is simply not queued.
--
-- Severity is defaulted here rather than with a column DEFAULT so that a client
-- posting an explicit `"severity": null` (which is what PostgREST forwards for
-- any key present in the JSON body) is normalised too, not just one that omits
-- the key. Pre-1.2.0 builds send no severity at all and land on 2, the middle.
create or replace function public.feedback_before_insert()
returns trigger
language plpgsql
as $$
begin
  if new.implement_requested and new.work_state is null then
    new.work_state      := 'queued';
    new.work_updated_at := now();
  end if;

  if new.severity is null then
    new.severity := 2;
  end if;

  return new;
end;
$$;

-- Renamed from `feedback_queue_on_insert` in 1.2.0. Drop the old trigger by
-- name — a rename is not a replace, and leaving it attached would run the
-- queueing logic twice — then drop the function it pointed at so nothing can
-- reattach a stale copy. Order matters: the trigger depends on the function.
drop trigger if exists feedback_queue_on_insert on public.feedback;
drop function if exists public.feedback_queue_on_insert();

drop trigger if exists feedback_before_insert on public.feedback;
create trigger feedback_before_insert
  before insert on public.feedback
  for each row execute function public.feedback_before_insert();

-- AFTER INSERT: a clarification retires the report it replaces.
--
-- SECURITY DEFINER because it updates a row the inserting client has no UPDATE
-- grant on and no RLS policy for — which is the whole point (the app may point
-- at a row, the database decides what pointing means), and also the reason the
-- WHERE clause below is security-critical rather than cosmetic.
--
-- Without `and f.app_id = ...` and the identity check, the app's own insert
-- grant on `clarifies` would be enough for any client to mark ANY report in the
-- database superseded — a stranger's bug report, in another app, silently
-- retired by inserting one row. The guard reduces that to "you may retire a row
-- that this install or this account sent", which is the same scope the read-back
-- function already enforces. Do not relax it; it is not a nicety.
--
-- `set search_path = public` for the usual SECURITY DEFINER reason: without it,
-- a caller-controlled search_path could resolve `feedback` to a table they own.
--
-- PUBLIC keeps its default EXECUTE on this function and that is harmless — a
-- plpgsql trigger function invoked as an ordinary function raises "trigger
-- functions can only be called as triggers" before it runs a line, so there is
-- no elevated path here for anyone to call.
create or replace function public.feedback_after_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.clarifies is not null then
    update public.feedback f
       set work_state      = 'superseded',
           superseded_by   = new.id,
           -- Nudge an untouched row to 'triaged' so it leaves the "new" inbox,
           -- but never walk back a decision the developer already made.
           status          = case when f.status in ('new', 'triaged')
                                  then 'triaged' else f.status end,
           work_updated_at = now()
     where f.id     = new.clarifies
       and f.app_id = new.app_id
       and (f.device_id = new.device_id
            or (new.user_id is not null and f.user_id = new.user_id));
  end if;

  -- AFTER-trigger return values are ignored; null is the convention.
  return null;
end;
$$;

drop trigger if exists feedback_after_insert on public.feedback;
create trigger feedback_after_insert
  after insert on public.feedback
  for each row execute function public.feedback_after_insert();

-- ---------------------------------------------------------------------------
-- 5. Read-back: security-definer functions, scoped to one install or account
-- ---------------------------------------------------------------------------
--
-- Why a security-definer function and not an RLS SELECT policy: with the
-- shipped key there is no JWT, so a policy has no trusted claim to scope on.
-- `using (device_id = current_setting(...))` would be scoped by a value the
-- client itself supplies, i.e. not scoped at all — any caller could read every
-- row by changing a query parameter. A function takes the install ID as an
-- argument and does the filtering *inside*, where the caller cannot reach it.
--
-- Since 1.2.0 the scope is "this install OR this account", so that reinstalling
-- or signing in on a second device no longer loses your history. The account ID
-- joins the same capability model, which is why the host app must supply an
-- opaque one. The length floors below are what stop a short or empty argument
-- becoming a wildcard: 32 for an install ID (a UUID with or without dashes), 16
-- for an account ID, which is the shortest thing that can plausibly carry
-- enough entropy to be a capability at all.
--
-- Note what is NOT returned: `notes` (private triage), `reporter`, `device`,
-- `device_id`, `user_id`, other installs' and accounts' rows, and the
-- screenshot paths (the bucket stays unreadable by the app — only a count is
-- exposed).

-- The argument list changed in 1.2.0, so `create or replace` is not enough:
-- replacing a function cannot add a parameter, and creating the new one beside
-- the old would leave two candidates that a two-argument PostgREST call matches
-- equally well ("could not choose a best candidate function"). Drop both
-- possible signatures first — the pre-1.2.0 one and the current one — so
-- exactly one ever exists.
drop function if exists public.feedback_for_install(text, text);
drop function if exists public.feedback_for_install(text, text, text);

create function public.feedback_for_install(
  p_app_id    text,
  p_device_id text,
  -- Defaulted, so a client build that predates 1.2.0 keeps working unchanged:
  -- it posts two arguments and PostgREST still resolves this function.
  p_user_id   text default null
)
returns table (
  id                  uuid,
  created_at          timestamptz,
  category            text,
  title               text,
  body                text,
  severity            smallint,
  screenshot_count    int,
  state               text,
  detail              text,
  fixed_in_build      text,
  implement_requested boolean,
  superseded_by       uuid
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
    f.title,
    f.body,
    f.severity,
    coalesce(array_length(f.screenshots, 1), 0)::int as screenshot_count,

    -- One user-facing state, derived here so every app renders the same
    -- vocabulary and no client has to know about work_state vs status.
    -- `implemented` is upgraded to "live for you" on the client, by comparing
    -- fixed_in_build against the running build.
    --
    -- `superseded` and `unclear` come first on purpose: both are about the row
    -- itself rather than about progress, and a superseded row may still carry
    -- whatever work_state it had before it was replaced.
    case
      when f.work_state = 'superseded'                  then 'superseded'
      when f.work_state = 'unclear'                     then 'unclear'
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

    -- For an `unclear` row this is the question the reporter needs to answer,
    -- which is why `work_note` is written in the second person.
    f.work_note as detail,
    f.fixed_in_build,
    f.implement_requested,
    -- Safe to return: it is an ID of a row the same caller already owns, so it
    -- reveals nothing they cannot already read.
    f.superseded_by
  from public.feedback f
  where f.app_id = p_app_id
    and (
          -- Refuse to answer for anything that isn't a full-length identifier,
          -- so a short or empty argument can never become a wildcard by
          -- accident. A null argument fails its arm here too: char_length(null)
          -- is null, and null is not true.
          (f.device_id is not null and f.device_id = p_device_id
           and char_length(p_device_id) >= 32)
       or (p_user_id is not null and char_length(p_user_id) >= 16
           and f.user_id is not null and f.user_id = p_user_id)
        )
  order by f.created_at desc
  limit 100;
$$;

-- Postgres grants EXECUTE to PUBLIC on new functions by default. Start from
-- zero and hand it back to exactly one role.
revoke all on function public.feedback_for_install(text, text, text) from public;
grant execute on function public.feedback_for_install(text, text, text) to anon;

-- Does this person get to start work without the developer approving it first?
--
-- The app asks before it shows the "start implementing this" toggle as a plain
-- switch rather than as a request, so the UI can stop promising something the
-- backend will only queue for approval.
--
-- This does let a caller probe whether an ID they already hold is allowlisted,
-- and that is acceptable: both IDs are unguessable capabilities already (same
-- length floors as above), so the only question anyone can ask is one about
-- themselves. It answers a single boolean and never returns the label, the
-- app's other actors, or how many there are. It is emphatically NOT an
-- authorisation check — the runner re-checks this table server-side before it
-- starts anything, because a client answer could be faked by not asking.
create or replace function public.feedback_capabilities(
  p_app_id    text,
  p_device_id text,
  p_user_id   text default null
)
returns table (auto_implement boolean)
language sql
security definer
stable
set search_path = public
as $$
  -- Two ways to be allowed, and the second one is the whole subtlety.
  --
  -- `exists` always produces exactly one row, so the caller gets `false`
  -- rather than an empty result when nothing matches.
  select (
    exists (
      select 1
      from public.feedback_actors a
      where a.app_id = p_app_id
        and a.auto_implement
        and (
              (p_user_id is not null and char_length(p_user_id) >= 16
               and a.actor = p_user_id)
           or (p_device_id is not null and char_length(p_device_id) >= 32
               and a.actor = p_device_id)
            )
    )
    -- …or this app has no allowlist at all. An empty allowlist has meant "no
    -- allowlist", not "hold everything", since the runner shipped, and this
    -- function exists solely to tell the sheet what the runner is going to do.
    -- Leave this arm out and every reporter on a fresh project is promised a
    -- review that never happens: `actor_allowed()` in the runner starts the
    -- work immediately. Wrong in the safe direction, but still a lie, and the
    -- one the sheet is least able to recover from.
    or not exists (
      select 1
      from public.feedback_actors a
      where a.app_id = p_app_id and a.auto_implement
    )
  ) as auto_implement;
$$;

revoke all on function public.feedback_capabilities(text, text, text) from public;
grant execute on function public.feedback_capabilities(text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 6. Triage view — surface the new columns for the developer
-- ---------------------------------------------------------------------------
--
-- Dropped and recreated rather than `create or replace`d: replacing a view can
-- only append columns to the end of the existing list, and `title` and
-- `severity_label` belong next to the things they describe, not bolted on
-- after `installed_at`. Dropping is safe here because the grants are reissued
-- immediately below and nothing else in the database depends on this view — it
-- exists for the developer, the runner and the /review-feedback skill, all of
-- which reach it over PostgREST by name.
drop view if exists public.feedback_inbox;
create view public.feedback_inbox as
  select id, created_at, app_id, category, status, priority,
         coalesce(reporter, 'anonymous') as reporter,
         title,
         body,
         severity,
         -- The words, not the number, because a human reads this view and 1
         -- means different things in a bug and in an idea. Kept here rather
         -- than in the client so the inbox, the runner and the skill can never
         -- disagree about what a 1 is called. Null only for a row somehow
         -- carrying no severity at all — the backfill and the trigger in
         -- section 4 between them mean that should not happen.
         case
           when severity is null then null
           when category = 'bug' then
             case severity when 1 then 'Critical'
                           when 2 then 'Important'
                           else        'Minor' end
           else
             case severity when 1 then 'Major'
                           when 2 then 'Mid'
                           else        'Minor' end
         end as severity_label,
         device ->> 'model'  as device_model,
         device ->> 'os'     as os_version,
         app_version, build_number, screenshots, notes,
         user_id, clarifies, superseded_by,
         implement_requested, work_state, work_note, work_branch, work_commit,
         work_error, work_attempts, work_started_at, work_updated_at,
         fixed_in_build, installed_at
  from public.feedback
  order by created_at desc;

-- DROP VIEW takes the old grants with it, so these are not decoration.
revoke all on public.feedback_inbox from anon, authenticated;
grant select on public.feedback_inbox to service_role;

-- Supabase reloads PostgREST's schema cache from a DDL event trigger, so this
-- is usually redundant. It is here for the one case where it isn't: a function
-- whose signature changed (section 5) answers 404 "Could not find the function
-- … in the schema cache" until the cache catches up, which reads exactly like a
-- typo in the client. Harmless to send twice.
notify pgrst, 'reload schema';
