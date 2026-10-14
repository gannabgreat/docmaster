import AppKit
import ConvertlyCore
import Foundation

// 창 앱과 같은 엔진을 터미널에서 쓰는 입구. 2차(Finder 우클릭)도 이걸 부른다.
let usage = """
사용법: convertly-cli [옵션] 파일...
  --to keep|jpg|png|heic|tiff|pdf|docx  출력 형식 (기본 jpg, docx 는 hwp·hwpx 만)
  입력: 이미지 · PDF · hwp · hwpx · docx · doc · rtf · odt
  --quality 0.0~1.0                 JPG·HEIC·PDF 품질 (기본 0.8)
  --max 픽셀                        긴 변 최대 크기 (기본 원본)
  --keep-metadata                   EXIF·GPS 남기기 (기본 지움)
  --no-merge                        PDF 로 바꿀 때 파일마다 따로
  --page a4|image                   이미지→PDF 페이지 크기 (기본 a4)
  --dpi 숫자                        PDF→이미지 해상도 (기본 150)
  --powerpoint                      pptx 를 PowerPoint 로 정확하게 (설치돼 있어야 함)
  --reflow                          hwp→docx 에서 줄바꿈을 Word 가 다시 계산 (기본: 원본 줄바꿈 유지)
  --crop                            배경 제거(--to cutout) 결과를 피사체 크기로 자르기
  --precise                         배경 제거를 정밀(BiRefNet)로 — 엔진이 없으면 안내 후 실패
  --install-precise                 정밀 엔진 받기(약 1.5GB)   --uninstall-precise  지우기
"""

var o = ConvertOptions()
var files: [URL] = []
var args = CommandLine.arguments.dropFirst()

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

while let a = args.popFirst() {
    switch a {
    case "--to":
        let v = args.popFirst() ?? ""
        guard let f = OutputFormat(rawValue: v == "jpg" ? "jpeg" : v) else { fail("알 수 없는 형식: \(v) (keep|jpg|png|heic|tiff|pdf|docx|cutout)") }
        o.format = f
    case "--quality":
        guard let v = args.popFirst().flatMap(Double.init), (0...1).contains(v) else { fail("--quality 는 0~1") }
        o.quality = v
    case "--max":
        guard let v = args.popFirst().flatMap(Int.init), v > 0 else { fail("--max 는 양의 정수") }
        o.maxPixel = v
    case "--keep-metadata": o.stripMetadata = false
    case "--no-merge": o.mergeIntoOnePDF = false
    case "--page":
        guard let v = args.popFirst().flatMap(PDFPageSize.init(rawValue:)) else { fail("--page 는 a4|image") }
        o.pdfPageSize = v
    case "--dpi":
        guard let v = args.popFirst().flatMap(Double.init), v > 0 else { fail("--dpi 는 양수") }
        o.pdfRenderDPI = v
    case "--powerpoint": o.slidesEngine = .powerPoint
    case "--reflow": o.docxKeepLineBreaks = false
    case "--crop": o.cutoutCrop = true
    case "--precise":
        guard PreciseCutout.isInstalled else { fail("정밀 엔진이 없어요. 먼저 convertly-cli --install-precise (약 1.5GB)") }
        o.cutoutPrecise = true
    case "--install-precise":
        do {
            var last = ""
            try PreciseCutout.install { s, _ in if s != last { last = s; print(s) } }
            print("✅ 정밀 엔진 설치 끝"); exit(0)
        } catch { fail(error.localizedDescription) }
    case "--uninstall-precise":
        do { try PreciseCutout.uninstall(); print("정밀 엔진 지움"); exit(0) } catch { fail(error.localizedDescription) }
    case "-h", "--help":
        print(usage); exit(0)
    default:
        let url = URL(fileURLWithPath: a)
        guard FileManager.default.fileExists(atPath: url.path) else { fail("파일 없음: \(a)") }
        guard Converter.isSupported(url) else { fail("지원하지 않는 파일: \(a)") }
        files.append(url)
    }
}

if files.isEmpty { fail(usage) }

// hwp·워드 문서는 WebKit·인쇄 엔진을 쓴다. 창 없이도 돌게 앱 객체만 만들어 둔다.
_ = NSApplication.shared

var failed = 0
for job in Converter.plan(files, o) {
    let names = job.inputs.map(\.lastPathComponent).joined(separator: ", ")
    do {
        let r = try Converter.run(job, o)
        let sizes = "\(Converter.formatBytes(r.inputBytes)) → \(Converter.formatBytes(r.outputBytes))"
        if let note = r.note {
            print("OK  \(names): \(note)")
        } else {
            print("OK  \(names) → \(r.outputs.map(\.path).joined(separator: ", ")) (\(sizes))")
        }
        if let w = r.warning { print("    ⚠ \(w)") }
    } catch {
        failed += 1
        print("ERR \(names): \(error.localizedDescription)")
    }
}
exit(failed == 0 ? 0 : 1)
