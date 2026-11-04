# Folio Native

This fork targets macOS 13+ only. The user explicitly chose AppKit/PDFKit and a standalone native PDFium helper for existing-text/image editing. Do not restore Electron, a browser runtime, JavaScript dependencies, AI integrations, network imports, or Word conversion.

Use a single agent. Preserve the upstream MIT attribution. Build dependencies are pinned in `scripts/fetch-pdfium.py`; PDFium must have V8 and XFA disabled. Do not add automatic updates or runtime network access.

Run `scripts/build.sh` and `scripts/test.sh` after changes. Never open a visible app window unless asked. Keep UI tests offscreen. Do not publish releases or open upstream pull requests unless asked. The fork's upstream release workflows have intentionally been removed.
