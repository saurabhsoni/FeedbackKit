# Changelog

Notable changes per version, newest first. Versions match the git tags apps
resolve against; up to 1.0.3 the release note lived in the tag message alone
(`git tag -n9`), and those entries are reproduced here.

Anything under **Upgrading** needs an action from you — usually re-running
`supabase/setup.sql`, which is idempotent.

## 1.2.0 — 2026-08-03

Nobody types their name any more, a report can be graded and titled, and a
report nobody understood gets a question back instead of a guess.

### Added

- **`FeedbackUser` and `.feedback(_:user:)`.** The host app supplies identity
  instead of asking for it. A non-empty `displayName` removes the "Your name"
  field from the sheet entirely and adds a `Sending as <name>` row to the "Also
  sent" disclosure; an `id` goes to the new `user_id` column. Both halves
  optional, both pushed through on change, so signing in or out mid-session
  re-scopes the history and re-tags the next report without anything being
  rebuilt. The one-argument `feedback(_:)` still exists and forwards `nil`, so
  an app with no accounts is untouched.
- **History scoped to "this install *or* this account".**
  `feedback_for_install` takes a third argument, `p_user_id`, with its own
  length floor (16, against the install ID's 32). The install ID already
  survived a reinstall; the account ID is what covers a second device or a
  keychain the OS didn't carry over.
- **`FeedbackSeverity`** — `high`/`medium`/`low` as `1`/`2`/`3`, rendered as a
  segmented control whose words follow the category (Critical/Important/Minor
  for a bug, Major/Mid/Minor for an idea). `1` is most severe, which makes
  `order by severity asc` the runner's priority queue. Defaults to `.medium`,
  and the before-insert trigger fills in `2` for anything that arrives without
  one.
- **`title`** — a one-line summary the runner writes with a cheap model, in one
  call for up to 20 untitled rows. The client never writes it; there is no
  insert grant, so a client cannot name its own rows in your inbox or in
  someone's notifications. The history list leads with it when present, and
  falls back to the body rather than faking one on-device.
- **`unclear` and `superseded`.** Triage can ask the reporter a question instead
  of guessing: `work_state = 'unclear'`, the question in `work_note`, and no
  worktree created. The row reads **Needs a detail** with an **Edit and resend**
  button, which opens the compose sheet prefilled and carrying
  `clarifies = <old id>`; an after-insert trigger then supersedes the original,
  which reads **Replaced**. `presentClarification(of:)` is the presenter API.
- **`FeedbackStatusWatcher`** — local notifications and an unread badge when a
  report's state changes, diffed against a snapshot in `UserDefaults`
  (`feedbackkit.seenStates.v1`). No push, no server, no device token.
  `FeedbackHistoryButton` carries `.badge(unreadCount)` unconditionally, and
  opening the list clears it. **Authorization is requested as `[.alert, .sound,
  .provisional]` and only ever provisional**, so adding this package can never
  spend an app's one chance to ask for notifications properly and can never
  produce a permission prompt the integrator didn't design.
- **`public.feedback_actors`** — the allowlist deciding whose implement request
  starts without a human yes, keyed `(app_id, actor)` where `actor` is a
  `user_id` or a `device_id`. Locked to `service_role`; managed with the
  runner's new `actors`, `allow` and `revoke` subcommands. An app with nobody
  listed still runs everything, unchanged.
- **`public.feedback_capabilities(p_app_id, p_device_id, p_user_id)`** — one
  boolean, granted to `anon`, so the sheet's footer can stop promising work
  starts immediately when it is actually going to an approval queue. Only a
  successful `true` changes the copy; unknown, offline and no all read the same
  cautious way. It mirrors the runner's rule including the empty-allowlist case,
  so a fresh project doesn't promise every reporter a review that never happens;
  the one thing it cannot see is the legacy `runner.json → trustedDevices` file.
  Not an authorization check — the runner re-reads the table server-side.
- **The visual gate, opt-in per app.** `.feedbackkit/app.json` gains `preview`
  (a script in `verify.sh`'s shape, last line `PREVIEW OK` / `PREVIEW FAILED:
  <reason>`) and `simulator` (`udid`, `bundleId`, `launchArgs`, `hint`). After
  verify and before merge, the runner puts the build on that simulator and an
  agent screenshots it and answers `{looksGood, reason}`. Only a yes merges and
  installs. **An app declaring neither behaves exactly as before**; declaring
  half logs a warning rather than silently skipping.
- `feedback_inbox` gains `title`, `severity`, `user_id`, `clarifies`,
  `superseded_by` and a computed `severity_label` — the words, not the number,
  kept in SQL so the inbox, the runner and `/review-feedback` can't disagree
  about what a `1` is called.

### Changed

- **The compose sheet offers `bug` and `idea` only.** `FeedbackCategory.general`
  stays in the enum (older builds still send it, the database CHECK still
  accepts it, removing the case would break decoding *and* the public API) but
  is gone from the picker via the new `FeedbackCategory.selectable`, which the
  sheet iterates instead of `allCases`. Its display title is now "Feedback",
  since "General" reads like a label the reporter chose and they didn't. The
  default category is `.bug`, was `.general`.
- **Every user-facing "Your feedback" is now "Your previous feedback"** — the
  history view's navigation title, the compose sheet's link row, the post-send
  confirmation's link, and `FeedbackHistoryButton`'s default title, which is
  now `"Your Previous Feedback"`. If you passed your own title, nothing changes.
- The insert grant for `anon` widened by exactly three columns: `severity`,
  `user_id`, `clarifies`. `title` and `superseded_by` are deliberately still
  ungranted — both are things the server concludes, not things a client
  asserts. `clarifies` is a pointer only; the after-insert trigger supersedes
  the target *only* when it belongs to the same install or account, which is
  what stops a client retiring a stranger's report.
- `feedback_queue_on_insert` split into `feedback_before_insert` (queueing plus
  the severity default) and `feedback_after_insert` (the supersede, `security
  definer` because it writes a different row).
- The runner processes **one item at a time, per app**, and refuses to claim a
  second while one is `working`. Queue order is `severity asc, created_at asc`.
- The privacy manifest declares `NSPrivacyCollectedDataTypeUserID` — the only
  *linked* item in it, since it is an account identifier by definition — and
  `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1`.
- `/review-feedback` knows about titles, severity labels, `unclear`,
  `superseded`, `feedback_actors`, and the runner's one-at-a-time rule.

### Upgrading

**This release requires a schema change, and it has to land first.** An app
built against 1.2.0 posts `severity`, `user_id` and `clarifies` and calls
`feedback_capabilities`; against an un-migrated project every send is a 400 and
every capability check a 404. Nothing degrades in that direction, and the 400 is
the expensive part: the offline queue treats 4xx as poison and drops the report
rather than retrying it, so reports written in that window are lost. Apply the
SQL, *then* ship the build.

Run `supabase/setup.sql` again (idempotent), or
`supabase/migrations/2026-08-03-titles-severity-identity.sql` for the delta
alone. Three things in it are easy to get wrong by hand and fail somewhere other
than where the mistake is:

- The `work_state` CHECK does **not** widen by itself. `add column if not
  exists` skips the entire clause — inline CHECK included — on a table that
  already has the column, so `'unclear'` keeps failing with a violation that
  reads like a client bug. It has to be dropped by name and re-added.
- `feedback_for_install` gained an argument, so `create or replace` cannot do
  it. Both the two- and three-argument signatures are dropped first, or
  PostgREST has two equally good candidates and answers "could not choose a best
  candidate function".
- Rows predating `severity` are backfilled to `2`. Without that,
  `order by severity asc` sorts NULLs *last* in Postgres and every pre-1.2.0
  report would queue behind every newer one.

The runner degrades rather than crashing against a database that hasn't been
migrated yet: no `title` column skips the title pass, no `severity` orders by
arrival, no `feedback_actors` falls back to `runner.json → trustedDevices`.

**Reports queued offline by 1.1.x still send.** `FeedbackReport` now has a
hand-written `init(from:)` that reads every field added in 1.2.0 with
`decodeIfPresent` and a default matching what the server would have applied
anyway. This is the fix for what 1.1.0 did silently — see its note below — and
the rule from here on: a new field on that type must never make an older
build's queued envelope undecodable.

The old `.feedback(_:)` call sites need no change. `FeedbackHistoryButton()`
with no arguments changes its visible title.

**No public symbol was removed, but two public enums gained cases** —
`FeedbackHistoryItem.State` and `FeedbackHistoryItem.DisplayState` both gained
`unclear` and `superseded`. That is source-breaking for anyone switching over
them exhaustively in their own code. Nothing in the package requires you to;
`DisplayState.title` is now public precisely so the pill words can be read
rather than re-derived.

## 1.1.3

Stop a locked keychain wedging the runner forever. `security
find-generic-password` blocks indefinitely waiting for a dialog nobody under
launchd will ever see, and `subprocess.run(timeout=)` couldn't save it — it
kills the child, then blocks in `communicate()` on a grandchild still holding
the pipe. The runner owns the process group now and treats a hang as a missing
secret, so the tick fails loudly and retries instead of wedging until reboot.

## 1.1.2

Worktree seeding and diagnosable timeouts, both from the first real run against
a live app, which timed out after 20 minutes and merged nothing.

A fresh worktree contains only *tracked* files, so a gitignored build input
(LifeApp's `Secrets.xcconfig`) simply isn't there and the very first command of
the verify gate fails. Apps now declare **`worktreeSeed`** and the runner
symlinks those paths in — symlinks rather than copies, because a secret should
exist in one place.

The reason that took so long to find: piped stdout died with the process on
timeout, so a wedged build and a slow one looked identical. Output now streams
into the run log as it happens. Also: classify retries once, and the
unstructured-output fallback no longer defaults `succeeded` to true.

## 1.1.1

The runner itself, in [`Runner/`](Runner/README.md) — no longer "not in this
repo yet". A LaunchAgent that every five minutes claims a queued report as a
compare-and-swap, sizes it with one cheap read-only call, implements it in a
throwaway git worktree, gates on the app's own `verify.sh`, merges `--no-ff`,
bumps the build number into `fixed_in_build`, and installs on a connected
phone. Apps opt in by committing `.feedbackkit/app.json` to their own repo.

## 1.1.0

Feedback can now ask to be *implemented*, and the person who sent it can see
what happened to it.

### Added

- **"Start implementing this"** toggle in the compose sheet, offered on `bug`
  and `idea` (not `general` — a remark isn't a thing that can be built).
  Changing the category away from bug/idea clears it, so a control nobody can
  see can't still be on at Send.
- **`implement_requested`** column, the one new thing the shipped key may write.
  It's a request, never a claim: a `before insert` trigger turns it into
  `work_state = 'queued'` server-side, and the app still cannot write
  `work_state`.
- **The work columns** the runner owns — `work_state`, `work_note`,
  `work_branch`, `work_commit`, `work_error`, `work_attempts`,
  `work_started_at`, `work_updated_at`, `fixed_in_build`, `installed_at` — plus
  a partial index for the runner's claim query. No column grant on any of them,
  exactly like the existing triage columns.
- **Read-back**, via one security-definer function
  `public.feedback_for_install(p_app_id, p_device_id)`. It returns only rows
  matching a full-length install ID the caller supplies, and only a safe subset
  of columns — never `notes`, `reporter`, `device`, or screenshot paths. A
  function rather than an RLS SELECT policy because the shipped key carries no
  JWT, so a policy could only be scoped on a value the client itself sent, which
  is not a scope at all.
- **`FeedbackHistoryButton()`** and **`@Environment(\.openFeedbackHistory)`**,
  presenting the list of this install's own reports with a status on each. The
  compose sheet links to it too, both under the form and on the confirmation
  right after a send.
- **`fixed_in_build`**, which the client compares against its own
  `CFBundleVersion` to split "implemented" into *Ready in the next update* and
  *Live in this version*. Numeric comparison when both sides parse as integers,
  exact match otherwise. This is why there is no separate `shipped` state, and
  why nothing needs to change when an app later ships via TestFlight or the App
  Store.
- **`.feedbackkit/app.json`** as the per-app opt-in contract for the runner —
  see the README. The runner itself is not in this repo yet.

### Changed

- `feedback_inbox` now also selects all of the columns above, so one query
  answers both "what came in" and "what is being done about it".
- The `insert` grant for `anon` widened by exactly one column,
  `implement_requested`.
- The one-line security model in `setup.sql` and the README was rewritten: the
  shipped key still cannot read the table, but "cannot read a single row back"
  is no longer accurate now that one scoped function exists.
- `/review-feedback` knows about the two status columns, how the runner keeps
  `status` in step, and that `work_note` is reporter-facing.

### Upgrading

Re-run `supabase/setup.sql` on the existing project — it is idempotent, and the
new columns are repeated in an `alter table ... add column if not exists` block
precisely because `create table if not exists` does nothing on a table that
already exists. `supabase/migrations/2026-08-02-implement-requests.sql` is the
same delta on its own if you'd rather apply just that.

**One-time effect on upgrade: queued offline reports from an older build are
dropped.** `FeedbackReport` gained a non-optional `implementRequested` field, so
a report sitting in the on-disk offline queue and encoded by a previous build no
longer decodes. `FeedbackQueue.drain()` already handles that — an envelope it
cannot read is deleted rather than left to wedge the head of the queue forever —
so the effect is silent and self-clearing, but a report that was still waiting to
send when the user updated will not arrive. This only touches reports that had
not yet reached the server; anything already sent is unaffected.

## 1.0.3

Fix missing `service_role` grants in `setup.sql`. Reading feedback back with the
secret key 403'd with "permission denied for table feedback" on any project
created with "Automatically expose new tables" unchecked.

Also: corrected the cross-app update instructions — `-resolvePackageDependencies`
on its own honours the existing pin and quietly does nothing.

## 1.0.2

Real tests, runnable on an iOS simulator destination.

## 1.0.1

Lint clean. No behaviour change.

## 1.0.0

Shake-to-report feedback for iOS apps: the sheet, automatic screenshot capture,
photo attachments, device context, redaction, offline queueing and retry, and a
Supabase backend shared across every app.
