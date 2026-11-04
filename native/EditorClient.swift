import AppKit
import PDFKit

struct FolioError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

struct EditTarget: Decodable {
    let index: Int
    let end: Int
    let kind: String
    let text: String
    let box: [Double]
    var bounds: NSRect { NSRect(x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1]) }
}

struct EditorReply: Decodable {
    let ok: Bool
    let bytes: Int
    let error: String?
    let targets: [EditTarget]?
}

enum EditorProcess {
    static let maximumBytes = 64 * 1024 * 1024

    // Called on a worker queue. The helper's only input is the selected document snapshot.
    static func run(pdf: Data, page: Int, operation: String, index: Int? = nil,
                    text: String? = nil, image: Data = Data(), box: NSRect? = nil) throws -> (EditorReply, Data) {
        guard !pdf.isEmpty, pdf.count <= maximumBytes else { throw FolioError("Content editing supports PDFs up to 64 MiB.") }
        guard image.count <= 24 * 1024 * 1024 else { throw FolioError("Choose an image under 24 MiB.") }
        var request: [String: Any] = ["operation": operation, "page": page, "pdfLength": pdf.count, "imageLength": image.count]
        if let index { request["index"] = index }
        if let text { request["text"] = text }
        if let box { request["box"] = [box.minX, box.minY, box.maxX, box.maxY] }
        var header = try JSONSerialization.data(withJSONObject: request)
        guard header.count < 65536 else { throw FolioError("This replacement text is too long.") }
        header.append(10)
        let process = Process()
        process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/FolioEditor")
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45, execute: watchdog)
        defer { watchdog.cancel(); if process.isRunning { process.terminate() } }
        do {
            try input.fileHandleForWriting.write(contentsOf: header)
            try input.fileHandleForWriting.write(contentsOf: pdf)
            try input.fileHandleForWriting.write(contentsOf: image)
            try input.fileHandleForWriting.close()
        } catch {
            try? input.fileHandleForWriting.close()
            throw FolioError("The PDF editor stopped before accepting the document.")
        }
        var response = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            guard response.count + chunk.count <= maximumBytes + 8 * 1024 * 1024 else {
                throw FolioError("The PDF editor returned too much data.")
            }
            response.append(chunk)
        }
        process.waitUntilExit()
        guard let newline = response.firstIndex(of: 10), newline <= 8 * 1024 * 1024 else {
            throw FolioError("The PDF editor stopped. Your document has not changed.")
        }
        let result = try JSONDecoder().decode(EditorReply.self, from: response[..<newline])
        guard result.ok, process.terminationStatus == 0 else { throw FolioError(result.error ?? "The PDF editor could not complete this change.") }
        let data = Data(response[response.index(after: newline)...])
        guard result.bytes == data.count, data.count <= maximumBytes else { throw FolioError("The editor returned an incomplete document.") }
        if let targets = result.targets {
            guard targets.count <= 10000, targets.allSatisfy({ $0.box.count == 4 && $0.box.allSatisfy(\.isFinite) }) else {
                throw FolioError("The editor returned invalid page items.")
            }
        }
        return (result, data)
    }
}

enum DocumentPolicy {
    static let maximumBytes = 300 * 1024 * 1024
    static func parse(_ data: Data) throws -> PDFDocument {
        guard data.count <= maximumBytes, data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil,
              let document = PDFDocument(data: data) else { throw FolioError("Choose a PDF smaller than 300 MiB.") }
        guard document.isLocked || (document.pageCount > 0 && document.pageCount <= 10000) else {
            throw FolioError("This PDF has no pages or exceeds the 10,000-page limit.")
        }
        return document
    }

    // Conservatively treat signature fields as read-only, including empty fields.
    static func hasSignatureField(_ data: Data) -> Bool {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let catalog = document.catalog else { return true }
        var permissions: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Perms", &permissions) { return true }
        var form: CGPDFDictionaryRef?, fields: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "AcroForm", &form), let form,
              CGPDFDictionaryGetArray(form, "Fields", &fields), let fields else { return false }
        var visited = 0
        func containsSignature(_ array: CGPDFArrayRef, depth: Int) -> Bool {
            if depth > 16 || visited > 10000 { return true }
            for index in 0..<CGPDFArrayGetCount(array) {
                visited += 1
                if visited > 10000 { return true }
                var field: CGPDFDictionaryRef?
                guard CGPDFArrayGetDictionary(array, index, &field), let field else { continue }
                var type: UnsafePointer<CChar>?
                if CGPDFDictionaryGetName(field, "FT", &type), let type, String(cString: type) == "Sig" { return true }
                var children: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(field, "Kids", &children), let children,
                   containsSignature(children, depth: depth + 1) { return true }
            }
            return false
        }
        return containsSignature(fields, depth: 0)
    }
}
