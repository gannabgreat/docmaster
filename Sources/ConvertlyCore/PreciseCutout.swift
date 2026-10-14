import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 정밀 배경 제거: BiRefNet(rembg, MIT) 를 앱 밖 전용 파이썬 환경에서 돌린다.
/// 기본으로는 안 깔려 있다(약 1.5GB). 사용자가 「정밀 모드」를 켤 때 안내 후 `install` 로 받는다
/// → ~/Library/Application Support/Convertly/bgremove. 앱 안 Resources/bgremove/install.sh 가 실제 설치를 한다.
/// Vision 보다 머리카락·가는 테두리·물건 경계가 깔끔하고, 한 장에 10~20초 걸린다(CPU).
public enum PreciseCutout {
    public static var home: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Convertly/bgremove", isDirectory: true)
    }
    static var python: URL { home.appendingPathComponent("venv/bin/python") }
    static var script: URL { home.appendingPathComponent("bgremove.py") }

    public static var isInstalled: Bool {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: python.path), fm.fileExists(atPath: script.path),
              let e = fm.enumerator(at: home.appendingPathComponent("models"), includingPropertiesForKeys: nil) else { return false }
        return e.contains { ($0 as? URL)?.lastPathComponent == "birefnet-general.onnx" }
    }

    public static let modelBytes: Int64 = 972_666_916
    public static let approxSize = "약 1.5GB"
    static var modelFile: URL { home.appendingPathComponent("models/birefnet-general/birefnet-general.onnx") }

    /// 설치. 막히는(blocking) 함수 — 백그라운드에서 부른다. progress(단계 설명, 0~1 또는 nil).
    public static func install(progress: @escaping (String, Double?) -> Void) throws {
        guard let script = Bundle.main.url(forResource: "install", withExtension: "sh", subdirectory: "bgremove") else {
            throw ConvertError.notApplicable("설치 파일이 앱 안에 없어요 (Convertly 를 다시 설치해 주세요)")
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = [script.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let lock = NSLock()
        var step = "python", errText = ""
        out.fileHandleForReading.readabilityHandler = { h in
            let text = String(data: h.availableData, encoding: .utf8) ?? ""
            for line in text.split(separator: "\n") where line.hasPrefix("STEP ") {
                lock.lock(); step = String(line.dropFirst(5)); lock.unlock()
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let text = String(data: h.availableData, encoding: .utf8) ?? ""
            lock.lock(); errText = String((errText + text).suffix(2000)); lock.unlock()
        }
        try p.run()
        let part = modelFile.appendingPathExtension("part")
        while p.isRunning {
            lock.lock(); let s = step; lock.unlock()
            switch s {
            case "python": progress("파이썬 준비 중…", nil)
            case "packages": progress("엔진 프로그램 받는 중… (약 450MB)", nil)
            case "model":
                let got = (try? FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64) ?? 0
                progress("모델 받는 중… \(got / 1_000_000) / \(modelBytes / 1_000_000) MB", Double(got) / Double(modelBytes))
            default: progress("마무리 중…", 1)
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        guard p.terminationStatus == 0, isInstalled else {
            lock.lock(); let e = errText.split(separator: "\n").last.map(String.init) ?? ""; lock.unlock()
            throw ConvertError.notApplicable("정밀 엔진 설치 실패\(e.isEmpty ? "" : ": " + e) — 인터넷 연결을 확인하고 다시 시도해 주세요")
        }
    }

    /// 엔진을 지워 공간을 돌려받는다.
    public static func uninstall() throws {
        if FileManager.default.fileExists(atPath: home.path) { try FileManager.default.removeItem(at: home) }
    }

    static func remove(_ image: CGImage, crop: Bool, name: String) throws -> CGImage {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("convertly-cut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let input = tmp.appendingPathComponent("in.png"), output = tmp.appendingPathComponent("out.png")
        guard let dest = CGImageDestinationCreateWithURL(input as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ConvertError.writeFailed(name)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ConvertError.writeFailed(name) }

        let p = Process()
        p.executableURL = python
        p.arguments = [script.path, input.path, output.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let src = CGImageSourceCreateWithURL(output as CFURL, nil),
              let lazy = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              let cut = decoded(lazy) else {
            let msg = String(data: errData, encoding: .utf8)?.split(separator: "\n").last.map(String.init) ?? ""
            throw ConvertError.unreadable("\(name) — 정밀 배경 제거 실패: \(msg)")
        }
        return crop ? (cropToAlpha(cut) ?? cut) : cut
    }

    /// 임시 파일을 지우기 전에 픽셀을 메모리로 다 읽어 둔다(CGImage 는 파일을 늦게 읽을 수 있다).
    static func decoded(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// 불투명한 부분을 감싸는 사각형으로 자른다.
    static func cropToAlpha(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where px[(y * w + x) * 4 + 3] > 8 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return image.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))
    }
}
