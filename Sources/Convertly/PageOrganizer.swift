import AppKit
import ConvertlyCore
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// PDF 쪽 순서 편집기. 쪽을 끌어 순서 바꾸기 · 삭제 · 회전 · 다른 파일 끼워넣기 → 새 PDF 로 저장.
/// 이미지·hwp·docx·pptx 도 넣으면 PDF 쪽으로 바꿔서 끼운다. 원본 파일은 건드리지 않는다.
struct PageItem: Identifiable {
    let id = UUID()
    let page: PDFPage
    let source: String
    var thumbnail: NSImage
}

@MainActor
final class OrganizerModel: ObservableObject {
    @Published var pages: [PageItem] = []
    @Published var selection: Set<UUID> = []
    @Published var loading = 0
    @Published var message: String?
    @Published var dirty = false
    var firstSource: URL?

    /// 파일들을 PDF 쪽으로 바꿔 `index` 자리(없으면 끝)에 끼운다. 문서 변환은 무거워서 백그라운드에서 한다.
    func insert(_ urls: [URL], at index: Int? = nil) {
        let accepted = urls.filter { Converter.isSupported($0) }
        let rejected = urls.count - accepted.count
        guard !accepted.isEmpty else {
            if rejected > 0 { message = "넣을 수 없는 파일 \(rejected)개" }
            return
        }
        if firstSource == nil { firstSource = accepted.first }
        loading += 1
        Task.detached(priority: .userInitiated) {
            var loaded: [(PDFPage, String)] = []
            var failed: [String] = []
            for url in accepted {
                do {
                    let doc = try Converter.loadAsPDF(url)
                    for i in 0..<doc.pageCount {
                        if let p = doc.page(at: i)?.copy() as? PDFPage { loaded.append((p, url.lastPathComponent)) }
                    }
                } catch {
                    failed.append(error.localizedDescription)
                }
            }
            let pagesLoaded = loaded, failures = failed
            await MainActor.run {
                let items = pagesLoaded.map { PageItem(page: $0.0, source: $0.1, thumbnail: Self.thumb($0.0)) }
                let at = min(index ?? self.pages.count, self.pages.count)
                self.pages.insert(contentsOf: items, at: at)
                if !items.isEmpty { self.dirty = true }
                self.loading -= 1
                var notes: [String] = []
                if !failures.isEmpty { notes.append(failures.joined(separator: " / ")) }
                if rejected > 0 { notes.append("넣을 수 없는 파일 \(rejected)개") }
                self.message = notes.isEmpty ? nil : notes.joined(separator: " · ")
            }
        }
    }

    static func thumb(_ page: PDFPage) -> NSImage {
        // 쪽 비율대로(가로 슬라이드는 가로로) 만든다. 정사각형으로 받으면 위아래에 빈 띠가 생긴다.
        var size = page.bounds(for: .cropBox).size
        if page.rotation % 180 != 0 { size = NSSize(width: size.height, height: size.width) }
        let scale = 360 / max(size.width, size.height, 1)
        return page.thumbnail(of: NSSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
    }

    func move(_ id: UUID, before target: UUID?) {
        guard let from = pages.firstIndex(where: { $0.id == id }) else { return }
        let ids = selection.contains(id) ? selection : [id]
        let moving = pages.filter { ids.contains($0.id) }
        var rest = pages.filter { !ids.contains($0.id) }
        let to = target.flatMap { t in rest.firstIndex { $0.id == t } } ?? rest.count
        rest.insert(contentsOf: moving, at: to)
        if rest.map(\.id) != pages.map(\.id) { pages = rest; dirty = true }
        _ = from
    }

    func rotateSelected(_ degrees: Int) {
        for i in pages.indices where selection.contains(pages[i].id) {
            pages[i].page.rotation = (pages[i].page.rotation + degrees + 360) % 360
            pages[i].thumbnail = Self.thumb(pages[i].page)
        }
        if !selection.isEmpty { dirty = true }
    }

    func deleteSelected() {
        guard !selection.isEmpty else { return }
        pages.removeAll { selection.contains($0.id) }
        selection = []
        dirty = true
    }

    func tap(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } else if flags.contains(.shift), let last = selection.compactMap({ s in pages.firstIndex { $0.id == s } }).max(),
                  let cur = pages.firstIndex(where: { $0.id == id }) {
            for i in min(last, cur)...max(last, cur) { selection.insert(pages[i].id) }
        } else {
            selection = [id]
        }
    }

    func save(from window: NSWindow?) {
        guard !pages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = firstSource?.deletingPathExtension().lastPathComponent ?? "문서"
        panel.nameFieldStringValue = base + "_편집.pdf"
        if let dir = firstSource?.deletingLastPathComponent() { panel.directoryURL = dir }
        let done: (NSApplication.ModalResponse) -> Void = { [self] r in
            guard r == .OK, let url = panel.url else { return }
            let out = PDFDocument()
            for item in pages {
                if let p = item.page.copy() as? PDFPage { out.insert(p, at: out.pageCount) }
            }
            if out.write(to: url) {
                dirty = false
                message = "저장함: \(url.lastPathComponent) (\(out.pageCount)쪽)"
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else {
                message = "저장하지 못했어요: \(url.lastPathComponent)"
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }
}

struct OrganizerView: View {
    @ObservedObject var model: OrganizerModel
    weak var window: NSWindow?
    @State private var importing = false
    @State private var dragging: UUID?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ZStack {
                if model.pages.isEmpty && model.loading == 0 {
                    VStack(spacing: 10) {
                        Image(systemName: "doc.on.doc").font(.system(size: 46, weight: .light)).foregroundStyle(.secondary)
                        Text("PDF·이미지·hwp·docx·pptx 를 끌어놓으세요").font(.title3)
                        Text("쪽을 끌어서 순서를 바꾸고, 골라서 회전·삭제한 뒤 저장해요").foregroundStyle(.secondary)
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(Array(model.pages.enumerated()), id: \.element.id) { index, item in
                                PageCell(item: item, number: index + 1, selected: model.selection.contains(item.id))
                                    .opacity(dragging == item.id ? 0.4 : 1)
                                    .onTapGesture { model.tap(item.id) }
                                    .onDrag {
                                        dragging = item.id
                                        if !model.selection.contains(item.id) { model.selection = [item.id] }
                                        return NSItemProvider(object: item.id.uuidString as NSString)
                                    }
                                    .onDrop(of: [.text, .fileURL], delegate: PageDrop(target: item.id, index: index,
                                                                                       model: model, dragging: $dragging))
                            }
                        }
                        .padding(16)
                    }
                    .onDrop(of: [.fileURL, .text], delegate: PageDrop(target: nil, index: nil, model: model, dragging: $dragging))
                }
                if model.loading > 0 {
                    ProgressView("파일을 쪽으로 바꾸는 중…").padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], delegate: PageDrop(target: nil, index: nil, model: model, dragging: $dragging))
            Divider()
            HStack {
                Text(model.message ?? "\(model.pages.count)쪽 · 선택 \(model.selection.count)쪽 · ⌘클릭 여러 개, ⇧클릭 범위")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(minWidth: 760, minHeight: 560)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image] + UTType.convertlyDocuments,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.insert(urls) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { importing = true } label: { Label("파일 추가", systemImage: "plus") }
            Divider().frame(height: 18)
            Button { model.rotateSelected(-90) } label: { Label("왼쪽으로", systemImage: "rotate.left") }
                .disabled(model.selection.isEmpty)
            Button { model.rotateSelected(90) } label: { Label("오른쪽으로", systemImage: "rotate.right") }
                .disabled(model.selection.isEmpty)
            Button(role: .destructive) { model.deleteSelected() } label: { Label("삭제", systemImage: "trash") }
                .disabled(model.selection.isEmpty)
                .keyboardShortcut(.delete, modifiers: [])
            Button("전체 선택") { model.selection = Set(model.pages.map(\.id)) }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(model.pages.isEmpty)
            Spacer()
            Button { model.save(from: window) } label: { Label("새 PDF로 저장", systemImage: "square.and.arrow.down") }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.pages.isEmpty || model.loading > 0)
        }
        .padding(10)
    }
}

private struct PageCell: View {
    let item: PageItem
    let number: Int
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: item.thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 190)
                .background(Color.white)
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            Text("\(number)").font(.callout.weight(.semibold)).monospacedDigit()
            Text(item.source).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(6)
        .background(selected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

/// 쪽 끌기(순서 바꾸기)와 Finder 에서 파일 끌어놓기(끼워넣기)를 같이 받는다.
private struct PageDrop: DropDelegate {
    let target: UUID?
    let index: Int?
    let model: OrganizerModel
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let d = dragging, let target, d != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { model.move(d, before: target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: dragging != nil ? .move : .copy) }

    func performDrop(info: DropInfo) -> Bool {
        if dragging != nil {
            if target == nil, let d = dragging { model.move(d, before: nil) }
            dragging = nil
            return true
        }
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        var urls = [URL?](repeating: nil, count: providers.count)
        let group = DispatchGroup()
        for (i, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async { urls[i] = url; group.leave() }
            }
        }
        let at = index
        group.notify(queue: .main) { model.insert(urls.compactMap { $0 }, at: at) }
        return true
    }
}

/// 편집기 창. 여러 개 열 수 있다.
@MainActor
final class PageOrganizer: NSObject, NSWindowDelegate {
    private static var open: Set<PageOrganizer> = []
    private let window: NSWindow
    private let model = OrganizerModel()

    static func show(_ files: [URL] = []) {
        let o = PageOrganizer()
        open.insert(o)
        if !files.isEmpty { o.model.insert(files) }
        o.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "PDF 쪽 편집"
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        window.contentView = NSHostingView(rootView: OrganizerView(model: model, window: window))
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        MainActor.assumeIsolated {
            guard model.dirty, !model.pages.isEmpty else { return true }
            let a = NSAlert()
            a.messageText = "저장하지 않고 닫을까요?"
            a.informativeText = "바꾼 순서는 저장해야 남아요. 원본 파일은 그대로예요."
            a.addButton(withTitle: "닫기")
            a.addButton(withTitle: "취소")
            return a.runModal() == .alertFirstButtonReturn
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { _ = Self.open.remove(self) }
    }
}
