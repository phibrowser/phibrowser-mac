#!/bin/sh
# Builds the bench profile: a fresh Phi Canary profile with 150 tabs of local
# fixture pages, arranged by make_fixture.py into tab groups, split views,
# pinned tabs, bookmarks and two more Spaces, saved as
# $BENCH_DIR/profile-snapshot for bench.sh.
#
# usage: seed.sh <Phi Canary.app>
#
# Quit every Phi Canary first. The new profile goes through onboarding and
# sign-in, which you complete by hand; the script waits for Return, then
# drives the app for about 40 minutes (keep your hands off the mouse and
# keyboard), and quits it to save the session.
set -eu
APP=$1 TABS=150
HERE=$(cd "$(dirname "$0")" && pwd)
BENCH_DIR=${BENCH_DIR:-$HOME/Library/Application Support/PhiSidebarBench}
BID=com.phibrowser.canary.Mac
PORT=8765
running() { osascript -e "tell application \"System Events\" to exists (first process whose bundle identifier is \"$BID\")" 2>/dev/null | grep -q true; }

running && { echo "Quit Phi Canary first."; exit 1; }
mkdir -p "$BENCH_DIR/site"
# Posts the clicks that open tab context menus.
xcrun swiftc -O "$HERE/mouse.swift" -o "$BENCH_DIR/mouse"
i=1
while [ $i -le "$TABS" ]; do
  n=$(printf %03d $i)
  printf '<!doctype html><html><head><meta charset="utf-8"><title>Bench page %s</title></head><body><h1>Bench page %s</h1></body></html>\n' "$n" "$n" > "$BENCH_DIR/site/p$n.html"
  i=$((i + 1))
done
(cd "$BENCH_DIR/site" && exec python3 -m http.server $PORT --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER=$!
caffeinate -d -u >/dev/null 2>&1 &
CAFFEINATE=$!
trap 'kill $SERVER $CAFFEINATE 2>/dev/null || true' EXIT

rm -rf "$BENCH_DIR/profile-seed"; mkdir -p "$BENCH_DIR/profile-seed"
open -a "$APP" --args --user-data-dir="$BENCH_DIR/profile-seed"
printf 'Finish onboarding and sign in until a browser window shows, then press Return here. '
read -r _

osascript - "$TABS" "$PORT" <<'OSA'
on run argv
	set tabs to (item 1 of argv) as integer
	set port to item 2 of argv
	tell application "System Events"
		set p to first process whose bundle identifier is "com.phibrowser.canary.Mac"
		set frontmost of p to true
		delay 0.5
		repeat with i from 1 to tabs
			if not (frontmost of p) then
				set frontmost of p to true
				delay 0.5
				if not (frontmost of p) then error "Phi Canary lost focus at tab " & i
			end if
			keystroke "t" using command down
			delay 0.6
			keystroke "127.0.0.1:" & port & "/p" & (text -3 thru -1 of ("00" & i)) & ".html"
			delay 0.15
			key code 36
			delay 0.6
		end repeat
	end tell
end run
OSA
sleep 3
WINDOW="(first window of (first process whose bundle identifier is \"$BID\") whose subrole is \"AXStandardWindow\")"
osascript -e "tell application \"System Events\" to set position of $WINDOW to {157, 127}"
osascript -e "tell application \"System Events\" to set size of $WINDOW to {1311, 812}"
python3 -I "$HERE/make_fixture.py" "$BENCH_DIR/mouse"
sleep 3
osascript -e "tell application id \"$BID\" to quit"
while running; do sleep 1; done
sleep 2
rm -rf "$BENCH_DIR/profile-snapshot"
cp -c -R "$BENCH_DIR/profile-seed" "$BENCH_DIR/profile-snapshot"
echo "Saved $BENCH_DIR/profile-snapshot."
