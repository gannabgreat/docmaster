import AppKit
import ConvertlyCore
import Foundation

struct FileItem: Identifiable {
    enum Status {
        case waiting
        case running
        case done(ConvertResult)
        case failed(String)
    }

    let id = UUID()
    let url: URL
    let bytes: Int64
    var status: Status = .waiting
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var options: ConvertOptions {
        didSet { try? UserDefaults.standard.set(JSONEncoder().encode(options), forKey: Self.optionsKey) }
    }
    @Published var isRunning = false
    @Published var skipped: [String] = []

    private static let optionsKey = "options"

    /// 마지막에 고른 옵션을 다시 쓴다. 못 읽으면 기본값.
    init() {
        let saved = UserDefaults.standard.data(forKey: Self.optionsKey)
            .flatMap { try? JSONDecoder().decode(ConvertOptions.self, from: $0) }
        options = saved ?? ConvertOptions()
    }

    var canRun: Bool { !items.isEmpty && !isRunning }

    /// 지원 형식만 받고, 이미 있는 파일은 다시 넣지 않는다. 폴더는 한 단계 안의 파일을 꺼낸다.
    func add(_ urls: [URL]) {
        var incoming: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                             options: [.skipsHiddenFiles])) ?? []
                incoming += children.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else {
                incoming.append(url)
            }
        }
        var rejected: [String] = []
        for url in incoming {
            guard Converter.isSupported(url) else { rejected.append(url.lastPathComponent); continue }
            guard !items.contains(where: { $0.url == url }) else { continue }
            items.append(FileItem(url: url, bytes: Converter.fileSize(url)))
        }
        skipped = rejected
    }

    func remove(_ id: FileItem.ID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
    }

    func clear() {
        guard !isRunning else { return }
        items.removeAll()
        skipped = []
    }

    func move(from source: IndexSet, to destination: Int) {
        guard !isRunning else { return }
        items.move(fromOffsets: source, toOffset: destination)
    }

    func run() {
        guard canRun else { return }
        isRunning = true
        for i in items.indices { items[i].status = .waiting }
        let opts = options
        let jobs = Converter.plan(items.map(\.url), opts)

        Task.detached(priority: .userInitiated) {
            for job in jobs {
                await self.set(job.inputs, .running)
                do {
                    let result = try Converter.run(job, opts)
                    await self.set(job.inputs, .done(result))
                } catch {
                    await self.set(job.inputs, .failed(error.localizedDescription))
                }
            }
            await MainActor.run { self.isRunning = false }
        }
    }

    private func set(_ urls: [URL], _ status: FileItem.Status) {
        for i in items.indices where urls.contains(items[i].url) {
            items[i].status = status
        }
    }

    func reveal(_ item: FileItem) {
        if case .done(let r) = item.status, !r.outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(r.outputs)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
    }

    /// 완료된 작업 전체의 전/후 합계. 합친 PDF 는 여러 줄이 같은 결과를 가리키므로 한 번만 센다.
    var totals: (before: Int64, after: Int64, done: Int, failed: Int)? {
        var seen = Set<String>()
        var before: Int64 = 0, after: Int64 = 0, done = 0, failed = 0
        for item in items {
            switch item.status {
            case .done(let r):
                let key = r.outputs.map(\.path).joined(separator: "|")
                if key.isEmpty || seen.insert(key).inserted {
                    before += r.inputBytes
                    after += r.outputs.isEmpty ? r.inputBytes : r.outputBytes
                }
                done += 1
            case .failed: failed += 1
            default: break
            }
        }
        return done + failed == 0 ? nil : (before, after, done, failed)
    }
}
