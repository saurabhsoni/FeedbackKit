# The runner

Consumes the queue that the **"Start implementing this"** toggle fills.

Every five minutes it asks Supabase for reports with `work_state = 'queued'`,
and for each one: sizes the job, opens a git worktree, hands it to Claude Code,
gates the result on the app's own verify script, merges, bumps the build number,
and installs on a connected iPhone.

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
| Flush | Anything merged but not yet installed (`work_state='implemented'`, `installed_at` null) gets another install attempt. This is how "installs when the phone is next connected" works. |
| Claim | `queued → working` as a compare-and-swap, so two ticks can never grab the same row. |
| Classify | One cheap read-only Sonnet call returns `trivial` / `small` / `medium` / `large`, plus a restatement of what the person is actually asking for. |
| Implement | Claude Code in the worktree, at the model and effort the tier selects. |
| Verify | The app's `verify.sh`. A non-zero exit fails the item; nothing unverified reaches `main`. |
| Merge | `--no-ff` into the default branch, bump the build number, push. |
| Ship | The app's `ship.sh`. |
| Record | `work_state`, `work_note` (shown in-app), `fixed_in_build`, `work_commit`. |

### Complexity → model

| Tier | Model | Effort | Subagents |
|---|---|---|---|
| trivial | Sonnet | low | none |
| small | Sonnet | medium | none |
| medium | Sonnet | high | 1–2 Explore agents to locate code |
| large | Opus | high | parallel Explore, then a separate reviewer |

Classification never blocks the work: if it fails or returns something
unrecognised, the item is treated as `small` and carries on.

## Adding an app

Commit a `.feedbackkit/app.json` to that app's repo. There is no central
registry — the runner globs `<searchRoot>/*/.feedbackkit/app.json`.

```json
{
  "appId": "lifescore",
  "defaultBranch": "main",
  "worktreeRoot": "/Users/you/Developer/.feedback-worktrees/lifescore",
  "verify": ".feedbackkit/verify.sh",
  "ship": ".feedbackkit/ship.sh",
  "buildNumber": { "file": "project.yml", "pattern": "^(\\s*CURRENT_PROJECT_VERSION:\\s*)(\\d+)\\s*$" },
  "allowedTools": ["Bash(xcodegen:*)", "Bash(xcodebuild:*)"],
  "contextHint": "One paragraph telling an implementing agent what this app is and what to read first."
}
```

| Key | Notes |
|---|---|
| `appId` | Must match the `appID` the app passes to `FeedbackConfig`. |
| `verify` | Run **inside the worktree**. Must not need signing or a device. Last line `VERIFY OK` by convention; only the exit code is load-bearing. |
| `ship` | Run in the main checkout after the merge. **Exit 75 means "no device connected"** and is not a failure — the next tick retries. Any other non-zero is a real failure. |
| `buildNumber` | Group 1 is kept verbatim (so indentation survives), group 2 is the integer to increment. Omit to skip bumping. |
| `allowedTools` | Extra tool patterns on top of the base set, for whatever this app's build needs. |
| `contextHint` | Injected into both the classify and implement prompts. Worth writing properly — it is the main lever on output quality. |

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

### The main dial

`~/.feedbackkit/runner.json` → `trustedDevices`. **Empty means every request
runs.** Put install IDs in it and anything else is held at `needs_approval`
until you release it:

```bash
python3 feedback_runner.py trust <device_id>
python3 feedback_runner.py approve <feedback_id>
```

`maxRunsPerDay` (default 10) is the runaway guard, counted from the run logs.

## Commands

```bash
python3 feedback_runner.py run --dry-run   # decide everything, change nothing
python3 feedback_runner.py status          # the queue
python3 feedback_runner.py apps            # repos this runner can act on
python3 feedback_runner.py retry <id>      # put a failed item back
```

## When something fails

| Where to look | What's in it |
|---|---|
| `~/Library/Logs/feedbackkit-runner.log` | One line per decision |
| `~/.feedbackkit/runs/<stamp>-<id>.log` | Full transcript: classify, implement, verify, ship |
| `work_error` column | Tail of the failure |
| `work_branch` | Branch kept **undeleted** on purpose so you can check it out |

A failure requeues while attempts remain (`maxAttempts`, default 2), then stops
at `work_state='failed'` with a reporter-facing note. The worktree is always
removed; the branch is kept only when something went wrong.
