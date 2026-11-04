#!/usr/bin/env python3
"""Verify the built app's dependency boundary and signed sandbox entitlements."""
import pathlib
import plistlib
import subprocess
import sys

app = pathlib.Path(sys.argv[1])
def entitlements(path):
    result = subprocess.run(['codesign', '-d', '--entitlements', ':-', str(path)], check=True, capture_output=True)
    return plistlib.loads(result.stdout)
assert entitlements(app) == {'com.apple.security.app-sandbox': True, 'com.apple.security.files.user-selected.read-write': True}
assert entitlements(app / 'Contents/Helpers/FolioEditor') == {'com.apple.security.app-sandbox': True, 'com.apple.security.inherit': True}
for path in app.rglob('*'):
    assert not any(word in path.name.lower() for word in ('electron', 'chromium framework', 'node_modules', 'app.asar'))
libraries = subprocess.check_output(['otool', '-L', str(app / 'Contents/MacOS/FolioNative')], text=True)
assert 'pdfium' not in libraries.lower(), 'PDFium must stay outside the UI process'
helper_libraries = subprocess.check_output(['otool', '-L', str(app / 'Contents/Helpers/FolioEditor')], text=True)
assert '@rpath/libpdfium.dylib' in helper_libraries and './libpdfium.dylib' not in helper_libraries
args = (app / 'Contents/Resources/PDFium-Licenses/args.gn').read_text()
assert 'pdf_enable_v8 = false' in args and 'pdf_enable_xfa = false' in args
print('PASS: signed sandbox entitlements; no browser runtime; PDFium isolated to helper; V8/XFA disabled')
