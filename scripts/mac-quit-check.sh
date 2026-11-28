#!/usr/bin/env bash
# macOS quit behaviour of a freshly built, unsigned Orchestrator package.
# Runs on a clean CI runner only: it installs to /Applications and drives the
# real GUI app.
#
#   quit:apple-event      osascript quit by bundle id (Dock, brew, logout send
#                         the same aevt/quit): main + daemon gone within ~5s
#   quit:in-app           Cmd-Q, Return in "Quit Orchestrator?" (or Escape in the
#                         first-day exit feedback prompt): window closes,
#                         main + daemon + tray stay
#   quit:after-in-app     quit Apple Event after an in-app Quit: gone within ~5s
#   quit:brew-uninstall   brew uninstall --cask with `uninstall quit:`: no
#                         "did not quit" warning, app gone
#
# env: ZIP (ditto zip of the .app), BUNDLE_ID
set -uo pipefail
. "$(dirname "$0")/lib.sh"

: "${BUNDLE_ID:=dev.agent-orchestrator.desktop}"
DEADLINE=${DEADLINE:-5}
d=$(mktemp -d)
diag=$RUNNER_TEMP/diag
mkdir -p "$diag"

unzip_app() {
	rm -rf "$d/x" && mkdir -p "$d/x" && ditto -x -k "$ZIP" "$d/x"
	find "$d/x" -maxdepth 1 -name '*.app' | head -n1
}
SRC=$(unzip_app)
NAME=$(basename "$SRC")
APP="/Applications/$NAME"
EXE_NAME=$(plutil -extract CFBundleExecutable raw -o - "$SRC/Contents/Info.plist")
info quit:build "$NAME $(plutil -extract CFBundleShortVersionString raw -o - "$SRC/Contents/Info.plist") ($BUNDLE_ID)"

install_app() {
	rm -rf "$APP"
	ditto "$1" "$APP"
	codesign --force --deep --sign - "$APP" >/dev/null 2>&1
	xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
}

main_pid() { pgrep -f "^$APP/Contents/MacOS/$EXE_NAME" | head -n1; }
daemon_pid() { python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["pid"])' ~/.ao/running.json 2>/dev/null; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

kill_all() {
	local dp
	dp=$(daemon_pid)
	pkill -9 -f "$APP/Contents" 2>/dev/null
	[ -n "$dp" ] && kill -9 "$dp" 2>/dev/null
	sleep 2
	rm -f ~/.ao/running.json
	# Answer the first-launch "Keep Orchestrator up to date automatically?"
	# prompt up front (it blocks startup); updates stay off for this check.
	mkdir -p ~/.ao
	echo '{"enabled":false,"channel":"latest","nightlyAck":false,"feature":null}' >~/.ao/update-settings.json
}

# Window / tray counts through System Events (runner has Accessibility).
ax() {
	osascript -e "tell application \"System Events\" to tell (first process whose unix id is $1) to $2" 2>/dev/null
}
windows() { ax "$1" "count windows"; }
tray() { ax "$1" "count menu bar items of menu bar 2"; }

# launch <label>: open via LaunchServices, wait for main + daemon /healthz.
MAIN= DAEMON=
launch() {
	kill_all
	open --stdout "$d/app-$1.log" --stderr "$d/app-$1.log" "$APP"
	local port
	for _ in $(seq 1 45); do
		MAIN=$(main_pid)
		DAEMON=$(daemon_pid)
		port=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["port"])' ~/.ao/running.json 2>/dev/null)
		if [ -n "$MAIN" ] && [ -n "$DAEMON" ] && [ -n "$port" ] &&
			curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then
			sleep 8 # let the window and tray finish coming up
			echo "launched $1: main $MAIN daemon $DAEMON port $port windows $(windows "$MAIN") tray $(tray "$MAIN")"
			return 0
		fi
		sleep 2
	done
	fail "quit:$1" "app did not come up (main '${MAIN}', daemon '${DAEMON}')"
	{
		echo "== $1"; ls -la ~/.ao 2>&1
		echo "== keychains"; security list-keychains 2>&1; security show-keychain-info 2>&1
		echo "== running.json"; cat ~/.ao/running.json 2>&1
		echo "== ps"; ps -axo pid,ppid,command | grep -v grep | grep -i -E "orchestrator|ao-daemon|/ao |tmux" | head -30
	} >>"$diag/launch-fail.txt" 2>&1
	cp "$d/app-$1.log" "$diag/" 2>/dev/null
	screencapture -x "$diag/launch-fail-$1.png" 2>/dev/null
	return 1
}

# wait_gone <seconds>: echo elapsed seconds when main and daemon are gone, or nothing.
wait_gone() {
	local t0 now
	t0=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
	while :; do
		now=$(perl -MTime::HiRes=time -e 'printf "%.0f", time*1000')
		if ! alive "$MAIN" && ! alive "$DAEMON"; then
			awk -v ms=$((now - t0)) 'BEGIN{printf "%.1f", ms/1000}'
			return 0
		fi
		[ $((now - t0)) -ge $(($1 * 1000)) ] && return 1
		sleep 0.25
	done
}

state() {
	local m=dead dm=dead
	alive "$MAIN" && m="alive (windows $(windows "$MAIN"), tray items $(tray "$MAIN"))"
	alive "$DAEMON" && dm=alive
	echo "main $m, daemon $dm"
}

install_app "$SRC"

# ---- (a) quit Apple Event by bundle id, window open ----
if launch apple-event; then
	osascript -e "tell application id \"$BUNDLE_ID\" to quit" >"$d/osa.log" 2>&1 &
	if t=$(wait_gone "$DEADLINE"); then
		pass quit:apple-event "main + daemon exited ${t}s after the quit Apple Event"
	elif t=$(wait_gone 10); then
		fail quit:apple-event "exited, but only after ${DEADLINE}s (+${t}s)"
	else
		fail quit:apple-event "still running $((DEADLINE + 10))s after the quit Apple Event: $(state)"
	fi
fi

# ---- (c) in-app Quit: Cmd-Q, then Return in "Quit Orchestrator?" ----
if launch in-app; then
	ax "$MAIN" "set frontmost to true"
	sleep 1
	before_w=$(windows "$MAIN")
	osascript -e 'tell application "System Events" to keystroke "q" using command down' 2>"$d/ax.err"
	sleep 2
	screencapture -x "$diag/in-app-dialog.png" 2>/dev/null
	osascript -e 'tell application "System Events" to key code 36' 2>>"$d/ax.err"
	sleep 5
	w=$(windows "$MAIN")
	via="Cmd-Q + Return"
	# The first quit on day one can show the exit feedback prompt instead of
	# "Quit Orchestrator?"; Escape skips it and the held Quit resumes.
	if [ "${w:-0}" != 0 ] && alive "$MAIN"; then
		screencapture -x "$diag/in-app-feedback.png" 2>/dev/null
		osascript -e 'tell application "System Events" to key code 53' 2>>"$d/ax.err"
		sleep 5
		w=$(windows "$MAIN")
		via="Cmd-Q, Escape in the exit feedback prompt"
	fi
	tr=$(tray "$MAIN")
	screencapture -x "$diag/in-app-after.png" 2>/dev/null
	if [ -s "$d/ax.err" ]; then
		warn quit:in-app-input "System Events keystroke failed: $(head -c 200 "$d/ax.err")"
	fi
	if alive "$MAIN" && alive "$DAEMON" && [ "${w:-x}" = 0 ] && [ "${tr:-0}" -ge 1 ] 2>/dev/null; then
		pass quit:in-app "${via}: windows ${before_w} -> 0, main + daemon alive, tray items ${tr}"
	else
		fail quit:in-app "after ${via} (windows before ${before_w}): $(state)"
	fi

	# ---- outside quit after the app was backgrounded ----
	if alive "$MAIN"; then
		osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 &
		if t=$(wait_gone "$DEADLINE"); then
			pass quit:after-in-app "backgrounded app exited ${t}s after the quit Apple Event"
		else
			wait_gone 10 >/dev/null
			fail quit:after-in-app "backgrounded app: $(state) $((DEADLINE + 10))s after the quit Apple Event"
		fi
	fi
fi

# ---- (b) brew uninstall --cask with `uninstall quit:` ----
kill_all
ditto -c -k --keepParent "$APP" "$d/signed.zip"
sha=$(shasum -a 256 "$d/signed.zip" | cut -d' ' -f1)
brew tap-new --no-git local/quitcheck >/dev/null 2>&1
tapdir=$(brew --repository local/quitcheck)
mkdir -p "$tapdir/Casks"
cat >"$tapdir/Casks/orchestrator-quitcheck.rb" <<EOF
cask "orchestrator-quitcheck" do
  version "0"
  sha256 "$sha"
  url "file://$d/signed.zip"
  name "Orchestrator quit check"
  homepage "https://github.com/OrchestratorInc/agent-orchestrator"
  app "$NAME"
  uninstall quit: "$BUNDLE_ID"
end
EOF
rm -rf "$APP"
if brew install --cask local/quitcheck/orchestrator-quitcheck >"$d/brew-install.log" 2>&1; then
	xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
	if launch brew-uninstall; then
		start=$(date +%s)
		brew uninstall --cask local/quitcheck/orchestrator-quitcheck >"$d/brew-uninstall.log" 2>&1
		took=$(($(date +%s) - start))
		cp "$d/brew-uninstall.log" "$diag/"
		sleep 1
		if grep -qi "did not quit" "$d/brew-uninstall.log"; then
			w=$(grep -i 'did not quit' "$d/brew-uninstall.log" | head -n1 | sed -e 's/^::warning:://' -e 's/%0A.*//' -e 's/\x1b\[[0-9;]*m//g')
			fail quit:brew-uninstall "brew warned \"$w\"; after uninstall: $(state)"
		elif alive "$MAIN" || alive "$DAEMON"; then
			fail quit:brew-uninstall "no warning, but after uninstall: $(state)"
		else
			pass quit:brew-uninstall "uninstall took ${took}s, no 'did not quit' warning, main + daemon gone"
		fi
	fi
else
	fail quit:brew-uninstall "local cask install failed: $(tail -n3 "$d/brew-install.log")"
	cp "$d/brew-install.log" "$diag/"
fi

kill_all
find ~/.ao \( -name "*.log" -o -name "*.jsonl" \) -size -5M -exec cp {} "$diag/" \; 2>/dev/null
cp "$d"/app-*.log "$diag/" 2>/dev/null
exit 0
