import AppKit
import PDFKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        if let icon = NSImage(contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "png")!) {
            NSApplication.shared.applicationIconImage = icon
        }
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}

@MainActor private func menuItem(_ title: String, _ action: Selector?, _ key: String = "", modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    return item
}
@MainActor func installMenus() {
    let bar = NSMenu()
    func add(_ title: String, _ items: [NSMenuItem]) {
        let menu = NSMenu(title: title); items.forEach(menu.addItem)
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu; bar.addItem(parent)
    }
    add("Folio Native", [menuItem("About Folio Native", #selector(NSApplication.orderFrontStandardAboutPanel(_:))), .separator(),
        menuItem("Hide Folio Native", #selector(NSApplication.hide(_:)), "h"),
        menuItem("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]),
        .separator(), menuItem("Quit Folio Native", #selector(NSApplication.terminate(_:)), "q")])
    add("File", [menuItem("New PDF", #selector(NSDocumentController.newDocument(_:)), "n"),
        menuItem("Open PDF…", #selector(NSDocumentController.openDocument(_:)), "o"), .separator(),
        menuItem("Close", #selector(NSWindow.performClose(_:)), "w"),
        menuItem("Save", #selector(NSDocument.save(_:)), "s"),
        menuItem("Save As…", #selector(NSDocument.saveAs(_:)), "s", modifiers: [.command, .shift]),
        menuItem("Revert to Saved…", #selector(NSDocument.revertToSaved(_:))), .separator(),
        menuItem("Print…", #selector(ReaderController.printPDF(_:)), "p")])
    add("Edit", [menuItem("Undo", Selector(("undo:")), "z"), menuItem("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]), .separator(),
        menuItem("Cut", #selector(NSText.cut(_:)), "x"), menuItem("Copy", #selector(NSText.copy(_:)), "c"),
        menuItem("Paste", #selector(NSText.paste(_:)), "v"), menuItem("Select All", #selector(NSText.selectAll(_:)), "a"), .separator(),
        menuItem("Find…", #selector(ReaderController.focusSearch(_:)), "f"),
        menuItem("Find Next", #selector(ReaderController.findNext(_:)), "g"),
        menuItem("Find Previous", #selector(ReaderController.findPrevious(_:)), "g", modifiers: [.command, .shift]), .separator(),
        menuItem("Edit Existing Text / Images", #selector(ReaderController.editContent(_:)), "e", modifiers: [.command, .shift]),
        menuItem("Delete Existing Object…", #selector(ReaderController.deleteObject(_:))),
        menuItem("Highlight Selection", #selector(ReaderController.highlight(_:)), "h", modifiers: [.command, .shift]),
        menuItem("Add Note…", #selector(ReaderController.addNote(_:)), "n", modifiers: [.command, .shift]),
        menuItem("Add Text Box", #selector(ReaderController.addTextBox(_:))),
        menuItem("Draw", #selector(ReaderController.drawInk(_:))),
        menuItem("Place Image / Signature…", #selector(ReaderController.addImage(_:)))])
    add("Page", [menuItem("Previous Page", #selector(ReaderController.previousPage(_:)), "\u{f702}", modifiers: [.command]),
        menuItem("Next Page", #selector(ReaderController.nextPage(_:)), "\u{f703}", modifiers: [.command]),
        menuItem("Go to Page…", #selector(ReaderController.goToPage(_:)), "l"), .separator(),
        menuItem("Rotate Clockwise", #selector(ReaderController.rotatePage(_:)), "r"),
        menuItem("Move Page…", #selector(ReaderController.movePage(_:))),
        menuItem("Delete Page…", #selector(ReaderController.deletePage(_:))),
        menuItem("Insert PDF…", #selector(ReaderController.insertPDF(_:)))])
    add("View", [menuItem("Show / Hide Sidebar", #selector(ReaderController.toggleSidebar(_:)), "\\"),
        menuItem("Zoom In", #selector(ReaderController.zoomIn(_:)), "+"),
        menuItem("Zoom Out", #selector(ReaderController.zoomOut(_:)), "-"),
        menuItem("Fit to Window", #selector(ReaderController.fitPage(_:)), "0"),
        menuItem("Two Pages", #selector(ReaderController.twoPages(_:))),
        menuItem("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", modifiers: [.command, .control])])
    add("Window", [menuItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
        menuItem("Show Previous Tab", #selector(NSWindow.selectPreviousTab(_:)), "[", modifiers: [.command, .shift]),
        menuItem("Show Next Tab", #selector(NSWindow.selectNextTab(_:)), "]", modifiers: [.command, .shift]),
        menuItem("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))])
    NSApplication.shared.mainMenu = bar
    NSApplication.shared.windowsMenu = bar.items.last?.submenu
}

@main struct NativeMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.contains("--render-preview") {
            do { FileHandle.standardOutput.write(try NativeTests.renderPreview()); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--self-test") {
            do { try NativeTests.run(); print("PASS: Folio Native integration tests"); exit(0) }
            catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
        }
        _ = app.setActivationPolicy(.regular)
        let documents = PDFFileController(), delegate = AppDelegate()
        app.delegate = delegate
        installMenus()
        withExtendedLifetime((documents, delegate)) { app.run() }
    }
}
