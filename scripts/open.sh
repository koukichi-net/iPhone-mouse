#!/bin/bash
# Start the installed HIDPad on the phone as a standalone app, as a tap on its icon would:
# no console is attached and nothing is logged on the Mac (the Release build has no log).
# A running HIDPad is restarted; a console process of scripts/launch.sh is stopped first.
# Usage: scripts/open.sh [--udid UDID]
set -euo pipefail
source "$(dirname "$0")/common.sh" "$@"
pkill -f "devicectl device process launch .*$BUNDLE_ID" 2>/dev/null && sleep 1 || true
xcrun devicectl device process launch --terminate-existing --device "$UDID" "$BUNDLE_ID"
