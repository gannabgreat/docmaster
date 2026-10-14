import AppKit
import Foundation
import ImageIO
import PDFKit
import Quartz
import UniformTypeIdentifiers
import Vision

/// 한 번에 처리할 묶음. 보통 파일 1개 = 작업 1개, PDF 합치기만 여러 파일 = 작업 1개.
public struct Job: Identifiable, Sendable {
    public enum Kind: Sendable {
        case image(OutputFormat)        // 이미지 → 이미지
        case imageToPDF                 // 이미지 1장 → PDF
        case mergePDF                   // 여러 이미지·PDF → PDF 하나
        case compressPDF                // PDF → 더 작은 PDF
        case pdfToImages(OutputFormat)  // PDF → 페이지별 이미지
        case documentToPDF              // hwp·hwpx·docx 등 → PDF
        case documentToImages(OutputFormat) // 문서 → 페이지별 이미지
        case hangulToDocx               // hwp·hwpx → docx
        case reject(String)             // 이 조합은 못 함(이유)
    }

    public let id = UUID()
    public let inputs: [URL]
    public let kind: Kind
}

public struct ConvertResult: Sendable {
    public var outputs: [URL]
    public var inputBytes: Int64
    public var outputBytes: Int64
    /// 결과에 붙일 한 줄 안내(예: 더 줄일 수 없음).
    public var note: String?
    /// 결과는 만들었지만 알아둘 것(예: 빠진 글꼴이 대체됨).
    public var warning: String? = nil
}

public enum Converter {
    public static let suffix = "_변환"

    // MARK: - 입력 판별

    public static func isPDF(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .pdf) ?? false
    }

    public static func isDocument(_ url: URL) -> Bool { DocumentKind.of(url) != nil }

    /// ImageIO 가 읽을 수 있는 이미지, PDF, 문서(hwp·hwpx·docx·doc·rtf·odt)면 받는다.
    public static func isSupported(_ url: URL) -> Bool {
        if isPDF(url) || isDocument(url) { return true }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        let readable = CGImageSourceCopyTypeIdentifiers() as? [String] ?? []
        return readable.contains { id in UTType(id).map { type.conforms(to: $0) } ?? false }
    }

    // MARK: - 계획

    public static func plan(_ urls: [URL], _ o: ConvertOptions) -> [Job] {
        if o.format == .pdf && o.mergeIntoOnePDF && urls.count > 1 {
            return [Job(inputs: urls, kind: .mergePDF)]
        }
        return urls.map { url in
            let target = o.format == .keep ? OutputFormat.resolvedKeep(for: url) : o.format
            if target == .cutout {
                return Job(inputs: [url], kind: isPDF(url) || isDocument(url)
                           ? .reject("배경 제거는 사진(이미지)만 돼요") : .image(.cutout))
            }
            if target == .docx {
                return Job(inputs: [url], kind: DocumentKind.of(url) == .hangul
                           ? .hangulToDocx : .reject("Word(docx)로는 hwp·hwpx 만 바꿀 수 있음"))
            }
            if isDocument(url) {
                return Job(inputs: [url], kind: target == .pdf ? .documentToPDF : .documentToImages(target))
            }
            if isPDF(url) {
                return Job(inputs: [url], kind: target == .pdf ? .compressPDF : .pdfToImages(target))
            }
            return Job(inputs: [url], kind: target == .pdf ? .imageToPDF : .image(target))
        }
    }

    public static func run(_ job: Job, _ o: ConvertOptions) throws -> ConvertResult {
        let before = job.inputs.reduce(Int64(0)) { $0 + fileSize($1) }
        var note: String?
        var outputs: [URL]

        switch job.kind {
        case .image(let fmt):
            outputs = [try convertImage(job.inputs[0], to: fmt, o)]
        case .imageToPDF, .mergePDF:
            outputs = [try makePDF(job.inputs, o)]
        case .pdfToImages(let fmt):
            outputs = try pdfToImages(job.inputs[0], to: fmt, o)
        case .documentToPDF:
            let data = try DocumentEngine.pdfData(job.inputs[0], slides: o.slidesEngine)
            let out = uniqueURL(next: job.inputs[0], ext: "pdf")
            try write(data, to: out)
            outputs = [out]
        case .documentToImages(let fmt):
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("convertly-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try write(try DocumentEngine.pdfData(job.inputs[0], slides: o.slidesEngine), to: tmp)
            outputs = try pdfToImages(tmp, to: fmt, o, nameFrom: job.inputs[0])
        case .hangulToDocx:
            let data = try DocumentEngine.docxData(job.inputs[0], keepLineBreaks: o.docxKeepLineBreaks)
            let out = uniqueURL(next: job.inputs[0], ext: "docx")
            try write(data, to: out)
            outputs = [out]
        case .reject(let why):
            throw ConvertError.notApplicable(why)
        case .compressPDF:
            let out = try compressPDF(job.inputs[0], o)
            if fileSize(out) >= before {
                try? FileManager.default.removeItem(at: out)
                outputs = []
                note = "이미 충분히 작아서 더 줄이지 못함 (새 파일 안 만듦)"
            } else {
                outputs = [out]
            }
        }

        let after = outputs.reduce(Int64(0)) { $0 + fileSize($1) }
        var result = ConvertResult(outputs: outputs, inputBytes: before, outputBytes: after, note: note)
        result.warning = fontWarning(job, o)
        return result
    }

    /// 자체 처리로 그린 pptx·docx 에 이 맥에 없는 글꼴이 있으면 알린다(PowerPoint 엔진은 원본 글꼴로 그림).
    static func fontWarning(_ job: Job, _ o: ConvertOptions) -> String? {
        switch job.kind {
        case .documentToPDF, .documentToImages, .mergePDF: break
        default: return nil
        }
        var missing: [String] = []
        for url in job.inputs {
            let kind = DocumentKind.of(url)
            if kind == .office || (kind == .slides && o.slidesEngine == .builtin) {
                missing += DocumentEngine.missingFonts(url)
            }
        }
        let uniq = Array(NSOrderedSet(array: missing)) as? [String] ?? missing
        guard !uniq.isEmpty else { return nil }
        let list = uniq.prefix(4).joined(separator: ", ") + (uniq.count > 4 ? " 외 \(uniq.count - 4)개" : "")
        return "이 맥에 없는 글꼴 대체됨: \(list)"
    }

    public static func missingFonts(_ url: URL) -> [String] { DocumentEngine.missingFonts(url) }


    // MARK: - 이미지 → 이미지

    static func convertImage(_ url: URL, to fmt: OutputFormat, _ o: ConvertOptions) throws -> URL {
        let (image, props) = try loadImage(url, maxPixel: o.maxPixel)
        let finalImage: CGImage
        switch fmt {
        case .cutout:
            finalImage = o.cutoutPrecise && PreciseCutout.isInstalled
                ? try PreciseCutout.remove(image, crop: o.cutoutCrop, name: url.lastPathComponent)
                : try removeBackground(image, crop: o.cutoutCrop, name: url.lastPathComponent)
        case .jpeg: finalImage = flattened(image)
        case .heic: finalImage = rgb(image)   // HEIC 인코더는 흑백+투명 이미지를 못 받는다
        default: finalImage = image
        }
        let out = uniqueURL(next: url, ext: fmt.fileExtension)
        let metadata = o.stripMetadata ? nil : carriedMetadata(props)
        try writeImage(finalImage, to: out, type: fmt.utType, quality: fmt.isLossy ? o.quality : nil, metadata: metadata)
        return out
    }

    /// 방향(EXIF orientation)을 픽셀에 반영하고, 필요하면 긴 변을 maxPixel 로 줄여서 읽는다.
    static func loadImage(_ url: URL, maxPixel: Int?) throws -> (CGImage, [CFString: Any]?) {
        let name = url.lastPathComponent
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else {
            throw ConvertError.unreadable(name)
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let full = max(w, h)
        guard full > 0 else { throw ConvertError.unreadable(name) }
        let target = min(maxPixel ?? full, full)

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: target,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ConvertError.unreadable(name)
        }
        return (image, props)
    }

    /// 맥 내장 Vision 「피사체 들어올리기」로 배경을 투명하게. 사람·동물·물건을 자동으로 고른다(macOS 14+).
    static func removeBackground(_ image: CGImage, crop: Bool, name: String) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { throw ConvertError.unreadable("\(name) — 배경 제거 실패: \(error.localizedDescription)") }
        guard let obs = request.results?.first, !obs.allInstances.isEmpty else {
            throw ConvertError.notApplicable("사진에서 피사체를 찾지 못했어요 (배경과 구분되는 사람·물건이 있어야 해요)")
        }
        let buffer = try obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: crop)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8,
                                                 colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw ConvertError.writeFailed(name)
        }
        return cg
    }

    /// 투명 영역을 흰색으로 채운다. JPG 는 투명을 못 담아서 그냥 저장하면 검게 나온다.
    static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// RGB 가 아닌 이미지(흑백 등)를 sRGB 로 다시 그린다. 투명은 그대로 둔다.
    static func rgb(_ image: CGImage) -> CGImage {
        guard image.colorSpace?.model != .rgb else { return image }
        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let info = hasAlpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: info.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage() ?? image
    }

    /// 메타데이터를 남길 때 옮길 사전. 방향은 이미 픽셀에 반영했으니 1(정방향)로 고친다.
    static func carriedMetadata(_ props: [CFString: Any]?) -> [CFString: Any]? {
        guard let props else { return nil }
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
            if let v = props[key] { out[key] = v }
        }
        if var tiff = out[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        out[kCGImagePropertyOrientation] = 1
        return out
    }

    static func writeImage(_ image: CGImage, to url: URL, type: UTType, quality: Double?, metadata: [CFString: Any]?) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            try? FileManager.default.removeItem(at: url)
            throw ConvertError.writeFailed(url.lastPathComponent)
        }
        var props = metadata ?? [:]
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            throw ConvertError.writeFailed(url.lastPathComponent)
        }
    }

    // MARK: - 이미지·PDF → PDF

    static func makePDF(_ inputs: [URL], _ o: ConvertOptions) throws -> URL {
        let doc = PDFDocument()
        for url in inputs {
            if isDocument(url) {
                guard let src = PDFDocument(data: try DocumentEngine.pdfData(url)) else { throw ConvertError.unreadable(url.lastPathComponent) }
                for i in 0..<src.pageCount {
                    if let page = src.page(at: i)?.copy() as? PDFPage { doc.insert(page, at: doc.pageCount) }
                }
                continue
            }
            if isPDF(url) {
                guard let src = PDFDocument(url: url) else { throw ConvertError.unreadable(url.lastPathComponent) }
                if src.isLocked { throw ConvertError.locked(url.lastPathComponent) }
                for i in 0..<src.pageCount {
                    if let page = src.page(at: i)?.copy() as? PDFPage { doc.insert(page, at: doc.pageCount) }
                }
                continue
            }
            let (image, _) = try loadImage(url, maxPixel: o.maxPixel)
            let flat = flattened(image)
            let ns = NSImage(cgImage: flat, size: NSSize(width: flat.width, height: flat.height))
            var opts: [PDFPage.ImageInitializationOption: Any] = [.compressionQuality: o.quality]
            if o.pdfPageSize == .a4 {
                let portrait = flat.height >= flat.width
                let box = portrait ? CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
                                   : CGRect(x: 0, y: 0, width: 841.89, height: 595.28)
                opts[.mediaBox] = NSValue(rect: box)
                opts[.upscaleIfSmaller] = true
            }
            guard let page = PDFPage(image: ns, options: opts) else { throw ConvertError.unreadable(url.lastPathComponent) }
            doc.insert(page, at: doc.pageCount)
        }

        let first = inputs[0]
        let out: URL
        if inputs.count > 1 {
            let base = first.deletingPathExtension().lastPathComponent + "_외\(inputs.count - 1)개"
            out = uniqueURL(dir: first.deletingLastPathComponent(), base: base, ext: "pdf")
        } else {
            out = uniqueURL(next: first, ext: "pdf")
        }
        guard doc.write(to: out) else {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError.writeFailed(out.lastPathComponent)
        }
        return out
    }

    // MARK: - 아무 입력이나 PDF 문서로 (쪽 편집기용)

    /// PDF 는 그대로, 이미지·문서는 PDF 로 바꿔서 연다. 쪽 편집기가 끼워넣기에 쓴다.
    public static func loadAsPDF(_ url: URL, _ o: ConvertOptions = ConvertOptions()) throws -> PDFDocument {
        let name = url.lastPathComponent
        if isPDF(url) {
            guard let doc = PDFDocument(url: url) else { throw ConvertError.unreadable(name) }
            if doc.isLocked { throw ConvertError.locked(name) }
            return doc
        }
        if isDocument(url) {
            guard let doc = PDFDocument(data: try DocumentEngine.pdfData(url)) else { throw ConvertError.unreadable(name) }
            return doc
        }
        let (image, _) = try loadImage(url, maxPixel: o.maxPixel)
        let flat = flattened(image)
        let ns = NSImage(cgImage: flat, size: NSSize(width: flat.width, height: flat.height))
        let portrait = flat.height >= flat.width
        let box = portrait ? CGRect(x: 0, y: 0, width: 595.28, height: 841.89) : CGRect(x: 0, y: 0, width: 841.89, height: 595.28)
        guard let page = PDFPage(image: ns, options: [.mediaBox: NSValue(rect: box), .upscaleIfSmaller: true,
                                                      .compressionQuality: o.quality]) else { throw ConvertError.unreadable(name) }
        let doc = PDFDocument()
        doc.insert(page, at: 0)
        return doc
    }

    // MARK: - PDF 압축

    /// 글자는 그대로 두고 안의 이미지만 JPG 로 다시 담고 해상도를 낮춘다.
    /// PDFKit 의 saveImagesAsJPEG·optimizeImagesForScreen 옵션은 실측상 크기가 그대로라
    /// 미리보기 「파일 크기 줄이기」와 같은 Quartz 필터를 품질·해상도만 바꿔 쓴다.
    static func compressPDF(_ url: URL, _ o: ConvertOptions) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw ConvertError.unreadable(url.lastPathComponent) }
        if doc.isLocked { throw ConvertError.locked(url.lastPathComponent) }
        let out = uniqueURL(next: url, ext: "pdf")
        let imageSettings: [String: Any] = [
            "Compression Quality": o.quality,
            "ImageCompression": "ImageJPEGCompress",
            "ImageScaleSettings": [
                "ImageResolution": Int(o.pdfRenderDPI),
                "ImageScaleInterpolate": true,
                // 최대 크기를 안 정했으면 해상도 × 16인치(150dpi → 2400px, 미리보기 기본값과 같음)
                "ImageSizeMax": o.maxPixel ?? Int(o.pdfRenderDPI * 16),
                "ImageSizeMin": 0,
            ],
        ]
        let filter = QuartzFilter(properties: [
            "Domains": ["Applications": true],
            "FilterType": 1,
            "Name": "Convertly",
            "FilterData": ["ColorSettings": ["ImageSettings": imageSettings]],
        ])
        let opts: [PDFDocumentWriteOption: Any] = [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter as Any]
        guard doc.write(to: out, withOptions: opts) else {
            try? FileManager.default.removeItem(at: out)
            throw ConvertError.writeFailed(out.lastPathComponent)
        }
        return out
    }

    // MARK: - PDF → 이미지

    /// `nameFrom` 이 있으면 결과 이름·위치는 그 파일을 따른다(문서를 임시 PDF 로 바꿔 넘길 때).
    static func pdfToImages(_ source: URL, to fmt: OutputFormat, _ o: ConvertOptions, nameFrom: URL? = nil) throws -> [URL] {
        let url = nameFrom ?? source
        let name = url.lastPathComponent
        guard let doc = CGPDFDocument(source as CFURL) else { throw ConvertError.unreadable(name) }
        if doc.isEncrypted && !doc.isUnlocked && !doc.unlockWithPassword("") { throw ConvertError.locked(name) }
        let count = doc.numberOfPages
        guard count > 0 else { throw ConvertError.unreadable(name) }

        let base = url.deletingPathExtension().lastPathComponent
        let dir: URL
        if count == 1 {
            dir = url.deletingLastPathComponent()
        } else {
            dir = uniqueURL(dir: url.deletingLastPathComponent(), base: base + suffix, ext: nil, directory: true)
        }
        let digits = String(count).count
        var outputs: [URL] = []

        for i in 1...count {
            guard let page = doc.page(at: i) else { continue }
            let image = try render(page, dpi: o.pdfRenderDPI, maxPixel: o.maxPixel)
            let out = count == 1
                ? uniqueURL(next: url, ext: fmt.fileExtension)
                : dir.appendingPathComponent(base + "_" + String(format: "%0\(digits)d", i)).appendingPathExtension(fmt.fileExtension)
            try writeImage(image, to: out, type: fmt.utType, quality: fmt.isLossy ? o.quality : nil, metadata: nil)
            outputs.append(out)
        }
        return outputs
    }

    static func render(_ page: CGPDFPage, dpi: Double, maxPixel: Int?) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let size = rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)

        var scale = dpi / 72
        if let maxPixel, max(size.width, size.height) * scale > Double(maxPixel) {
            scale = Double(maxPixel) / max(size.width, size.height)
        }
        let pw = max(1, Int((size.width * scale).rounded()))
        let ph = max(1, Int((size.height * scale).rounded()))

        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConvertError.writeFailed("페이지 렌더링")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(pw) / size.width, y: CGFloat(ph) / size.height)
        // 회전·원점 보정. rect 를 페이지 크기와 같게 줘서 확대·축소는 위의 scaleBy 만 담당한다.
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: box)
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { throw ConvertError.writeFailed("페이지 렌더링") }
        return image
    }

    // MARK: - 파일 이름·크기

    /// uniqueURL 이 미리 만들어 둔 빈 파일 자리에 쓴다. 실패하면 빈 파일을 지운다.
    static func write(_ data: Data, to url: URL) throws {
        do { try data.write(to: url) } catch {
            try? FileManager.default.removeItem(at: url)
            throw ConvertError.writeFailed(url.lastPathComponent)
        }
    }

    /// 원본 옆에 `이름_변환.ext`. 이미 있으면 `이름_변환 2.ext`, `이름_변환 3.ext` …
    static func uniqueURL(next input: URL, ext: String) -> URL {
        uniqueURL(dir: input.deletingLastPathComponent(),
                  base: input.deletingPathExtension().lastPathComponent + suffix, ext: ext)
    }

    /// 이름을 고르는 순간 그 자리에 빈 파일(또는 폴더)을 배타적으로 만들어 둔다.
    /// 확인만 하고 나중에 쓰면, 같은 원본을 동시에 두 번 돌릴 때(CLI·Finder 빠른 동작) 서로 덮어쓴다.
    static func uniqueURL(dir: URL, base: String, ext: String?, directory: Bool = false) -> URL {
        var n = 1
        while true {
            var candidate = dir.appendingPathComponent(n == 1 ? base : "\(base) \(n)")
            if let ext { candidate.appendPathExtension(ext) }
            let created: Bool
            if directory {
                created = mkdir(candidate.path, 0o755) == 0
            } else {
                let fd = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
                if fd >= 0 { close(fd) }
                created = fd >= 0
            }
            // 이미 있으면 다음 번호. 권한 같은 다른 오류는 쓰기 단계에서 「저장 실패」로 드러난다.
            if created || errno != EEXIST { return candidate }
            n += 1
        }
    }

    public static func fileSize(_ url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    public static func formatBytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
