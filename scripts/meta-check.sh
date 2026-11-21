#!/usr/bin/env bash
# Channel metadata checks that need no install: release assets and their
# aliases, updater feeds, website and README links, install scripts, and the
# version each package registry is serving.
#
# env: VERSION (e.g. 0.15.3), TAG (v0.15.3), NIGHTLY_TAG, REPO, GH_TOKEN
set -uo pipefail
. "$(dirname "$0")/lib.sh"

REPO=${REPO:-OrchestratorInc/agent-orchestrator}
V=$VERSION
WORK=$(mktemp -d)
cd "$WORK" || exit 1

gh api "repos/$REPO/releases/tags/$TAG" >release.json || { fail release-json "cannot read release $TAG"; finish; exit; }
jq -r '.assets[] | "\(.name)\t\(.size)\t\(.digest)"' release.json >assets.tsv
asset_digest() { awk -F'\t' -v n="$1" '$1==n{print $3}' assets.tsv; }
asset_size() { awk -F'\t' -v n="$1" '$1==n{print $2}' assets.tsv; }
info asset-count "$(wc -l <assets.tsv | tr -d ' ') assets on $TAG"

# --- 1. Release assets and aliases ------------------------------------------
for a in \
	Orchestrator-darwin-arm64.dmg Orchestrator-darwin-x64.dmg \
	agent-orchestrator-darwin-arm64.zip agent-orchestrator-darwin-x64.zip \
	"Agent.Orchestrator-darwin-arm64-$V.zip" "Agent.Orchestrator-darwin-x64-$V.zip" \
	agent-orchestrator-win32-x64.exe "Agent.Orchestrator.Setup.$V.exe" \
	agent-orchestrator-linux-x64.AppImage "Agent.Orchestrator-$V.AppImage" \
	agent-orchestrator-linux-x64.deb agent-orchestrator-linux-x64.rpm \
	latest.yml latest-mac.yml latest-linux.yml; do
	if [ -n "$(asset_digest "$a")" ]; then pass "asset:$a" "present"; else fail "asset:$a" "missing from $TAG"; fi
done

# Byte-identical alias groups (GitHub publishes a sha256 digest per asset).
same() {
	local id=$1 a=$2 b=$3
	local da db
	da=$(asset_digest "$a")
	db=$(asset_digest "$b")
	if [ -z "$da" ] || [ -z "$db" ]; then
		warn "$id" "cannot compare $a / $b (one is missing)"
	elif [ "$da" = "$db" ]; then
		pass "$id" "$a == $b"
	else
		fail "$id" "$a and $b differ"
	fi
}
for arch in arm64 x64; do
	same "alias-dmg-$arch" "Orchestrator-darwin-$arch.dmg" "agent-orchestrator-darwin-$arch.dmg"
	same "alias-zip-$arch" "agent-orchestrator-darwin-$arch.zip" "Agent.Orchestrator-darwin-$arch-$V.zip"
done
same alias-exe agent-orchestrator-win32-x64.exe "Agent.Orchestrator.Setup.$V.exe"
same alias-appimage agent-orchestrator-linux-x64.AppImage "Agent.Orchestrator-$V.AppImage"

# The pre-rename dmg alias was meant to be dropped after two stables.
if [ -n "$(asset_digest agent-orchestrator-darwin-arm64.dmg)" ]; then
	fail legacy-dmg-alias-still-published "agent-orchestrator-darwin-*.dmg still published (transitional alias, planned removal after v0.14.11)"
else
	pass legacy-dmg-alias-still-published "legacy dmg alias gone"
fi

if [ -n "$(asset_digest SHA256SUMS)" ] || [ -n "$(asset_digest SHA256SUMS.txt)" ]; then
	pass sha256sums "SHA256SUMS asset present"
else
	fail sha256sums "no SHA256SUMS asset (install scripts and package repos have to trust GitHub's API digest)"
fi

if jq -e '.assets[].name | select(test("(linux|win32).*arm64"))' release.json >/dev/null; then
	pass arm64-linux-windows "arm64 Linux/Windows assets exist"
else
	fail arm64-linux-windows "no Linux arm64 or Windows arm64 build"
fi

# --- 2. Updater feeds ---------------------------------------------------------
for f in latest.yml latest-mac.yml latest-linux.yml; do
	curl -fsSL "https://github.com/$REPO/releases/latest/download/$f" -o "$f" || { fail "feed:$f" "cannot download"; continue; }
	fv=$(sed -n 's/^version: *//p' "$f" | tr -d "'\"")
	eq "feed:$f:version" "$V" "$fv" "$f version"
	while read -r url; do
		[ -z "$url" ] && continue
		if [ -n "$(asset_digest "$url")" ]; then
			want=$(asset_size "$url")
			got=$(awk -v u="$url" '$0 ~ "url: "u {f=1; next} f && /size:/ {print $2; exit}' "$f")
			eq "feed:$f:$url" "$want" "$got" "size of $url in $f"
		else
			fail "feed:$f:$url" "$f points at $url, which is not on $TAG"
		fi
	done < <(sed -n 's/^ *- url: *//p' "$f")
done
# Nightly feeds on the newest nightly prerelease.
if [ -n "${NIGHTLY_TAG:-}" ]; then
	for f in nightly.yml nightly-mac.yml nightly-linux.yml; do
		s=$(http_status "https://github.com/$REPO/releases/download/$NIGHTLY_TAG/$f")
		eq "nightly-feed:$f" 200 "$s" "$NIGHTLY_TAG/$f HTTP"
	done
fi

# --- 3. Website download page (every locale) and README ------------------
curl -fsSL https://orchestrator.inc/download/ -o download.html || fail download-page "cannot fetch /download/"
locales=$(grep -oE 'href="/[A-Za-z-]+/download/"' download.html | sed -E 's#href="/([^/]+)/download/"#\1#' | sort -u)
pages="download/"
for l in $locales; do pages="$pages $l/download/"; done
: >links.txt
bad_pages=0
for p in $pages; do
	f="page-${p//\//_}.html"
	if ! curl -fsSL "https://orchestrator.inc/$p" -o "$f"; then
		bad_pages=$((bad_pages + 1))
		fail "page:/$p" "fetch failed"
		continue
	fi
	grep -oE "https://github.com/$REPO/releases/[^\"'<> \\\\]+" "$f" >>links.txt || true
	# Pinned stable links must point at the latest stable tag.
	stale=$(grep -oE "releases/download/v[0-9]+\.[0-9]+\.[0-9]+/" "$f" | sort -u | grep -v "/$TAG/" || true)
	if [ -n "$stale" ]; then fail "page-stable-tag:/$p" "links pinned to an older stable: $(echo "$stale" | tr '\n' ' ')"; fi
	if [ -n "${NIGHTLY_TAG:-}" ]; then
		stale_n=$(grep -oE "releases/download/v[0-9.]+-nightly\.[0-9]+/" "$f" | sort -u | grep -v "/$NIGHTLY_TAG/" || true)
		if [ -n "$stale_n" ]; then fail "page-nightly-tag:/$p" "nightly links pinned to an older nightly: $(echo "$stale_n" | tr '\n' ' ')"; fi
	fi
done
[ "$bad_pages" = 0 ] && pass download-pages "$(echo "$pages" | wc -w | tr -d ' ') locale download pages fetched"
eq page-has-stable-tag yes "$(grep -q "/download/$TAG/" download.html && echo yes || echo no)" "/download/ links the current stable $TAG"

curl -fsSL "https://raw.githubusercontent.com/$REPO/main/README.md" -o README.md && grep -oE "https://github.com/$REPO/releases/[^\")> ]+" README.md >>links.txt
sort -u links.txt -o links.txt
bad=0
while read -r u; do
	[ -z "$u" ] && continue
	s=$(curl -sSIL -o /dev/null -w '%{http_code}' "$u")
	if [ "$s" != 200 ]; then bad=$((bad + 1)); fail "link:$u" "HTTP $s"; fi
done <links.txt
[ "$bad" = 0 ] && pass links "$(wc -l <links.txt | tr -d ' ') release links on the website and README all resolve"

grep -qiE 'brew install' download.html && pass page-shows-brew "download page shows a brew command" || fail page-shows-brew "download page shows no brew / winget / CLI install command"
grep -q "nightly.*rpm\|/$NIGHTLY_TAG/agent-orchestrator-linux-x64.rpm" download.html && pass page-nightly-rpm "nightly rpm linked" || warn page-nightly-rpm "nightly rpm is published but not linked on the download page"

# --- 4. Install scripts -------------------------------------------------------
s=$(curl -sS -o install.sh -w '%{http_code}' https://orchestrator.inc/cli/install.sh)
eq install-sh-http 200 "$s" "/cli/install.sh HTTP"
if grep -q 'agentwrapper/tap' install.sh; then
	fail install-sh-old-tap "/cli/install.sh installs the old agentwrapper/tap cask (no ao on PATH), not the official cask"
else
	pass install-sh-old-tap "install.sh no longer uses the old tap"
fi
if grep -qE 'uname|Linux' install.sh; then pass install-sh-linux "install.sh handles Linux"; else fail install-sh-linux "install.sh requires Homebrew; no Linux path"; fi
for u in https://orchestrator.inc/install.sh https://orchestrator.inc/install.ps1 https://orchestrator.inc/cli/install.ps1 https://orchestrator.inc/install.md; do
	s=$(http_status "$u")
	id="exists:${u#https://orchestrator.inc/}"
	if [ "$s" = 200 ]; then pass "$id" "$u is live"; else fail "$id" "$u HTTP $s"; fi
done

# --- 5. Package registries ----------------------------------------------------
cv=$(curl -fsSL https://formulae.brew.sh/api/cask/agent-orchestrator.json | jq -r .version)
eq cask-version "$V" "$cv" "homebrew-cask agent-orchestrator version"
curl -fsSL https://formulae.brew.sh/api/cask/agent-orchestrator.json | jq -e '.artifacts[] | select(.binary)' >/dev/null &&
	pass cask-binary "official cask links ao (binary stanza)" || fail cask-binary "official cask has no binary stanza"

gh api repos/agentwrapper/homebrew-tap/contents/Casks/agent-orchestrator.rb --jq .content | base64 -d >tap.rb
tv=$(sed -n 's/^ *version "\(.*\)"/\1/p' tap.rb)
eq tap-version "$V" "$tv" "agentwrapper/tap version"
grep -q 'binary ' tap.rb && pass tap-binary "tap cask links ao" || fail tap-binary "agentwrapper/tap cask has no binary stanza: ao is not linked"
grep -q 'github.com/AgentWrapper/' tap.rb && warn tap-old-org-url "tap cask downloads via the old AgentWrapper org URL (works only through GitHub's rename redirect)"

wv=$(gh api repos/microsoft/winget-pkgs/contents/manifests/o/OrchestratorInc/AgentOrchestrator --jq '.[].name' | sort -V | tail -1)
eq winget-version "$V" "$wv" "winget OrchestratorInc.AgentOrchestrator newest manifest"

npm view @aoagents/ao --json >npm.json 2>/dev/null
nv=$(jq -r '.version' npm.json)
info npm-version "@aoagents/ao latest = $nv (app is $V)"
if [ "$(jq -r '.deprecated // empty' npm.json)" != "" ]; then
	pass npm-deprecated "@aoagents/ao is deprecated with a message"
else
	fail npm-deprecated "@aoagents/ao $nv is not deprecated; npm i -g still installs a stale ao"
fi

# Channels we do not have yet: report whether anything exists.
s=$(http_status "https://aur.archlinux.org/rpc/v5/info?arg[]=agent-orchestrator-bin")
n=$(curl -fsSL "https://aur.archlinux.org/rpc/v5/info?arg[]=agent-orchestrator-bin" | jq -r .resultcount 2>/dev/null)
[ "$n" = 1 ] && pass aur "AUR agent-orchestrator-bin exists" || fail aur "no AUR agent-orchestrator-bin"
s=$(http_status https://raw.githubusercontent.com/ScoopInstaller/Extras/master/bucket/agent-orchestrator.json)
[ "$s" = 200 ] && pass scoop "scoop extras/agent-orchestrator exists" || fail scoop "no scoop manifest"
# Chocolatey has a community package (auto-updated by its maintainer's AU job).
chv=$(curl -fsSL "https://community.chocolatey.org/api/v2/FindPackagesById()?id='agent-orchestrator'" |
	python3 -c 'import sys,re; x=sys.stdin.read(); print(max((tuple(map(int,v.split("."))) for v in re.findall(r"<d:Version>([0-9.]+)<",x)), default=()) and ".".join(map(str,max(tuple(map(int,v.split("."))) for v in re.findall(r"<d:Version>([0-9.]+)<",x)))))')
eq chocolatey-version "$V" "$chv" "chocolatey agent-orchestrator (community-maintained) version"
s=$(http_status https://flathub.org/api/v2/appstream/dev.agent_orchestrator.desktop)
info flathub "flathub appstream lookup HTTP $s"
s=$(curl -s -o /dev/null -w '%{http_code}' -H 'Snap-Device-Series: 16' https://api.snapcraft.io/v2/snaps/info/agent-orchestrator)
info snap "snap store lookup HTTP $s"

finish
