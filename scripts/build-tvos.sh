#!/usr/bin/env bash
# Local tvOS builds only. Game data is imported at runtime, never packaged.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---simulator}"
JOBS="${TVOS_BUILD_JOBS:-2}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || { echo 'TVOS_BUILD_JOBS must be positive' >&2; exit 2; }
case "$MODE" in
 --simulator) SDK=appletvsimulator; BUILD="${SPAGHETTIPAD_TV_SIM_BUILD_DIR:-$ROOT/build-tvos-sim}" ;;
 --device) SDK=appletvos; BUILD="${SPAGHETTIPAD_TV_BUILD_DIR:-$ROOT/build-tvos}" ;;
 *) echo 'Usage: scripts/build-tvos.sh [--simulator|--device]' >&2; exit 2 ;;
esac
PORT="${SPAGHETTIPAD_PORT_ARCHIVE:-$ROOT/build-mac/spaghetti.o2r}"
[ -s "$PORT" ] || { echo 'Generate the ROM-free spaghetti.o2r first; set SPAGHETTIPAD_PORT_ARCHIVE if needed.' >&2; exit 1; }
python3 "$ROOT/scripts/patch-metal-archive.py" "$PORT"
SOURCE="$ROOT/build-tvos-source"
python3 "$ROOT/scripts/prepare-tvos-source.py" "$SOURCE"
VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$ROOT/version.json")"
NUMBER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["build"])' "$ROOT/version.json")"
SOURCES=()
if [ "$MODE" = --device ]; then
 for input in "$ROOT/build-tvos-sim/_deps/"*-src; do
  [ -d "$input" ] || continue
  name="$(basename "$input" -src | tr '[:lower:]' '[:upper:]')"
  SOURCES+=("-DFETCHCONTENT_SOURCE_DIR_$name=$input")
 done
fi
cmake -S "$SOURCE" -B "$BUILD" -GXcode \
 "${SOURCES[@]}" -DCMAKE_SYSTEM_NAME=tvOS -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 \
 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DENABLE_SCRIPTING=OFF \
 -DCMAKE_PROJECT_INCLUDE="$ROOT/cmake/tvOS.cmake" \
 -DCMAKE_PROJECT_SDL2_INCLUDE="$ROOT/cmake/SDL2SceneLifecycle.cmake" \
 -DSPAGHETTIPAD_SHELL_DIR="$ROOT/tvos" -DSPAGHETTIPAD_PORT_ARCHIVE="$PORT" \
 -DSPAGHETTIPAD_VERSION="$VERSION" -DSPAGHETTIPAD_BUILD_NUMBER="$NUMBER" \
 -DBUNDLE_ID="${BUNDLE_ID:-com.emanuelfranzen.spaghettipad.tv}" -DDEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
[ "${TVOS_CONFIGURE_ONLY:-0}" = 1 ] && exit 0
SIGNING=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
if [ "$MODE" = --device ] && [ -n "${DEVELOPMENT_TEAM:-}" ] && [ -z "${TVOS_PROFILE:-}" ]; then
 SIGNING=(-allowProvisioningUpdates CODE_SIGN_IDENTITY='Apple Development')
fi
cmake --build "$BUILD" --config Release --target Spaghettify --parallel "$JOBS" -- "${SIGNING[@]}"
if [ "$MODE" = --device ] && [ -n "${TVOS_PROFILE:-}" ]; then
 python3 "$ROOT/scripts/sign-tvos.py" "$BUILD/Release-$SDK/SpaghettiPad.app" "$TVOS_PROFILE"
fi
echo "Local app: $BUILD/Release-$SDK/SpaghettiPad.app"
