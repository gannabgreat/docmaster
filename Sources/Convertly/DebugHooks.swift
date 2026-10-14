import AppKit

/// 개발용. 화면이 꺼진·잠긴 맥에서도 창 모습과 변환 흐름을 확인하려고 쓴다.
///   CONVERTLY_AUTORUN=1              실행 1초 뒤 「변환 시작」
///   CONVERTLY_SNAPSHOT=/경로.png      몇 초 뒤 창 내용을 PNG 로 저장
///   CONVERTLY_SNAPSHOT_DELAY=초       저장까지 기다릴 시간(기본 4)
///   CONVERTLY_EDITOR=/문서.hwp        HWP 편집기 창으로 바로 열기
///   CONVERTLY_ORGANIZER=/a.pdf:/b.hwp PDF 쪽 편집 창으로 바로 열기(콜론으로 구분)
///   CONVERTLY_QR=1                    QR 창 열기
///   CONVERTLY_SNAPSHOT_TITLE=제목      CONVERTLY_SNAPSHOT 이 찍을 창(기본: 처음 보이는 창)
///   CONVERTLY_EDITOR_SNAPSHOT=/경로.png 몇 초 뒤 편집기 화면(웹뷰)을 PNG 로 저장
enum DebugHooks {
    @MainActor
    static func start(model: AppModel) {
        let env = ProcessInfo.processInfo.environment
        if env["CONVERTLY_AUTORUN"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.run() }
        }
        if let doc = env["CONVERTLY_EDITOR"] {
            HWPEditor.show(URL(fileURLWithPath: doc))
            if let path = env["CONVERTLY_EDITOR_SNAPSHOT"] {
                let delay = Double(env["CONVERTLY_SNAPSHOT_DELAY"] ?? "") ?? 6
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { HWPEditor.debugSnapshot(to: path) }
            }
        }
        if let list = env["CONVERTLY_ORGANIZER"] {
            PageOrganizer.show(list.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        if env["CONVERTLY_QR"] == "1" { QRWindow.show() }
        if let path = env["CONVERTLY_SNAPSHOT"] {
            let delay = Double(env["CONVERTLY_SNAPSHOT_DELAY"] ?? "") ?? 4
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { snapshot(to: path) }
        }
    }

    /// 창 PNG 와 함께 `<경로>.views.txt` 에 뷰 트리(버튼 제목·상태·활성)를 적는다.
    /// cacheDisplay 는 일부 컨트롤(강조 버튼·토글 상태)을 못 그려서 그쪽은 트리로 확인한다.
    @MainActor
    private static func snapshot(to path: String) {
        let title = ProcessInfo.processInfo.environment["CONVERTLY_SNAPSHOT_TITLE"]
        guard let window = NSApp.windows.first(where: { $0.isVisible && (title == nil || $0.title == title) }), let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))

        // 레이어로 그린 버전도 남긴다(강조 버튼처럼 cacheDisplay 가 빠뜨리는 것 확인용).
        if let layer = view.layer {
            let scale = window.backingScaleFactor
            let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
            if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.scaleBy(x: scale, y: scale)
                layer.render(in: ctx)
                if let img = ctx.makeImage() {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: path + ".layer.png"))
                }
            }
        }

        var lines: [String] = []
        func walk(_ v: NSView, _ depth: Int) {
            var line = String(repeating: "  ", count: depth) + String(describing: type(of: v))
            if let b = v as? NSButton { line += " title=\(b.title) state=\(b.state.rawValue) enabled=\(b.isEnabled)" }
            else if let c = v as? NSControl { line += " value=\(c.stringValue) enabled=\(c.isEnabled)" }
            lines.append(line)
            for sub in v.subviews { walk(sub, depth + 1) }
        }
        walk(view, 0)
        try? lines.joined(separator: "\n").write(toFile: path + ".views.txt", atomically: true, encoding: .utf8)
    }
}
