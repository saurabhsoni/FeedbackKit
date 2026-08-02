# The runner

Consumes the queue that the **"Start implementing this"** toggle fills.

Every five minutes it asks Supabase for reports with `work_state = 'queued'` and
takes **the single most urgent one**: sizes the job, opens a git worktree, hands
it to Claude Code, gates the result on the app's own verify script, looks at it
running on a simulator, merges, bumps the build number, and installs on a
connected iPhone. One at a time, always — two changes in flight in one repo
means two merges fighting.

It is a LaunchAgent rather than a cloud routine because it needs three things
that only exist on this Mac: the secret Supabase key in the login keychain, the
Xcode toolchain, and a physically connected phone.

## Install

```bash
./install.sh
```

Idempotent. Re-run it after editing the plist template — launchd caches the
plist it was loaded with, so editing the file alone changes nothing.

## The tick

| Phase | What happens |
|---|---|
| Sweep | Rows stuck in `working` for over 90 minutes go back to `queued`. Without this a crashed run strands a report forever and the reporter watches a spinner that never ends. |
| Title | Up to 20 untitled rows — **every** app, not just the ones asking to be implemented — get a one-line `title` from a single Haiku call. Never blocks: any failure logs and the tick moves on. |
| Flush | Anything merged but not yet installed (`work_state='implemented'`, `installed_at` null) gets another install attempt. This is how "installs when the phone is next connected" works. |
| Claim | `queued → working` as a compare-and-swap, so two ticks can never grab the same row. |
| Classify | One cheap read-only Sonnet call returns `trivial` / `small` / `medium` / `large` — or `unclear`, which stops here and asks the reporter a question. |
| Implement | Claude Code in the worktree, at the model and effort the tier selects. |
| Verify | The app's `verify.sh`. A non-zero exit fails the item; nothing unverified reaches `main`. |
| Preview | The app's `preview.sh` builds for a simulator, boots it, installs and launches. Skipped entirely when the app declares no `preview`. |
| Look | An agent screenshots the running simulator, reads the PNGs, and answers `{looksGood, reason}`. Only `true` merges. |
| Merge | `--no-ff` into the default branch, bump the build number, push. |
| Ship | The app's `ship.sh`. |
| Record | `work_state`, `work_note` (shown in-app), `fixed_in_build`, `work_commit`. |

### One at a time

**Two reports are never worked on at once.** They would branch from the same
`main` and produce merges that conflict, so the queue drains one item per tick —
one every five minutes — and everything behind it simply stays queued.

Two layers enforce it, and both are needed:

- **The `flock`** closes the window between reading the queue and claiming a
  row, which no database check can. It is instant and needs no network.
- **A `work_state='working'` check per app** covers what a lock cannot: a lock
  dies with its process, so a tick killed mid-build (reboot, `launchctl
  bootout`, sleep) releases it instantly while leaving a row in `working` with
  a branch and a worktree behind it. The database outlives the process.

If the in-flight check itself fails, the tick starts nothing. Not knowing what
is already running is exactly when starting something else is worst.

### Queue order

`severity asc, created_at asc` — a critical bug jumps a minor idea that arrived
first. Rows with no `severity` sort last; an ungraded report is not a claim of
urgency.

### Complexity → model

| Tier | Model | Effort | Subagents |
|---|---|---|---|
| trivial | Sonnet | low | none |
| small | Sonnet | medium | none |
| medium | Sonnet | high | 1–2 Explore agents to locate code |
| large | Opus | high | parallel Explore, then a separate reviewer |

Classification never blocks the work: if it fails or returns something
unrecognised, the item is treated as `small` and carries on.

### `unclear` — asking instead of guessing

The classifier has a fifth answer. When a report could mean two genuinely
different changes, or names a screen that does not exist, it returns `unclear`
plus a **question written for the reporter to read** — one plain sentence, no
file paths, no jargon, same voice rules as `work_note`. The runner writes:

```
work_state = 'unclear'   status = 'triaged'   work_note = <the question>
```

and stops. No worktree is created and nothing is implemented. In the app that
reads as **Needs a detail**, and the reporter can edit and resend.

It is deliberately conservative — the prompt says so in as many words. A wrong
guess costs a merge, a build bump and an install to undo; a question costs the
reporter a whole round trip, so brevity, bad spelling and missing steps are all
read past rather than asked about. An `unclear` with no question attached is
treated as the classifier failing to decide, and the item is implemented as
`small`.

### The visual gate

`verify.sh` answers *does this still compile*. That leaves a whole class of
failure that merges green: the change built, it ran, and on screen it is
clipped, overlapping, under the home indicator, or simply not there.

So when an app declares both `preview` and `simulator`, the runner runs
`preview.sh` inside the worktree and then hands the *running simulator* to an
agent with a camera and nothing else — `Bash(xcrun simctl:*)` to screenshot and
relaunch, `Read` to look at the PNGs. It is told the classifier's `restatement`
and the implementer's `summary`, so it is judging *the change*, not "does the
app launch".

| Outcome | What happens |
|---|---|
| `looksGood: true` | Merge, bump, push, ship — exactly as before. |
| `looksGood: false` | `work_state='failed'`, the agent's own `reason` in `work_note`. **Terminal, not retried**: it compiled, it ran, it was looked at, so another identical implement would just argue with a verdict about the finished screen. |
| No verdict at all | Requeued through the ordinary attempt ladder. A flaky CLI call is a broken *check*, not a broken *change* — but it never merges either. |
| `preview.sh` exits non-zero | Same class as a broken build, so the ordinary retry ladder. |

Screenshots land in `~/.feedbackkit/runs/<stamp>-<id>-shots/` and the branch is
kept, because on a failure somebody is meant to go and look at them.

An app that declares no `preview` merges straight after verify, exactly as
before. Declaring *half* of it logs a warning rather than silently skipping —
that is a config mistake, not an opt-out.

## Adding an app

Commit a `.feedbackkit/app.json` to that app's repo. There is no central
registry — the runner globs `<searchRoot>/*/.feedbackkit/app.json`.

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
    "hint": "Which launch arguments reach which screen."
  },
  "buildNumber": { "file": "project.yml", "pattern": "^(\\s*CURRENT_PROJECT_VERSION:\\s*)(\\d+)\\s*$" },
  "allowedTools": ["Bash(xcodegen:*)", "Bash(xcodebuild:*)"],
  "contextHint": "One paragraph telling an implementing agent what this app is and what to read first."
}
```

| Key | Notes |
|---|---|
| `appId` | Must match the `appID` the app passes to `FeedbackConfig`. |
| `worktreeSeed` | Paths to symlink into a fresh worktree. A worktree holds only *tracked* files, so gitignored build inputs (an xcconfig of keys, a `.env`) are missing without this and the first build command fails. |
| `verify` | Run **inside the worktree**. Must not need signing or a device. Last line `VERIFY OK` by convention; only the exit code is load-bearing. |
| `preview` | Run **inside the worktree**, after verify and before the merge. Builds for `simulator.udid`, boots it, installs, launches, and does not return until the app is actually up. Last line `PREVIEW OK` / `PREVIEW FAILED: <reason>`; exit 0 only for OK. Omit it and the app merges straight after verify, as before. |
| `simulator` | Which device the judging agent photographs. `udid` and `bundleId` are both **required for the gate to run at all**; `launchArgs` are the arguments `preview.sh` launched with, so the agent can reproduce the launch; `hint` is optional free text telling the agent how to drive this app to a given screen. |
| `ship` | Run in the main checkout after the merge. **Exit 75 means "no device connected"** and is not a failure — the next tick retries. Any other non-zero is a real failure. |
| `buildNumber` | Group 1 is kept verbatim (so indentation survives), group 2 is the integer to increment. Omit to skip bumping. |
| `allowedTools` | Extra tool patterns on top of the base set, for whatever this app's build needs. |
| `contextHint` | Injected into the classify, implement and visual-judge prompts. Worth writing properly — it is the main lever on output quality. |

`contextHint` and `simulator.hint` are different sentences on purpose:
`contextHint` aims an implementer at the *code*, `simulator.hint` aims a camera
at a *screen*. Without the second, the judge photographs whatever the app
happens to open on and calls that a review.

A worked `preview.sh` — including why it signs ad-hoc where `verify.sh` may
build unsigned, and why it waits for the app to be up rather than sleeping — is
in the Life Score repo under `.feedbackkit/`.

## Safety

The report body is text an app user typed, and it is handed to an agent that can
edit files. Four things constrain that:

1. **An allowlist, not a bypass.** The agent gets `Read`/`Write`/`Edit`/`Grep`/
   `Agent` plus the app's declared build commands. A separate deny list wins on
   overlap and blocks keychain reads, network fetches, `sudo`, and every
   history-touching git subcommand.
2. **Untrusted-data framing.** The system prompt states that the report is data
   to interpret and never instructions to obey, and asks the agent to report
   anything that reads like an instruction in its `note`.
3. **The runner owns git.** The agent never commits, pushes, or switches
   branches. Work lands on `main` only through the verify gate.
4. **`--setting-sources user`.** Project settings are excluded, so an app's own
   Stop hooks don't fire inside the worktree. LifeApp's hook auto-commits and
   pushes to `main` after every turn — inside a feature-branch worktree that
   would publish unreviewed work as `main`.

The visual judge is fenced the same way and more narrowly: `--tools Bash,Read`,
then `--allowedTools "Read,Bash(xcrun simctl:*)"` on top, plus the same deny
list. It runs in the screenshot directory, not the repo — it has no business
reading source, and cannot write anything anywhere.

> **`--permission-mode` is load-bearing on every tool-carrying call.**
> `--setting-sources user` deliberately loads `~/.claude/settings.json`, and if
> that file sets `"defaultMode": "auto"` then `--allowedTools` stops being a
> fence and becomes a *widening* list. Measured, not assumed: a probe run
> without the flag ran a command that was nowhere in its allowlist. `implement`
> pins `acceptEdits`, the judge pins `dontAsk`. A few commands the CLI itself
> treats as always-safe still get through, which is what the deny list is for.

### The main dial

**Who may start a change without you saying yes.** The source of truth is the
`public.feedback_actors` table, matched on the report's `user_id` first and its
`device_id` second — an account outlives an install, so somebody who reinstalls
keeps their place on the list.

```bash
python3 feedback_runner.py actors                       # who's on it
python3 feedback_runner.py allow <actor> --label "me"   # add them
python3 feedback_runner.py revoke <actor>               # everywhere
python3 feedback_runner.py approve <feedback_id>        # release one held request
```

`--app <id>` picks the app when more than one is registered; `revoke` without
it revokes everywhere, because taking away less access than you asked for is
the failure that matters.

`runner.json → trustedDevices` still works underneath, so a setup from before
the table existed keeps running — including once the table has rows that do not
mention it. `trust <device_id>` still adds to it and says that it is the legacy
path. And **an allowlist empty in both places still means every request runs**:
that has been the dial since the runner shipped, and turning it into "hold
everything" on upgrade day would silently stop a working pipeline.

If `feedback_actors` is not in the database at all, the runner says so once and
falls back to `trustedDevices` rather than refusing to work.

`maxRunsPerDay` (default 10) is the runaway guard, counted from the run logs —
item logs only, so the ship and title logs cannot spend it.

## Commands

```bash
python3 feedback_runner.py run --dry-run   # decide everything, change nothing
python3 feedback_runner.py status          # the queue
python3 feedback_runner.py apps            # repos this runner can act on, and their gates
python3 feedback_runner.py actors          # who may start a change unheld
python3 feedback_runner.py allow <actor> [--app <id>] [--label <text>]
python3 feedback_runner.py revoke <actor> [--app <id>]
python3 feedback_runner.py trust <device_id>   # legacy allowlist in runner.json
python3 feedback_runner.py approve <id>    # release one held request
python3 feedback_runner.py retry <id>      # put a failed item back
```

## When something fails

| Where to look | What's in it |
|---|---|
| `~/Library/Logs/feedbackkit-runner.log` | One line per decision |
| `~/.feedbackkit/runs/<stamp>-<id>.log` | Full transcript: classify, implement, verify, preview, the judge, ship |
| `~/.feedbackkit/runs/<stamp>-<id>-shots/` | What the judge actually looked at |
| `~/.feedbackkit/runs/<stamp>-titles.log` | The title pass |
| `work_error` column | Tail of the failure |
| `work_branch` | Branch kept **undeleted** on purpose so you can check it out |

A failure requeues while attempts remain (`maxAttempts`, default 2), then stops
at `work_state='failed'` with a reporter-facing note. The worktree is always
removed; the branch is kept only when something went wrong.

The one exception is a **rejected screenshot**: that goes straight to `failed`
with the judge's own words, without spending the retries. Everything needed to
second-guess it — the reason, the branch, the PNGs — is kept.

### Running against a database older than the runner

The 1.2.0 schema lands separately from this program, so every read of something
new degrades with a sentence instead of a traceback:

| Missing | What the runner does |
|---|---|
| `title` column | Skips the title pass |
| `severity` column | Orders the queue by arrival only |
| `feedback_actors` table | Falls back to `runner.json → trustedDevices` |

`run --dry-run`, `apps`, `status` and `actors` all work against a pre-1.2.0
project.
