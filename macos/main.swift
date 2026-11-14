// Word Processor — native macOS wrapper around the wordprocessor web app.
// Build with macos/build.sh. The web app lives in Contents/Resources/wordprocessor.
//
// Bridges exposed to JavaScript (window.webkit.messageHandlers):
//   print    — body: {top, bottom, left, right} margins in points; runs NSPrintOperation
//   saveFile — body: {name, tabId?, path?, text? | base64?}
//              with path: writes directly (Cmd+S save-back); without: shows NSSavePanel
//   openFile — shows NSOpenPanel, loads files into tabs (keeps path for save-back)
//
// JavaScript entry points the wrapper calls:
//   openTextDocument(name, content, path)
//   openDocxBase64(name, base64, path)
//   savedAs(tabId, path)
//   createNewTab(), saveDocument(), exportFile(), printDocument(), showToast(msg)

import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    var window: NSWindow!
    var webView: WKWebView!
    private var pageLoaded = false
    private var pendingJS: [(body: String, args: [String: Any])] = []

    private let openableExtensions = ["txt", "text", "log", "md", "markdown", "csv", "json", "xml",
                                      "yaml", "yml", "ini", "cfg", "sh", "bat", "js", "html", "css",
                                      "py", "docx"]

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.userContentController.add(self, name: "print")
        config.userContentController.add(self, name: "saveFile")
        config.userContentController.add(self, name: "openFile")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let size = NSSize(width: min(1100, visible.width * 0.85), height: min(800, visible.height * 0.9))
        let rect = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                          width: size.width, height: size.height)

        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Word Processor"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentView = webView
        window.setFrameAutosaveName("WordProcessorMainWindow")
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)

        buildMenu()

        if let resources = Bundle.main.resourcePath {
            let dir = URL(fileURLWithPath: resources).appendingPathComponent("wordprocessor", isDirectory: true)
            webView.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        debugLog("open urls: \(urls.map { $0.path })")
        for url in urls { openDocument(url) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        debugLog("page loaded, flushing \(pendingJS.count) pending JS")
        pageLoaded = true
        for js in pendingJS { evalJS(js.body, js.args) }
        pendingJS = []

        // test hook: only active alongside the /tmp/wp-debug-on flag file
        if FileManager.default.fileExists(atPath: "/tmp/wp-debug-on"),
           let testJS = ProcessInfo.processInfo.environment["WP_TEST_JS"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.evalJS(testJS, [:]) }
        }
    }

    private func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["WP_DEBUG"] != nil ||
              FileManager.default.fileExists(atPath: "/tmp/wp-debug-on") else { return }
        let line = "\(Date()) \(message)\n"
        if let handle = FileHandle(forWritingAtPath: "/tmp/wp.log") {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        } else {
            try? line.write(toFile: "/tmp/wp.log", atomically: true, encoding: .utf8)
        }
    }

    private func evalJS(_ body: String, _ args: [String: Any]) {
        webView.callAsyncJavaScript(body, arguments: args, in: nil, in: .page) { result in
            switch result {
            case .failure(let error): self.debugLog("JS error: \(error)")
            case .success(let value): self.debugLog("JS ok: \(String(describing: value))")
            }
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Word Processor",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide Word Processor", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Word Processor", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Tab", action: #selector(menuNewTab), keyEquivalent: "n")
        fileMenu.addItem(withTitle: "Open…", action: #selector(menuOpen), keyEquivalent: "o")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Save", action: #selector(menuSave), keyEquivalent: "s")
        fileMenu.addItem(withTitle: "Save As…", action: #selector(menuSaveAs), keyEquivalent: "S")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Print…", action: #selector(menuPrint), keyEquivalent: "p")
        fileMenuItem.submenu = fileMenu

        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        let viewMenuItem = NSMenuItem()
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen",
                                          action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenuItem.submenu = viewMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    @objc private func menuNewTab() { runJS("createNewTab();") }
    @objc private func menuSave() { runJS("saveDocument();") }
    @objc private func menuSaveAs() { runJS("exportFile();") }
    @objc private func menuPrint() { runJS("printDocument();") }

    @objc private func menuOpen() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = openableExtensions
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            for url in panel.urls { self.openDocument(url) }
        }
    }

    // MARK: - Opening files

    private func openDocument(_ url: URL) {
        let name = url.deletingPathExtension().lastPathComponent
        if url.pathExtension.lowercased() == "docx" {
            guard let data = try? Data(contentsOf: url) else {
                showJSToast("Could not read \(url.lastPathComponent)"); return
            }
            runJS("""
                  const content = await readDocxBuffer(base64ToBytes(b64).buffer);
                  openTextDocument(name, content, path);
                  return tabs.length;
                  """,
                  ["name": name, "b64": data.base64EncodedString(), "path": url.path])
        } else {
            guard let text = readTextFile(url) else {
                showJSToast("Could not read \(url.lastPathComponent)"); return
            }
            runJS("openTextDocument(name, content, path);",
                  ["name": name, "content": text, "path": url.path])
        }
    }

    private func readTextFile(_ url: URL) -> String? {
        if let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return s }
        return nil
    }

    // MARK: - JS bridge

    private func runJS(_ body: String, _ args: [String: Any] = [:]) {
        if pageLoaded {
            evalJS(body, args)
        } else {
            pendingJS.append((body, args))
        }
    }

    private func showJSToast(_ message: String) {
        runJS("showToast(msg);", ["msg": message])
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case "print": handlePrint(message.body)
        case "saveFile": handleSaveFile(message.body)
        case "openFile": menuOpen()
        default: break
        }
    }

    // MARK: - Printing

    private func handlePrint(_ body: Any) {
        let printInfo = NSPrintInfo()
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
        if let margins = body as? [String: Any] {
            printInfo.topMargin = points(margins["top"])
            printInfo.bottomMargin = points(margins["bottom"])
            printInfo.leftMargin = points(margins["left"])
            printInfo.rightMargin = points(margins["right"])
        }
        let operation = webView.printOperation(with: printInfo)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func points(_ value: Any?) -> CGFloat {
        if let n = value as? NSNumber { return CGFloat(truncating: n) }
        return 72
    }

    // MARK: - Saving files

    private func handleSaveFile(_ body: Any) {
        guard let dict = body as? [String: Any], let name = dict["name"] as? String else { return }

        // direct save-back to a known path (Cmd+S on a file opened from disk)
        if let path = dict["path"] as? String, !path.isEmpty {
            writeFile(dict, to: URL(fileURLWithPath: path), tabId: nil)
            return
        }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        let tabId = dict["tabId"] as? String
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            self.writeFile(dict, to: url, tabId: tabId)
        }
    }

    private func writeFile(_ dict: [String: Any], to url: URL, tabId: String?) {
        do {
            if let b64 = dict["base64"] as? String {
                guard let data = Data(base64Encoded: b64) else {
                    throw NSError(domain: "WordProcessor", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "could not decode file data"])
                }
                try data.write(to: url)
            } else {
                let text = (dict["text"] as? String) ?? ""
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            if let tabId = tabId {
                runJS("savedAs(tabId, path);", ["tabId": tabId, "path": url.path])
            }
            showJSToast("Saved \(url.lastPathComponent)")
        } catch {
            showJSToast("Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - <input type=file> support (drag-drop/browser path, no fsPath)

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
