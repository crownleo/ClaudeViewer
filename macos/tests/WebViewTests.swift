import AppKit
import WebKit

// An integration host for synthetic fixtures only. It exercises the real WebKit
// fetch/CSP/Promise bridge while ArchiveStore writes solely below a temporary root.
final class WebViewTests: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKURLSchemeHandler {
    let directory: URL
    let page: URL
    let store: ArchiveStore
    let dataStore = WKWebsiteDataStore.nonPersistent()
    var window: NSWindow!
    var webView: WKWebView!
    var phase = 0
    var schemeReads = 0
    var bridgeCalls = 0
    var temporaryModes: [Bool] = []
    var finished = false
    var exported: [(ArchiveRecord, URL)] = []

    init(directory: URL) throws {
        self.directory = directory
        self.page = directory.appendingPathComponent("viewer.html").standardizedFileURL
        self.store = try ArchiveStore(root: directory.appendingPathComponent("Archives"))
        super.init()
        _ = try store.importSources([directory.appendingPathComponent("legacy-a.zip"), directory.appendingPathComponent("modern-b"), directory.appendingPathComponent("corrupt.zip")])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 820), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        startPage()
        DispatchQueue.main.asyncAfter(deadline: .now() + 50) { [weak self] in self?.finish("Timed out waiting for real WKWebView tests", success: false) }
    }

    func startPage() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.setURLSchemeHandler(self, forURLScheme: "claude-archive")
        config.userContentController.add(self, name: "testReport")
        config.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "archives")
        let initial = "window.__nativeTestPhase = \(phase); window.addEventListener('error', e => window.webkit.messageHandlers.testReport.postMessage({failure:String(e.message)})); window.addEventListener('unhandledrejection', e => window.webkit.messageHandlers.testReport.postMessage({failure:String(e.reason && (e.reason.stack || e.reason.message) || e.reason)}));"
        config.userContentController.addUserScript(WKUserScript(source: initial, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1220, height: 820), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.contentView = webView
        // No user-facing window, app data store, archive or preference is opened.
        webView.loadFileURL(page, allowingReadAccessTo: directory)
    }

    func finish(_ message: String, success: Bool) {
        guard !finished else { return }
        finished = true
        print((success ? "PASS: " : "FAIL: ") + message)
        fflush(stdout)
        exit(success ? 0 : 1)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { finish("Malformed test result", success: false); return }
        if let failure = body["failure"] as? String { finish(failure, success: false); return }
        if body["reload"] as? Bool == true {
            guard phase == 0 else { finish("Unexpected additional reload", success: false); return }
            phase = 1
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.stopLoading()
            webView.removeFromSuperview()
            startPage()
            return
        }
        if let checks = body["passed"] as? Int {
            do {
                guard phase == 1, schemeReads >= 10, bridgeCalls >= 12, !exported.isEmpty else { throw ArchiveError.invalid("Expected integration paths did not execute") }
                let transitions = temporaryModes.reduce(into: [Bool]()) { states, mode in if states.last != mode { states.append(mode) } }
                guard transitions == [false, true, false] else { throw ArchiveError.invalid("Native temporary-mode transitions were not false → true → false") }
                for (record, destination) in exported {
                    for (index, file) in record.files.enumerated() {
                        let original = try Data(contentsOf: store.originalURL(record, index: index))
                        let copy = try Data(contentsOf: destination.appendingPathComponent(file.name))
                        guard copy == original else { throw ArchiveError.invalid("Export bytes changed") }
                    }
                }
                finish("\(checks) browser assertions; \(schemeReads) real archive scheme reads; \(bridgeCalls) native Promise calls; temporary-mode sync, restart restore and original-byte export verified", success: true)
            } catch { finish(error.localizedDescription, success: false) }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.name == "archives", message.webView === webView, message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL == page, webView.url?.standardizedFileURL == page,
              let body = message.body as? [String: Any], let command = body["command"] as? String else {
            replyHandler(["ok": false, "error": "Untrusted test bridge request"], nil); return
        }
        bridgeCalls += 1
        do {
            var result: Any = true
            if command == "list" { result = try store.list().map { try $0.json() } }
            else if command == "warnings" { result = store.warnings }
            else if command == "mode" {
                guard let temporary = body["temporary"] as? Bool else { throw ArchiveError.invalid("Missing temporary mode") }
                temporaryModes.append(temporary)
            }
            else if command == "import" {
                // The fixture selector stands in for NSOpenPanel and cannot access arbitrary paths.
                let fixture = body["mode"] as? String == "missing-fixture" ? "missing-b" : "legacy-a.zip"
                result = try store.importSources([directory.appendingPathComponent(fixture)]).map { try $0.json() }
            } else if command == "reveal" { result = true }
            else {
                guard let id = body["id"] as? String else { throw ArchiveError.invalid("Missing record ID") }
                switch command {
                case "get": result = try store.record(id).json()
                case "metadata":
                    let bytes = try JSONSerialization.data(withJSONObject: body["metadata"] ?? [:])
                    result = try store.updateMetadata(id, metadata: JSONDecoder().decode(ArchiveMetadata.self, from: bytes)).json()
                case "rename": result = try store.rename(id, name: body["name"] as? String ?? "").json()
                case "export":
                    let target = directory.appendingPathComponent("Exports")
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    if let index = body["index"] as? Int { _ = try store.exportFile(id, index: index, to: target) }
                    else { let record = try store.record(id); exported.append((record, try store.exportSet(id, to: target))) }
                case "remove":
                    // Only fixture paths are deleted. Never calls the system Trash/Finder.
                    for url in try store.recycleURLs(id) { try FileManager.default.removeItem(at: url) }
                default: throw ArchiveError.invalid("Unexpected bridge command: " + command)
                }
            }
            replyHandler(["ok": true, "result": result], nil)
        } catch { replyHandler(["ok": false, "error": error.localizedDescription], nil) }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        do {
            guard webView === self.webView, webView.url?.standardizedFileURL == page,
                  let url = task.request.url, url.scheme == "claude-archive", url.host == "archive", task.request.httpMethod == "GET" else { throw ArchiveError.invalid("Untrusted scheme request") }
            let parts = url.path.split(separator: "/")
            guard parts.count == 2, let index = Int(parts[1]), index >= 0 else { throw ArchiveError.invalid("Invalid archive URL") }
            let record = try store.record(String(parts[0]))
            let bytes = try Data(contentsOf: store.originalURL(record, index: index))
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/octet-stream", "Content-Length": String(bytes.count), "Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"])!
            schemeReads += 1
            task.didReceive(response); task.didReceive(bytes); task.didFinish()
        } catch { task.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error.localizedDescription, success: false) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler(); finish("Unexpected alert: " + message, success: false) }
}

@main
struct RunWebViewTests {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { throw ArchiveError.invalid("Pass the temporary fixture directory") }
            let app = NSApplication.shared
            let runner = try WebViewTests(directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
            app.delegate = runner
            app.setActivationPolicy(.prohibited)
            withExtendedLifetime(runner) { app.run() }
        } catch { print("FAIL: " + error.localizedDescription); exit(1) }
    }
}
