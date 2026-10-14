import AppKit
import ConvertlyCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var dropTargeted = false
    @State private var importing = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                fileArea
                Divider()
                bottomBar
            }
            Divider()
            OptionsPanel()
                .frame(width: 300)
        }
        .frame(minWidth: 860, minHeight: 640)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .pdf, .folder] + UTType.convertlyDocuments,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
    }

    private var fileArea: some View {
        ZStack {
            if model.items.isEmpty {
                DropHint(targeted: dropTargeted)
            } else {
                List {
                    ForEach(model.items) { item in
                        FileRow(item: item)
                    }
                    .onMove { model.move(from: $0, to: $1) }
                }
                .listStyle(.inset)
            }
        }
        .overlay {
            if dropTargeted && !model.items.isEmpty {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            loadDropped(providers)
            return true
        }
    }

    /// 끌어놓은 순서를 지키려고 다 읽은 뒤 한 번에 넣는다.
    private func loadDropped(_ providers: [NSItemProvider]) {
        var urls = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        let lock = NSLock()
        for (i, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                lock.lock(); urls[i] = url; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            model.add(urls.compactMap { $0 })
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.skipped.isEmpty {
                Text("지원하지 않는 파일 \(model.skipped.count)개 건너뜀: \(model.skipped.prefix(3).joined(separator: ", "))\(model.skipped.count > 3 ? " …" : "")")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack(spacing: 8) {
                Button("파일 추가…") { importing = true }
                    .disabled(model.isRunning)
                Button("목록 비우기") { model.clear() }
                    .disabled(model.items.isEmpty || model.isRunning)
                Menu {
                    Button("목록 파일로 열기") { PageOrganizer.show(model.items.map(\.url)) }
                        .disabled(model.items.isEmpty)
                    Button("빈 파일로 열기") { PageOrganizer.show() }
                } label: { Label("PDF 편집", systemImage: "doc.on.doc") }
                .fixedSize()
                .disabled(model.isRunning)
                Menu {
                    Button("HWP 편집기") { HWPEditor.show() }
                    Button("QR 만들기") { QRWindow.show() }
                } label: { Label("도구", systemImage: "wrench.and.screwdriver") }
                .fixedSize()
                .disabled(model.isRunning)
                Spacer()
                if let t = model.totals {
                    Text(totalsText(t))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Button {
                    model.run()
                } label: {
                    Label(model.isRunning ? "변환 중…" : "변환 시작", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canRun)
            }
        }
        .padding(12)
    }

    private func totalsText(_ t: (before: Int64, after: Int64, done: Int, failed: Int)) -> String {
        var s = "완료 \(t.done)개 · \(Converter.formatBytes(t.before)) → \(Converter.formatBytes(t.after))"
        if t.failed > 0 { s += " · 실패 \(t.failed)개" }
        return s
    }
}

private struct DropHint: View {
    let targeted: Bool

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.and.arrow.down.on.square")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(targeted ? Color.accentColor : .secondary)
            Text("파일이나 폴더를 여기로 끌어놓으세요")
                .font(.title3.weight(.medium))
            Text("PNG · JPG · HEIC · WebP · TIFF · GIF · BMP · PDF · HWP · HWPX · DOCX · PPTX")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(16)
        )
    }
}

private struct FileRow: View {
    @EnvironmentObject private var model: AppModel
    let item: FileItem

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Converter.formatBytes(item.bytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            status
            if Converter.isPDF(item.url) || Converter.isDocument(item.url) {
                Button { PageOrganizer.show([item.url]) } label: { Image(systemName: "rectangle.grid.2x2") }
                    .buttonStyle(.borderless)
                    .help("PDF 쪽 편집(순서·삭제·회전)")
            }
            if DocumentKind.of(item.url) == .hangul {
                Button { HWPEditor.show(item.url) } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("HWP 편집기로 열기")
            }
            if case .done = item.status {
                Button { model.reveal(item) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help("Finder에서 결과 보기")
            }
            if !model.isRunning {
                Button { model.remove(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("목록에서 빼기")
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.reveal(item) }
    }

    @ViewBuilder
    private var status: some View {
        switch item.status {
        case .waiting:
            Text("대기").font(.caption).foregroundStyle(.secondary)
        case .running:
            ProgressView().controlSize(.small)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        case .done(let r):
            if let note = r.note {
                Text(note).font(.caption).foregroundStyle(.orange).lineLimit(2)
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(resultName(r)).font(.caption).lineLimit(1).truncationMode(.middle)
                    if let w = r.warning {
                        Text("⚠ " + w).font(.caption2).foregroundStyle(.orange).lineLimit(1).truncationMode(.tail).help(w)
                    }
                    Text(change(r)).font(.caption.weight(.semibold)).foregroundStyle(r.outputBytes < r.inputBytes ? .green : .orange)
                        .monospacedDigit()
                }
            }
        }
    }

    private func resultName(_ r: ConvertResult) -> String {
        guard let first = r.outputs.first else { return "" }
        return r.outputs.count > 1 ? "\(first.deletingLastPathComponent().lastPathComponent)/ \(r.outputs.count)장" : first.lastPathComponent
    }

    private func change(_ r: ConvertResult) -> String {
        let after = Converter.formatBytes(r.outputBytes)
        guard r.inputBytes > 0 else { return after }
        let ratio = Double(r.outputBytes) / Double(r.inputBytes)
        if ratio >= 10 { return "\(after) (\(Int(ratio))배)" }
        let pct = Int((ratio - 1) * 100)
        return "\(after) (\(pct >= 0 ? "+" : "−")\(abs(pct))%)"
    }
}
