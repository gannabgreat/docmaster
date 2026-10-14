import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers
import WebKit

/// 문서(한글·워드 계열) 입력. 맥은 hwp·hwpx 를 못 읽어서 rhwp(Rust+WASM, MIT)를 WKWebView 로 돌리고,
/// docx·doc·rtf·odt 는 NSAttributedString 으로 읽어 인쇄 엔진으로 쪽을 나눈다.
/// pptx·ppt·key·odp 는 맥 내장 Quick Look 엔진으로 HTML 로 펼친 뒤 슬라이드마다 PDF 로 찍는다.
public enum DocumentKind: Sendable {
    case hangul   // hwp, hwpx
    case office   // docx, doc, rtf, odt
    case slides   // pptx, ppt, key, odp

    public static func of(_ url: URL) -> DocumentKind? {
        switch url.pathExtension.lowercased() {
        case "hwp", "hwpx": return .hangul
        case "docx", "doc", "rtf", "odt", "html", "htm": return .office
        case "pptx", "ppt", "key", "odp": return .slides
        default: return nil
        }
    }
}

public extension UTType {
    static let docx = UTType("org.openxmlformats.wordprocessingml.document") ?? UTType(filenameExtension: "docx") ?? .data
    /// 파일 고르기 창에 넣을 문서 형식들. hwp·hwpx 는 맥에 등록된 UTI 가 없을 수 있어 확장자로 만든다.
    static var convertlyDocuments: [UTType] {
        var types: [UTType] = [.docx, .rtf, .html]
        if let t = UTType("org.openxmlformats.presentationml.presentation") { types.append(t) }
        for ext in ["hwp", "hwpx", "doc", "odt", "ppt", "key", "odp"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }
}

enum DocumentEngine {
    /// 문서를 PDF 데이터로. 쪽 크기는 원본 문서를 따른다.
    static func pdfData(_ url: URL, slides: SlidesEngine = .builtin) throws -> Data {
        guard let kind = DocumentKind.of(url) else { throw ConvertError.unsupported(url.lastPathComponent) }
        switch kind {
        case .hangul:
            let bytes = try readBytes(url)
            return try onMain { try await RHWPRenderer().pdf(bytes) }
        case .office:
            // HTML 발표자료(슬라이드)면 WebKit 으로 슬라이드마다 한 쪽씩, 아니면 일반 문서처럼
            if ["html", "htm"].contains(url.pathExtension.lowercased()),
               let data = try onMain({ try await HTMLDeckRenderer().pdf(url) }) {
                return data
            }
            return try onMain { try officePDF(url) }
        case .slides:
            return slides == .powerPoint ? try onMain { try powerPointPDF(url) } : try slidesPDF(url)
        }
    }

    // MARK: - 발표 자료 → PDF (PowerPoint, 고르면)

    static let powerPointID = "com.microsoft.Powerpoint"

    /// 설치된 PowerPoint 에 AppleScript 로 「PDF로 저장」을 시킨다. 차트·글꼴이 원본 그대로.
    /// PowerPoint 는 샌드박스 앱이라 자기 컨테이너의 tmp 에 쓰게 하고 거기서 가져온다.
    @MainActor
    static func powerPointPDF(_ url: URL) throws -> Data {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: powerPointID) != nil else {
            throw ConvertError.notApplicable("PowerPoint가 설치돼 있지 않아요 — 옵션을 「자체 처리」로 바꾸세요")
        }
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: powerPointID).isEmpty
        let box = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(powerPointID)/Data/tmp")
        try? FileManager.default.createDirectory(at: box, withIntermediateDirectories: true)
        let tmp = box.appendingPathComponent("convertly-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        func q(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let source = """
        tell application id "\(powerPointID)"
            open POSIX file "\(q(url.path))"
            set p to active presentation
            try
                save p in POSIX file "\(q(tmp.path))" as save as PDF
            on error m number n
                close p saving no
                error m number n
            end try
            close p saving no
            \(wasRunning ? "" : "quit")
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err {
            let n = err[NSAppleScript.errorNumber] as? Int ?? 0
            if n == -1743 {
                throw ConvertError.notApplicable("PowerPoint 제어 권한이 필요해요: 시스템 설정 → 개인정보 보호 및 보안 → 자동화 → Convertly → Microsoft PowerPoint 켜기")
            }
            throw ConvertError.unreadable("\(url.lastPathComponent) — PowerPoint: \(err[NSAppleScript.errorMessage] as? String ?? "\(n)")")
        }
        guard let data = try? Data(contentsOf: tmp), !data.isEmpty else { throw ConvertError.writeFailed(url.lastPathComponent) }
        return data
    }

    // MARK: - 빠진 글꼴

    /// pptx·docx 가 쓰는 글꼴 중 이 맥에 없는 것. 없으면 비슷한 글꼴로 대체돼 모양이 달라진다.
    /// 테마의 다국어 대체 글꼴 목록(아랍·인도 문자 등)은 실제로 안 쓰여서 슬라이드·본문과 주 글꼴만 본다.
    public static func missingFonts(_ url: URL) -> [String] {
        let ext = url.pathExtension.lowercased()
        let parts: (String) -> Bool
        let pattern: String
        switch ext {
        case "pptx":
            parts = { $0.hasPrefix("ppt/slides/slide") || $0.hasPrefix("ppt/theme/theme") }
            pattern = #"<a:(?:latin|ea)\s+typeface="([^"+][^"]*)""#
        case "docx":
            parts = { $0 == "word/document.xml" || $0 == "word/styles.xml" || $0.hasPrefix("word/theme/") }
            pattern = #"w:(?:ascii|eastAsia|hAnsi)="([^"]+)"|<a:(?:latin|ea)\s+typeface="([^"+][^"]*)""#
        default:
            return []
        }
        guard let names = try? zipEntries(url).filter(parts), !names.isEmpty,
              let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var used = Set<String>()
        for name in names {
            guard let xml = try? zipRead(url, name) else { continue }
            let ns = xml as NSString
            for m in re.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
                for g in 1..<m.numberOfRanges where m.range(at: g).location != NSNotFound {
                    let f = ns.substring(with: m.range(at: g)).trimmingCharacters(in: .whitespaces)
                    if !f.isEmpty { used.insert(f) }
                }
            }
        }
        let families = Set(NSFontManager.shared.availableFontFamilies.map { $0.lowercased() })
        return used.filter { name in
            !families.contains(name.lowercased()) && NSFont(name: name, size: 12) == nil
        }.sorted()
    }

    static func zipEntries(_ url: URL) throws -> [String] {
        let out = try runTool("/usr/bin/zipinfo", ["-1", url.path])
        return out.split(separator: "\n").map(String.init)
    }

    static func zipRead(_ url: URL, _ entry: String) throws -> String {
        try runTool("/usr/bin/unzip", ["-p", url.path, entry])
    }

    static func runTool(_ path: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 발표 자료 → PDF (맥 내장 미리보기 엔진)

    /// pptx 등을 맥 내장 Quick Look 엔진(OfficeImport)이 HTML 로 펼치게 한 뒤(`qlmanage -p -o`),
    /// 그 HTML 을 WKWebView 로 그려 슬라이드마다 PDF 한 쪽으로 찍는다. Keynote·PowerPoint 없이 된다.
    static func slidesPDF(_ url: URL) throws -> Data {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("convertly-ql-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ql = Process()
        ql.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
        ql.arguments = ["-p", "-o", dir.path, url.path]
        ql.standardOutput = FileHandle.nullDevice
        ql.standardError = FileHandle.nullDevice
        try ql.run()
        ql.waitUntilExit()
        let bundle = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "qlpreview" }
        guard let html = bundle?.appendingPathComponent("Preview.html"), fm.fileExists(atPath: html.path) else {
            throw ConvertError.unreadable(url.lastPathComponent + " — 맥 미리보기 엔진이 열지 못함")
        }
        return try onMain { try await SlidesRenderer().pdf(html: html) }
    }

    /// hwp·hwpx → docx. hwpx 는 그대로, hwp 는 rhwp 로 hwpx 를 만든 뒤 `HwpxDocx` 가 표·문단 모양 값을 Word 로 옮긴다.
    /// 그 길이 실패하면 예전 방식(rhwp HTML → `DocxWriter`)으로 글자·표만이라도 살린다.
    static func docxData(_ url: URL, keepLineBreaks: Bool = true) throws -> Data {
        guard DocumentKind.of(url) == .hangul else { throw ConvertError.unsupported(url.lastPathComponent) }
        let bytes = try readBytes(url)
        do {
            let hwpx = HwpxDocx.isZip(bytes) ? bytes : try onMain { try await RHWPRenderer().hwpx(bytes) }
            return try HwpxDocx.docx(fromHWPX: hwpx, keepLineBreaks: keepLineBreaks)
        } catch {
            RHWPRenderer.log("hwpx → docx 실패, HTML 경로로: \(error)")
        }
        let html = try onMain { try await RHWPRenderer().html(bytes) }
        if RHWPRenderer.debug { try? html.write(toFile: NSTemporaryDirectory() + "convertly-last.html", atomically: true, encoding: .utf8) }
        return try DocxWriter.docx(fromHTML: html)
    }

    static func readBytes(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch { throw ConvertError.unreadable(url.lastPathComponent) }
    }

    // MARK: - 워드 계열 → PDF

    @MainActor
    static func officePDF(_ url: URL) throws -> Data {
        let name = url.lastPathComponent
        guard let attr = try? NSAttributedString(url: url, options: [:], documentAttributes: nil), attr.length > 0 else {
            throw ConvertError.unreadable(name)
        }
        let paper = NSSize(width: 595.28, height: 841.89)   // A4
        let margin: CGFloat = 56.7                          // 20mm
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("convertly-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let info = NSPrintInfo()
        info.paperSize = paper
        info.leftMargin = margin; info.rightMargin = margin
        info.topMargin = margin; info.bottomMargin = margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = tmp

        let width = paper.width - margin * 2
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        view.isVerticallyResizable = true
        view.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(attr)
        if let lm = view.layoutManager, let tc = view.textContainer {
            lm.ensureLayout(for: tc)
            view.setFrameSize(NSSize(width: width, height: ceil(lm.usedRect(for: tc).height) + 1))
        }

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), let data = try? Data(contentsOf: tmp), !data.isEmpty else {
            throw ConvertError.writeFailed(name)
        }
        return data
    }

    // MARK: - 메인 스레드 다리

    /// WebKit·인쇄는 메인 스레드에서만 돈다. 앱은 변환을 백그라운드에서 부르고(메인은 비어 있음),
    /// CLI 는 메인에서 부른다(런루프를 직접 돌려야 WebKit 콜백이 온다). 두 경우를 다 받는다.
    static func onMain<T>(_ op: @escaping @MainActor () async throws -> T) throws -> T {
        var result: Result<T, Error>?
        if Thread.isMainThread {
            Task { @MainActor in
                do { result = .success(try await op()) } catch { result = .failure(error) }
            }
            while result == nil {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            }
        } else {
            let done = DispatchSemaphore(value: 0)
            Task { @MainActor in
                do { result = .success(try await op()) } catch { result = .failure(error) }
                done.signal()
            }
            done.wait()
        }
        return try result!.get()
    }
}

// MARK: - rhwp (WKWebView)

/// rhwp 리소스 폴더. 안에 `rhwp/`(rhwp-studio 오프라인 사본 + render.html)가 있다.
/// 앱 번들 → 환경변수 → 저장소(개발용) 순으로 찾는다.
public enum RHWPResources {
    public static var directory: URL? {
        var candidates: [URL] = []
        if let r = Bundle.main.resourceURL { candidates.append(r.appendingPathComponent("rhwp-studio")) }
        if let env = ProcessInfo.processInfo.environment["CONVERTLY_RHWP_DIR"] { candidates.append(URL(fileURLWithPath: env)) }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(dir.appendingPathComponent("Resources/rhwp-studio"))
            dir.deleteLastPathComponent()
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("rhwp/render.html").path) }
    }
}

/// `convertly-rhwp://app/…` 요청에 리소스 파일과 문서 바이트를 준다. 렌더러와 편집기 창이 같이 쓴다.
/// - `/rhwp/…` → rhwp-studio 파일 (`/rhwp/rhwp_bg.wasm` 은 assets/rhwp_bg-*.wasm 로 연결)
/// - `/rhwp/doc` → 렌더링할 문서, `/file/<id>/<이름>` → 편집기로 연 문서
@MainActor
public final class RHWPSchemeHandler: NSObject, WKURLSchemeHandler {
    public static let scheme = "convertly-rhwp"
    let root: URL
    var doc = Data()
    var files: [String: Data] = [:]

    public init(root: URL) { self.root = root }

    /// 편집기에 넘길 파일을 등록하고 그 URL 을 돌려준다.
    public func register(_ data: Data, name: String) -> URL {
        let id = UUID().uuidString
        files[id] = data
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "document.hwp"
        return URL(string: "\(Self.scheme)://app/file/\(id)/\(enc)")!
    }

    func resolve(_ path: String) -> (Data, String)? {
        if path == "/rhwp/doc" { return (doc, "application/octet-stream") }
        let parts = path.split(separator: "/").map(String.init)
        if parts.first == "file", parts.count >= 2, let d = files[parts[1]] { return (d, "application/octet-stream") }
        var rel = String(path.drop(while: { $0 == "/" }))
        if rel == "rhwp/rhwp_bg.wasm",
           let hit = try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("rhwp/assets").path)
            .first(where: { $0.hasPrefix("rhwp_bg") && $0.hasSuffix(".wasm") }) {
            rel = "rhwp/assets/" + hit
        }
        let file = root.appendingPathComponent(rel).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path), let data = try? Data(contentsOf: file) else { return nil }
        let mime: String
        switch file.pathExtension {
        case "html": mime = "text/html"
        case "js": mime = "text/javascript"
        case "css": mime = "text/css"
        case "wasm": mime = "application/wasm"
        case "json", "webmanifest": mime = "application/json"
        case "svg": mime = "image/svg+xml"
        case "png": mime = "image/png"
        case "ico": mime = "image/x-icon"
        case "woff2": mime = "font/woff2"
        default: mime = "application/octet-stream"
        }
        return (data, mime)
    }

    nonisolated public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        MainActor.assumeIsolated {
            let path = task.request.url?.path ?? ""
            RHWPRenderer.log("request \(path)")
            guard let url = task.request.url, let (data, mime) = resolve(path) else {
                task.didFailWithError(URLError(.fileDoesNotExist)); return
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": mime, "Content-Length": "\(data.count)",
                                                          "Access-Control-Allow-Origin": "*"])!
            task.didReceive(response)
            task.didReceive(data)
            task.didFinish()
        }
    }
    nonisolated public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

@MainActor
final class RHWPRenderer: NSObject, WKNavigationDelegate {
    /// SVG 는 CSS px(96dpi). PDF 는 pt(72dpi) 라서 0.75배로 줄여 찍으면 A4 가 정확히 595×842pt 가 된다.
    static let zoom: CGFloat = 0.75

    private var handler: RHWPSchemeHandler!
    private var loaded: CheckedContinuation<Void, Error>?
    private var webView: WKWebView!

    private func open(_ bytes: Data) async throws {
        guard let dir = RHWPResources.directory else {
            throw ConvertError.unsupported("hwp 엔진(rhwp) 리소스를 찾지 못함")
        }
        handler = RHWPSchemeHandler(root: dir)
        handler.doc = bytes
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(handler, forURLScheme: RHWPSchemeHandler.scheme)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1200), configuration: config)
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            webView.load(URLRequest(url: URL(string: "\(RHWPSchemeHandler.scheme)://app/rhwp/render.html")!))
        }
    }

    func pdf(_ bytes: Data) async throws -> Data {
        try await open(bytes)
        let json = try await call("return await window.convertlyRender()")
        guard let data = json.data(using: .utf8),
              let sizes = try? JSONDecoder().decode([[Double]].self, from: data), !sizes.isEmpty else {
            throw ConvertError.unreadable("hwp 렌더링 결과 없음")
        }
        let maxW = sizes.map { $0[0] }.max() ?? 800
        let total = sizes.reduce(0) { $0 + $1[1] }
        webView.pageZoom = Self.zoom
        webView.setFrameSize(NSSize(width: maxW * Self.zoom, height: min(total * Self.zoom, 20000)))

        let out = PDFDocument()
        var y = 0.0
        for size in sizes {
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: y * Self.zoom, width: size[0] * Self.zoom, height: size[1] * Self.zoom)
            let pageData = try await webView.pdf(configuration: config)
            if let page = PDFDocument(data: pageData)?.page(at: 0) { out.insert(page, at: out.pageCount) }
            y += size[1]
        }
        guard out.pageCount > 0, let result = out.dataRepresentation() else {
            throw ConvertError.writeFailed("hwp → PDF")
        }
        return result
    }

    func hwpx(_ bytes: Data) async throws -> Data {
        try await open(bytes)
        let b64 = try await call("return await window.convertlyHWPX()")
        guard let data = Data(base64Encoded: b64), HwpxDocx.isZip(data) else { throw ConvertError.unreadable("hwp → hwpx") }
        return data
    }

    func html(_ bytes: Data) async throws -> String {
        try await open(bytes)
        return try await call("return await window.convertlyHTML()")
    }

    nonisolated static let debug = ProcessInfo.processInfo.environment["CONVERTLY_DEBUG"] != nil
    nonisolated static func log(_ m: String) { if debug { FileHandle.standardError.write(("[rhwp] " + m + "\n").data(using: .utf8)!) } }

    /// didFinish 가 모듈 스크립트(rhwp.js import)보다 먼저 올 수 있어서, 준비 표시를 기다린 뒤 부른다.
    private func call(_ body: String) async throws -> String {
        let js = "for (let i = 0; i < 500 && !window.convertlyReady; i++) await new Promise(r => setTimeout(r, 20));\n" + body
        Self.log("call \(body)")
        let value: Any?
        do {
            value = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
        } catch let error as NSError {
            let msg = error.userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
            throw ConvertError.unreadable("hwp 엔진 오류 — \(msg)")
        }
        guard let s = value as? String else { throw ConvertError.unreadable("hwp 문서") }
        return s
    }

    // WKNavigationDelegate
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        RHWPRenderer.log("didFinish")
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }
}

/// Quick Look 이 만든 슬라이드 HTML(div.slide 들)을 쪽마다 PDF 로.
@MainActor
final class SlidesRenderer: NSObject, WKNavigationDelegate {
    private var loaded: CheckedContinuation<Void, Error>?
    private var webView: WKWebView!

    func pdf(html: URL) async throws -> Data {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 1000))
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            webView.loadFileURL(html, allowingReadAccessTo: html.deletingLastPathComponent())
        }
        // 화면용 여백·그림자·회색 배경을 없애고 슬라이드 위치를 잰다.
        let js = """
        const st = document.createElement('style');
        st.textContent = 'body{background:#fff!important;margin:0!important} div.slide{margin:0!important;-webkit-box-shadow:none!important;box-shadow:none!important} div.loading-slide{display:none!important}';
        document.head.appendChild(st);
        await new Promise(r => setTimeout(r, 50));
        return JSON.stringify([...document.querySelectorAll('div.slide')].map(e => {
          const r = e.getBoundingClientRect();
          return [r.left + window.scrollX, r.top + window.scrollY, r.width, r.height];
        }));
        """
        let value = try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
        guard let json = value as? String, let rects = try? JSONDecoder().decode([[Double]].self, from: Data(json.utf8)),
              !rects.isEmpty else { throw ConvertError.unreadable("슬라이드를 찾지 못함") }
        let zoom = RHWPRenderer.zoom
        let maxW = rects.map { $0[0] + $0[2] }.max() ?? 1280
        let maxH = rects.map { $0[1] + $0[3] }.max() ?? 720
        webView.pageZoom = zoom
        webView.setFrameSize(NSSize(width: maxW * zoom, height: min(maxH * zoom, 20000)))
        let out = PDFDocument()
        for r in rects {
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: r[0] * zoom, y: r[1] * zoom, width: r[2] * zoom, height: r[3] * zoom)
            if let page = PDFDocument(data: try await webView.pdf(configuration: config))?.page(at: 0) {
                out.insert(page, at: out.pageCount)
            }
        }
        guard out.pageCount > 0, let data = out.dataRepresentation() else { throw ConvertError.writeFailed("슬라이드 → PDF") }
        return data
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }
}

/// HTML 발표자료 → PDF. 브라우저처럼 스크립트·웹폰트까지 돌린 뒤 슬라이드를 하나씩만 보이게 해서 16:9 한 쪽씩 찍는다.
/// 슬라이드 찾기: reveal.js(.slides > section) → .slide → main/body/article > section (2장 이상일 때). 못 찾으면 nil.
@MainActor
final class HTMLDeckRenderer: NSObject, WKNavigationDelegate {
    static let width: CGFloat = 1280, height: CGFloat = 720
    private var loaded: CheckedContinuation<Void, Error>?
    private var webView: WKWebView!

    func pdf(_ url: URL) async throws -> Data? {
        let config = WKWebViewConfiguration()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height), configuration: config)
        webView.navigationDelegate = self
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            loaded = c
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        let count = try await js("""
        await (document.fonts ? document.fonts.ready : Promise.resolve());
        await new Promise(r => setTimeout(r, 300));
        const rules = ['.reveal .slides > section', '.slide', 'main > section', 'body > section', 'article > section'];
        let list = [];
        for (const q of rules) { list = [...document.querySelectorAll(q)]; if (list.length >= 2) break; }
        if (list.length < 2) return 0;
        list.forEach((el, i) => el.setAttribute('data-cv-slide', i));
        const st = document.createElement('style');
        st.id = 'cv-style';
        st.textContent = `html,body{overflow:hidden!important} *{transition:none!important;animation:none!important}
          nav, .bar, .controls, .progress, .slide-number, .navigate-left, .navigate-right{display:none!important}
          ::-webkit-scrollbar{display:none}`;
        document.head.appendChild(st);
        return list.length;
        """) as? Int ?? 0
        guard count >= 2 else { return nil }

        let zoom: CGFloat = 0.75   // CSS px → pt (1280×720 → 960×540pt)
        let out = PDFDocument()
        for n in 0..<count {
            _ = try await js("""
            const n = \(n);
            if (window.Reveal && Reveal.slide) { Reveal.slide(n); }
            else {
              const list = [...document.querySelectorAll('[data-cv-slide]')];
              let st = document.getElementById('cv-show');
              if (!st) { st = document.createElement('style'); st.id = 'cv-show'; document.head.appendChild(st); }
              // 겹쳐 쌓인 덱은 그 장만 보이게, 아래로 이어지는 문서는 그 장으로 스크롤
              st.textContent = `[data-cv-slide]{visibility:hidden!important;opacity:0!important}
                [data-cv-slide="${n}"]{visibility:visible!important;opacity:1!important}`;
              list.forEach(el => el.classList.toggle('on', +el.dataset.cvSlide === n));
              const r = list[n].getBoundingClientRect();
              window.scrollTo(0, r.top + window.scrollY);
            }
            await new Promise(r => setTimeout(r, 250));
            return 1;
            """)
            webView.pageZoom = zoom
            webView.setFrameSize(NSSize(width: Self.width * zoom, height: Self.height * zoom))
            let cfg = WKPDFConfiguration()
            let top = try await js("return window.scrollY") as? Double ?? 0
            cfg.rect = CGRect(x: 0, y: CGFloat(top) * zoom, width: Self.width * zoom, height: Self.height * zoom)
            if let page = PDFDocument(data: try await webView.pdf(configuration: cfg))?.page(at: 0) {
                out.insert(page, at: out.pageCount)
            }
        }
        return out.pageCount > 0 ? out.dataRepresentation() : nil
    }

    private func js(_ body: String) async throws -> Any? {
        do { return try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page) }
        catch let e as NSError { throw ConvertError.unreadable("HTML — \(e.userInfo["WKJavaScriptExceptionMessage"] as? String ?? e.localizedDescription)") }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { loaded?.resume(); loaded = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }
    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { loaded?.resume(throwing: error); loaded = nil }
    }
}
