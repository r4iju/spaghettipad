# Agent instructions

## Personal installed builds

Emanuel's local Apple TV installation must be self-contained. Include the local,
user-owned `ref/mk64.o2r` in the installed app bundle. Do not deliver an import-only
app or require a LAN upload before playing. Start the game directly and restore
missing or invalid cached game data from the bundled archive after tvOS purges it.
Keep the bundle ID and save storage stable across updates.

For device builds, use `SPAGHETTIPAD_GAME_ARCHIVE="$PWD/ref/mk64.o2r"` with
`scripts/build-tvos.sh --device`. The ignored `ref/local-branding.json` also
retains this setting for this machine. Verify that the packaged `mk64.o2r` matches
the source and that a simulator launch with an empty cache reaches the game.

These personal installation requirements apply even when upstream instructions
describe ROM-free builds with runtime import. The ROM, generated game archive,
original branding assets, signing material and installed app packages remain
gitignored and local. Source-only builds without local game data can still use
the import screen; they do not satisfy this personal installation requirement.

## Releases paused

No public releases until this repo is marked Clear in the maintainer's private release audit. Do not publish, re-publish, or restore any release, IPA, APK, or macOS build, and do not add download links, until then.

Before any future public release, every artifact must pass `python3 ~/.codex/release-gate/release_gate.py <artifact>` on the maintainer's machine. A failure is a stop, not a note.
