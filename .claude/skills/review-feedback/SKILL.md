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
report one underlying problem in different words. For each item give the
reporter, what they said, and what you think it means in terms of the code.
Point at specific files where you can, but only if the current project is the
app that item is about; don't guess at another project's file layout from
here.

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
