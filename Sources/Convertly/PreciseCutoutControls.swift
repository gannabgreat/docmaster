import ConvertlyCore
import SwiftUI

/// 「정밀 모드」 켜기. 엔진(약 1.5GB)이 없으면 켤 때 안내하고, 동의하면 그 자리에서 받는다.
@MainActor
final class PreciseInstaller: ObservableObject {
    static let shared = PreciseInstaller()
    @Published var installed = PreciseCutout.isInstalled
    @Published var running = false
    @Published var status = ""
    @Published var fraction: Double?
    @Published var error: String?

    func install(then done: @escaping () -> Void) {
        guard !running else { return }
        running = true; error = nil; status = "준비 중…"; fraction = nil
        Task.detached {
            do {
                try PreciseCutout.install { s, f in
                    Task { @MainActor in self.status = s; self.fraction = f }
                }
                await MainActor.run { self.running = false; self.installed = true; done() }
            } catch {
                await MainActor.run { self.running = false; self.installed = PreciseCutout.isInstalled; self.error = error.localizedDescription }
            }
        }
    }

    func uninstall() {
        do { try PreciseCutout.uninstall() } catch { self.error = error.localizedDescription }
        installed = PreciseCutout.isInstalled
    }
}

struct PreciseCutoutControls: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var inst = PreciseInstaller.shared
    @State private var askInstall = false
    @State private var askRemove = false

    var body: some View {
        Toggle("정밀 모드 (머리카락·경계가 깔끔 · 한 장 10~20초)", isOn: Binding(
            get: { model.options.cutoutPrecise && inst.installed },
            set: { on in
                if on && !inst.installed { askInstall = true } else { model.options.cutoutPrecise = on }
            }))
            .disabled(inst.running)
            .alert("정밀 모드 엔진을 받을까요?", isPresented: $askInstall) {
                Button("받기 (\(PreciseCutout.approxSize))") { inst.install { model.options.cutoutPrecise = true } }
                Button("취소", role: .cancel) {}
            } message: {
                Text("AI 누끼 모델(BiRefNet)을 이 맥에 내려받아요. 인터넷으로 \(PreciseCutout.approxSize), 몇 분 걸려요. 받은 뒤엔 인터넷 없이 써요. 나중에 「정밀 엔진 지우기」로 지울 수 있어요.")
            }
            .alert("정밀 엔진을 지울까요?", isPresented: $askRemove) {
                Button("지우기", role: .destructive) { inst.uninstall(); model.options.cutoutPrecise = false }
                Button("취소", role: .cancel) {}
            } message: {
                Text("\(PreciseCutout.approxSize)를 확보해요. 다시 켜면 또 받아요.")
            }
        if inst.running {
            VStack(alignment: .leading, spacing: 4) {
                if let f = inst.fraction { ProgressView(value: f) } else { ProgressView().controlSize(.small) }
                Text(inst.status).font(.caption).foregroundStyle(.secondary)
            }
        } else if let e = inst.error {
            Text(e).font(.caption).foregroundStyle(.red)
        } else if inst.installed {
            Button("정밀 엔진 지우기 (\(PreciseCutout.approxSize) 확보)") { askRemove = true }
                .buttonStyle(.link).font(.caption)
        } else {
            Text("정밀 모드는 처음 켤 때 추가 파일(\(PreciseCutout.approxSize))을 받아요. 끄면 맥 기본 방식으로 빠르게 해요.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
