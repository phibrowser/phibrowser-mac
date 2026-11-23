#!/bin/sh
# One measured round of the sidebar bench.
#
# usage: bench.sh <label> <Phi Canary.app> <toggle|scroll> <round>
#
# Starts the build on a fresh APFS clone of $BENCH_DIR/profile-snapshot
# (seed.sh), places the window at a fixed frame, makes sure the sidebar is
# expanded and scrolled to the top, then records the Time Profiler for 20s
# while a driver runs the scenario through Accessibility:
#   toggle  View > Toggle Sidebar 24 times, 0.6s apart
#   scroll  the sidebar tab list's scroll bar top -> bottom -> top, twice, 100 steps per leg
# Writes $BENCH_DIR/out/<label>-<scenario>-<round>.xml (the time-profile table).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
LABEL=$1 APP=$2 SCENARIO=$3 ROUND=$4
BENCH_DIR=${BENCH_DIR:-$HOME/Library/Application Support/PhiSidebarBench}
BID=com.phibrowser.canary.Mac
OUT=$BENCH_DIR/out; mkdir -p "$OUT"
RUN=$BENCH_DIR/run-profile
NAME=$LABEL-$SCENARIO-$ROUND
LAYOUT=${BENCH_LAYOUT:-performance}
PORT=8765
WINDOW='(first window whose subrole is "AXStandardWindow")'
SIDEBAR_BAR="scroll bar 1 of scroll area 1 of (first UI element of $WINDOW whose role is \"AXSplitGroup\")"

running() { osascript -e "tell application \"System Events\" to exists (first process whose bundle identifier is \"$BID\")" 2>/dev/null | grep -q true; }
ax() { osascript -e "tell application \"System Events\" to tell (first process whose bundle identifier is \"$BID\") to $1"; }

test -d "$BENCH_DIR/profile-snapshot" || { echo "No profile; run seed.sh first."; exit 1; }
# Sparkle can replace a quit build-folder app with a release; that is not the build under test.
test "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" = debug || { echo "Not a debug build: $APP"; exit 1; }
if running; then osascript -e "tell application id \"$BID\" to quit"; while running; do sleep 1; done; sleep 2; fi

rm -rf "$RUN"; cp -c -R "$BENCH_DIR/profile-snapshot" "$RUN"
# Keeps the display awake for this round only. Detached from stdout so a
# caller piping our output doesn't wait for it to time out.
caffeinate -d -u -t 120 >/dev/null 2>&1 &
CLEANUP="kill $! 2>/dev/null || true"
# The fixture's tabs load from the local site; without it they show URLs.
if ! curl -s -o /dev/null "http://127.0.0.1:$PORT/p001.html"; then
  (cd "$BENCH_DIR/site" && exec python3 -m http.server $PORT --bind 127.0.0.1 >/dev/null 2>&1) &
  CLEANUP="$CLEANUP; kill $! 2>/dev/null || true"
  sleep 1
fi
# The layout is an app-wide preference the user's own Canary shares: set it
# for this round and put the user's value back afterwards.
PREVIOUS_LAYOUT=$(defaults read $BID layoutMode 2>/dev/null || true)
defaults write $BID layoutMode -string "$LAYOUT"
if [ -n "$PREVIOUS_LAYOUT" ]; then
  CLEANUP="$CLEANUP; defaults write $BID layoutMode -string $PREVIOUS_LAYOUT"
else
  CLEANUP="$CLEANUP; defaults delete $BID layoutMode 2>/dev/null || true"
fi
trap "$CLEANUP" EXIT

open -a "$APP" --args --user-data-dir="$RUN"
until osascript -e "tell application \"System Events\" to get name of menu bar 1 of (first process whose bundle identifier is \"$BID\")" >/dev/null 2>&1; do sleep 1; done
sleep 15
ax "set frontmost to true"
ax "set position of $WINDOW to {157, 127}"
ax "set size of $WINDOW to {1311, 812}"
sleep 2
# The tab list's scroll area is exposed only while the column shows.
if ! ax "get value of $SIDEBAR_BAR" >/dev/null 2>&1; then
  ax 'click menu item "Toggle Sidebar" of menu 1 of menu bar item "View" of menu bar 1' >/dev/null
  sleep 2
fi
ax "set value of $SIDEBAR_BAR to 0"
sleep 3
PID=$(ax 'get unix id')

xcrun xctrace record --template 'Time Profiler' --attach "$PID" --time-limit 20s \
  --output "$OUT/$NAME.trace" > "$OUT/$NAME.log" 2>&1 &
XP=$!
sleep 3
osascript "$HERE/drive_$SCENARIO.applescript" > "$OUT/$NAME.driver.log" 2>&1
wait $XP
xcrun xctrace export --input "$OUT/$NAME.trace" \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' > "$OUT/$NAME.xml"
rm -rf "$OUT/$NAME.trace"
# xctrace leaves several GB of kernel trace per recording in the temp folder.
rm -f "${TMPDIR:-/tmp}"/instruments*.ktrace 2>/dev/null || true
osascript -e "tell application id \"$BID\" to quit"
while running; do sleep 1; done
echo "$NAME: $(wc -c < "$OUT/$NAME.xml" | tr -d ' ') bytes, $(cat "$OUT/$NAME.driver.log")"
