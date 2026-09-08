import AppKit
import WebKit
import UniformTypeIdentifiers
import CryptoKit

final class ArchiveWebView: WKWebView {
    var importDroppedZIPs: (([URL]) -> Void)?
    var importArchivesEnabled = true
    private func droppedZIPs(_ sender: NSDraggingInfo) -> [URL] {
        guard importArchivesEnabled else { return [] }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        // Recognize export directories without consuming a Claude Code directory drop.
        return urls.allSatisfy { url in
            if url.pathExtension.lowercased() == "zip" { return true }
            guard let children = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else { return false }
            return children.contains { $0.pathExtension.lowercased() == "zip" || $0.lastPathComponent == "conversations.json" }
        } ? urls : []
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
    var waitingToTerminate = false
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
        fileMenu.addItem(withTitle: "添加完整导出文件夹…", action: #selector(openArchive), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "添加旧版完整 ZIP…", action: #selector(openLegacyArchive), keyEquivalent: "")
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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "ClaudeViewer", .applicationVersion: version + " · macOS Archives", .credits: NSAttributedString(string: "crownleo/ClaudeViewer\n本地 macOS 查看器，非 Anthropic 官方应用。\nGNU GPL-3.0；源码与许可证随附。")])
    }

    @objc func openArchive() {
        window.makeKeyAndOrderFront(nil)
        chooseArchives(mode: "folder") { [weak self] urls in if !urls.isEmpty { self?.importURLs(urls) } }
    }

    @objc func openLegacyArchive() {
        chooseArchives(mode: "files") { [weak self] urls in if !urls.isEmpty { self?.importURLs(urls) } }
    }

    @objc func refreshArchives() { notifyArchivesChanged() }
    @objc func revealArchives() { NSWorkspace.shared.open(store.root) }

    func application(_ application: NSApplication, open urls: [URL]) {
        let sources = urls.filter { $0.isFileURL }
        if store == nil || webView?.isLoading != false { pendingOpenURLs += sources } else { importURLs(sources) }
    }

    private func chooseArchives(mode: String, _ completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = mode == "files" ? "添加旧版完整 ZIP（每份 ZIP 独立建档）" : "选择完整导出文件夹（每个文件夹独立建档）"
        panel.message = mode == "files" ? "新版 manifest 与分类 ZIP 请使用「添加完整导出文件夹」。" : "同一账号、同一次导出的 manifest 和全部 ZIP 放在一个文件夹中。多个账号请分别放入不同文件夹。"
        panel.prompt = "保存档案"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = mode == "files"
        panel.canChooseDirectories = mode != "files"
        if mode == "files" { panel.allowedContentTypes = [.zip] }
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { completion($0 == .OK ? panel.urls : []) }
    }

    private func importURLs(_ urls: [URL]) {
        archiveQueue.async {
            do {
                let records = try self.store.importSources(urls).map { try $0.json() }
                DispatchQueue.main.async { self.notifyArchivesChanged(records: records) }
            } catch { DispatchQueue.main.async { self.notifyArchivesChanged(); self.showError(error.localizedDescription) } }
        }
    }

    private func notifyArchivesChanged(records: [[String: Any]] = []) {
        guard webView?.url?.standardizedFileURL == viewerURL else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: records), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.dispatchEvent(new CustomEvent('claude-archives-changed', {detail: " + json + "}))", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        if !pendingOpenURLs.isEmpty { let urls = pendingOpenURLs; pendingOpenURLs = []; importURLs(urls) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard webView?.url?.standardizedFileURL == viewerURL else { return .terminateNow }
        if waitingToTerminate { return .terminateLater }
        waitingToTerminate = true
        // Metadata writes are ordered in JavaScript before entering the IO queue.
        // Await both layers so an immediate Quit after a tag edit does not lose it.
        webView.callAsyncJavaScript("return await window.claudeNativeFlush?.();", arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success:
                self.archiveQueue.async { DispatchQueue.main.async { sender.reply(toApplicationShouldTerminate: true) } }
            case .failure(let error):
                self.waitingToTerminate = false
                sender.reply(toApplicationShouldTerminate: false)
                self.showError("整理信息尚未确认保存，暂未退出：" + error.localizedDescription)
            }
        }
        return .terminateLater
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
        if command == "mode" {
            guard let temporary = body["temporary"] as? Bool else { reply(.failure(ArchiveError.invalid("导入模式无效。"))); return }
            (webView as? ArchiveWebView)?.importArchivesEnabled = !temporary
            reply(.success(true)); return
        }
        if command == "import" {
            chooseArchives(mode: body["mode"] as? String ?? "folder") { urls in
                self.archiveQueue.async {
                    do {
                        reply(.success(try self.store.importSources(urls).map { try $0.json() }))
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
                if command == "warnings" { reply(.success(self.store.warnings)); return }
                guard let id = body["id"] as? String else { throw ArchiveError.invalid("缺少档案 ID。") }
                switch command {
                case "get": reply(.success(try self.store.record(id).json()))
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
                    let index = body["index"] as? Int
                    DispatchQueue.main.async { self.exportOriginal(id: id, index: index, reply: reply) }
                case "remove":
                    let record = try self.store.record(id)
                    let urls = try self.store.recycleURLs(id)
                    DispatchQueue.main.async { self.recycle(record: record, urls: urls, reply: reply) }
                default: throw ArchiveError.invalid("不支持的档案操作。")
                }
            } catch { reply(.failure(error)) }
        }
    }

    private func exportOriginal(id: String, index: Int?, reply: @escaping (Result<Any, Error>) -> Void) {
        let panel = NSOpenPanel()
        panel.title = index == nil ? "取出整套原始文件（保留原文件名和内容）" : "取出未经修改的原文件"
        panel.prompt = "导出到这里"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let destination = panel.url else { reply(.success(NSNull())); return }
            self.archiveQueue.async {
                do {
                    let exported = try index.map { try self.store.exportFile(id, index: $0, to: destination) } ?? self.store.exportSet(id, to: destination)
                    DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([exported]); reply(.success(true)) }
                } catch { reply(.failure(error)) }
            }
        }
    }

    private func recycle(record: ArchiveRecord, urls: [URL], reply: @escaping (Result<Any, Error>) -> Void) {
        let alert = NSAlert()
        alert.messageText = "将“\(record.name)”移到废纸篓？"
        alert.informativeText = "档案库中的整套原始文件和对应的收藏、标签将移到废纸篓，可以从 Finder 恢复。档案文件夹以外的原始文件不会被删除。"
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
        guard path.count == 2, let index = Int(path[1]), index >= 0, String(index) == path[1], UUID(uuidString: String(path[0])) != nil,
              parts.percentEncodedPath == "/\(path[0])/\(index)" else {
            schemeTasks.remove(key)
            urlSchemeTask.didFailWithError(ArchiveError.invalid("档案地址无效。")); return
        }
        archiveQueue.async {
            do {
                let record = try self.store.record(String(path[0]))
                let data = try Data(contentsOf: self.store.originalURL(record, index: index), options: .mappedIfSafe)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard digest == record.files[index].sha256 else {
                    throw ArchiveError.invalid("原件与档案校验值不符，请刷新后检查文件。")
                }
                DispatchQueue.main.async {
                    guard self.schemeTasks.remove(key) != nil else { return }
                    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                        "Content-Type": "application/octet-stream", "Content-Length": String(data.count),
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
