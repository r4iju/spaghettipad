#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -x "$ROOT/build-mac/Spaghettify" ] || { echo 'Run scripts/build-macos.sh first' >&2; exit 1; }
if [ ! -s "$ROOT/build-mac/mk64.o2r" ]; then
 [ -s "$ROOT/ref/mk64.o2r" ] || { echo 'Generate ref/mk64.o2r from your local ROM first' >&2; exit 1; }
 cp "$ROOT/ref/mk64.o2r" "$ROOT/build-mac/mk64.o2r"
fi
python3 "$ROOT/scripts/patch-metal-archive.py" "$ROOT/build-mac/spaghetti.o2r"
cd "$ROOT/build-mac"
exec ./Spaghettify "$@"
