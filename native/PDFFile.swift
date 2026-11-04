import AppKit
import PDFKit

@MainActor final class PDFFile: NSDocument {
    var pdf = PDFDocument()
    private(set) var revision = UUID()
    private var savedRevision: UUID
    private var source = Data()
    private(set) var signed = false

    override init() {
        savedRevision = revision
        super.init()
        let page = PDFPage()
        page.setBounds(NSRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
        pdf.insert(page, at: 0)
        hasUndoManager = true
        undoManager?.levelsOfUndo = 10
    }
    override class var autosavesInPlace: Bool { false }
    override class var autosavesDrafts: Bool { false }
    override class var preservesVersions: Bool { false }
    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool { false }
    override var isDocumentEdited: Bool { revision != savedRevision }

    override func read(from url: URL, ofType typeName: String) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= DocumentPolicy.maximumBytes else {
            throw FolioError("Choose a regular PDF file smaller than 300 MiB.")
        }
        try read(from: Data(contentsOf: url, options: .mappedIfSafe), ofType: typeName)
    }
    override func read(from data: Data, ofType typeName: String) throws {
        try MainActor.assumeIsolated {
            pdf = try DocumentPolicy.parse(data)
            source = data
            signed = DocumentPolicy.hasSignatureField(data)
            revision = UUID(); savedRevision = revision
            undoManager?.removeAllActions()
        }
    }
    override func data(ofType typeName: String) throws -> Data {
        if pdf.isEncrypted || signed { return source }
        guard let data = pdf.dataRepresentation(), data.count <= DocumentPolicy.maximumBytes else {
            throw FolioError("Couldn't serialize this PDF within the 300 MiB limit.")
        }
        return data
    }
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        let savingRevision = revision
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            if error == nil && saveOperation != .saveToOperation {
                self?.savedRevision = savingRevision
                self?.refreshEditedState()
            }
            completionHandler(error)
        }
    }
    func ensureEditable() throws {
        guard !pdf.isEncrypted, !pdf.isLocked, !signed else {
            throw FolioError("Encrypted PDFs and PDFs with signature fields are read-only. Open an unsigned, unencrypted copy to edit.")
        }
    }
    func snapshot() throws -> Data { try data(ofType: "com.adobe.pdf") }

    func mutate(_ name: String, _ action: (PDFDocument) throws -> Void) throws {
        try ensureEditable()
        let before = try snapshot(), identity = revision
        // Work on a copy so a failed operation never leaves a partial mutation behind.
        let working = try DocumentPolicy.parse(before)
        try action(working)
        guard let changed = working.dataRepresentation() else { throw FolioError("Couldn't prepare the edited document.") }
        try install(changed, name: name, before: before, identity: identity)
    }
    func replaceContents(_ data: Data, name: String, expectedRevision: UUID) throws {
        guard revision == expectedRevision else { throw FolioError("The document changed while editing. Select the item again.") }
        try ensureEditable()
        try install(data, name: name, before: snapshot(), identity: revision)
    }
    private func install(_ data: Data, name: String, before: Data, identity: UUID) throws {
        let replacement = try DocumentPolicy.parse(data)
        guard !replacement.isLocked else { throw FolioError("Couldn't read back the changed document.") }
        undoManager?.registerUndo(withTarget: self) { target in target.restore(before, identity: identity, name: name) }
        undoManager?.setActionName(name)
        pdf = replacement; revision = UUID()
        updateChangeCount(.changeDone)
        reloadWindows()
    }
    private func restore(_ data: Data, identity: UUID, name: String) {
        do {
            let inverse = try snapshot(), inverseIdentity = revision
            pdf = try DocumentPolicy.parse(data); revision = identity
            undoManager?.registerUndo(withTarget: self) { target in target.restore(inverse, identity: inverseIdentity, name: name) }
            undoManager?.setActionName(name)
            reloadWindows()
        } catch { presentError(error) }
    }
    private func refreshEditedState() { for controller in windowControllers { controller.window?.isDocumentEdited = isDocumentEdited } }
    private func reloadWindows() {
        for case let controller as ReaderWindowController in windowControllers { controller.reader.reloadDocument() }
        refreshEditedState()
    }
    override func makeWindowControllers() {
        let controller = ReaderWindowController(file: self)
        addWindowController(controller)
    }
}

@MainActor final class PDFFileController: NSDocumentController {
    override var defaultType: String? { "com.adobe.pdf" }
    override func documentClass(forType typeName: String) -> AnyClass? { typeName == "com.adobe.pdf" ? PDFFile.self : nil }
    override func noteNewRecentDocumentURL(_ url: URL) { /* Deliberately retain no recent-document list. */ }
}
