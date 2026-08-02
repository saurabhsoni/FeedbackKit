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
implement-on-request toggle, the "Your previous feedback" status list, and a
quiet notification when something someone sent moves.

If your app knows who is using it, hand that over too and nobody has to type
their name — see [Identity](#4-identity-if-the-app-has-accounts).

---

## Setup

### 1. The backend, once for all your apps

Create a free Supabase project, open the SQL Editor, and run
[`supabase/setup.sql`](supabase/setup.sql).

The security model matters here, so it's worth stating plainly: **the key that
ships inside your app can INSERT, and can read back only the reports it sent
itself — or that the account it names sent.** It cannot SELECT the table, cannot
delete, and cannot write the triage columns. The insert side is enforced by three independent layers — RLS with no
SELECT policy, column-level grants, and PostgREST returning no body — so no
single mistake exposes anyone's feedback. Screenshots go to a private bucket
with an insert-only policy.

Reading back goes through two security-definer functions and nothing else.
`feedback_for_install(p_app_id, p_device_id, p_user_id)` returns a safe subset
of columns — never `notes`, `reporter`, `device`, `device_id`, `user_id`, or a
screenshot path — for rows matching a full-length install ID **or** a
full-length account ID the caller supplies.
`feedback_capabilities(p_app_id, p_device_id, p_user_id)` answers one boolean:
does an implement request from this person start work, or wait for you to say
yes. Functions rather than RLS SELECT policies because the shipped key carries
no JWT: a policy would have to be scoped on a value the client itself sent,
which is not a scope at all. A function takes the identifier as an argument and
filters inside, where the caller can't reach it. The length floors — 32 for an
install ID, 16 for an account ID — are what stop a short or empty argument
becoming a wildcard.

The app may write three more columns than it used to, and each is safe for a
different reason worth knowing:

| Column | Why a client may write it |
|---|---|
| `severity` | The reporter's own opinion. Worst case someone marks everything Critical, which reorders *their own* reports in a queue you still start and stop by hand — exactly as abusable as typing "URGENT" into the body. |
| `user_id` | An opaque account ID the app already holds. It only ever widens read-back to rows carrying the same ID, and reading by account ID already requires knowing it, so writing one grants nothing that knowing one didn't. It is not a login and nothing treats it as proof. |
| `clarifies` | A foreign-keyed pointer at an existing row. Pointing is harmless; what pointing *means* is decided by an after-insert trigger, which supersedes the target only when it belongs to the same install or account. Without that check the grant would let any client retire a stranger's report. |

`title` and `superseded_by` are conspicuously not granted, and must stay that
way: the runner writes the first and a trigger writes the second, so a client
cannot name its own rows in your inbox or retire them.

This means the publishable key is safe to commit and safe to ship. The *secret*
key never leaves your Mac.

> **Apply the SQL before you ship the app build, not after.** An app built
> against 1.2.0 posts `severity`, `user_id` and `clarifies` and calls
> `feedback_capabilities`; against a project that hasn't been migrated, those
> are a 400 on every send and a 404 on every capability check. Nothing degrades
> gracefully in that direction, and the failure mode is the bad one: a 400 is
> what the offline queue treats as poison, so the reports written in that
> window are dropped rather than retried. The schema is the older half of the
> pair — migrate first, ship second.

Already have a project from an earlier version? Run `setup.sql` again — it's
idempotent, and re-running it is how an existing project picks up new columns.
`supabase/migrations/` holds each release's delta on its own if you'd rather
apply just that.

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

### 4. Identity, if the app has accounts

Asking someone to type their name into a feedback form asks them for something
the app already knows, and gets a worse answer than the one it has — people
type "me", or nothing. So hand it over instead:

```swift
ContentView()
    .feedback(config, user: FeedbackUser(
        id: account?.userID,          // stable, opaque account ID
        displayName: account?.fullName
    ))
```

Both halves are optional and do different jobs.

**`displayName` removes the "Your name" field.** The section disappears from
the sheet entirely and the "Also sent" disclosure gains a `Sending as <name>`
row — hiding the field is not the same as hiding the fact. On the first launch
with a host-supplied name, the keychain's typed name is *overwritten* with it.
That is deliberate and one-way: the field that used to edit it is gone, so
leaving a stale hand-typed "s" behind would strand reports under a name nobody
remembers choosing. Sign in with Apple hands over a name exactly once and only
if the user allows it, so an app can perfectly well have an `id` and no name —
in which case the typed field comes back, exactly as before.

**`id` is what makes history follow a person.** It goes to the `user_id`
column, and `feedback_for_install` widens from "this install" to "this install
**or** this account". The install ID lives in the keychain and already survives
a reinstall; the account ID is what covers the cases it can't — a second device,
a new phone, a restore that didn't carry the keychain over.

> **`id` must be opaque, because it is a read capability.** Anyone holding it
> can read that account's feedback history. Pass Apple's `userID`, a random
> account UUID, something nobody can guess — **never an email address, a
> username, or a sequential integer**. There is no format check in the database
> to save you here; every host app's ID looks different, so the column accepts
> anything up to 128 characters. The only guard is the read function's floor of
> 16, and that exists to stop an empty argument matching everything — not to
> judge whether what you passed was guessable.

Pass the *current* value on every render rather than a snapshot taken at launch.
The modifier pushes each change through, so signing in or out mid-session
re-scopes the history list and re-tags the next report without anything being
rebuilt. With `@Observable` that means reading the store inside the `Scene` body:

```swift
.feedback(
    FeedbackConfig.fromInfoPlist(appID: "myeverythingapp"),
    user: FeedbackUser(
        id: AccountStore.shared.account?.userID,
        displayName: AccountStore.shared.account?.displayName
    )
)
```

An app with no accounts changes nothing: keep calling `.feedback(config)`, keep
the typed name field, keep grouping by install. Everything below still works.

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

## Kind and severity

The sheet asks two questions above the text box, both segmented controls.

**Kind** offers **Bug** and **Idea**, and nothing else. There used to be a
third, `general`, and it turned out to be where everything went that the
reporter couldn't be bothered to classify — which is also the one thing nothing
downstream can act on. It can't be triaged, queued or built. So it is gone from
the picker via `FeedbackCategory.selectable`, which the sheet iterates instead
of `allCases`.

The *case* stays. Builds already in the field still send `general`, the
database CHECK still accepts it, and deleting it would break decoding as well
as the public API. It survives as vocabulary for reading rather than writing —
with the display title "Feedback", because "General" reads like a label the
user chose and they didn't; an older build chose it for them.

**Severity** is three steps whose words depend on the kind:

| | 1 | 2 | 3 |
|---|---|---|---|
| Bug | Critical | Important | Minor |
| Idea | Major | Mid | Minor |

"Critical" is a real thing to say about a bug and a faintly absurd thing to say
about a feature request, so the words are a function of the category while the
*value* is what travels. Switching Bug to Idea rewrites all three labels and
leaves the selection where it was — the picker tags by value, not by position,
so the middle one stays the middle one.

`1` is most severe, which makes a plain `order by severity asc` a priority
queue: this is what the runner drains in, ahead of arrival order. Don't
renumber `FeedbackSeverity`; the raw values are the wire format. The default is
`.medium`, and a report that arrives with no severity at all — an older build,
a report queued offline before the upgrade — is filled in as 2 by the insert
trigger, so old and new sort together.

---

## Your previous feedback — showing people what happened

Feedback that disappears into a form teaches people to stop sending it. The
package can show each person the reports *they* sent and what became of each
one. It needs no extra setup: the same install ID that goes out on every report
is what reads them back, plus the account ID if you supplied one.

**A row**, next to the send button:

```swift
Section {
    FeedbackButton()                                   // "Send Feedback"
    FeedbackHistoryButton()                            // "Your Previous Feedback"
    FeedbackHistoryButton("What I've reported", systemImage: "clock")
    FeedbackHistoryButton { MyOwnStyledRow() }         // any label you like
}
```

**From anywhere** inside `.feedback(_:)`:

```swift
@Environment(\.openFeedbackHistory) private var openFeedbackHistory
...
Button("Your previous feedback") { openFeedbackHistory() }
```

**The compose sheet links to it itself**, so you get the entry point even if you
never add a row: there's a "Your previous feedback" button under the form, and
another on the confirmation right after a send — which is the moment someone
most wants to see the queue they just joined.

Both sheets are presented through one `.sheet(item:)` inside `.feedback(_:)`.
That's deliberate: chaining two `.sheet(isPresented:)` on the same view is a
long-standing SwiftUI trap where the second one simply never appears. It's also
why moving between them goes through a "no sheet at all" hop rather than
swapping the item in place.

The list is read-only by construction — see the security note under Setup. It
loads once per presentation, supports pull-to-refresh, and is invalidated after
a successful send so the report you just wrote is there when you look. Rows
carry a one-line `title` once the runner has written one; until then the body
*is* the row, which is why its line limit changes rather than a title being
faked on-device.

### Telling them when something moves

A status list nobody opens is a status list nobody reads. So every time the app
comes forward, the history is refreshed in the background, each row's pill is
diffed against a snapshot in `UserDefaults`, and anything that genuinely moved
becomes a local notification and an unread count.

`FeedbackHistoryButton` carries `.badge(unreadCount)` unconditionally — the
badge draws nothing at zero, so there is no state for you to branch on — and
opening the list clears it. The count survives a relaunch, because a change
noticed while the app was closed is exactly the case the badge exists for.

Two silences are deliberate. The **first ever run seeds the snapshot and says
nothing**, so a fresh install doesn't greet its owner with a notification per
historical report. And a row that appears for the first time against a snapshot
that already exists is one this person sent seconds ago — "Received" is not
news about a thing you just did.

> **Authorization is requested as `[.alert, .sound, .provisional]`, and only
> ever provisional.** That is what makes this safe to put in a package:
> provisional authorization is granted without showing a prompt and delivers
> quietly to Notification Centre, so adding FeedbackKit can never spend the one
> chance iOS gives your app to ask for notifications properly, and can never
> produce a permission alert you didn't design. A host app that asks for full
> authorization later is unaffected — its prompt still appears, and promoting
> the setting promotes these too. Never call `requestAuthorization` from this
> package with a non-provisional option set.

### When the report isn't clear enough to build

Triage can end in a fifth answer: **the question is asked back**. Instead of
guessing between two genuinely different changes, the classifier writes one
plain sentence for the reporter and stops — no worktree, nothing implemented.
In the app that row reads **Needs a detail**, in the one colour nothing else
uses, with the question underneath and an **Edit and resend** button.

Tapping it reopens the compose sheet prefilled with that report's body, kind and
severity, and with `clarifies` pointing at the original. On a successful send
the server supersedes the old row: it goes quiet as **Replaced** and the new one
starts again at Received. The old one is dimmed rather than hidden — seeing what
you sent before is half of understanding why the new one reads differently.

The presenter API is `presentClarification(of:)`, and the direction of the two
columns is the whole security design: the app may write `clarifies` (a pointer),
never `superseded_by` (the consequence). A trigger decides what pointing means,
and only supersedes a row belonging to the same install or account.

---

## Implement on request

On a **bug** or an **idea** the sheet offers a toggle: *Start implementing this*.
Since the picker offers nothing else, that is every report someone writes today;
the check survives for the one case that still hits it, a clarification
prefilled from a legacy `general` row. Switching to a kind that can't be built
clears the toggle, so a control nobody can see can't still be on at Send.

The toggle sets one column, `implement_requested`, and it's safe because it's a
*request*, not a claim: a database trigger turns it into `work_state = 'queued'`
server-side. The app cannot write `work_state` at all, so no client can enqueue,
re-queue, or self-declare progress.

From there a runner on your Mac picks the row up, implements it in a git
worktree, verifies, looks at it running on a simulator, merges, bumps the build
number into `fixed_in_build`, and installs. **One item at a time per app** —
two changes in flight in one repo means two merges fighting.

### The lifecycle

`work_state` is the automation's column. The reporter never sees the word
itself — only the right-hand column:

| `work_state` | Meaning | What the reporter sees |
|---|---|---|
| `queued` | waiting for a runner | **Queued** |
| `needs_approval` | claimed, but wants a human yes first | **Queued** |
| `working` | an agent is on it | **Being worked on** |
| `unclear` | triage couldn't tell what to build, and asked | **Needs a detail** |
| `superseded` | a clearer rewrite replaced it | **Replaced** |
| `implemented` | merged, with a build number recorded | **Ready in the next update** → **Live in this version** |
| `failed` | the attempt didn't survive verification, or didn't survive being looked at | **Needs a closer look** |
| `declined` | not going to be done | **Not planned** |

`unclear` and `superseded` are checked first in the mapping, ahead of the rest:
both are facts about the row itself rather than about progress, and a superseded
row may still be carrying whatever `work_state` it had before it was replaced.

A row with no `work_state` at all — anything sent without the toggle — reads as
**Received**, and your ordinary triage still shows through: `status = in_progress`
renders as **Being worked on**, `done` as implemented, `wontfix` as **Not
planned**. That mapping happens in SQL, inside `feedback_for_install`, so every
app speaks the same vocabulary and no client has to know that `status` and
`work_state` are two different columns.

### Who may start work without you

A request from anyone lands in the queue; whether it *starts* is decided by
`public.feedback_actors`, one row per `(app_id, actor)` with an
`auto_implement` flag. `actor` holds a `user_id` when the app has accounts and a
`device_id` when it doesn't — one column rather than two, because the question
is always "is this identity trusted for this app" and the answer never depends
on which kind of identity it is. Matching tries `user_id` first, because an
account outlives an install and a list that quietly forgets someone when they
reinstall is worse than no list at all.

An app with **nobody** listed still runs everything: that has been the dial
since the runner shipped, and flipping it to "hold everything" on upgrade day
would silently stop a working pipeline. Adding the first actor for an app is
what turns the list on. Once it is on, anyone not listed goes to
`needs_approval` and waits for you.

The table is locked to `service_role`, so manage it through the runner rather
than by hand:

```bash
python3 Runner/feedback_runner.py actors                       # who's on it
python3 Runner/feedback_runner.py allow <actor> --label "me"    # add them
python3 Runner/feedback_runner.py revoke <actor>                # everywhere
```

The client never reads that table. It asks `feedback_capabilities`, which
answers one boolean about an identity the caller already holds and nothing about
anyone else — no label, no other actors, not even how many there are.

**That boolean only changes one sentence of footer copy, and that is the point.**
Telling someone their request goes straight to the workshop when it is actually
going into an approval queue is a small lie the reporter discovers by watching
nothing happen. So the confident wording appears only on a *successful* yes;
unknown, offline and no all read the same cautious way, and the last successful
answer is cached so the footer doesn't visibly swap promises a second after the
sheet opens.

It is emphatically not an authorization check. The runner re-reads
`feedback_actors` server-side before it starts anything, because a client answer
could be faked by not asking.

It mirrors the runner's rule rather than reimplementing half of it, which
matters most in the case you hit first: **an app with an empty allowlist.** That
has always meant "no allowlist" rather than "hold everything" — turning it into
the latter on upgrade day would silently stop a working pipeline — so the
function answers yes there too. Leave that arm out and every reporter on a fresh
project is promised a review that never happens, which is the one lie the sheet
has no way to take back.

One gap remains, and it is deliberate: `feedback_capabilities` reads the
database, so it cannot see the legacy `runner.json → trustedDevices` list, which
lives in a file on your Mac. An app allowlisted *only* that way gets the cautious
copy while the work starts anyway — wrong in the safe direction. If you want the
footer to be accurate, express the allowlist with `allow` rather than the legacy
file.

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
  "worktreeSeed": ["Secrets.xcconfig"],
  "verify": ".feedbackkit/verify.sh",
  "preview": ".feedbackkit/preview.sh",
  "ship": ".feedbackkit/ship.sh",
  "simulator": {
    "udid": "F8028761-2B1A-430C-8145-98E0B57E254F",
    "bundleId": "in.saurabhsoni.lifescore",
    "launchArgs": ["-reset-state", "-seed-demo", "-debug-signed-in"],
    "hint": "How to drive this app to a given screen from the CLI."
  },
  "buildNumber": {
    "file": "project.yml",
    "pattern": "^(\\s*CURRENT_PROJECT_VERSION:\\s*)(\\d+)\\s*$"
  },
  "allowedTools": ["Bash(xcodegen:*)", "Bash(xcodebuild:*)"],
  "contextHint": "…what an agent needs to know before touching this codebase…"
}
```

| Key | What it's for |
|---|---|
| `appId` | The slug reports arrive under — must match the `appID` you pass to `FeedbackConfig`, or the runner will never match a row to this repo. |
| `defaultBranch` | Branched from, and merged back into. |
| `worktreeRoot` | Where per-item worktrees are created. Outside the repo, so a run can't trip over your own working copy. |
| `worktreeSeed` | Untracked files to link into a fresh worktree. A worktree holds only *tracked* files, so a gitignored build input — an xcconfig of keys, a `.env` — is simply missing and the first build command fails. |
| `verify` | The compile gate. Runs **inside the worktree**; must answer "does this tree still build and lint". |
| `preview` | The behaviour gate. Runs **inside the worktree** after verify, builds for `simulator.udid`, boots, installs and launches. Last line `PREVIEW OK` / `PREVIEW FAILED: <reason>`, exit 0 only for OK. |
| `simulator` | Which device the judging agent photographs, and how to relaunch on it. `udid` and `bundleId` are required for the gate to run at all; `launchArgs` and `hint` are how it reaches the screen the report was about. |
| `ship` | Build and install. Runs in the **main checkout**, after the merge. |
| `buildNumber` | `{file, pattern}` — a regex with two capture groups: group 1 is everything before the number (which preserves indentation on rewrite), group 2 is the number to bump. |
| `allowedTools` | Extra tool patterns on top of the runner's base set, for whatever this app's build needs. |
| `contextHint` | What the implementing agent is told about this codebase before it starts. Worth real effort: point it at your `CLAUDE.md`, name the generated-project step if you have one, and call out the things that *look* like bugs but are deliberate. |

**`ship` exits 75 to mean "no device connected — retry later".** That is not a
failure and must not be reported as a broken build; it's the mechanism behind
*the change installs when the phone is next plugged in*. Every other non-zero
exit is a real problem (in Life Score's script: 1 = every connected device
failed to install, 2 = the build failed, 3 = preflight failed).

### The visual gate is opt-in

`verify.sh` asks a compiler a question a compiler can answer. That leaves a
whole class of failure that merges green: the change built, it ran, and on
screen it is clipped, overlapping, under the home indicator, or simply not
there.

So when an app declares **both** `preview` and `simulator`, the runner puts the
build on that simulator and hands the running app to an agent with a camera and
nothing else — screenshots in, `{looksGood, reason}` out. Only a yes merges and
reaches a physical device; a no is terminal rather than retried, with the
agent's own words in `work_note` and the screenshots kept.

**An app that declares neither behaves exactly as before**: merge straight after
verify, no simulator involved, nothing to configure. Declaring *half* of it logs
a warning rather than silently skipping — that is a config mistake, not an
opt-out. This only works at all when an app is scriptable enough for an agent to
drive to the right screen, which is what `simulator.hint` is for; without it the
judge photographs whatever the app happens to open on and calls that a review.

A worked example of all four files — `app.json`, `verify.sh`, `preview.sh`,
`ship.sh` — with the full exit-code table and the reason `verify.sh` may use
`CODE_SIGNING_ALLOWED=NO` while neither of the other two may copy that flag, is
in the Life Score repo under `.feedbackkit/`.

> **The runner now lives here**, in [`Runner/`](Runner/README.md) — that README
> is the authority on the tick, the model tiering, the safety fences and the
> full `app.json` key set, and it goes into more detail than this summary.
> Nothing in `.feedbackkit/` is used by the app or by a normal build, so adding
> the file to a repo that isn't ready for a runner yet is still harmless.

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

The account ID you pass as `FeedbackUser.id` is the same kind of thing and
carries the same warning — it reads history back, so it has to be opaque. It is
the one item in the privacy manifest declared as *linked*, because it is an
account identifier by definition; everything else stays unlinked. The package
declares `NSPrivacyCollectedDataTypeUserID` for it and `CA92.1` for the
`UserDefaults` it keeps the seen-state snapshot, the unread set and the cached
allowlist answer in.

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

Everything worth reading is on the `feedback_inbox` view, including `title`,
`user_id`, `clarifies`, `superseded_by`, and a computed `severity_label` — the
words rather than the number, kept in SQL so the inbox, the runner and the
skill can never disagree about what a `1` is called.

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
git tag 1.2.0 && git push --tags
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
3. If the app has accounts, pass `.feedback(config, user:)` with an **opaque**
   account ID — see [Identity](#4-identity-if-the-app-has-accounts). If it
   doesn't, skip it; the typed name field stays.
4. Commit `.feedbackkit/app.json` to that app's repo, with `appId` set to the
   same slug — see [Opting an app in](#opting-an-app-in). Skip this if you don't
   want the app's feedback implemented on request; everything else still works.
   Add `preview` + `simulator` only if the app is scriptable enough for an agent
   to drive to a screen; omit both and it merges after verify, as before.
5. Decide who may start work unheld:
   `python3 Runner/feedback_runner.py allow <actor> --app <slug>`, where
   `<actor>` is the account ID for an app with accounts and the install ID
   otherwise. The check is per app, and an app with **nobody** listed still runs
   everything — that has been the dial since the runner shipped, and the first
   name you add is what switches the app from "everyone" to "these people".
6. Done — it shares the same project, table and bucket.
