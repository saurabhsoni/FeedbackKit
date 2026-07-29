#!/bin/bash
# Daily local check for new FeedbackKit reports. Runs via a LaunchAgent
# (see ~/Library/LaunchAgents/in.saurabhsoni.feedbackkit.check.plist) because
# it needs the secret key from this Mac's login keychain — that key can never
# leave this machine, so this check cannot run as a cloud routine.
#
# Silent when there's nothing new. Posts a macOS notification when there is,
# or when the check itself fails (missing keychain items, network, or a
# paused Supabase project) — a check that fails silently is worse than no
# check at all.
set -uo pipefail

notify() {
    local title="$1" message="$2"
    osascript -e "display notification \"$message\" with title \"$title\" sound name \"Glass\"" >/dev/null 2>&1
}

REF=$(security find-generic-password -s feedbackkit-project-ref -w 2>/dev/null)
KEY=$(security find-generic-password -s feedbackkit-supabase -w 2>/dev/null)

if [ -z "$REF" ] || [ -z "$KEY" ]; then
    echo "$(date -u +%FT%TZ) missing keychain item(s): feedbackkit-project-ref / feedbackkit-supabase"
    notify "FeedbackKit check failed" "Keychain items missing — see ~/Library/Logs/feedbackkit-check.log"
    exit 1
fi

RESPONSE=$(curl -s --max-time 15 \
    "https://$REF.supabase.co/rest/v1/feedback_inbox?status=eq.new&select=app_id" \
    -H "apikey: $KEY" -H "Authorization: Bearer $KEY")
CURL_STATUS=$?

if [ $CURL_STATUS -ne 0 ]; then
    echo "$(date -u +%FT%TZ) curl failed with exit code $CURL_STATUS"
    notify "FeedbackKit check failed" "Couldn't reach Supabase — check network"
    exit 1
fi

COUNT=$(echo "$RESPONSE" | python3 -c "
import sys, json
try:
    print(len(json.load(sys.stdin)))
except Exception:
    print(-1)
" 2>/dev/null)

if [ "$COUNT" = "-1" ] || [ -z "$COUNT" ]; then
    echo "$(date -u +%FT%TZ) unexpected response: $RESPONSE"
    notify "FeedbackKit check failed" "Unexpected response — project may be paused"
    exit 1
fi

echo "$(date -u +%FT%TZ) $COUNT new report(s)"

if [ "$COUNT" -gt 0 ]; then
    if [ "$COUNT" -eq 1 ]; then
        notify "FeedbackKit" "1 new feedback report waiting"
    else
        notify "FeedbackKit" "$COUNT new feedback reports waiting"
    fi
fi
