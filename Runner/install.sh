#!/bin/bash
# Install (or reinstall) the FeedbackKit runner LaunchAgent.
#
# Idempotent: safe to re-run after editing the plist template or the runner.
# Re-running is in fact the supported way to pick up a template change, since
# launchd caches the plist it was loaded with.
set -euo pipefail

RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="in.saurabhsoni.feedbackkit.runner"
TEMPLATE="$RUNNER_DIR/$LABEL.plist"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$HOME/.feedbackkit"
CONFIG="$STATE_DIR/runner.json"

die() { echo "install: $*" >&2; exit 1; }

[ -f "$TEMPLATE" ] || die "missing template at $TEMPLATE"

# --- preflight -------------------------------------------------------------
# Fail here with a sentence you can act on, rather than silently installing a
# job that fails every five minutes into a log nobody reads.

command -v python3 >/dev/null || die "python3 not found"

for item in feedbackkit-project-ref feedbackkit-supabase; do
    security find-generic-password -s "$item" -w >/dev/null 2>&1 \
        || die "keychain item '$item' missing — the runner cannot reach Supabase without it"
done

CLAUDE_BIN="$(command -v claude || true)"
[ -n "$CLAUDE_BIN" ] || die "the 'claude' CLI is not on PATH"

# The plist pins PATH explicitly; check the tools are actually at those places
# rather than merely on the interactive shell's PATH.
for tool in xcodegen swiftformat swiftlint; do
    command -v "$tool" >/dev/null || echo "install: warning — '$tool' not on PATH; verify.sh may fail"
done

# --- state -----------------------------------------------------------------

mkdir -p "$STATE_DIR" "$STATE_DIR/runs" "$HOME/Library/LaunchAgents"

if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" <<JSON
{
  "searchRoots": ["$HOME/Developer"],
  "trustedDevices": [],
  "maxRunsPerDay": 10,
  "maxAttempts": 2,
  "claudeBin": "$CLAUDE_BIN"
}
JSON
    echo "install: wrote $CONFIG"
else
    echo "install: kept existing $CONFIG"
fi

# --- launchd ---------------------------------------------------------------

sed "s|__HOME__|$HOME|g" "$TEMPLATE" > "$TARGET"
plutil -lint "$TARGET" >/dev/null || die "generated plist is malformed"

# bootout is the modern unload; ignore failure when it was never loaded.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$TARGET"

echo "install: loaded $LABEL (every 5 minutes)"
echo
echo "Check it:   launchctl list | grep feedbackkit"
echo "Dry run:    python3 $RUNNER_DIR/feedback_runner.py run --dry-run"
echo "Queue:      python3 $RUNNER_DIR/feedback_runner.py status"
echo "Log:        tail -f $HOME/Library/Logs/feedbackkit-runner.log"
echo
echo "Stop it:    launchctl bootout gui/$(id -u)/$LABEL"
