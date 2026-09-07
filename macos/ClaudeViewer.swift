import AppKit
import WebKit
import UniformTypeIdentifiers

final class ArchiveWebView: WKWebView {
    var importDroppedZIPs: (([URL]) -> Void)?
    private func droppedZIPs(_ sender: NSDraggingInfo) -> [URL] {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        // Mixed/non-ZIP drops continue through WebKit to the Claude Code importer.
        return urls.allSatisfy { $0.pathExtension.lowercased() == "zip" } ? urls : []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedZIPs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedZIPs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedZIPs(sender)
        if urls.isEmpty { return super.performDragOperation(sender) }
        importDroppedZIPs?(urls)
        return true
    }
}

// A small native shell around crownleo's GPL-3.0 ClaudeViewer.
// Web content can read only bundled resources and files selected by the user.
final class AppDelegate: NSObject, NSApplicationDelegate, WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKURLSchemeHandler {
    var window: NSWindow!
    var webView: WKWebView!
    var popupWindows: [NSWindow] = []
    var destinations: [ObjectIdentifier: (URL, URL)] = [:]
    var store: ArchiveStore!
    let archiveQueue = DispatchQueue(label: "cn.crownleo.ClaudeViewer.archives", qos: .userInitiated)
    var schemeTasks = Set<ObjectIdentifier>()
    var pendingOpenURLs: [URL] = []
    var viewerURL: URL { Bundle.main.url(forResource: "claude_viewer", withExtension: "html")!.standardizedFileURL }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            store = try ArchiveStore(root: support.appendingPathComponent("ClaudeViewer/Archives", isDirectory: true))
        } catch { showError(error.localizedDescription); NSApp.terminate(nil); return }
        buildMenu()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Route the viewer's PDF print button into the native macOS print dialog.
        configuration.userContentController.add(self, name: "nativePrint")
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "archives")
        configuration.setURLSchemeHandler(self, forURLScheme: "claude-archive")
        configuration.userContentController.addUserScript(WKUserScript(source: "window.print = () => window.webkit.messageHandlers.nativePrint.postMessage(null);", injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let archiveWebView = ArchiveWebView(frame: .zero, configuration: configuration)
        archiveWebView.importDroppedZIPs = { [weak self] urls in self?.importURLs(urls) }
        webView = archiveWebView
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        window = makeWindow(title: "ClaudeViewer", view: webView)
        window.setFrameAutosaveName("ClaudeViewer.MainWindow")
        let page = Bundle.main.url(forResource: "claude_viewer", withExtension: "html")!
        webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if !pendingOpenURLs.isEmpty { importURLs(pendingOpenURLs); pendingOpenURLs = [] }
    }

    func makeWindow(title: String, view: WKWebView) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = title
        w.minSize = NSSize(width: 760, height: 520)
        w.contentView = view
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    func buildMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        bar.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "关于 ClaudeViewer", action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 ClaudeViewer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 ClaudeViewer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileMenu = NSMenu(title: "文件")
        let fileItem = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        fileItem.submenu = fileMenu
        bar.addItem(fileItem)
        fileMenu.addItem(withTitle: "打开导出文件…", action: #selector(openArchive), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "刷新档案", action: #selector(refreshArchives), keyEquivalent: "r")
        fileMenu.addItem(withTitle: "在 Finder 中显示档案文件夹", action: #selector(revealArchives), keyEquivalent: "")
        fileMenu.addItem(withTitle: "打开导出文件夹", action: #selector(openExports), keyEquivalent: "")
        fileMenu.addItem(withTitle: "打印当前页面…", action: #selector(printPage), keyEquivalent: "p")
        fileMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editMenu = NSMenu(title: "编辑")
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        bar.addItem(editItem)
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = bar
    }

    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "ClaudeViewer", .applicationVersion: "5.7 · macOS Archives", .credits: NSAttributedString(string: "crownleo/ClaudeViewer\n本地 macOS 查看器，非 Anthropic 官方应用。\nGNU GPL-3.0；源码与许可证随附。")])
    }

    @objc func openArchive() {
        window.makeKeyAndOrderFront(nil)
        chooseArchives { [weak self] urls in if !urls.isEmpty { self?.importURLs(urls) } }
    }

    @objc func refreshArchives() { notifyArchivesChanged() }
    @objc func revealArchives() { NSWorkspace.shared.open(store.root) }

    func application(_ application: NSApplication, open urls: [URL]) {
        let zips = urls.filter { $0.isFileURL && $0.pathExtension.lowercased() == "zip" }
        if store == nil { pendingOpenURLs += zips } else { importURLs(zips) }
    }

    private func chooseArchives(_ completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "将 ZIP 原件保存到 ClaudeViewer 档案库"
        panel.prompt = "保存档案"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { completion($0 == .OK ? panel.urls : []) }
    }

    private func importURLs(_ urls: [URL]) {
        archiveQueue.async {
            var failures: [String] = []
            for url in urls {
                do { _ = try self.store.importZIP(url) }
                catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                self.notifyArchivesChanged()
                if !failures.isEmpty { self.showError(failures.joined(separator: "\n")) }
            }
        }
    }

    private func notifyArchivesChanged() {
        guard webView?.url?.standardizedFileURL == viewerURL else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('claude-archives-changed'))", completionHandler: nil)
    }

    private func trusted(_ message: WKScriptMessage) -> Bool {
        message.webView === webView && message.frameInfo.isMainFrame &&
        message.frameInfo.request.url?.standardizedFileURL == viewerURL && webView.url?.standardizedFileURL == viewerURL
    }

    // No command accepts a filesystem path. ZIP import/export require native panels;
    // bridge access is restricted to the bundled main page, protected by a nonce CSP.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.name == "archives", trusted(message), let body = message.body as? [String: Any],
              let command = body["command"] as? String else {
            replyHandler(["ok": false, "error": "档案操作仅允许来自主窗口。"], nil); return
        }
        let reply: (Result<Any, Error>) -> Void = { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let value): replyHandler(["ok": true, "result": value], nil)
                case .failure(let error): replyHandler(["ok": false, "error": error.localizedDescription], nil)
                }
            }
        }
        if command == "import" {
            chooseArchives { urls in
                self.archiveQueue.async {
                    do {
                        var records: [[String: Any]] = []
                        for url in urls { records.append(try self.store.importZIP(url).json()) }
                        reply(.success(records))
                    } catch { reply(.failure(error)) }
                }
            }
            return
        }
        if command == "reveal", body["id"] == nil {
            NSWorkspace.shared.open(store.root); reply(.success(true)); return
        }
        archiveQueue.async {
            do {
                if command == "list" { reply(.success(try self.store.list().map { try $0.json() })); return }
                guard let id = body["id"] as? String else { throw ArchiveError.invalid("缺少档案 ID。") }
                switch command {
                case "metadata":
                    guard let metadata = body["metadata"] as? [String: Any] else { throw ArchiveError.invalid("整理信息无效。") }
                    let data = try JSONSerialization.data(withJSONObject: metadata)
                    guard data.count <= 8 * 1024 * 1024 else { throw ArchiveError.invalid("整理信息过大。") }
                    let parsed = try JSONDecoder().decode(ArchiveMetadata.self, from: data)
                    reply(.success(try self.store.updateMetadata(id, metadata: parsed).json()))
                case "rename":
                    guard let name = body["name"] as? String else { throw ArchiveError.invalid("缺少档案名称。") }
                    reply(.success(try self.store.rename(id, name: name).json()))
                case "reveal":
                    let original = try self.store.originalURL(self.store.record(id))
                    DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([original]); reply(.success(true)) }
                case "export":
                    _ = try self.store.record(id)
                    DispatchQueue.main.async { self.exportOriginal(id: id, reply: reply) }
                case "remove":
                    let record = try self.store.record(id)
                    let urls = try self.store.recycleURLs(id)
                    DispatchQueue.main.async { self.recycle(record: record, urls: urls, reply: reply) }
                default: throw ArchiveError.invalid("不支持的档案操作。")
                }
            } catch { reply(.failure(error)) }
        }
    }

    private func exportOriginal(id: String, reply: @escaping (Result<Any, Error>) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "选择文件夹，取出未经修改的 ZIP 原件"
        panel.prompt = "导出到这里"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let destination = panel.url else { reply(.success(NSNull())); return }
            self.archiveQueue.async {
                do {
                    let exported = try self.store.exportZIP(id, to: destination)
                    DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([exported]); reply(.success(true)) }
                } catch { reply(.failure(error)) }
            }
        }
    }

    private func recycle(record: ArchiveRecord, urls: [URL], reply: @escaping (Result<Any, Error>) -> Void) {
        let alert = NSAlert()
        alert.messageText = "将“\(record.name)”移到废纸篓？"
        alert.informativeText = "档案库中的 ZIP 和对应的收藏、标签将移到废纸篓，可以从 Finder 恢复。档案文件夹以外的原始文件不会被删除。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { reply(.success(false)); return }
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error = error { reply(.failure(error)) }
                else { reply(.success(true)); DispatchQueue.main.async { self.notifyArchivesChanged() } }
            }
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        schemeTasks.insert(key)
        guard webView === self.webView, webView.url?.standardizedFileURL == viewerURL,
              let url = urlSchemeTask.request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "claude-archive", parts.host == "archive", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil,
              urlSchemeTask.request.httpMethod == "GET" else {
            schemeTasks.remove(key)
            urlSchemeTask.didFailWithError(ArchiveError.invalid("档案请求无效。")); return
        }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 2, path[1] == "original.zip", UUID(uuidString: String(path[0])) != nil,
              parts.percentEncodedPath == "/\(path[0])/original.zip" else {
            schemeTasks.remove(key)
            urlSchemeTask.didFailWithError(ArchiveError.invalid("档案地址无效。")); return
        }
        archiveQueue.async {
            do {
                let record = try self.store.record(String(path[0]))
                let data = try Data(contentsOf: self.store.originalURL(record), options: .mappedIfSafe)
                DispatchQueue.main.async {
                    guard self.schemeTasks.remove(key) != nil else { return }
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                        "Content-Type": "application/zip", "Content-Length": String(data.count),
                        "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"
                    ])!
                    urlSchemeTask.didReceive(response)
                    urlSchemeTask.didReceive(data)
                    urlSchemeTask.didFinish()
                }
            } catch {
                DispatchQueue.main.async {
                    if self.schemeTasks.remove(key) != nil { urlSchemeTask.didFailWithError(error) }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { schemeTasks.remove(ObjectIdentifier(urlSchemeTask)) }

    var exportDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("ClaudeViewer", isDirectory: true)
    }

    @objc func openExports() {
        do {
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(exportDirectory)
        } catch { showError(error.localizedDescription) }
    }

    @objc func printPage() {
        let view = (NSApp.keyWindow?.contentView as? WKWebView) ?? webView!
        let operation = view.printOperation(with: NSPrintInfo.shared)
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.run()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "nativePrint", let view = message.webView else { return }
        view.window?.makeKeyAndOrderFront(nil)
        printPage()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Let any byte copy or sidecar atomic write already accepted by the bridge finish.
        archiveQueue.sync { }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "选择 Claude 导出文件"
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: webView.window ?? window) { result in
            completionHandler(result == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "ClaudeViewer"
        alert.informativeText = message
        alert.beginSheetModal(for: webView.window ?? window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: webView.window ?? window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // window.open('') is used by the viewer's PDF exporter. Navigation stays
        // subject to the same local-resource policy as the main window.
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.uiDelegate = self
        popup.navigationDelegate = self
        let w = makeWindow(title: "ClaudeViewer · PDF 预览", view: popup)
        popupWindows.append(w)
        w.makeKeyAndOrderFront(nil)
        return popup
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.shouldPerformDownload && ["blob", "data"].contains(url.scheme ?? "") {
            decisionHandler(.download)
        } else if url.isFileURL && url.standardizedFileURL.path.hasPrefix(Bundle.main.resourceURL!.path + "/") {
            decisionHandler(.allow)
        } else if url.absoluteString == "about:blank" {
            decisionHandler(.allow)
        } else {
            // External links open only after a deliberate click, in the default browser.
            if navigationAction.navigationType == .linkActivated && ["https", "http", "mailto"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        do {
            try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
            let name = (suggestedFilename as NSString).lastPathComponent
            let base = exportDirectory.appendingPathComponent(name.isEmpty ? "export" : name)
            var target = base
            var suffix = 1
            while FileManager.default.fileExists(atPath: target.path) || destinations.values.contains(where: { $0.1 == target }) {
                let stem = base.deletingPathExtension().lastPathComponent
                let ext = base.pathExtension
                target = exportDirectory.appendingPathComponent("\(stem) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)"))
                suffix += 1
            }
            // Download to a temporary file, then move it without overwriting an existing export.
            let stage = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeViewer-" + UUID().uuidString)
            self.destinations[ObjectIdentifier(download)] = (stage, target)
            completionHandler(stage)
        } catch { completionHandler(nil); showError(error.localizedDescription) }
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let (stage, target) = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        do {
            try FileManager.default.moveItem(at: stage, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch { showError("保存失败：\(error.localizedDescription)") }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let (stage, _) = destinations.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: stage) }
        showError("导出失败：\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { showError(error.localizedDescription) }
    func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ClaudeViewer"
        alert.informativeText = message
        alert.runModal()
    }
}

@main
struct ClaudeViewerApplication {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
