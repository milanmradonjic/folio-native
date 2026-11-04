# Third-party notices

Folio Native is derived from Forward-Future/folio, copyright (c) 2026 mberman84, under MIT. The upstream license remains in `LICENSE`, and the app bundles it in `Contents/Resources/LICENSE`. The app icon is retained from that project. Text-object grouping and original-font verification in the native helper adapt the upstream editing approach.

The standalone PDFium dependency is version 158.0.8125.0, from `bblanchon/pdfium-binaries`, tag `chromium/8125`. It is built with `pdf_enable_v8 = false`, `pdf_enable_xfa = false`, and `pdf_is_standalone = true`. Fetch URLs and architecture-specific SHA-256 values are committed in `scripts/fetch-pdfium.py`.

PDFium and its bundled components have their own licenses. The build copies the distribution's complete `LICENSE` and `licenses/` directory into `Contents/Resources/PDFium-Licenses`, together with its `VERSION` and `args.gn`. Preserve these notices when distributing the app. Build tooling in the binary-distribution project has its own MIT license; no scripts from that project are executed by this fork.

AppKit, PDFKit, Core Graphics, ImageIO, Foundation and the Swift runtime are Apple system frameworks/runtime components. This repository links against those installed system components and does not redistribute Apple's SDK.
