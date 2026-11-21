#!/usr/bin/env bash
# macOS in-app update, N-1 -> N, measured step by step:
#   1. download + stage (Squirrel.Mac signals through AO_E2E_UPDATE_SENTINEL)
#   2. does a quit request (Apple Event, as Dock/brew/logout send) end the app?
#   3. once the process is gone, does ShipIt swap in version N?
#   4. does N launch and answer /healthz?
# env: VERSION, PREV (tag), REPO
set -uo pipefail
. "$(dirname "$0")/lib.sh"

APP="/Applications/Agent Orchestrator.app"
d=$(mktemp -d)
curl -fsSL "https://github.com/$REPO/releases/download/$PREV/agent-orchestrator-darwin-arm64.zip" -o "$d/prev.zip"
rm -rf "$APP"
ditto -x -k "$d/prev.zip" /Applications
ver() { plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist"; }
info mac-update:baseline "$(ver)"

st=$d/state
mkdir -p "$st/run"
echo '{"enabled":true,"channel":"latest","nightlyAck":false,"feature":null}' >"$st/run/update-settings.json"
sentinel=$d/sentinel.json
exe="$APP/Contents/MacOS/$(plutil -extract CFBundleExecutable raw -o - "$APP/Contents/Info.plist")"

AO_E2E_UPDATE_SENTINEL=$sentinel AO_RUN_FILE=$st/run/running.json AO_DATA_DIR=$st/data \
	"$exe" >"$d/app.log" 2>&1 &
pid=$!
start=$(date +%s)
for _ in $(seq 1 180); do [ -f "$sentinel" ] && break; sleep 5; done
if [ -f "$sentinel" ]; then
	pass mac-update:staged "$PREV downloaded and staged $VERSION in $(($(date +%s) - start))s"
else
	fail mac-update:staged "nothing staged in 15 min"
	tail -30 "$d/app.log"
fi

# 2. Quit as the Dock, Homebrew's uninstall and logout do.
osascript -e 'tell application id "dev.agent-orchestrator.desktop" to quit' >/dev/null 2>&1
for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 2; done
if kill -0 "$pid" 2>/dev/null; then
	fail mac-update:quit-exits "app still running 60s after a quit Apple Event (window closes, process + tray stay), so the staged update is never installed on quit"
	kill -9 "$pid" 2>/dev/null
	pkill -9 -f "$APP/Contents" 2>/dev/null || true
else
	pass mac-update:quit-exits "app exited on a quit Apple Event"
fi

# 3. With the process gone, ShipIt should swap the bundle.
swapped=no
for _ in $(seq 1 60); do [ "$(ver)" = "$VERSION" ] && swapped=yes && break; sleep 5; done
if [ $swapped = yes ]; then
	pass mac-update:swap "ShipIt installed $VERSION after the app exited ($(($(date +%s) - start))s from launch)"
else
	fail mac-update:swap "bundle still $(ver) 5 min after the app exited"
	tail -20 ~/Library/Caches/dev.agent-orchestrator.desktop.ShipIt/ShipIt_stderr.log 2>/dev/null
fi

# 4. Relaunch N.
rm -f "$st/run/running.json"
AO_RUN_FILE=$st/run/running.json AO_DATA_DIR=$st/data "$exe" >"$d/app2.log" 2>&1 &
pid2=$!
ok=no
for _ in $(seq 1 90); do
	if [ -f "$st/run/running.json" ]; then
		port=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["port"])' "$st/run/running.json" 2>/dev/null)
		[ -n "$port" ] && curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && ok=yes && break
	fi
	sleep 2
done
if [ $ok = yes ]; then pass mac-update:relaunch "$(ver) launched and its daemon answered /healthz"; else fail mac-update:relaunch "relaunched $(ver) did not come up"; fi
kill -9 "$pid2" 2>/dev/null
pkill -9 -f "$APP/Contents" 2>/dev/null || true

mkdir -p "$RUNNER_TEMP/diag"
cp "$d"/app*.log "$RUNNER_TEMP/diag/" 2>/dev/null
cp "$st/run/logs/updater.jsonl" "$RUNNER_TEMP/diag/" 2>/dev/null
cp ~/Library/Caches/dev.agent-orchestrator.desktop.ShipIt/ShipIt_stderr.log "$RUNNER_TEMP/diag/" 2>/dev/null
exit 0
