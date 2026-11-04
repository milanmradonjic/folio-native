#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
ARCH="$(uname -m)"
python3 scripts/fetch-pdfium.py --arch "$ARCH"
APP="$ROOT/.build/Folio Native.app"
mkdir -p "$APP/Contents/"{MacOS,Helpers,Frameworks,Resources} .build/module-cache
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.png LICENSE "$APP/Contents/Resources/"
cp vendor/pdfium/"$ARCH"/lib/libpdfium.dylib "$APP/Contents/Frameworks/"
rm -rf "$APP/Contents/Resources/PDFium-Licenses"
mkdir -p "$APP/Contents/Resources/PDFium-Licenses"
cp vendor/pdfium/"$ARCH"/LICENSE "$APP/Contents/Resources/PDFium-Licenses/PDFium.txt"
cp vendor/pdfium/"$ARCH"/licenses/* "$APP/Contents/Resources/PDFium-Licenses/"
cp vendor/pdfium/"$ARCH"/{VERSION,args.gn} "$APP/Contents/Resources/PDFium-Licenses/"
xcrun clang++ -std=c++17 -fobjc-arc -O2 -mmacosx-version-min=13.0 \
  -I"vendor/pdfium/$ARCH/include" -L"vendor/pdfium/$ARCH/lib" -lpdfium \
  -framework Foundation -framework ImageIO -framework CoreGraphics \
  -Wl,-rpath,@executable_path/../Frameworks native/EditorWorker.mm \
  -o "$APP/Contents/Helpers/FolioEditor"
install_name_tool -id @rpath/libpdfium.dylib "$APP/Contents/Frameworks/libpdfium.dylib"
install_name_tool -change ./libpdfium.dylib @rpath/libpdfium.dylib "$APP/Contents/Helpers/FolioEditor"
xcrun swiftc -swift-version 5 -parse-as-library -O -module-name FolioNative \
  -target "$ARCH-apple-macosx13.0" -module-cache-path .build/module-cache \
  -framework AppKit -framework PDFKit -framework UniformTypeIdentifiers \
  native/*.swift -o "$APP/Contents/MacOS/FolioNative"
IDENTITY="${FOLIO_SIGNING_IDENTITY:--}"
codesign --force --sign "$IDENTITY" --options runtime "$APP/Contents/Frameworks/libpdfium.dylib"
# macOS library validation requires a shared Apple Team ID. Ad-hoc signatures have none.
# Keep the helper sandboxed in development; Developer ID builds also harden the helper.
if [ "$IDENTITY" != "-" ]; then
  codesign --force --sign "$IDENTITY" --options runtime --entitlements Resources/Editor.entitlements "$APP/Contents/Helpers/FolioEditor"
else
  codesign --force --sign - --entitlements Resources/Editor.entitlements "$APP/Contents/Helpers/FolioEditor"
fi
codesign --force --sign "$IDENTITY" --options runtime --entitlements Resources/App.entitlements "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
