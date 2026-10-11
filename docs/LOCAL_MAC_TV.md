# Local Mac and Apple TV

These are local development builds. Public releases remain paused. The maintained
engine, libultraship and Torch gitlinks remain clean at their pinned commits.

## Mac

The upstream native macOS target uses Metal and SDL. No desktop port was added.

```sh
cd /Volumes/ai-ssd/code/spaghettipad
MAC_BUILD_JOBS=2 scripts/build-macos.sh
scripts/run-macos.sh
```

The launcher uses the locally generated `ref/mk64.o2r`, copying it into `build-mac`
if needed. Saves and configuration are in `build-mac`. The source ROM stays in
`ref/baserom.us.z64`; its supported SHA1 is
`579c48e211ae952530ffc8738709f078d5dd215e`. For regeneration, the existing
`scripts/generate-port-archive.sh` uses the local oracle extraction workspace.
Use `ORACLE_BUILD_JOBS=2` when regenerating alongside other game threads.

`patch-metal-archive.py` corrects invalid `thread const` qualifiers on Metal
texture/sampler helper parameters in the port archive. The original archive
caused a Metal shader compilation failure and a subsequent renderer assertion.
The patch preserves every other archive entry and is idempotent.

## tvOS

For local original-game branding, decode the logo from your own game archive:

```sh
python3 scripts/import-local-branding.py ref/mk64.o2r
```

This creates `tvos/LocalBranding.xcassets` and `ref/local-branding.json`, both
gitignored. Local tvOS builds then use the original logo, layered app icons and
game display name. A checkout without these local inputs retains the neutral
name and transfer screen. Bundle identifiers, executable names and save locations
stay stable. Ignoring these files keeps them out of source commits; it does not
grant permission to distribute a branded app. Public releases remain paused.

The new UIKit shell provides a focused Play button, local network archive import,
save backup/restore, and controller instructions. The Siri Remote is excluded
from gamepad slots; up to four extended gamepads use the existing player routing.
View/Back opens the game settings. Transfer is under Settings → Controls.

Game data lives in `Library/Caches/SpaghettiPad`, as required for purgeable tvOS
assets. EEPROM, controller-pak files and settings are copied into app preferences
on EEPROM writes, periodically and on backgrounding, and recovered on launch.
Keep the game archive and downloaded JSON save backups on the Mac. Uninstalling
the app removes its preferences too. A restored backup takes effect next launch.

Build the ROM-free app:

```sh
cd /Volumes/ai-ssd/code/spaghettipad
TVOS_BUILD_JOBS=2 scripts/build-tvos.sh --simulator
TVOS_BUILD_JOBS=2 scripts/build-tvos.sh --device
```

Sources are staged under ignored `build-tvos-source`; maintained submodules are
not edited. Device dependencies reuse simulator dependency sources. Normal app
builds package only the clean `spaghetti.o2r`, never `mk64.o2r` or the ROM.

Set `TVOS_PROFILE` to the local matching tvOS development profile, then sign:

```sh
python3 scripts/sign-tvos.py \
  build-tvos/Release-appletvos/SpaghettiPad.app \
  "$TVOS_PROFILE" \
  --device a5ef39a5001ef59dec9c2fa15838447215252137
```

Alternatively pass `TVOS_PROFILE=/absolute/path/to/profile.mobileprovision` to
`build-tvos.sh --device` to sign after building. Automatic provisioning is used
only when `DEVELOPMENT_TEAM` is supplied without `TVOS_PROFILE`; it requires an
Xcode account. The profile used for local verification was created with the existing developer key,
includes Living Room TV, and expires 2027-10-11.

Install and launch:

```sh
xcrun devicectl device install app \
  --device a5ef39a5001ef59dec9c2fa15838447215252137 \
  build-tvos/Release-appletvos/SpaghettiPad.app
xcrun devicectl device process launch \
  --device a5ef39a5001ef59dec9c2fa15838447215252137 \
  com.emanuelfranzen.spaghettipad.tv
```

Open the private address displayed on the TV from a Mac on the same LAN. Upload
`ref/mk64.o2r`, then choose Play on the TV. The server runs only while Transfer is
open, uses a random per-session URL, bounds uploads, and validates the archive
before replacing game data. Archive replacement requires relaunching if the game
has already loaded. Save backups can be downloaded while Transfer is open.

## Verification

- Mac: rendering observed; actual non-silent process audio captured. Emanuel
  confirmed that the connected Xbox controller entered a race and steering worked.
- tvOS simulator: first-run import screen rendered; invalid upload rejected and
  local game archive accepted. Virtual SDL gamepad Start/A navigated menus and
  entered a single-player race. Acceleration and steering visibly moved Mario.
- tvOS simulator: four controllers were assigned separate player slots. A real
  four-player versus race rendered all four views; isolated inputs moved players
  2, 3 and 4 while player 1 remained stationary.
- tvOS simulator: View/Back opened settings; D-pad/A opened Transfer from its
  menu. Settings accept input from all paired gamepads. Background/resume restored
  the native transfer screen and regenerated its private URL.
- tvOS simulator: downloaded and restored a JSON backup; invalid restore rejected. EEPROM (512 bytes) and
  configuration were recovered byte-for-byte after deleting their cached copies
  and relaunching. Cup completion and time-trial record persistence were not tested.
- The device app was signed, installed and launched on Living Room TV. Its
  native transfer screen rendered and accepted the local archive over the LAN.
  Emanuel confirmed race entry, steering and audio on the physical Apple TV.
  The subsequent explicit Siri Remote slot exclusion was built, signed and
  installed, but has not yet been checked on the TV. TV interaction is paused
  for the evening at Emanuel's request; further checks use a leased simulator.
- Physical four-controller play and save recovery remain untested. Simulator
  controller tests use simulator-only environment hooks; those hooks are
  compiled out of the device app. No build, signing or installation blocker
  remains for the paired Living Room TV.

Simulator leases must be obtained with `sim acquire tv --for spaghettipad` and
released with `sim release <udid>`. T3's Device panel does not expose tvOS here;
verification uses platform screenshots and logs on the leased simulator.
