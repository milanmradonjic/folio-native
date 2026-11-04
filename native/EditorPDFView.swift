import AppKit
import PDFKit

enum ReaderTool: Int, CaseIterable {
    case read, edit, text, ink, rectangle, oval, arrow, image
    var title: String { ["Read", "Edit Content", "Text Box", "Draw", "Rectangle", "Oval", "Arrow", "Image / Sign"][rawValue] }
}

@MainActor private final class PageEditOverlay: NSView {
    weak var owner: EditorPDFView?
    weak var page: PDFPage?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { if let owner, let page { owner.drawOverlay(page: page, in: self) } }
}

@MainActor final class EditorPDFView: PDFView, @preconcurrency PDFPageOverlayViewProvider {
    var tool: ReaderTool = .read { didSet { currentSelection = nil; refreshOverlay() } }
    var targets: [EditTarget] = [] { didSet { refreshOverlay() } }
    var targetPage: PDFPage?
    var contentClick: ((PDFPage, NSPoint) -> Void)?
    var finishedGesture: ((ReaderTool, PDFPage, [NSPoint]) -> Void)?
    var openExternal: ((URL) -> Void)?
    var annotationClick: ((PDFPage, PDFAnnotation) -> Void)?
    var cancelledTool: (() -> Void)?
    private var gesturePage: PDFPage?
    private var points: [NSPoint] = []
    private var dragStart: NSPoint?
    private var overlays: [ObjectIdentifier: PageEditOverlay] = [:]

    override init(frame: NSRect) {
        super.init(frame: frame)
        pageOverlayViewProvider = self
        isInMarkupMode = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = PageEditOverlay()
        overlay.owner = self; overlay.page = page
        overlays[ObjectIdentifier(page)] = overlay
        return overlay
    }
    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        if overlays[ObjectIdentifier(page)] === overlayView { overlays.removeValue(forKey: ObjectIdentifier(page)) }
    }

    func refreshOverlay() {
        overlays.values.forEach { $0.needsDisplay = true }
    }
    fileprivate func drawOverlay(page: PDFPage, in overlay: NSView) {
        func rectangle(_ rect: NSRect) -> NSRect { overlay.convert(convert(rect, from: page), from: self) }
        func point(_ point: NSPoint) -> NSPoint { overlay.convert(convert(point, from: page), from: self) }
        if tool == .edit && page === targetPage {
            for target in targets {
                let color: NSColor = target.kind == "text" ? .systemBlue : .systemOrange
                let path = NSBezierPath(rect: rectangle(target.bounds).insetBy(dx: -2, dy: -2))
                color.withAlphaComponent(0.055).setFill(); path.fill()
                color.withAlphaComponent(0.8).setStroke(); path.lineWidth = 1; path.stroke()
            }
        }
        guard page === gesturePage, let first = points.first, let last = points.last else { return }
        NSColor.controlAccentColor.setStroke()
        let rect = NSRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
        let path: NSBezierPath
        switch tool {
        case .ink:
            path = NSBezierPath(); path.move(to: point(first)); points.dropFirst().forEach { path.line(to: point($0)) }
        case .oval: path = NSBezierPath(ovalIn: rectangle(rect))
        case .arrow:
            path = NSBezierPath(); path.move(to: point(first)); path.line(to: point(last))
        default: path = NSBezierPath(rect: rectangle(rect))
        }
        path.lineWidth = max(1, 2 * scaleFactor); path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if tool == .read {
            if let page = page(for: location, nearest: false), let annotation = page.annotation(at: convert(location, to: page)),
               annotation.type == "Widget" || (event.clickCount > 1 && ["Text", "FreeText"].contains(annotation.type ?? "")) {
                annotationClick?(page, annotation); return
            }
            super.mouseDown(with: event); return
        }
        guard let page = page(for: location, nearest: false) else { return }
        let point = convert(location, to: page)
        if tool == .edit { contentClick?(page, point); return }
        gesturePage = page; dragStart = point; points = [point]
        refreshOverlay()
    }
    override func mouseDragged(with event: NSEvent) {
        guard tool != .read else { super.mouseDragged(with: event); return }
        guard let page = gesturePage else { return }
        let point = convert(convert(event.locationInWindow, from: nil), to: page)
        let bounds = page.bounds(for: displayBox)
        let clamped = NSPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        if tool == .ink {
            if points.count < 20000 { points.append(clamped) }
        } else { points = [dragStart!, clamped] }
        refreshOverlay()
    }
    override func mouseUp(with event: NSEvent) {
        guard tool != .read else { super.mouseUp(with: event); return }
        guard let page = gesturePage else { return }
        let finished = points
        gesturePage = nil; points = []; dragStart = nil; refreshOverlay()
        finishedGesture?(tool, page, finished)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelledTool?(); return }
        // Keep keyboard focus navigation out of PDFKit's untracked form editor.
        if event.keyCode == 48 { window?.selectNextKeyView(self); return }
        super.keyDown(with: event)
    }
    // Only in-document navigation runs automatically. External actions require a native confirmation.
    override func perform(_ action: PDFAction) {
        if action is PDFActionGoTo { super.perform(action) }
        else if let link = action as? PDFActionURL, let url = link.url { openExternal?(url) }
        else if let named = action as? PDFActionNamed {
            switch named.name {
            case .firstPage: goToFirstPage(nil)
            case .lastPage: goToLastPage(nil)
            case .nextPage: goToNextPage(nil)
            case .previousPage: goToPreviousPage(nil)
            default: break
            }
        }
    }
}
