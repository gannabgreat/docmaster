import Foundation
import UniformTypeIdentifiers

/// 사용자가 고르는 출력 형식. `keep` 은 형식은 그대로 두고 용량만 줄인다.
public enum OutputFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case keep, jpeg, png, heic, tiff, pdf, docx, cutout

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .keep: return "원본 형식 유지 (용량만 줄이기)"
        case .jpeg: return "JPG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .tiff: return "TIFF"
        case .pdf: return "PDF"
        case .docx: return "Word (docx) — 한글 문서만"
        case .cutout: return "배경 제거 (투명 PNG) — 사진만"
        }
    }

    public var fileExtension: String {
        switch self {
        case .keep: return ""
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .tiff: return "tiff"
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .cutout: return "png"
        }
    }

    public var utType: UTType {
        switch self {
        case .keep: return .data
        case .jpeg: return .jpeg
        case .png: return .png
        case .heic: return .heic
        case .tiff: return .tiff
        case .pdf: return .pdf
        case .docx: return .docx
        case .cutout: return .png
        }
    }

    /// 품질 슬라이더가 의미 있는 형식.
    public var isLossy: Bool { self == .jpeg || self == .heic }

    /// `keep` 일 때 입력 파일이 실제로 저장될 형식.
    /// ImageIO 가 쓰지 못하는 형식(webp·avif 등)은 JPG 로, 무손실 계열(gif·bmp)은 PNG 로 보낸다.
    public static func resolvedKeep(for url: URL) -> OutputFormat {
        if DocumentKind.of(url) != nil { return .pdf }   // 문서는 「유지」면 PDF 로
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .jpeg }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .png) { return .png }
        if type.conforms(to: .jpeg) { return .jpeg }
        if type.conforms(to: .heic) || type.conforms(to: .heif) { return .heic }
        if type.conforms(to: .tiff) { return .tiff }
        if type.conforms(to: .gif) || type.conforms(to: .bmp) { return .png }
        return .jpeg
    }
}

public enum PDFPageSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case a4, image
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .a4: return "A4에 맞춤"
        case .image: return "이미지 크기 그대로"
        }
    }
}

/// 발표 자료(pptx 등)를 그릴 엔진.
public enum SlidesEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case builtin, powerPoint
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .builtin: return "자체 처리 (빠름, 다른 앱 없음)"
        case .powerPoint: return "PowerPoint로 정확하게 (차트·글꼴 원본)"
        }
    }
}

public struct ConvertOptions: Codable, Sendable {
    public var format: OutputFormat = .jpeg
    /// 0.0(최대 압축) ~ 1.0(최고 품질). JPG·HEIC·PDF 안 이미지에 쓴다.
    public var quality: Double = 0.8
    /// 긴 변 최대 픽셀. nil 이면 원본 크기.
    public var maxPixel: Int? = nil
    /// EXIF·GPS 등 메타데이터를 지운다.
    public var stripMetadata: Bool = true
    /// 출력이 PDF 이고 파일이 여러 개면 PDF 하나로 합친다.
    public var mergeIntoOnePDF: Bool = true
    public var pdfPageSize: PDFPageSize = .a4
    /// PDF 를 이미지로 바꿀 때 해상도. PDF 압축 때 안 이미지 해상도로도 쓴다.
    public var pdfRenderDPI: Double = 150
    public var slidesEngine: SlidesEngine = .builtin
    /// 배경 제거 결과를 피사체 크기에 맞춰 자른다.
    public var cutoutCrop: Bool = false
    /// 정밀 배경 제거(BiRefNet). 기본 끔 — 켜는 사람만 엔진을 받는다. 엔진이 없으면 맥 기본(Vision).
    public var cutoutPrecise: Bool = false
    /// hwp → docx 에서 한글이 꺾은 줄 위치를 그대로 둔다(모양 그대로). 끄면 Word 가 다시 꺾는다(편집이 편함).
    public var docxKeepLineBreaks: Bool = true

    public init() {}

    /// 예전 버전이 저장한 옵션(새 칸 없음)도 읽히게 칸마다 기본값으로 채운다.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ConvertOptions()
        format = (try? c.decode(OutputFormat.self, forKey: .format)) ?? d.format
        quality = (try? c.decode(Double.self, forKey: .quality)) ?? d.quality
        maxPixel = try? c.decodeIfPresent(Int.self, forKey: .maxPixel)
        stripMetadata = (try? c.decode(Bool.self, forKey: .stripMetadata)) ?? d.stripMetadata
        mergeIntoOnePDF = (try? c.decode(Bool.self, forKey: .mergeIntoOnePDF)) ?? d.mergeIntoOnePDF
        pdfPageSize = (try? c.decode(PDFPageSize.self, forKey: .pdfPageSize)) ?? d.pdfPageSize
        pdfRenderDPI = (try? c.decode(Double.self, forKey: .pdfRenderDPI)) ?? d.pdfRenderDPI
        slidesEngine = (try? c.decode(SlidesEngine.self, forKey: .slidesEngine)) ?? d.slidesEngine
        cutoutCrop = (try? c.decode(Bool.self, forKey: .cutoutCrop)) ?? d.cutoutCrop
        cutoutPrecise = (try? c.decode(Bool.self, forKey: .cutoutPrecise)) ?? d.cutoutPrecise
        docxKeepLineBreaks = (try? c.decode(Bool.self, forKey: .docxKeepLineBreaks)) ?? d.docxKeepLineBreaks
    }
}

public enum ConvertError: LocalizedError {
    case unsupported(String)
    case unreadable(String)
    case locked(String)
    case writeFailed(String)
    case notApplicable(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let n): return "지원하지 않는 파일: \(n)"
        case .unreadable(let n): return "파일을 읽지 못함: \(n)"
        case .locked(let n): return "암호가 걸린 PDF: \(n)"
        case .writeFailed(let n): return "저장 실패: \(n)"
        case .notApplicable(let n): return n
        }
    }
}
