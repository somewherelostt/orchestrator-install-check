#!/usr/bin/env bash
# Assertions on an installed macOS app bundle.
#
# usage: mac-assert.sh <prefix> <app path> <expect-ao-on-path: yes|no>
# env:   VERSION, LAUNCH=1 to boot the app once and wait for its daemon.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

P=$1 APP=$2 EXPECT_AO=$3
V=$VERSION
TEAM=X9LNSP8MC2

if [ ! -d "$APP" ]; then
	fail "$P:app-present" "$APP missing"
	exit 0
fi
pass "$P:app-present" "$APP"

plist="$APP/Contents/Info.plist"
eq "$P:version" "$V" "$(plutil -extract CFBundleShortVersionString raw -o - "$plist")" "bundle version"
eq "$P:bundle-id" dev.agent-orchestrator.desktop "$(plutil -extract CFBundleIdentifier raw -o - "$plist")" "bundle id"
dn=$(plutil -extract CFBundleDisplayName raw -o - "$APP/Contents/Resources/en.lproj/InfoPlist.strings" 2>/dev/null || echo "")
eq "$P:display-name" Orchestrator "$dn" "localized (en) display name"
info "$P:base-name" "Info.plist CFBundleDisplayName=$(plutil -extract CFBundleDisplayName raw -o - "$plist"); folder=$(basename "$APP")"

team=$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')
eq "$P:team" "$TEAM" "$team" "codesign team"
check "$P:codesign-strict" "codesign --verify --deep --strict" codesign --verify --deep --strict "$APP"
sp=$(spctl -a -vv "$APP" 2>&1 | tr '\n' ' ')
case $sp in *accepted*Notarized*) pass "$P:gatekeeper" "$sp" ;; *) fail "$P:gatekeeper" "$sp" ;; esac
check "$P:stapled" "notarization ticket stapled" xcrun stapler validate "$APP"

feed="$APP/Contents/Resources/app-update.yml"
eq "$P:feed-repo" OrchestratorInc/agent-orchestrator "$(sed -n 's/^owner: *//p' "$feed")/$(sed -n 's/^repo: *//p' "$feed")" "baked update feed"

AO="$APP/Contents/Resources/daemon/ao"
TH=$(mktemp -d)
run_ao() { env HOME="$TH" AO_DATA_DIR="$TH/data" AO_RUN_FILE="$TH/run/running.json" AO_PORT=39117 "$@"; }
if [ -x "$AO" ]; then
	out=$(run_ao timeout 60 "$AO" version 2>&1 | head -1)
	case $out in "$V"*) pass "$P:bundled-ao" "$out" ;; *) fail "$P:bundled-ao" "bundled ao version: $out" ;; esac
else
	fail "$P:bundled-ao" "no $AO"
fi

# Fresh login shell, as a user (or their agent) opening a new terminal would.
resolved=$(zsh -lc 'command -v ao' 2>/dev/null || true)
all=$(zsh -lc 'which -a ao' 2>/dev/null | tr '\n' ' ' || true)
info "$P:which-a-ao" "${all:-none}"
if [ "$EXPECT_AO" = yes ]; then
	if [ -n "$resolved" ]; then
		out=$(zsh -lc "export HOME='$TH' AO_DATA_DIR='$TH/data' AO_RUN_FILE='$TH/run/running.json' AO_PORT=39117; timeout 60 ao version" 2>&1 | head -1)
		case $out in "$V"*) pass "$P:ao-on-path" "$resolved -> $out" ;; *) fail "$P:ao-on-path" "$resolved runs '$out', not $V" ;; esac
	else
		fail "$P:ao-on-path" "ao not found in a fresh login shell"
	fi
else
	if [ -n "$resolved" ]; then
		out=$(zsh -lc "export HOME='$TH' AO_DATA_DIR='$TH/data' AO_RUN_FILE='$TH/run/running.json' AO_PORT=39117; timeout 60 ao version" 2>&1 | head -1)
		info "$P:ao-on-path" "this channel does not link ao, but $resolved is on PATH ($out)"
	else
		fail "$P:ao-on-path" "this channel leaves no ao on PATH (user must link it by hand)"
	fi
fi

if [ "${LAUNCH:-0}" = 1 ]; then
	LH=$(mktemp -d)
	exe=$(plutil -extract CFBundleExecutable raw -o - "$plist")
	env HOME="$HOME" AO_DATA_DIR="$LH/data" AO_RUN_FILE="$LH/run/running.json" \
		"$APP/Contents/MacOS/$exe" >"$LH/app.log" 2>&1 &
	pid=$!
	ok=no
	for _ in $(seq 1 90); do
		if [ -f "$LH/run/running.json" ]; then
			port=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["port"])' "$LH/run/running.json" 2>/dev/null)
			if [ -n "$port" ] && curl -fsS "http://127.0.0.1:$port/healthz" >/dev/null 2>&1; then ok=yes; break; fi
		fi
		sleep 2
	done
	if [ $ok = yes ]; then pass "$P:launch" "app booted and daemon /healthz answered"; else
		fail "$P:launch" "daemon did not come up in 180s"
		tail -30 "$LH/app.log"
	fi
	[ -e /usr/local/bin/ao ] && info "$P:usr-local-ao-after-launch" "$(ls -l /usr/local/bin/ao)"
	osascript -e 'tell application id "dev.agent-orchestrator.desktop" to quit' >/dev/null 2>&1 || true
	sleep 5
	kill "$pid" 2>/dev/null || true
	pkill -f "$LH" 2>/dev/null || true
fi
exit 0
