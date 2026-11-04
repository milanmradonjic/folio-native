#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/.build/Folio Native.app"
"$APP/Contents/MacOS/FolioNative" --self-test
codesign --verify --deep --strict "$APP"
python3 "$ROOT/scripts/check-bundle.py" "$APP"
