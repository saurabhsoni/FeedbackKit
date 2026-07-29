# FeedbackKit

In-app feedback for iOS apps. Shake the phone, type a sentence, send. The
screenshot of what you were looking at is already attached.

Built to be dropped into several apps at once: one Supabase project holds
feedback for all of them, and Claude Code reads it back so you can go straight
from "someone reported this" to implementing it.

```swift
ContentView()
    .feedback(FeedbackConfig(
        appID: "myeverythingapp",
        projectURL: URL(string: "https://xyz.supabase.co")!,
        publishableKey: "sb_publishable_…"
    ))
```

That single line gives you shake-to-report, the sheet, automatic screenshot
capture, photo attachments, device context, offline queueing and retry.

---

## Setup

### 1. The backend, once for all your apps

Create a free Supabase project, open the SQL Editor, and run
[`supabase/setup.sql`](supabase/setup.sql).

The security model matters here, so it's worth stating plainly: **the key that
ships inside your app can only INSERT.** It cannot read a row back, cannot
delete, and cannot write the triage columns. That's enforced by three
independent layers — RLS with no SELECT policy, column-level grants, and
PostgREST returning no body — so no single mistake exposes anyone's feedback.
Screenshots go to a private bucket with an insert-only policy.

This means the publishable key is safe to commit and safe to ship. The *secret*
key never leaves your Mac.

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

---

## Updating it across apps

Tag a release, and each app picks it up when *you* choose:

```bash
git tag 1.1.0 && git push --tags
```

```bash
xcodebuild -project YourApp.xcodeproj -scheme YourApp -resolvePackageDependencies
```

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
3. Done — it shares the same project, table and bucket.
