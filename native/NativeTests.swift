import AppKit
import PDFKit
import Darwin

// Runs only with --self-test. It creates no visible windows and retains no document files.
@MainActor enum NativeTests {
    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw FolioError(message) }
    }
    static func fixture(signed: Bool = false, clipped: Bool = false) -> Data {
        func stream(_ contents: String) -> String { "<< /Length \(contents.utf8.count) >>\nstream\n\(contents)\nendstream" }
        let resources = "<< /Font << /F1 6 0 R >> /XObject << /Im0 5 0 R >> >>"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R \(signed ? "/AcroForm << /Fields [9 0 R] >>" : "") >>",
            "<< /Type /Pages /Count 2 /Kids [3 0 R 4 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources \(resources) /Contents 7 0 R \(signed ? "/Annots [9 0 R]" : "") >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources \(resources) /Contents 8 0 R >>",
            "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length 7 >>\nstream\nFF0000>\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            stream("BT /F1 20 Tf 1 0 0 1 40 240 Tm (Hello ) Tj 1 0 0 1 91.12 240 Tm (world) Tj ET q \(clipped ? "40 120 30 60 re W n " : "")60 0 0 60 40 120 cm /Im0 Do Q q 60 0 0 60 140 120 cm /Im0 Do Q"),
            stream("BT /F1 16 Tf 1 0 0 1 40 240 Tm (Second page) Tj ET q 60 0 0 60 40 120 cm /Im0 Do Q")
        ]
        if signed {
            objects += ["<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signature) /P 3 0 R /Rect [0 0 0 0] /V 10 0 R >>",
                        "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange [0 1 2 1] /Contents <010203> >>"]
        }
        var result = Data("%PDF-1.7\n".utf8), offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(result.count)
            result.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let start = result.count
        var xref = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { xref += String(format: "%010d 00000 n \n", offset) }
        xref += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        result.append(Data(xref.utf8)); return result
    }
    static func blueImage() -> Data {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
        for index in 0..<16 {
            let pixel = bitmap.bitmapData!.advanced(by: index * 4)
            pixel[0] = 0; pixel[1] = 0; pixel[2] = 255; pixel[3] = 255
        }
        return bitmap.representation(using: .png, properties: [:])!
    }
    private static func sample(_ page: PDFPage, x: Double, y: Double) -> NSColor {
        let image = page.thumbnail(of: NSSize(width: 300, height: 300), for: .mediaBox)
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let color = bitmap.colorAt(x: Int(x * Double(bitmap.pixelsWide) / 300), y: Int((300 - y) * Double(bitmap.pixelsHigh) / 300))!
        return color.usingColorSpace(.deviceRGB)!
    }
    static func run() throws {
        // A real syscall check complements the static entitlement inspection.
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        if socket < 0 { try check(errno == EPERM || errno == EACCES, "Sandbox must reject network socket creation") }
        else {
            defer { Darwin.close(socket) }
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(9).bigEndian
            address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
            let result = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            try check(result == -1 && (errno == EPERM || errno == EACCES), "App Sandbox must deny outgoing network access")
        }
        let blank = PDFFile()
        let blankPDF = try DocumentPolicy.parse(blank.snapshot())
        try check(blankPDF.pageCount == 1, "New PDF must contain one valid blank page")
        let source = fixture(), pdf = try DocumentPolicy.parse(source)
        try check(pdf.pageCount == 2 && pdf.string?.contains("Hello world") == true, "Fixture must have readable text and two pages")
        let targets = try EditorProcess.run(pdf: source, page: 0, operation: "inspect").0.targets ?? []
        guard let text = targets.first(where: { $0.kind == "text" && $0.text == "Hello world" }) else { throw FolioError("Consecutive text fragments were not grouped into an editable line") }
        try check(text.end > text.index, "Fragment grouping must include the complete run")
        let edited = try EditorProcess.run(pdf: source, page: 0, operation: "text", index: text.index, text: "Hello reader").1
        let changed = try DocumentPolicy.parse(edited)
        try check(changed.string?.contains("Hello reader") == true && changed.string?.contains("world") == false, "Text replacement must change the underlying text, not cover it")
        let afterTargets = try EditorProcess.run(pdf: edited, page: 0, operation: "inspect").0.targets ?? []
        try check(abs((afterTargets.first { $0.kind == "text" })!.bounds.minX - text.bounds.minX) < 0.2, "Text replacement must preserve its placement")
        let erased = try EditorProcess.run(pdf: source, page: 0, operation: "text", index: text.index, text: "").1
        try check(PDFDocument(data: erased)?.page(at: 0)?.string?.contains("Hello") != true, "Deleting a text run must remove all original fragments")
        do {
            _ = try EditorProcess.run(pdf: source, page: 0, operation: "text", index: text.index, text: "line\nbreak")
            throw FolioError("Multiline replacement must be rejected")
        } catch let error as FolioError { if error.message == "Multiline replacement must be rejected" { throw error } }
        let images = targets.filter { $0.kind == "image" }
        try check(images.count == 2, "Fixture must have two placements of one shared image")
        let replaced = try EditorProcess.run(pdf: source, page: 0, operation: "image", index: images[0].index, image: blueImage()).1
        let imagePDF = try DocumentPolicy.parse(replaced)
        let first = sample(imagePDF.page(at: 0)!, x: 70, y: 150)
        let second = sample(imagePDF.page(at: 0)!, x: 170, y: 150)
        let otherPage = sample(imagePDF.page(at: 1)!, x: 70, y: 150)
        try check(first.blueComponent > 0.8 && first.redComponent < 0.2, "Chosen image must be replaced")
        try check(second.redComponent > 0.8 && second.blueComponent < 0.2 && otherPage.redComponent > 0.8 && otherPage.blueComponent < 0.2,
                  "Replacing a shared image must not modify other placements or pages")
        let clipped = fixture(clipped: true)
        let clippedTargets = try EditorProcess.run(pdf: clipped, page: 0, operation: "inspect").0.targets!
        let clippedImage = clippedTargets.first { $0.kind == "image" }!
        do { _ = try EditorProcess.run(pdf: clipped, page: 0, operation: "image", index: clippedImage.index, image: blueImage()); throw FolioError("Clipped image replacement must be rejected") }
        catch let error as FolioError { if error.message == "Clipped image replacement must be rejected" { throw error } }
        do { _ = try EditorProcess.run(pdf: source, page: 0, operation: "text", index: text.index, text: "Hello 🦊"); throw FolioError("Missing font glyph must be rejected") }
        catch let error as FolioError { if error.message == "Missing font glyph must be rejected" { throw error } }
        let inserted = try EditorProcess.run(pdf: source, page: 0, operation: "insertImage", image: blueImage(), box: NSRect(x: 200, y: 30, width: 40, height: 50)).1
        let insertedTargets = try EditorProcess.run(pdf: inserted, page: 0, operation: "inspect").0.targets ?? []
        try check(insertedTargets.filter { $0.kind == "image" }.count == 3, "Image insertion must add a distinct PDF object")
        let note = PDFAnnotation(bounds: NSRect(x: 20, y: 20, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Retain this note"; pdf.page(at: 0)!.addAnnotation(note)
        let annotated = pdf.dataRepresentation()!
        let annotatedTargets = try EditorProcess.run(pdf: annotated, page: 0, operation: "inspect").0.targets ?? []
        let annotatedText = annotatedTargets.first { $0.kind == "text" }!
        let withNote = try EditorProcess.run(pdf: annotated, page: 0, operation: "text", index: annotatedText.index, text: "Updated").1
        try check(PDFDocument(data: withNote)?.page(at: 0)?.annotations.contains { $0.contents == "Retain this note" } == true,
                  "Content edits must preserve annotations")
        let file = PDFFile(); try file.read(from: source, ofType: "com.adobe.pdf")
        file.undoManager!.groupsByEvent = false; file.undoManager!.beginUndoGrouping()
        try file.mutate("Rotate") { $0.page(at: 0)!.rotation = 90 }
        file.undoManager!.endUndoGrouping()
        try check(file.isDocumentEdited && file.pdf.page(at: 0)!.rotation == 90, "Page edits must update the document's unsaved state")
        file.undoManager!.undo()
        try check(!file.isDocumentEdited && file.pdf.page(at: 0)!.rotation == 0, "Undo must restore both page state and saved identity")
        file.undoManager!.redo()
        try check(file.isDocumentEdited && file.pdf.page(at: 0)!.rotation == 90, "Redo must restore the page edit")
        let revision = file.revision
        do { try file.replaceContents(edited, name: "Stale Edit", expectedRevision: UUID()); throw FolioError("Stale editor result must be rejected") }
        catch let error as FolioError { if error.message == "Stale editor result must be rejected" { throw error } }
        try check(file.revision == revision, "Rejected stale result must not change the document")
        let signed = fixture(signed: true)
        try check(DocumentPolicy.hasSignatureField(signed), "Signature fields must make a document read-only")
        do { _ = try EditorProcess.run(pdf: signed, page: 0, operation: "inspect"); throw FolioError("Signed PDF must be rejected by editor") }
        catch let error as FolioError { if error.message == "Signed PDF must be rejected by editor" { throw error } }
        let protected = PDFDocument(data: source)!.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "secret", PDFDocumentWriteOption.ownerPasswordOption: "owner"])!
        let encrypted = try DocumentPolicy.parse(protected)
        try check(encrypted.isLocked && encrypted.unlock(withPassword: "secret"), "Password-protected PDF must remain readable after unlocking")
        do { _ = try EditorProcess.run(pdf: protected, page: 0, operation: "inspect"); throw FolioError("Encrypted PDF must be rejected by editor") }
        catch let error as FolioError { if error.message == "Encrypted PDF must be rejected by editor" { throw error } }
        // Construct and lay out the reader offscreen; do not order a window onto the desktop.
        let window = ReaderWindowController(file: file)
        file.addWindowController(window); window.window!.contentView!.layoutSubtreeIfNeeded()
        try check(window.reader.pdfView.document === file.pdf, "Reader window must show the document model")
        let splits = window.window!.contentView!.subviews.flatMap { $0.subviews }.compactMap { $0 as? NSSplitView }
        try check(splits.allSatisfy { !$0.hasAmbiguousLayout }, "Reader split view must have an unambiguous layout")
        window.window!.close(); file.removeWindowController(window)
        print("Verified: network denial; real text replacement/deletion; glyph rejection; image insertion and shared-image isolation; clipping rejection; annotation retention; undo/redo; stale edits; protected documents; offscreen reader")
    }

    static func renderPreview() throws -> Data {
        let file = PDFFile(); try file.read(from: fixture(), ofType: "com.adobe.pdf")
        let controller = ReaderWindowController(file: file); file.addWindowController(controller)
        let window = controller.window!
        window.appearance = NSAppearance(named: .aqua)
        window.setFrameOrigin(NSPoint(x: -16000, y: -16000))
        window.orderBack(nil)
        controller.reader.editContent(nil)
        for _ in 0..<8 { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1)) }
        let view = window.contentView!
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw FolioError("Couldn't render the offscreen reader") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        window.close(); file.removeWindowController(controller)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw FolioError("Couldn't encode the reader preview") }
        return data
    }
}
