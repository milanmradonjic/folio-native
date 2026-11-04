import AppKit
import PDFKit
import UniformTypeIdentifiers

@MainActor private final class ReaderBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) { NSColor.windowBackgroundColor.setFill(); dirtyRect.fill() }
}

@MainActor final class ReaderWindowController: NSWindowController {
    let reader: ReaderController
    init(file: PDFFile) {
        reader = ReaderController(file: file)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 850),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Folio Native"
        window.minSize = NSSize(width: 880, height: 600)
        window.tabbingMode = .preferred; window.tabbingIdentifier = "FolioNativePDF"
        window.isRestorable = false
        window.contentViewController = reader
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

@MainActor final class ReaderController: NSViewController, @preconcurrency PDFViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
                                          NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    unowned let file: PDFFile
    let pdfView = EditorPDFView()
    private let splitController = NSSplitViewController()
    private var split: NSSplitView { splitController.splitView }
    private var sidebarItem: NSSplitViewItem!
    private var minimumSidebarWidth: CGFloat = 250
    private let sidebar = NSView()
    private let thumbnails = PDFThumbnailView()
    private let outline = NSOutlineView()
    private let notes = NSTableView()
    private let sidebarPages = NSView()
    private let outlineScroll = NSScrollView(), notesScroll = NSScrollView()
    private let pageField = NSTextField(string: "1")
    private let pageCount = NSTextField(labelWithString: "of 1")
    private let search = NSSearchField()
    private let status = NSTextField(labelWithString: "")
    private let tools = NSPopUpButton()
    private let inkColor = NSColorWell()
    private let busyIndicator = NSProgressIndicator()
    private var sidebarMode: NSSegmentedControl!
    private var noteEntries: [(Int, PDFAnnotation)] = []
    private var busy = false
    private var editGeneration = UUID()
    private var observers: [NSObjectProtocol] = []
    private var scrollMonitor: Any?
    private let editorQueue = DispatchQueue(label: "local.folio.native.editor", qos: .userInitiated)

    init(file: PDFFile) { self.file = file; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    private func button(_ title: String, _ symbol: String, _ action: Selector) -> NSButton {
        let control = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!, target: self, action: action)
        control.bezelStyle = .texturedRounded; control.toolTip = title
        control.setAccessibilityLabel(title)
        return control
    }
    override func loadView() {
        view = ReaderBackgroundView()
        let root = NSStackView(); root.orientation = .vertical; root.spacing = 0; root.alignment = .leading
        root.distribution = .fill
        root.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor), root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), root.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        let navigation = NSStackView(); navigation.spacing = 7; navigation.edgeInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
        navigation.heightAnchor.constraint(equalToConstant: 44).isActive = true
        navigation.addArrangedSubview(button("Show or hide sidebar", "sidebar.left", #selector(toggleSidebar(_:))))
        navigation.addArrangedSubview(button("Open PDF", "folder", #selector(openPDF(_:))))
        navigation.addArrangedSubview(button("Save PDF", "square.and.arrow.down", #selector(savePDF(_:))))
        navigation.addArrangedSubview(button("Previous page", "chevron.left", #selector(previousPage(_:))))
        navigation.addArrangedSubview(button("Next page", "chevron.right", #selector(nextPage(_:))))
        pageField.alignment = .right; pageField.target = self; pageField.action = #selector(pageEntered(_:)); pageField.setAccessibilityLabel("Page number")
        pageField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        navigation.addArrangedSubview(pageField); navigation.addArrangedSubview(pageCount)
        navigation.addArrangedSubview(NSView())
        navigation.addArrangedSubview(button("Zoom out", "minus.magnifyingglass", #selector(zoomOut(_:))))
        navigation.addArrangedSubview(button("Fit to window", "arrow.up.left.and.arrow.down.right", #selector(fitPage(_:))))
        navigation.addArrangedSubview(button("Zoom in", "plus.magnifyingglass", #selector(zoomIn(_:))))
        search.placeholderString = "Find in PDF"; search.target = self; search.action = #selector(findNext(_:))
        search.sendsSearchStringImmediately = false; search.sendsWholeSearchString = true
        search.widthAnchor.constraint(equalToConstant: 220).isActive = true
        navigation.addArrangedSubview(search)
        root.addArrangedSubview(navigation)
        let editBar = NSStackView(); editBar.spacing = 8; editBar.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 8, right: 12)
        editBar.heightAnchor.constraint(equalToConstant: 36).isActive = true
        tools.addItems(withTitles: ReaderTool.allCases.map(\.title)); tools.target = self; tools.action = #selector(toolChanged(_:))
        tools.setAccessibilityLabel("Editing tool"); editBar.addArrangedSubview(tools)
        inkColor.color = .systemBlue; inkColor.widthAnchor.constraint(equalToConstant: 44).isActive = true
        inkColor.setAccessibilityLabel("Annotation color"); editBar.addArrangedSubview(inkColor)
        editBar.addArrangedSubview(button("Highlight selected text", "highlighter", #selector(highlight(_:))))
        editBar.addArrangedSubview(button("Add a note", "note.text.badge.plus", #selector(addNote(_:))))
        editBar.addArrangedSubview(button("Rotate this page", "rotate.right", #selector(rotatePage(_:))))
        editBar.addArrangedSubview(button("Unlock PDF", "lock.open", #selector(unlockPDF(_:))))
        busyIndicator.style = .spinning; busyIndicator.controlSize = .small; busyIndicator.isDisplayedWhenStopped = false
        editBar.addArrangedSubview(busyIndicator)
        status.lineBreakMode = .byTruncatingTail; status.textColor = .secondaryLabelColor
        editBar.addArrangedSubview(status)
        root.addArrangedSubview(editBar)
        configureSidebar()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        let sidebarController = NSViewController(); sidebarController.view = sidebar
        let documentController = NSViewController(); documentController.view = pdfView
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = minimumSidebarWidth
        sidebarItem.maximumThickness = 500
        sidebarItem.canCollapse = true
        // Interactive divider dragging has priority 490; a higher hold locks it in place.
        sidebarItem.holdingPriority = .defaultLow
        let documentItem = NSSplitViewItem(viewController: documentController)
        documentItem.minimumThickness = 360
        addChild(splitController)
        splitController.addSplitViewItem(sidebarItem)
        splitController.addSplitViewItem(documentItem)
        let splitContainer = splitController.view
        split.isVertical = true; split.dividerStyle = .thin
        splitContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
        root.addArrangedSubview(splitContainer)
        [navigation, editBar, splitContainer].forEach { $0.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true }
        pdfView.delegate = self; pdfView.autoScales = true; pdfView.minScaleFactor = 0.1; pdfView.maxScaleFactor = 10
        pdfView.displayMode = .singlePageContinuous; pdfView.backgroundColor = .windowBackgroundColor
        pdfView.openExternal = { [weak self] url in self?.confirmExternal(url) }
        pdfView.annotationClick = { [weak self] page, annotation in self?.editAnnotation(page: page, annotation: annotation) }
        pdfView.cancelledTool = { [weak self] in self?.setTool(.read) }
        pdfView.contentClick = { [weak self] page, point in self?.clickedContent(page, point: point) }
        pdfView.finishedGesture = { [weak self] tool, page, points in self?.finishGesture(tool, page: page, points: points) }
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageChanged() }
        })
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.modifierFlags.contains(.command), event.window === self.view.window else { return event }
            let point = self.pdfView.convert(event.locationInWindow, from: nil)
            guard self.pdfView.bounds.contains(point) else { return event }
            self.pdfView.zoomByScroll(delta: event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.002 : 0.08))
            return nil
        }
        reloadDocument()
    }
    private func configureSidebar() {
        sidebarMode = NSSegmentedControl(labels: ["Pages", "Outline", "Notes"], trackingMode: .selectOne, target: self, action: #selector(changeSidebar(_:)))
        sidebarMode.selectedSegment = 0
        sidebarMode.setContentCompressionResistancePriority(.required, for: .horizontal)
        minimumSidebarWidth = max(250, sidebarMode.fittingSize.width + 14)
        let layout = NSStackView(views: [sidebarMode, sidebarPages]); layout.orientation = .vertical; layout.spacing = 8
        layout.distribution = .fill
        sidebarMode.heightAnchor.constraint(equalToConstant: 24).isActive = true
        layout.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(layout)
        NSLayoutConstraint.activate([layout.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 7),
            layout.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -7), layout.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 8),
            layout.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor), sidebarPages.widthAnchor.constraint(equalTo: layout.widthAnchor)])
        thumbnails.pdfView = pdfView; thumbnails.thumbnailSize = NSSize(width: 130, height: 170)
        thumbnails.backgroundColor = .windowBackgroundColor
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outline")))
        outline.outlineTableColumn = outline.tableColumns.first; outline.headerView = nil
        outline.dataSource = self; outline.delegate = self
        outline.target = self; outline.action = #selector(outlineSelected(_:))
        outlineScroll.documentView = outline; outlineScroll.hasVerticalScroller = true
        notes.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("notes")))
        notes.headerView = nil; notes.dataSource = self; notes.delegate = self; notes.rowHeight = 46
        notes.target = self; notes.action = #selector(noteSelected(_:)); notes.doubleAction = #selector(editNote(_:))
        notesScroll.documentView = notes; notesScroll.hasVerticalScroller = true
        let noteMenu = NSMenu(); let edit = NSMenuItem(title: "Edit Note…", action: #selector(editNote(_:)), keyEquivalent: "")
        edit.target = self; noteMenu.addItem(edit)
        let remove = NSMenuItem(title: "Delete Annotation", action: #selector(deleteAnnotation(_:)), keyEquivalent: "")
        remove.target = self; noteMenu.addItem(remove); notes.menu = noteMenu
        for child in [thumbnails, outlineScroll, notesScroll] {
            child.translatesAutoresizingMaskIntoConstraints = false; sidebarPages.addSubview(child)
            NSLayoutConstraint.activate([child.leadingAnchor.constraint(equalTo: sidebarPages.leadingAnchor), child.trailingAnchor.constraint(equalTo: sidebarPages.trailingAnchor),
                child.topAnchor.constraint(equalTo: sidebarPages.topAnchor), child.bottomAnchor.constraint(equalTo: sidebarPages.bottomAnchor)])
        }
        changeSidebar(nil)
    }
    func reloadDocument() {
        guard isViewLoaded else { return }
        let page = pdfView.currentPage.flatMap { pdfView.document?.index(for: $0) } ?? 0
        editGeneration = UUID(); pdfView.targets = []; pdfView.targetPage = nil
        pdfView.document = file.pdf
        if let target = file.pdf.page(at: min(page, max(0, file.pdf.pageCount - 1))) { pdfView.go(to: target) }
        thumbnails.pdfView = pdfView; outline.reloadData(); reloadNotes(); pageChanged()
        if file.pdf.isLocked { status.stringValue = "This PDF is locked. Choose Unlock to read it." }
        else if file.pdf.isEncrypted || file.signed { status.stringValue = "Read-only protected document" }
    }
    private func reloadNotes() {
        let types: Set<String> = ["Text", "FreeText", "Highlight", "Ink", "Square", "Circle", "Line", "Stamp", "Underline", "StrikeOut"]
        noteEntries = (0..<file.pdf.pageCount).flatMap { page in (file.pdf.page(at: page)?.annotations ?? []).filter { types.contains($0.type ?? "") }.map { (page, $0) } }
        notes.reloadData()
    }
    private var currentIndex: Int { pdfView.currentPage.map { file.pdf.index(for: $0) } ?? 0 }
    private func pageChanged() {
        pageField.stringValue = file.pdf.isLocked ? "—" : String(currentIndex + 1)
        pageCount.stringValue = "of \(file.pdf.pageCount)"
        if (pdfView.tool == .edit || pdfView.tool == .deleteObject) && !busy { inspectPage() }
    }
    private func report(_ error: Error) { NSAlert(error: error).runModal() }
    private func performMutation(_ name: String, _ mutation: (PDFDocument) throws -> Void) {
        guard !busy else { NSSound.beep(); return }
        do { try file.mutate(name, mutation) } catch { report(error) }
    }
    private func askText(_ title: String, value: String = "", detail: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 440, height: 26)
        alert.accessoryView = field; alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
    @objc private func openPDF(_ sender: Any?) { NSDocumentController.shared.openDocument(sender) }
    @objc private func savePDF(_ sender: Any?) { file.save(sender) }
    @objc func previousPage(_ sender: Any?) { pdfView.goToPreviousPage(sender) }
    @objc func nextPage(_ sender: Any?) { pdfView.goToNextPage(sender) }
    @objc func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }
    @objc func fitPage(_ sender: Any?) { pdfView.autoScales = true }
    @objc func twoPages(_ sender: Any?) { pdfView.displayMode = pdfView.displayMode == .twoUpContinuous ? .singlePageContinuous : .twoUpContinuous }
    @objc func focusSearch(_ sender: Any?) { view.window?.makeFirstResponder(search) }
    @objc func findNext(_ sender: Any?) { find(backwards: false) }
    @objc func findPrevious(_ sender: Any?) { find(backwards: true) }
    private func find(backwards: Bool) {
        guard !search.stringValue.isEmpty else { focusSearch(nil); return }
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        let match = file.pdf.findString(search.stringValue, fromSelection: pdfView.currentSelection, withOptions: options)
            ?? file.pdf.findString(search.stringValue, fromSelection: nil, withOptions: options)
        guard let match else { status.stringValue = "No matches"; NSSound.beep(); return }
        pdfView.setCurrentSelection(match, animate: true); pdfView.go(to: match)
        status.stringValue = ""
    }
    @objc private func pageEntered(_ sender: Any?) {
        guard let index = Int(pageField.stringValue), let page = file.pdf.page(at: index - 1) else { pageChanged(); NSSound.beep(); return }
        pdfView.go(to: page)
    }
    @objc func goToPage(_ sender: Any?) {
        guard let input = askText("Go to Page", value: String(currentIndex + 1)), let number = Int(input), let page = file.pdf.page(at: number - 1) else { return }
        pdfView.go(to: page)
    }
    @objc func toggleSidebar(_ sender: Any?) { sidebarItem.isCollapsed.toggle() }

    func checkSidebarResizing() throws {
        view.layoutSubtreeIfNeeded()
        let initial = sidebar.frame.width
        guard initial >= minimumSidebarWidth - 1,
              sidebarMode.frame.width >= sidebarMode.fittingSize.width - 1 else {
            throw FolioError("Sidebar clips its navigation labels (width \(initial), minimum \(minimumSidebarWidth), control \(sidebarMode.frame.width), fitting \(sidebarMode.fittingSize.width))")
        }
        split.setPosition(initial + 90, ofDividerAt: 0)
        view.layoutSubtreeIfNeeded()
        guard sidebar.frame.width > initial + 60 else { throw FolioError("Sidebar divider cannot expand") }
        split.setPosition(minimumSidebarWidth, ofDividerAt: 0)
        view.layoutSubtreeIfNeeded()
        guard abs(sidebar.frame.width - minimumSidebarWidth) < 2 else { throw FolioError("Sidebar divider cannot shrink") }
        sidebarItem.isCollapsed = true
        view.layoutSubtreeIfNeeded()
        sidebarItem.isCollapsed = false
        view.layoutSubtreeIfNeeded()
        guard sidebarMode.frame.width >= sidebarMode.fittingSize.width - 1 else { throw FolioError("Restored sidebar clips its labels") }
    }
    @objc private func changeSidebar(_ sender: Any?) {
        thumbnails.isHidden = sidebarMode.selectedSegment != 0; outlineScroll.isHidden = sidebarMode.selectedSegment != 1; notesScroll.isHidden = sidebarMode.selectedSegment != 2
    }
    @objc private func unlockPDF(_ sender: Any?) {
        guard file.pdf.isLocked else { status.stringValue = "This PDF is already unlocked."; return }
        let alert = NSAlert(); alert.messageText = "Unlock PDF"; alert.addButton(withTitle: "Unlock"); alert.addButton(withTitle: "Cancel")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 26)); alert.accessoryView = password
        alert.window.initialFirstResponder = password
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard file.pdf.unlock(withPassword: password.stringValue) else { report(FolioError("That password did not unlock the PDF.")); return }
        password.stringValue = ""; reloadDocument()
    }
    @objc private func toolChanged(_ sender: Any?) { setTool(ReaderTool(rawValue: tools.indexOfSelectedItem) ?? .read) }
    private func setTool(_ tool: ReaderTool) {
        guard !busy || tool == .read else { return }
        if tool != .read { do { try file.ensureEditable() } catch { tools.selectItem(at: 0); report(error); return } }
        pdfView.tool = tool; tools.selectItem(at: tool.rawValue)
        status.stringValue = tool == .deleteObject ? "Click an object to delete. Click empty space to list all page objects." : tool == .read ? "" : tool == .edit ? "Click outlined text or an image to edit it." : "Drag on the page to place \(tool.title.lowercased())."
        if tool == .edit || tool == .deleteObject { inspectPage() } else { editGeneration = UUID(); pdfView.targets = [] }
    }
    @objc func editContent(_ sender: Any?) { setTool(pdfView.tool == .edit ? .read : .edit) }
    @objc func deleteObject(_ sender: Any?) { setTool(.deleteObject) }
    @objc func addTextBox(_ sender: Any?) { setTool(.text) }
    @objc func drawInk(_ sender: Any?) { setTool(.ink) }
    @objc func addImage(_ sender: Any?) { setTool(.image) }
    private func setBusy(_ value: Bool) {
        busy = value; tools.isEnabled = !value
        if value { busyIndicator.startAnimation(nil) } else { busyIndicator.stopAnimation(nil) }
    }
    private func inspectPage() {
        guard !busy, let page = pdfView.currentPage else { return }
        let index = file.pdf.index(for: page), revision = file.revision, generation = UUID()
        editGeneration = generation; pdfView.targets = []; pdfView.targetPage = page
        do {
            let data = try file.snapshot()
            setBusy(true)
            editorQueue.async { [weak self] in
                let result = Result { try EditorProcess.run(pdf: data, page: index, operation: "inspect") }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.setBusy(false)
                    guard self.editGeneration == generation, self.file.revision == revision, (self.pdfView.tool == .edit || self.pdfView.tool == .deleteObject) else { return }
                    if self.currentIndex != index { self.inspectPage(); return }
                    switch result {
                    case .success(let response): self.pdfView.targets = response.0.targets ?? []
                    case .failure(let error): self.setTool(.read); self.report(error)
                    }
                }
            }
        } catch { report(error) }
    }
    private func clickedContent(_ page: PDFPage, point: NSPoint) {
        guard !busy, page === pdfView.targetPage else { return }
        if pdfView.tool == .deleteObject { chooseObjectToDelete(page, point: point); return }
        let hit = pdfView.targets.filter { $0.kind != "object" && $0.bounds.insetBy(dx: -2, dy: -2).contains(point) }
            .sorted { ($0.kind == "text" ? 0 : 1, $0.bounds.width * $0.bounds.height) < ($1.kind == "text" ? 0 : 1, $1.bounds.width * $1.bounds.height) }.first
        guard let target = hit else { status.stringValue = "No editable text or image here. Scans and grouped artwork are not text objects."; return }
        if target.kind == "text" {
            guard let text = askText("Edit Existing Text", value: target.text, detail: "Keeps the original font and position. Longer text can overlap nearby content. Clear the field to delete this text.") else { return }
            contentOperation("text", page: page, index: target.index, text: text, name: "Edit Text")
        } else if let image = chooseImage() { contentOperation("image", page: page, index: target.index, image: image, name: "Replace Image") }
    }
    private func chooseObjectToDelete(_ page: PDFPage, point: NSPoint) {
        let hits = pdfView.targets.filter { $0.bounds.insetBy(dx: -3, dy: -3).contains(point) }
            .sorted { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
        let candidates = hits.isEmpty ? pdfView.targets : hits
        let annotations = page.annotations.filter { $0.bounds.contains(point) }
        guard !candidates.isEmpty || !annotations.isEmpty else { status.stringValue = "This page has no deletable objects."; return }
        let alert = NSAlert(); alert.messageText = "Delete existing object?"
        alert.informativeText = "Choose the object. Grouped artwork is deleted as a whole. Undo restores the deletion."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 440, height: 28))
        for candidate in candidates { picker.addItem(withTitle: "\(candidate.kind.capitalized) #\(candidate.index + 1): \(candidate.text.prefix(65))") }
        for annotation in annotations { picker.addItem(withTitle: "Annotation: \(annotation.type ?? "Note")") }
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selection = picker.indexOfSelectedItem
        if selection < candidates.count {
            contentOperation("delete", page: page, index: candidates[selection].index, name: "Delete Object")
        } else {
            let annotation = annotations[selection - candidates.count]
            guard let index = page.annotations.firstIndex(where: { $0 === annotation }) else { return }
            let pageIndex = file.pdf.index(for: page)
            performMutation("Delete Annotation") { document in
                if let target = document.page(at: pageIndex) { target.removeAnnotation(target.annotations[index]) }
            }
        }
    }
    private func chooseImage() -> Data? {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= 24 * 1024 * 1024 else { throw FolioError("Choose an image under 24 MiB.") }
            return try Data(contentsOf: url)
        } catch { report(error); return nil }
    }
    private func contentOperation(_ operation: String, page: PDFPage, index: Int? = nil, text: String? = nil,
                                  image: Data = Data(), box: NSRect? = nil, name: String) {
        guard !busy else { return }
        do {
            let data = try file.snapshot(), revision = file.revision, pageIndex = file.pdf.index(for: page)
            setBusy(true); status.stringValue = "Applying edit…"
            editorQueue.async { [weak self] in
                let result = Result { try EditorProcess.run(pdf: data, page: pageIndex, operation: operation, index: index, text: text, image: image, box: box) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }; self.setBusy(false)
                    do {
                        let response = try result.get()
                        try self.file.replaceContents(response.1, name: name, expectedRevision: revision)
                        self.status.stringValue = "\(name) applied. Save to keep your changes."
                    } catch { self.report(error); if self.pdfView.tool == .edit || self.pdfView.tool == .deleteObject { self.inspectPage() } }
                }
            }
        } catch { report(error) }
    }
    private func finishGesture(_ tool: ReaderTool, page: PDFPage, points: [NSPoint]) {
        guard !busy, let start = points.first, let end = points.last else { return }
        let index = file.pdf.index(for: page)
        var rect = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        if rect.width < 3 || rect.height < 3 { rect = NSRect(x: start.x, y: start.y - 38, width: 180, height: 40).intersection(page.bounds(for: .mediaBox)) }
        if tool == .image {
            guard let image = chooseImage() else { return }
            contentOperation("insertImage", page: page, image: image, box: rect, name: "Place Image")
            return
        }
        let text: String?
        if tool == .text { text = askText("Add Text Box"); if text?.isEmpty != false { return } } else { text = nil }
        let color = inkColor.color.usingColorSpace(.deviceRGB) ?? NSColor(deviceRed: 0.1, green: 0.3, blue: 0.9, alpha: 1)
        performMutation(tool.title) { document in
            guard let targetPage = document.page(at: index) else { return }
            let annotation: PDFAnnotation
            switch tool {
            case .text:
                annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
                annotation.font = NSFont.systemFont(ofSize: 14); annotation.fontColor = color; annotation.color = .clear
                annotation.contents = text
            case .ink:
                guard points.count > 1 else { return }
                let bounds = points.reduce(NSRect(x: start.x, y: start.y, width: 0.01, height: 0.01)) { $0.union(NSRect(x: $1.x, y: $1.y, width: 0.01, height: 0.01)) }.insetBy(dx: -3, dy: -3)
                annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
                let path = NSBezierPath(); path.move(to: NSPoint(x: start.x - bounds.minX, y: start.y - bounds.minY))
                for point in points.dropFirst() { path.line(to: NSPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)) }
                annotation.add(path); annotation.color = color
            case .arrow:
                annotation = PDFAnnotation(bounds: rect.insetBy(dx: -3, dy: -3), forType: .line, withProperties: nil)
                annotation.startPoint = NSPoint(x: start.x - annotation.bounds.minX, y: start.y - annotation.bounds.minY)
                annotation.endPoint = NSPoint(x: end.x - annotation.bounds.minX, y: end.y - annotation.bounds.minY)
                annotation.endLineStyle = .openArrow; annotation.color = color
            default:
                annotation = PDFAnnotation(bounds: rect, forType: tool == .oval ? .circle : .square, withProperties: nil)
                annotation.color = color
            }
            let border = PDFBorder(); border.lineWidth = 2; annotation.border = border
            annotation.shouldPrint = true; targetPage.addAnnotation(annotation)
        }
    }
    @objc func highlight(_ sender: Any?) {
        guard let selection = pdfView.currentSelection, selection.string?.isEmpty == false else { status.stringValue = "Select text first."; return }
        let lines = selection.selectionsByLine().flatMap { line in line.pages.map { (file.pdf.index(for: $0), line.bounds(for: $0)) } }
        performMutation("Highlight") { document in
            for (index, bounds) in lines {
                let mark = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                mark.color = NSColor(deviceRed: 1, green: 0.85, blue: 0, alpha: 0.45); mark.shouldPrint = true
                document.page(at: index)?.addAnnotation(mark)
            }
        }
    }
    @objc func addNote(_ sender: Any?) {
        guard let page = pdfView.currentPage, let text = askText("Add Note"), !text.isEmpty else { return }
        let index = file.pdf.index(for: page), bounds = page.bounds(for: .cropBox)
        let selection = pdfView.currentSelection?.bounds(for: page)
        let point = selection?.origin ?? NSPoint(x: bounds.midX, y: bounds.midY)
        performMutation("Add Note") { document in
            let note = PDFAnnotation(bounds: NSRect(x: point.x, y: point.y, width: 22, height: 22), forType: .text, withProperties: nil)
            note.contents = text; note.color = NSColor(deviceRed: 1, green: 0.85, blue: 0, alpha: 1); note.shouldPrint = true
            document.page(at: index)?.addAnnotation(note)
        }
    }
    @objc func rotatePage(_ sender: Any?) { let index = currentIndex; performMutation("Rotate Page") { doc in if let page = doc.page(at: index) { page.rotation = (page.rotation + 90) % 360 } } }
    @objc func movePage(_ sender: Any?) {
        let from = currentIndex
        guard let text = askText("Move Page", value: String(from + 1), detail: "Enter the page's new position."), let position = Int(text),
              position > 0, position <= file.pdf.pageCount, position != from + 1 else { return }
        performMutation("Move Page") { document in
            guard let page = document.page(at: from) else { return }
            document.removePage(at: from); document.insert(page, at: position - 1)
        }
    }
    @objc func deletePage(_ sender: Any?) {
        guard file.pdf.pageCount > 1 else { status.stringValue = "A PDF must retain at least one page."; return }
        let index = currentIndex, alert = NSAlert(); alert.messageText = "Delete page \(index + 1)?"
        alert.addButton(withTitle: "Delete Page"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        performMutation("Delete Page") { $0.removePage(at: index) }
    }
    @objc func insertPDF(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max <= DocumentPolicy.maximumBytes else { throw FolioError("Choose a PDF smaller than 300 MiB.") }
            let other = try DocumentPolicy.parse(Data(contentsOf: url))
            guard !other.isLocked, !other.isEncrypted else { throw FolioError("Insert an unencrypted PDF.") }
            guard file.pdf.pageCount + other.pageCount <= 10000 else { throw FolioError("The result would exceed 10,000 pages.") }
            let index = currentIndex + 1
            performMutation("Insert PDF") { document in for i in 0..<other.pageCount { if let copy = other.page(at: i)?.copy() as? PDFPage { document.insert(copy, at: index + i) } } }
        } catch { report(error) }
    }
    @objc func printPDF(_ sender: Any?) {
        guard !file.pdf.isLocked, file.pdf.allowsPrinting else { report(FolioError("This PDF does not allow printing.")); return }
        pdfView.print(with: file.printInfo, autoRotate: true)
    }
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) { confirmExternal(url) }
    func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) { /* User must select external files explicitly. */ }
    func pdfViewPerformPrint(_ sender: PDFView) { /* PDF actions never start printing. */ }
    private func confirmExternal(_ url: URL) {
        guard ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        let alert = NSAlert(); alert.messageText = "Open this link in another app?"; alert.informativeText = String(url.absoluteString.prefix(2000))
        alert.addButton(withTitle: "Open Link"); alert.addButton(withTitle: "Cancel"); alert.buttons[1].keyEquivalent = "\r"; alert.buttons[0].keyEquivalent = ""
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? PDFOutline ?? file.pdf.outlineRoot)?.numberOfChildren ?? 0 }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? PDFOutline)?.numberOfChildren ?? 0 > 0 }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? PDFOutline ?? file.pdf.outlineRoot)!.child(at: index)! }
    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? { (item as? PDFOutline)?.label ?? "" }
    @objc private func outlineSelected(_ sender: Any?) {
        if let item = outline.item(atRow: outline.selectedRow) as? PDFOutline, let destination = item.destination { pdfView.go(to: destination) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { noteEntries.count }
    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        let entry = noteEntries[row]; return "Page \(entry.0 + 1) · \(entry.1.type ?? "Annotation")\n\(entry.1.contents ?? "")"
    }
    private var selectedNoteRow: Int { notes.clickedRow >= 0 ? notes.clickedRow : notes.selectedRow }
    @objc private func noteSelected(_ sender: Any?) {
        let row = selectedNoteRow
        guard noteEntries.indices.contains(row), let page = file.pdf.page(at: noteEntries[row].0) else { return }
        pdfView.go(to: noteEntries[row].1.bounds, on: page)
    }
    @objc private func editNote(_ sender: Any?) {
        let row = selectedNoteRow
        guard noteEntries.indices.contains(row) else { return }
        let (pageIndex, annotation) = noteEntries[row]
        guard let page = file.pdf.page(at: pageIndex) else { return }
        editAnnotation(page: page, annotation: annotation)
    }
    private func editAnnotation(page: PDFPage, annotation: PDFAnnotation) {
        guard !busy else { return }
        do { try file.ensureEditable() } catch { report(error); return }
        let pageIndex = file.pdf.index(for: page)
        guard let index = page.annotations.firstIndex(where: { $0 === annotation }) else { return }
        if annotation.type == "Widget" {
            guard !annotation.isReadOnly else { status.stringValue = "This form field is read-only."; return }
            guard annotation.widgetFieldType == .text else { status.stringValue = "Only text form fields can be edited in this version."; return }
            guard let text = askText("Edit Form Field", value: annotation.widgetStringValue ?? "") else { return }
            performMutation("Edit Form Field") { $0.page(at: pageIndex)?.annotations[index].widgetStringValue = text }
        } else {
            guard let text = askText(annotation.type == "FreeText" ? "Edit Text Box" : "Edit Note", value: annotation.contents ?? "") else { return }
            performMutation("Edit Note") { $0.page(at: pageIndex)?.annotations[index].contents = text }
        }
    }
    @objc private func deleteAnnotation(_ sender: Any?) {
        let row = selectedNoteRow
        guard noteEntries.indices.contains(row) else { return }
        let (pageIndex, annotation) = noteEntries[row]
        guard let page = file.pdf.page(at: pageIndex), let index = page.annotations.firstIndex(where: { $0 === annotation }) else { return }
        performMutation("Delete Annotation") { document in if let page = document.page(at: pageIndex) { page.removeAnnotation(page.annotations[index]) } }
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let editActions: Set<Selector> = [#selector(deleteObject(_:)), #selector(editContent(_:)), #selector(highlight(_:)), #selector(addNote(_:)), #selector(addTextBox(_:)),
            #selector(drawInk(_:)), #selector(addImage(_:)), #selector(rotatePage(_:)), #selector(movePage(_:)), #selector(deletePage(_:)), #selector(insertPDF(_:))]
        guard let action = menuItem.action else { return false }
        return !editActions.contains(action) || (!busy && !file.pdf.isEncrypted && !file.signed && !file.pdf.isLocked)
    }
}
