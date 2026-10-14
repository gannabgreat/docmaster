import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // `Convertly 파일…` 처럼 실행 인자로 받은 파일도 목록에 넣는다.
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        let urls = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        Task { @MainActor in
            if !urls.isEmpty { model.add(urls) }
            DebugHooks.start(model: model)
        }
    }

    // `open -a Convertly 파일` · Dock 아이콘에 끌어놓기
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in model.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct ConvertlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Convertly", id: "main") {
            ContentView()
                .environmentObject(delegate.model)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("PDF 편집") {
                Button("빈 파일로 열기") { PageOrganizer.show() }.keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandMenu("도구") {
                Button("HWP 편집기") { HWPEditor.show() }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button("QR 만들기") { QRWindow.show() }.keyboardShortcut("q", modifiers: [.command, .shift])
            }
        }
    }
}
