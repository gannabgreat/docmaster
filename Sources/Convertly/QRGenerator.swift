import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers

/// QR 코드 만들기. 맥 기본 CoreImage 생성기를 쓰고, PNG(크기 선택)·SVG(벡터)로 저장하거나 복사한다.
struct QRContent {
    enum Kind: String, CaseIterable, Identifiable {
        case link = "링크·글자", wifi = "와이파이"
        var id: String { rawValue }
    }
    var kind: Kind = .link
    var text = "https://"
    var ssid = ""
    var password = ""
    var security = "WPA"

    /// QR 에 실제로 담을 문자열. 와이파이는 휴대폰 카메라가 바로 접속하는 표준 형식(WIFI:...).
    var payload: String {
        switch kind {
        case .link: return text
        case .wifi:
            func esc(_ s: String) -> String {
                s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;")
                    .replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ":", with: "\\:")
                    .replacingOccurrences(of: "\"", with: "\\\"")
            }
            return security == "nopass" ? "WIFI:T:nopass;S:\(esc(ssid));;" : "WIFI:T:\(security);S:\(esc(ssid));P:\(esc(password));;"
        }
    }
}

enum QR {
    /// 모듈(검은 칸) 행렬. true = 칠함. 여백(quiet zone)은 포함하지 않는다.
    static func matrix(_ text: String, correction: String) -> [[Bool]]? {
        guard !text.isEmpty else { return nil }
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = correction
        guard let img = f.outputImage else { return nil }
        let ctx = CIContext()
        let w = Int(img.extent.width), h = Int(img.extent.height)
        guard let cg = ctx.createCGImage(img, from: img.extent) else { return nil }
        var px = [UInt8](repeating: 0, count: w * h)
        guard let bm = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                 space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        bm.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CoreImage 출력에는 사방 1칸 여백이 이미 있다 → 걷어낸다.
        let rows = (0..<h).map { y in (0..<w).map { x in px[y * w + x] < 128 } }
        return Array(rows.dropFirst().dropLast().map { Array($0.dropFirst().dropLast()) })
    }

    static func image(_ m: [[Bool]], pixels: Int, margin: Int, fg: NSColor, bg: NSColor) -> CGImage? {
        let n = m.count + margin * 2
        let scale = max(1, pixels / n)
        let size = n * scale
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(bg.usingColorSpace(.sRGB)?.cgColor ?? .white)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(fg.usingColorSpace(.sRGB)?.cgColor ?? .black)
        for (y, row) in m.enumerated() {
            for (x, on) in row.enumerated() where on {
                ctx.fill(CGRect(x: (x + margin) * scale, y: size - (y + margin + 1) * scale, width: scale, height: scale))
            }
        }
        return ctx.makeImage()
    }

    static func svg(_ m: [[Bool]], margin: Int, fg: NSColor, bg: NSColor) -> String {
        let n = m.count + margin * 2
        func hex(_ c: NSColor) -> String {
            let c = c.usingColorSpace(.sRGB) ?? .black
            return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        var path = ""
        for (y, row) in m.enumerated() {
            var x = 0
            while x < row.count {
                if row[x] {
                    var run = 1
                    while x + run < row.count && row[x + run] { run += 1 }
                    path += "M\(x + margin) \(y + margin)h\(run)v1h-\(run)z"
                    x += run
                } else { x += 1 }
            }
        }
        return """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(n) \(n)" shape-rendering="crispEdges"><rect width="\(n)" height="\(n)" fill="\(hex(bg))"/><path d="\(path)" fill="\(hex(fg))"/></svg>
        """
    }
}

struct QRView: View {
    @State private var content = QRContent()
    @State private var correction = "M"
    @State private var pixels = 1024
    @State private var margin = 4
    @State private var fg = Color.black
    @State private var bg = Color.white
    @State private var status: String?
    weak var window: NSWindow?

    private var matrix: [[Bool]]? { QR.matrix(content.payload, correction: correction) }
    private var nsFG: NSColor { NSColor(fg) }
    private var nsBG: NSColor { NSColor(bg) }

    var body: some View {
        HStack(spacing: 0) {
            Form {
                Section("내용") {
                    Picker("종류", selection: $content.kind) {
                        ForEach(QRContent.Kind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if content.kind == .link {
                        TextField("링크나 글자", text: $content.text, axis: .vertical).lineLimit(3...6)
                    } else {
                        TextField("와이파이 이름(SSID)", text: $content.ssid)
                        Picker("보안", selection: $content.security) {
                            Text("WPA/WPA2/WPA3").tag("WPA"); Text("WEP").tag("WEP"); Text("비밀번호 없음").tag("nopass")
                        }
                        if content.security != "nopass" { SecureField("비밀번호", text: $content.password) }
                    }
                }
                Section("모양") {
                    Picker("오류 복원", selection: $correction) {
                        Text("낮음 (7%)").tag("L"); Text("보통 (15%)").tag("M"); Text("높음 (25%)").tag("Q"); Text("최고 (30%)").tag("H")
                    }
                    Picker("PNG 크기", selection: $pixels) {
                        ForEach([256, 512, 1024, 2048], id: \.self) { Text("\($0)px").tag($0) }
                    }
                    Stepper("여백 \(margin)칸", value: $margin, in: 0...8)
                    ColorPicker("코드 색", selection: $fg, supportsOpacity: false)
                    ColorPicker("배경 색", selection: $bg, supportsOpacity: false)
                }
                Section {
                    Text("로고를 가운데 얹을 거면 오류 복원을 「높음」 이상으로 두세요. 색은 진한 코드 + 밝은 배경이어야 잘 읽혀요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(width: 330)

            Divider()

            VStack(spacing: 14) {
                Spacer()
                if let m = matrix, let cg = QR.image(m, pixels: 600, margin: margin, fg: nsFG, bg: nsBG) {
                    Image(decorative: cg, scale: 1).interpolation(.none).resizable().frame(width: 300, height: 300)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                    Text("\(m.count)×\(m.count) 칸 · \(content.payload.utf8.count)바이트").font(.caption).foregroundStyle(.secondary)
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(width: 300, height: 300)
                        .overlay(Text(content.payload.isEmpty ? "내용을 입력하세요" : "너무 길어서 QR에 안 들어가요").foregroundStyle(.secondary))
                }
                HStack {
                    Button("복사") { copy() }.disabled(matrix == nil)
                    Button("SVG 저장…") { save(svg: true) }.disabled(matrix == nil)
                    Button("PNG 저장…") { save(svg: false) }.buttonStyle(.borderedProminent).disabled(matrix == nil)
                }
                Text(status ?? " ").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .frame(minWidth: 760, minHeight: 520)
    }

    private func copy() {
        guard let m = matrix, let cg = QR.image(m, pixels: pixels, margin: margin, fg: nsFG, bg: nsBG) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))])
        status = "클립보드에 복사함 (\(cg.width)px)"
    }

    private func save(svg: Bool) {
        guard let m = matrix else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [svg ? .svg : .png]
        panel.nameFieldStringValue = "QR." + (svg ? "svg" : "png")
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let write: (NSApplication.ModalResponse) -> Void = { r in
            guard r == .OK, let url = panel.url else { return }
            do {
                if svg {
                    try QR.svg(m, margin: margin, fg: nsFG, bg: nsBG).write(to: url, atomically: true, encoding: .utf8)
                } else {
                    guard let cg = QR.image(m, pixels: pixels, margin: margin, fg: nsFG, bg: nsBG),
                          let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
                    try data.write(to: url)
                }
                status = "저장함: \(url.lastPathComponent)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                status = "저장 실패: \(error.localizedDescription)"
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: write) } else { write(panel.runModal()) }
    }
}

@MainActor
enum QRWindow {
    private static var window: NSWindow?

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "QR 만들기"
        w.isReleasedWhenClosed = false
        var view = QRView()
        view.window = w
        w.contentView = NSHostingView(rootView: view)
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
