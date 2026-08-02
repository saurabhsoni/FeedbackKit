# Changelog

Notable changes per version, newest first. Versions match the git tags apps
resolve against; up to 1.0.3 the release note lived in the tag message alone
(`git tag -n9`), and those entries are reproduced here.

Anything under **Upgrading** needs an action from you — usually re-running
`supabase/setup.sql`, which is idempotent.

## 1.1.0 — unreleased

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
