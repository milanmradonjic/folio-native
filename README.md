# Folio Native

A macOS PDF reader and editor, forked from [Forward-Future/folio](https://github.com/Forward-Future/folio) v1.15.1 (`a2e43c7`). The original web interface has been replaced with AppKit and PDFKit. Existing page text and images are edited by a separate native PDFium helper.

**macOS 13 or later. No Electron, Chromium browser, WebView, Node/npm, AI integration, Word conversion, URL imports, telemetry, or automatic updates.** Standalone PDFium is retained intentionally; it originates in the Chromium project, but this build disables V8 and XFA and contains no browser runtime.

## Features

- **Delete Object:** select the tool and click existing text, an image, vector shape, shading or whole artwork group. Overlapping objects have a chooser; click empty space to list all page objects. Annotations can also be deleted. Deletion supports undo and is not secure redaction.
- Hold **⌘** while scrolling over the PDF to zoom in/out. Scrolling without ⌘ remains ordinary scrolling.
- Native document windows and macOS window tabs; PDF thumbnails and outline navigation.
- Text selection/copying, find next/previous, page navigation, zoom, two-page view and printing.
- **Edit existing text:** choose **Edit Content**, click an outlined text run, and replace it or clear the field to delete it. Consecutive compatible glyph runs are grouped into one editable line. Edits change PDF objects, rather than covering the old text.
- **Replace embedded images:** in Edit Content, click an outlined image and choose a PNG or JPEG. Its placement is retained.
- **Insert images and visual signatures:** choose **Image / Sign**, drag a rectangle, and select a PNG or JPEG. This is a visual image, not a cryptographic signature. Signature files are not remembered.
- Highlights, notes, text boxes, pen drawings, rectangles, ovals and arrows. The Notes sidebar lists annotations; double-click an entry to edit its text, or use its context menu to delete it.
- Text form fields open a native editing dialog with undo support. Other form control types are read-only in this version.
- Rotate, move and delete pages; insert another PDF after the current page.
- Undo/redo for edits; explicit Save and Save As. There is no separate annotation database or document-history cache.
- Password-protected PDFs can be unlocked for reading. Encrypted PDFs and PDFs with signature fields remain read-only.

This is a new native implementation, **not full feature parity with upstream**. It does not include OCR, existing text reflow, arbitrary font substitution, image inspection tools, camera signature capture, persistent personal bookmarks, or the upstream version-history UI. PDFs do not behave like Word documents: longer replacement text can overlap nearby content, and subset fonts may reject characters they do not contain. Content inside grouped artwork, outlined lettering and scanned words is not exposed as editable text. Image replacement rejects existing placements with clipping, transparency or blend effects; inserting a new PNG with transparency is supported. This is not a secure-redaction tool.

## Build

Requires Apple's Xcode/Command Line Tools with a Swift compiler, and Python 3. There are no Swift package dependencies or npm packages.

```sh
python3 scripts/fetch-pdfium.py --download
./scripts/build.sh
./scripts/test.sh
```

The initial fetch downloads a pinned native PDFium archive, checks its committed SHA-256, rejects unsafe archive paths, and verifies that V8/XFA are disabled. Later builds are offline and re-extract the verified archive. The app is written to `.build/Folio Native.app`; it is not installed or launched automatically. Builds target the current Mac's architecture.

Tests run offscreen against synthetic PDFs. They check network denial, worker waits without delayed-callback delivery, actual text replacement/deletion, missing-font-glyph rejection, shared-image replacement isolation, image insertion, clipping rejection, annotation retention, undo/redo, stale-edit rejection, protected PDFs, the reader view, bundle dependencies and sandbox entitlements. They do not replace testing with your own PDFs. Running a sandboxed app inside another restrictive sandbox may require running the tests from a normal Terminal session.

## Security and privacy

- The app is signed with **App Sandbox**, allowing user-selected files. It has no incoming/outgoing network, camera, microphone, persistent-bookmark, or automation entitlement. External HTTP(S)/email links require a confirmation and open in another app. Remote-file and document-triggered print actions are not executed automatically.
- PDFKit handles display. PDFium is linked only into a separate helper process, which inherits the app sandbox, accepts bounded data over pipes, has a 30-second CPU budget and a 45-second parent watchdog, and starts without inherited account credentials. No JavaScript/form engine is initialized. This is process isolation, not an XPC service with a narrower sandbox than the parent.
- Reading is limited to 300 MiB/10,000 pages. Existing-content editing is limited to 64 MiB; image files to 24 MiB/20 megapixels. Original-font text replacements are read back before accepting a change.
- Documents and edits stay in memory until you explicitly save. There is no recent-file list, AI account store, automatic document copy, draft autosave or application version archive. Undo snapshots exist in memory while a document is open. macOS, swap, printing and other applications may have their own retention behavior.
- PDFium is a pinned third-party prebuilt library from [bblanchon/pdfium-binaries](https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium%2F8125). Hash pinning prevents a changed archive from silently entering a build; it is not independent proof of the binary's source provenance. PDF parser vulnerabilities remain possible. Keep macOS and the pinned library maintained.

### Signing

Local builds are **ad-hoc signed, not Developer ID-signed or notarized**. Do not treat this as a verified-publisher release. Hardened Runtime is enabled for the UI. In ad-hoc builds the helper retains App Sandbox but omits Hardened Runtime, because macOS library validation requires matching Apple Team IDs for the helper and PDFium dylib. No `disable-library-validation` entitlement is added.

With an appropriate installed identity, build with `FOLIO_SIGNING_IDENTITY="Developer ID Application: …" ./scripts/build.sh`. That signs the app, helper and library with the same identity and also enables Hardened Runtime for the helper. Notarization and public release publication are separate maintainer steps; the build does neither automatically. Upstream's release workflows and update channel have been removed.

## Provenance and license

Forked under the upstream MIT license; its copyright notice is retained in [LICENSE](LICENSE). The native implementation preserves the reader/editor intent and adapts the original text-run grouping and verification approach. PDFium's BSD-style and third-party license notices are copied from the pinned distribution into every app bundle. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
