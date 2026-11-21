#!/usr/bin/env bash
# Assertions on an installed (or extracted) Linux app tree.
#
# usage: linux-assert.sh <prefix> <app root dir> <desktop file or ""> <expect-ao-on-path: yes|no>
# env:   VERSION
set -uo pipefail
. "$(dirname "$0")/lib.sh"

P=$1 ROOT=$2 DESKTOP=$3 EXPECT_AO=$4
V=$VERSION

if [ ! -d "$ROOT" ]; then
	fail "$P:app-present" "$ROOT missing"
	exit 0
fi
pass "$P:app-present" "$ROOT"

AO=$(find "$ROOT" -path '*resources/daemon/ao' -type f 2>/dev/null | head -1)
TH=$(mktemp -d)
if [ -n "$AO" ]; then
	out=$(HOME=$TH AO_DATA_DIR=$TH/data AO_RUN_FILE=$TH/run/running.json AO_PORT=39117 timeout 60 "$AO" version 2>&1 | head -1)
	case $out in "$V"*) pass "$P:bundled-ao" "$AO: $out" ;; *) fail "$P:bundled-ao" "bundled ao: $out" ;; esac
else
	fail "$P:bundled-ao" "no resources/daemon/ao under $ROOT"
fi

feed=$(find "$ROOT" -name app-update.yml -path '*resources*' 2>/dev/null | head -1)
if [ -n "$feed" ]; then
	eq "$P:feed-repo" OrchestratorInc/agent-orchestrator "$(sed -n 's/^owner: *//p' "$feed")/$(sed -n 's/^repo: *//p' "$feed")" "baked update feed"
else
	info "$P:feed-repo" "no app-update.yml (expected for deb/rpm: they do not self-update)"
fi

if [ -n "$DESKTOP" ]; then
	if [ -f "$DESKTOP" ]; then
		eq "$P:display-name" Orchestrator "$(sed -n 's/^Name=//p' "$DESKTOP" | head -1)" "desktop entry Name"
		info "$P:desktop-exec" "$(grep -E '^(Exec|Icon|StartupWMClass)=' "$DESKTOP" | tr '\n' ' ')"
	else
		fail "$P:display-name" "no desktop entry at $DESKTOP"
	fi
fi

resolved=$(env -i HOME="$HOME" PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -lc 'command -v ao' 2>/dev/null || true)
if [ "$EXPECT_AO" = yes ]; then
	[ -n "$resolved" ] && pass "$P:ao-on-path" "$resolved" || fail "$P:ao-on-path" "ao not found in a fresh login shell"
else
	if [ -n "$resolved" ]; then info "$P:ao-on-path" "$resolved"; else fail "$P:ao-on-path" "this channel leaves no ao on PATH"; fi
fi
exit 0
