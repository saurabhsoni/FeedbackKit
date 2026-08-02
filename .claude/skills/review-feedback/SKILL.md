---
name: review-feedback
description: Read new in-app feedback submitted by users of any app using FeedbackKit, show it with screenshots, and triage it. Use whenever the user asks what feedback has come in, wants to review feedback, or says something like "what are people saying" or "let's work through the feedback" — regardless of which project the current session is in.
---

# Review feedback

Feedback arrives from the FeedbackKit sheet inside an app (shake to open, or
a "Send Feedback" button) and lands in one Supabase project shared across
every app that uses FeedbackKit — not just the one this session happens to be
in. This is a global skill for exactly that reason: which app you're
currently working on doesn't change where the feedback lives or how to read
it.

## Credentials

Reading requires the **secret** key, which lives only on this Mac — never in
any app, repo, or xcconfig. It's in the login keychain, and is the same for
every app/project on this machine:

```bash
security find-generic-password -s feedbackkit-supabase -w
```

The project ref is stored alongside it:

```bash
security find-generic-password -s feedbackkit-project-ref -w
```

If either is missing, stop and ask — don't guess a project URL.

## Reading

Prefer the Supabase MCP server if it's connected (`read_only=true`, so it
cannot modify anything): just query the `feedback_inbox` view.

Otherwise use REST directly:

```bash
REF=$(security find-generic-password -s feedbackkit-project-ref -w)
KEY=$(security find-generic-password -s feedbackkit-supabase -w)

curl -s "https://$REF.supabase.co/rest/v1/feedback_inbox?status=eq.new&order=created_at.desc" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" | jq .
```

This returns feedback for **every** app on the shared backend, most recent
first. The `app_id` column tells you which app each row is from — if the
user only cares about the app in the current project, filter with
`&app_id=eq.<slug>`, but default to showing everything unless asked to
narrow it, since new apps get added to the same backend over time.

## What the runner is already doing

A reporter can now tick **"Start implementing this"** when sending a bug or an
idea. That sets `implement_requested`, and a database trigger queues the row by
setting `work_state = 'queued'` for a runner to pick up. `feedback_inbox`
carries the whole of that: `implement_requested`, `work_state`, `work_note`,
`work_error`, `work_branch`, `work_commit`, `work_attempts`, `work_started_at`,
`work_updated_at`, `fixed_in_build`, `installed_at` — plus `title`, a short
auto-generated summary the runner backfills onto untitled rows a few at a
time, so a very fresh row may not have one yet.

**Check this before hand-implementing anything.** A row that is queued but not
yet claimed still has `status = new`, so it shows up in the query above looking
like ordinary untouched feedback. If its `work_state` is `working`, a runner
has it right now — leave it alone rather than duplicating the work or colliding
with the branch it has open. The runner also only works one item per app at a
time and refuses to claim a second while that one is `working`, so a working
row also tells you every other queued item for the same app is just waiting,
not stuck — hand-implementing one of those yourself is safe and won't collide
with what's already in flight.

If it's `queued` and nothing is moving, that's normal: the runner is a separate
program and may not be running on this Mac at all. Implementing it by hand is
fine — just close the queue entry when you're done, or a runner that starts
later will do it again:

```bash
curl -s -X PATCH "https://$REF.supabase.co/rest/v1/feedback?id=eq.<uuid>" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"status":"done","work_state":"implemented","fixed_in_build":"<build>",
       "work_note":"<one plain sentence for the reporter>",
       "title":"<subject line, only if this row doesnt have one yet>",
       "notes":"<private detail>"}'
```

`fixed_in_build` is the `CURRENT_PROJECT_VERSION` the fix first landed in. The
app compares it against the build the person is running, so it's what turns
*Ready in the next update* into *Live in this version* on their screen. Leave it
out and the item is stuck at "ready" forever.

```bash
curl -s "https://$REF.supabase.co/rest/v1/feedback_inbox?work_state=in.(queued,needs_approval,working,failed)&order=created_at.desc&select=id,app_id,created_at,category,title,severity,severity_label,body,status,work_state,work_note,work_error,work_branch,work_attempts,fixed_in_build" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" | jq .
```

Read it as: `queued` waiting for a runner, `needs_approval` claimed but wanting
a human yes, `working` in flight right now, `failed` tried and didn't survive
verification, `implemented` merged with a build number in `fixed_in_build`,
`declined` not going to be done, `unclear` waiting on the reporter for a
detail, `superseded` replaced by a clearer rewrite. For everything ever asked
for, including what already landed, swap the filter for
`implement_requested=is.true`.

`unclear` means the classifier couldn't tell what was being asked for —
`work_note` holds a question written for the reporter, the app shows them an
**Edit and resend** button, and nothing is being worked on. You can set this
by hand too, the same way you'd set `declined`, when you want to ask a
reporter for a detail before doing anything yourself.

`superseded` means the reporter rewrote the report as a new, clearer one —
`superseded_by` points at the replacement. Don't implement a superseded row;
go read the row it points to instead.

To see everything currently waiting on a reporter's answer:

```bash
curl -s "https://$REF.supabase.co/rest/v1/feedback_inbox?work_state=eq.unclear&order=created_at.desc&select=id,app_id,created_at,category,title,body,work_note" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" | jq .
```

## Who can auto-implement

Ticking "Start implementing this" queues a row, but the runner only starts on
it without asking a human when the reporter is on the allowlist,
`public.feedback_actors` (`app_id`, `actor`, `auto_implement`, `label`,
`created_at`). `actor` is a `user_id` for apps with accounts, a `device_id`
otherwise. A non-allowlisted request still shows up as `needs_approval` rather
than sailing through `queued`.

Read it directly like any other table (needs the secret key — it's locked to
`service_role`):

```bash
curl -s "https://$REF.supabase.co/rest/v1/feedback_actors?order=app_id,created_at" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" | jq .
```

Manage it through the runner rather than editing rows by hand:

```bash
python3 feedback_runner.py actors                                  # list
python3 feedback_runner.py allow <actor> [--app <id>] [--label <text>]
python3 feedback_runner.py revoke <actor> [--app <id>]
```

The older `~/.feedbackkit/runner.json` → `trustedDevices` list still works as
a fallback — worth checking if someone's requests are auto-running and they're
not in `feedback_actors` — but `feedback_actors` is the primary source now.

## Screenshots

The bucket is private, so images need the secret key too. Paths come from the
`screenshots` array on each row.

```bash
curl -s -o /tmp/shot.jpg \
  "https://$REF.supabase.co/storage/v1/object/feedback-shots/<path>" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY"
```

Then **Read the downloaded file** — the screenshot usually answers questions
the text doesn't, and often shows the actual bug.

## How to present it

Group by app first, then by theme within each app — several people often
report one underlying problem in different words. `user_id` (present on apps
with accounts) ties one person's reports together across their devices, so
check it before assuming two reports from different devices are two different
people. For each item give the reporter, what they said, and what you think
it means in terms of the code. Point at specific files where you can, but
only if the current project is the app that item is about; don't guess at
another project's file layout from here.

`category` is `bug`, `idea`, or — from older builds still in the field —
`general`; current apps only offer bug/idea in the compose sheet, so a
`general` row isn't secretly a bug, it's just feedback sent before the picker
had categories. Lead with `severity` (1 is most severe) when deciding what to
look at first — `feedback_inbox` carries the computed `severity_label` too,
so you're reading words (Critical/Important/Minor for bugs, Major/Mid/Minor
for everything else) instead of numbers. It's also the order queued work gets
claimed in: severity ascending, then oldest first.

Then ask which to implement. Don't start changing code off the back of a
feedback item without checking — a report is a symptom, and the fix is a
design decision. If an item belongs to a different app than the one open in
this session, say so rather than trying to act on it from the wrong project.

## Triage

After acting on something, mark it so it stops reappearing. This needs the
secret key (the app's own key cannot write these columns):

```bash
curl -s -X PATCH "https://$REF.supabase.co/rest/v1/feedback?id=eq.<uuid>" \
  -H "apikey: $KEY" -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"status":"done","notes":"Fixed in <commit or description>"}'
```

Statuses: `new`, `triaged`, `in_progress`, `done`, `wontfix`.

The app now posts a local notification whenever an item's displayed state
changes, so triage flips aren't free — setting something to `wontfix` and then
changing your mind pings the reporter's phone twice. Get it right the first
time rather than toggling while you think.

### Two status columns, and how they relate

`status` is still the human triage column and still means what it always did —
it is what you write when you've dealt with something. `work_state` is the
automation's lifecycle and belongs to the runner; don't set it by hand unless
you're deliberately steering the queue (`declined` to call something off,
`queued` to hand a row over, `unclear` to ask the reporter for a detail before
anything starts).

The runner keeps `status` in step as it goes: `in_progress` while working,
`done` once implemented, `triaged` on failure — deliberately not `wontfix`,
because a failed attempt is still something to look at. That's why the
`status=eq.new` query at the top of this file keeps behaving: anything the
runner has touched has already left `new`.

### `work_note` and `title` are read by the reporter

Both are **displayed inside the app**: `work_note` on the person's own "Your
previous feedback" list, and `title` there too plus as the headline of the
local notification they get when the item's state changes (falling back to
the first ~40 characters of the body when there's no title yet). `notes` is
private triage and is never returned to any client.

So write both for them, in plain language:

- `work_note` — one plain sentence, past tense, describing what changed. No
  file paths, no symbol names, no branch names, no jargon.
- `title` — a short subject line describing what they reported, not what you
  did about it. The runner normally generates this itself in a title pass
  over new rows, so you don't usually need to touch it — but if you're
  implementing something by hand before a runner ever sees the row, set it
  too, or their list and notification fall back to the first 40 characters of
  a possibly long paragraph.

- Good `work_note`: `Added a Clear button to the note sheet.`
- Good `title`: `Note editor needs a way to clear text`
- Bad `work_note`: `Fixed in CheckInSlideRow.swift, see feedback/abc123.`

Everything else you'd want to say goes in `notes`.

## When something failed

`work_state = 'failed'` now covers three different things, and telling them
apart matters because the fix is different each time:

- **Didn't compile**, or **didn't pass lint** — the ordinary case. `work_error`
  holds the tail of the run log, which is usually the compiler or lint error
  itself and often enough on its own.
- **Didn't look right** — new: a simulator gate now runs between verify and
  merge on apps that declare a `preview` script (not all do; check
  `.feedbackkit/app.json`). An agent installs the change on the app's
  simulator, screenshots it, and judges whether it actually landed. When the
  judgement is no, there's no compiler error to show — the code built and
  linted fine and did the wrong thing. The judge's plain-language reason is in
  `work_note` instead of `work_error`, and the screenshots it took are kept in
  `~/.feedbackkit/runs/` alongside the run transcript, so you can see what the
  simulator actually showed and decide whether the judge called it right.

Two more places to look regardless of which kind:

1. **`work_branch`** — the branch was deliberately kept rather than deleted, so
   the half-finished work is there to inspect: `git log`/`git diff` it against
   the default branch before deciding whether to salvage or start over.
2. **`~/.feedbackkit/runs/`** — the full transcript of the run, when the tail
   in `work_error` (or the reason in `work_note`) isn't enough.

`work_attempts` tells you whether this has failed repeatedly. More than one or
two failures on the same item usually means the request is ambiguous rather than
hard — the useful move is to go back to what the reporter said, not to retry.

## Note on the free plan

A free Supabase project pauses after 7 days with no activity, and a paused
project silently rejects incoming feedback. A daily local check and a daily
cloud keep-alive ping already run against this project for exactly this
reason. If a submission ever seems to have vanished, check whether the
project is paused in the dashboard before assuming a bug in the app.

## Older per-app logs

Some projects kept a hand-maintained feedback log before FeedbackKit existed
(e.g. `myeverythingapp-feedback.md` in MyEverythingApp's repo root). Worth
reading for historical context on that specific app's past decisions, but new
feedback no longer goes there — it all flows through the shared backend now.
