# orchestrator-install-check

Nightly end-to-end check of every public way to install the Orchestrator desktop
app and its `ao` CLI, on clean GitHub-hosted runners:

| Job | What it installs |
|---|---|
| `meta` | No install: release assets and aliases, updater feeds, every locale of orchestrator.inc/download, README links, install scripts, and the version Homebrew, the old tap, winget, Chocolatey and npm serve |
| `mac-brew` | Official cask (arm64 + x64), the old `agentwrapper/tap` cask, and `orchestrator.inc/cli/install.sh` |
| `mac-direct` | The DMG and ZIP from `releases/latest/download` |
| `mac-update` | Previous stable → latest through the in-app updater (upstream's own harness) |
| `windows` | NSIS `.exe` silent install, winget, Chocolatey |
| `windows-update` | Previous stable → latest: download + sha512 of the staged installer |
| `linux-deb-appimage` | `.deb`, AppImage, Homebrew-on-Linux cask, npm `@aoagents/ao` |
| `linux-rpm` | `.rpm` in a Fedora container |
| `linux-update` | Previous stable AppImage → latest |

Each check is one row: `PASS`, `FAIL`, `KNOWN` (a known broken thing listed in
`KNOWN_ISSUES` in the workflow), `WARN` or `INFO`. The run goes red only on a
new `FAIL`. Remove an id from `KNOWN_ISSUES` once its fix ships so it stays
fixed.

Read-only against upstream: nothing here pushes, comments or files anything.
