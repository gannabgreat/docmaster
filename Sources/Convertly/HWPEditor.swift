import AppKit
import ConvertlyCore
import UniformTypeIdentifiers
import WebKit

/// rhwp-studio(오픈소스 HWP 편집기, MIT)를 앱 안 창으로 띄운다. 파일은 앱 번들에 들어 있어 인터넷 없이 돈다.
/// 열기 = `?url=` 로 문서를 넘김 / 저장 = 편집기의 내려받기를 가로채 저장 위치를 묻는다.
@MainActor
final class HWPEditor: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    private static var open: Set<HWPEditor> = []

    private let window: NSWindow
    private let webView: WKWebView
    private let handler: RHWPSchemeHandler
    private let source: URL?

    /// 편집기 창을 연다. `file` 이 있으면 그 문서를 바로 띄운다.
    static func show(_ file: URL? = nil) {
        guard let root = RHWPResources.directory else {
            let a = NSAlert()
            a.messageText = "HWP 편집기 파일을 찾지 못했어요"
            a.informativeText = "앱을 다시 빌드·설치해 주세요(Resources/rhwp-studio)."
            a.runModal()
            return
        }
        let editor = HWPEditor(root: root, file: file)
        open.insert(editor)
        editor.window.makeKeyAndOrderFront(nil)
    }

    private init(root: URL, file: URL?) {
        handler = RHWPSchemeHandler(root: root)
        source = file
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: RHWPSchemeHandler.scheme)
        webView = WKWebView(frame: .zero, configuration: config)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 860),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()

        window.title = file.map { "HWP 편집 — \($0.lastPathComponent)" } ?? "HWP 편집"
        window.contentView = webView
        window.center()
        window.setFrameAutosaveName("HWPEditor")
        window.isReleasedWhenClosed = false
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self

        var comps = URLComponents(string: "\(RHWPSchemeHandler.scheme)://app/rhwp/index.html")!
        if let file, let data = try? Data(contentsOf: file) {
            let url = handler.register(data, name: file.lastPathComponent)
            comps.queryItems = [URLQueryItem(name: "url", value: url.absoluteString),
                                URLQueryItem(name: "filename", value: file.lastPathComponent)]
        }
        webView.load(URLRequest(url: comps.url!))
    }

    /// 개발용(DebugHooks): 마지막으로 연 편집기의 웹 화면을 PNG 로 저장.
    static func debugSnapshot(to path: String) {
        guard let editor = open.first else { return }
        editor.webView.takeSnapshot(with: nil) { image, _ in
            guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { _ = Self.open.remove(self) }
    }

    // MARK: 저장 = 내려받기 가로채기

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        MainActor.assumeIsolated { decisionHandler(action.shouldPerformDownload ? .download : .allow) }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                             decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        MainActor.assumeIsolated { decisionHandler(response.canShowMIMEType ? .allow : .download) }
    }

    nonisolated func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        MainActor.assumeIsolated { download.delegate = self }
    }

    nonisolated func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        MainActor.assumeIsolated { download.delegate = self }
    }

    nonisolated func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                              suggestedFilename: String, completionHandler: @escaping @MainActor @Sendable (URL?) -> Void) {
        MainActor.assumeIsolated {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedFilename
            if let source { panel.directoryURL = source.deletingLastPathComponent() }
            panel.canCreateDirectories = true
            panel.beginSheetModal(for: window) { result in
                guard result == .OK, let url = panel.url else { completionHandler(nil); return }
                // 덮어쓰기는 저장 창이 이미 확인했다. WKDownload 는 파일이 있으면 실패하므로 먼저 치운다.
                try? FileManager.default.removeItem(at: url)
                completionHandler(url)
            }
        }
    }

    nonisolated func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        MainActor.assumeIsolated {
            let a = NSAlert(error: error)
            a.messageText = "저장하지 못했어요"
            a.beginSheetModal(for: window)
        }
    }

    // MARK: 파일 열기·알림 창

    nonisolated func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                             initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void) {
        MainActor.assumeIsolated {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = false
            panel.beginSheetModal(for: window) { completionHandler($0 == .OK ? panel.urls : nil) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
        MainActor.assumeIsolated {
            let a = NSAlert()
            a.messageText = message
            a.beginSheetModal(for: window) { _ in completionHandler() }
        }
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                             initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
        MainActor.assumeIsolated {
            let a = NSAlert()
            a.messageText = message
            a.addButton(withTitle: "확인")
            a.addButton(withTitle: "취소")
            a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
        }
    }

    nonisolated func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                             defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                             completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
        MainActor.assumeIsolated {
            let a = NSAlert()
            a.messageText = prompt
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = defaultText ?? ""
            a.accessoryView = field
            a.addButton(withTitle: "확인")
            a.addButton(withTitle: "취소")
            a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
        }
    }
}
