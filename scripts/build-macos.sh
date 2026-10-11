#!/usr/bin/env bash
# Build the existing upstream macOS target locally, with reviewed shader repair.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${MAC_BUILD_JOBS:-2}"
[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || exit 2
python3 "$ROOT/scripts/check-source-pins.py"
cmake -S "$ROOT/sources/spaghettikart" -B "$ROOT/build-mac" -GNinja \
 -DCMAKE_BUILD_TYPE=Release -DENABLE_SCRIPTING=OFF
cmake --build "$ROOT/build-mac" --target Spaghettify GenerateO2R --parallel "$JOBS"
python3 "$ROOT/scripts/patch-metal-archive.py" "$ROOT/build-mac/spaghetti.o2r"
if [ ! -s "$ROOT/build-mac/gamecontrollerdb.txt" ]; then
 curl --fail --location --silent --show-error \
  https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/03d390c37b1342fcb7d8d294cd9621ab9d640bb3/gamecontrollerdb.txt \
  -o "$ROOT/build-mac/gamecontrollerdb.txt"
fi
[ "$(shasum -a 256 "$ROOT/build-mac/gamecontrollerdb.txt" | awk '{print $1}')" = eb002773dc8a16aa96f9ee2609798e231a9deb60c45e21fbdd4e221c9e8b7d77 ]
echo "Native executable: $ROOT/build-mac/Spaghettify"
