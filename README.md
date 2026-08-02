# FeedbackKit

In-app feedback for iOS apps. Shake the phone, type a sentence, send. The
screenshot of what you were looking at is already attached.

Built to be dropped into several apps at once: one Supabase project holds
feedback for all of them, and Claude Code reads it back so you can go straight
from "someone reported this" to implementing it.

A reporter can also flip **"Start implementing this"** on a bug or an idea,
which queues it for the runner on your Mac instead of your inbox, and the app
can show them what became of everything they sent — received, being worked on,
live in the version they're holding.

```swift
ContentView()
    .feedback(FeedbackConfig(
        appID: "myeverythingapp",
        projectURL: URL(string: "https://xyz.supabase.co")!,
        publishableKey: "sb_publishable_…"
    ))
```

That single line gives you shake-to-report, the sheet, automatic screenshot
capture, photo attachments, device context, offline queueing and retry, the
implement-on-request toggle, and the "Your feedback" status list.

---

## Setup

### 1. The backend, once for all your apps

Create a free Supabase project, open the SQL Editor, and run
[`supabase/setup.sql`](supabase/setup.sql).

The security model matters here, so it's worth stating plainly: **the key that
ships inside your app can INSERT, and can read back only the reports it sent
itself.** It cannot SELECT the table, cannot delete, and cannot write the triage
columns. The insert side is enforced by three independent layers — RLS with no
SELECT policy, column-level grants, and PostgREST returning no body — so no
single mistake exposes anyone's feedback. Screenshots go to a private bucket
with an insert-only policy.

Reading back goes through exactly one function,
`feedback_for_install(p_app_id, p_device_id)`, which returns only rows matching
a full-length install ID the caller supplies and only a safe subset of columns —
never `notes`, never `reporter` or `device`, never another install's rows. It's
a security-definer function rather than an RLS SELECT policy because the shipped
key carries no JWT: a policy would have to be scoped on a value the client
itself sent, which is not a scope at all. The function takes the install ID as
an argument and filters inside, where the caller can't reach it.

This means the publishable key is safe to commit and safe to ship. The *secret*
key never leaves your Mac.

Already have a project from an earlier version? Run `setup.sql` again — it's
idempotent, and re-running it is how an existing project picks up new columns.

### 2. Add the package

In `project.yml`:

```yaml
packages:
  FeedbackKit:
    url: https://github.com/saurabhsoni/FeedbackKit
    from: "1.0.0"

targets:
  YourApp:
    dependencies:
      - package: FeedbackKit
        product: FeedbackKit
```

Then `xcodegen generate`.

> **App target only.** Don't add it to a widget or other extension target — it
> reaches `UIApplication.shared` to find the window to screenshot. The public
> API is annotated `@available(iOSApplicationExtension, unavailable)`, so this
> is a compile error rather than a silent runtime failure.

### 3. Configure

Keep the keys out of source with a gitignored `Secrets.xcconfig`:

```
FEEDBACK_PROJECT_URL = https:/$()/xyz.supabase.co
FEEDBACK_PUBLISHABLE_KEY = sb_publishable_xxx
```

(The `$()` is how you escape `//` in an xcconfig — without it the rest of the
line is treated as a comment.)

Wire it through `project.yml` and Info.plist, then:

```swift
if let config = FeedbackConfig.fromInfoPlist(appID: "myeverythingapp") {
    ContentView().feedback(config)
} else {
    ContentView()   // misconfigured build — see below
}
```

`fromInfoPlist` returns `nil` rather than a half-built config when a key is
missing or unsubstituted, so a missing `Secrets.xcconfig` fails visibly instead
of producing a green build where feedback silently vanishes.

---

## Triggers

**Shake** works everywhere by default, including while a sheet is up.

Two detectors run behind one debounce, because neither is sufficient alone:
UIKit motion events are what the Simulator's ⌃⌘Z injects (so they're the only
testable path on a Mac) but they're delivered via the responder chain and get
skipped when nothing is focused; CoreMotion has no such hole but doesn't exist
in the Simulator.

**A button**, for a settings screen or menu:

```swift
Section {
    FeedbackButton()                                  // "Send Feedback" row
    FeedbackButton("Report a bug", systemImage: "ladybug")
}
```

**From anywhere** inside `.feedback(_:)`:

```swift
@Environment(\.openFeedback) private var openFeedback
...
Button("Something looks wrong") { openFeedback() }
```

---

## Your feedback — showing people what happened

Feedback that disappears into a form teaches people to stop sending it. The
package can show each person the reports *they* sent and what became of each
one. It needs no extra setup: the same install ID that goes out on every report
is what reads them back.

**A row**, next to the send button:

```swift
Section {
    FeedbackButton()                                   // "Send Feedback"
    FeedbackHistoryButton()                            // "Your Feedback"
    FeedbackHistoryButton("What I've reported", systemImage: "clock")
    FeedbackHistoryButton { MyOwnStyledRow() }         // any label you like
}
```

**From anywhere** inside `.feedback(_:)`:

```swift
@Environment(\.openFeedbackHistory) private var openFeedbackHistory
...
Button("Your feedback") { openFeedbackHistory() }
```

**The compose sheet links to it itself**, so you get the entry point even if you
never add a row: there's a "Your feedback" button under the form, and another on
the confirmation right after a send — which is the moment someone most wants to
see the queue they just joined.

Both sheets are presented through one `.sheet(item:)` inside `.feedback(_:)`.
That's deliberate: chaining two `.sheet(isPresented:)` on the same view is a
long-standing SwiftUI trap where the second one simply never appears. It's also
why moving between them goes through a "no sheet at all" hop rather than
swapping the item in place.

The list is read-only by construction — see the security note under Setup. It
loads once per presentation, supports pull-to-refresh, and is invalidated after
a successful send so the report you just wrote is there when you look.

---

## Implement on request

On a **bug** or an **idea** the sheet offers a toggle: *Start implementing this*.
(Not on **general** — a remark isn't a thing that can be built. Switching the
category away from bug/idea clears the toggle, so a control nobody can see can't
still be on at Send.)

The toggle sets one column, `implement_requested`. That's the only new thing the
shipped key may write, and it's safe because it's a *request*, not a claim: a
database trigger turns it into `work_state = 'queued'` server-side. The app
cannot write `work_state` at all, so no client can enqueue, re-queue, or
self-declare progress.

From there a runner on your Mac picks the row up, implements it in a git
worktree, verifies, merges, bumps the build number into `fixed_in_build`, and
installs.

### The lifecycle

`work_state` is the automation's column. The reporter never sees the word
itself — only the right-hand column:

| `work_state` | Meaning | What the reporter sees |
|---|---|---|
| `queued` | waiting for a runner | **Queued** |
| `needs_approval` | claimed, but wants a human yes first | **Queued** |
| `working` | an agent is on it | **Being worked on** |
| `implemented` | merged, with a build number recorded | **Ready in the next update** → **Live in this version** |
| `failed` | the attempt didn't survive verification | **Needs a closer look** |
| `declined` | not going to be done | **Not planned** |

A row with no `work_state` at all — anything sent without the toggle — reads as
**Received**, and your ordinary triage still shows through: `status = in_progress`
renders as **Being worked on**, `done` as implemented, `wontfix` as **Not
planned**. That mapping happens in SQL, inside `feedback_for_install`, so every
app speaks the same vocabulary and no client has to know that `status` and
`work_state` are two different columns.

### The `fixed_in_build` trick

There is no `shipped` state, and that's on purpose. When a fix merges, the
runner writes the build number it first landed in. The client compares that
against its own `CFBundleVersion` and splits `implemented` in two: *Ready in the
next update* when the reporter isn't on that build yet, *Live in this version*
when they are.

That comparison is numeric whenever both sides parse as integers — a fix marked
for build 41 is also present in 43 — and falls back to exact equality for
anything else, rather than inventing an ordering for a `1.2.3`-style string.

The nice property is that nothing has to tell the app when a build reaches
someone. The answer is computed from the binary in their hand, so it stays
correct with ad-hoc installs today and with TestFlight or the App Store later,
with no extra state and no push.

### Opting an app in

The runner discovers an app by finding **`.feedbackkit/app.json`** committed to
that app's own repo. No central registry — an app joins by adding the file, and
leaves by deleting it.

```json
{
  "appId": "lifescore",
  "defaultBranch": "main",
  "worktreeRoot": "/Users/you/Developer/.feedback-worktrees/lifescore",
  "verify": ".feedbackkit/verify.sh",
  "ship": ".feedbackkit/ship.sh",
  "buildNumber": {
    "file": "project.yml",
    "pattern": "^(\\s*CURRENT_PROJECT_VERSION:\\s*)(\\d+)\\s*$"
  },
  "contextHint": "…what an agent needs to know before touching this codebase…"
}
```

| Key | What it's for |
|---|---|
| `appId` | The slug reports arrive under — must match the `appID` you pass to `FeedbackConfig`, or the runner will never match a row to this repo. |
| `defaultBranch` | Branched from, and merged back into. |
| `worktreeRoot` | Where per-item worktrees are created. Outside the repo, so a run can't trip over your own working copy. |
| `verify` | The compile gate. Runs **inside the worktree**; must answer "does this tree still build and lint". |
| `ship` | Build and install. Runs in the **main checkout**, after the merge. |
| `buildNumber` | `{file, pattern}` — a regex with two capture groups: group 1 is everything before the number (which preserves indentation on rewrite), group 2 is the number to bump. |
| `contextHint` | What the implementing agent is told about this codebase before it starts. Worth real effort: point it at your `CLAUDE.md`, name the generated-project step if you have one, and call out the things that *look* like bugs but are deliberate. |

**`ship` exits 75 to mean "no device connected — retry later".** That is not a
failure and must not be reported as a broken build; it's the mechanism behind
*the change installs when the phone is next plugged in*. Every other non-zero
exit is a real problem (in Life Score's script: 1 = every connected device
failed to install, 2 = the build failed, 3 = preflight failed).

A worked example of all three files — `app.json`, `verify.sh`, `ship.sh` — with
the full exit-code table and the reason `verify.sh` may use
`CODE_SIGNING_ALLOWED=NO` while `ship.sh` must never copy that flag, is in the
Life Score repo under `.feedbackkit/`.

> **The runner itself is not in this repo yet.** It's pending a permission
> decision by the repo owner, so this section documents the contract an app
> commits to, not a program you can run today. Nothing in `.feedbackkit/` is
> used by the app or by a normal build, so adding the file early is harmless.
>
> Expect the key set to grow when the runner lands — an allow-list of extra
> Bash tool patterns an app's build needs is the obvious next one. The seven
> keys above are what the reference config actually carries today.

---

## Privacy

The sheet shows the user exactly what's being sent — device, system, app
version, language — in an "Also sent" row. The automatic screenshot can be
removed with one tap before sending.

Secure text fields are blacked out in captures automatically. For anything else
sensitive, mark it:

```swift
BalanceView()
    .feedbackRedact()
```

This is done explicitly rather than relying on the system: iOS's secure-layer
exclusion applies to *system* screenshots, while this renders in-process.
SwiftUI's `.privacySensitive()` doesn't help either — it only activates under
redaction reasons the system applies to widgets and the Lock Screen.

Reports carry a random per-install UUID kept in the keychain, so one person's
reports group together across the reinstalls a free Apple team forces every
seven days. It's random, never joined against anything, and not derived from
any hardware signal — `identifierForVendor` is explicitly *not* used, because
Apple rotates it on exactly those ad-hoc reinstalls.

That same ID is what reads the history list back, so treat it as a capability
rather than a label: anyone holding it can see that install's own reports and
nothing else. It stays in the keychain and is never displayed, logged, or sent
anywhere but the report itself.

Not collected: IDFA, MAC address, UDID, phone number, contacts, location,
carrier. A privacy manifest ships with the package.

---

## Offline

If a send fails for a network reason, the report is written to Application
Support and retried when the app next comes forward. The user sees success,
because it *is* success — the report is durably recorded.

A 4xx response is treated as poison and dropped rather than retried forever; a
malformed report would otherwise block everything queued behind it.

---

## Reading feedback

Set up the MCP server once:

```bash
claude mcp add --scope user --transport http supabase \
  "https://mcp.supabase.com/mcp?project_ref=<REF>&read_only=true&features=database,storage"
```

Then just ask: *"show me new feedback for myeverythingapp"*.

`read_only=true` runs every query as a read-only Postgres user, so an agent
reading your feedback can't modify it.

### Claude Code skill

A ready-made `/review-feedback` skill lives at
[`.claude/skills/review-feedback/`](.claude/skills/review-feedback/SKILL.md)
in this repo — it queries the shared backend directly (no MCP setup needed),
shows screenshots, and can triage. It's a **global** skill on purpose: which
app's project you happen to have open shouldn't change how you read feedback
that spans all of them, so it belongs in `~/.claude/skills/`, not any one
app's `.claude/skills/`.

On a machine that already has this repo cloned, link it in once:

```bash
ln -s "$(pwd)/.claude/skills/review-feedback" ~/.claude/skills/review-feedback
```

From then on, editing the skill here — `git pull`, or a local edit you
commit — is what keeps every project's `/review-feedback` in sync, the same
way updating the Swift package keeps every app's feedback *feature* in sync.
Don't copy the file into an individual app's `.claude/skills/`; that creates
a second copy that silently drifts.

---

## Updating it across apps

Tag a release, and each app picks it up when *you* choose:

```bash
git tag 1.1.0 && git push --tags
```

In Xcode: **File → Packages → Update to Latest Package Versions**.

From the command line it takes more than you'd expect, and this is worth
knowing because the obvious command quietly does nothing:

```bash
rm -f YourApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
rm -rf ~/Library/Caches/org.swift.swiftpm/repositories/FeedbackKit-*
xcodebuild -project YourApp.xcodeproj -scheme YourApp -resolvePackageDependencies
```

`-resolvePackageDependencies` on its own **honours the existing pin** — it
resolves what `Package.resolved` already says rather than looking for anything
newer. And even after deleting the pin, SPM serves a cached clone of the repo
that predates your new tag, so it re-resolves to the *same old version* and
looks like the tag never landed. Both lines above are needed. Then commit the
updated `Package.resolved`.

`from: "1.0.0"` is what makes syncing *possible*; the committed
`Package.resolved` is what stops apps drifting on their own. Note that for an
XcodeGen project `Package.resolved` lives *inside* the generated `.xcodeproj`,
which is usually gitignored — so commit it explicitly:

```gitignore
*.xcodeproj/*
!*.xcodeproj/project.xcworkspace/
*.xcodeproj/project.xcworkspace/*
!*.xcodeproj/project.xcworkspace/xcshareddata/
*.xcodeproj/project.xcworkspace/xcshareddata/*
!*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/
!*.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

Without that, every fresh clone re-resolves and you lose the pin.

Breaking API change → major version. Other apps stay on `1.x` and are
untouched until you move them.

### Working on the package itself

Point an app at your local checkout without editing the committed spec:

```yaml
# project.local.yml — gitignored
include: [project.yml]
packages:
  FeedbackKit:
    path: ../FeedbackKit
```

```bash
xcodegen generate --spec project.local.yml
```

---

## Adding a new app

1. Pick a slug (`^[a-z0-9][a-z0-9._-]{1,39}$`). No schema change needed.
2. Add the package, set `appID` to the slug.
3. Commit `.feedbackkit/app.json` to that app's repo, with `appId` set to the
   same slug — see [Opting an app in](#opting-an-app-in). Skip this if you don't
   want the app's feedback implemented on request; everything else still works.
4. Done — it shares the same project, table and bucket.
