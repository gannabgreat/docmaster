import CoreText
import Foundation

/// HWPX(OWPML) → docx.
/// hwp 는 rhwp 가 hwpx 로 내보낸 것을, hwpx 는 파일 그대로 읽는다. 예전처럼 rhwp 의 클립보드 HTML 을 거치면
/// 열 너비·행 높이·셀별 테두리·문단 여백·쪽 크기가 빠져서 양식이 무너졌다. 여기서는 한글이 저장한 값(HWPUNIT = 1/7200 인치)을
/// Word 단위로 바로 옮긴다.
/// 담는 것: 쪽 크기·여백·단, 문단(정렬·여백·들여쓰기/내어쓰기·줄간격·탭·쪽 나눔·테두리·배경), 글자(글꼴·크기·장평·자간·굵게·기울임·
/// 밑줄·취소선·색·음영·위/아래첨자), 표(열 너비·행 높이·셀 병합·셀별 테두리·배경·안 여백·세로 정렬·대각선·제목 행·중첩 표),
/// 그림(글자처럼 / 떠 있는 위치), 머리말·꼬리말·쪽 번호, 각주·미주, 문단 번호·글머리표, 글상자(한 칸짜리 표로).
/// 빠지는 것: 도형 모양(선·타원 등), 차트·OLE, 수식(스크립트 글자로 남김), 짝수 쪽 머리말.
enum HwpxDocx {
    /// keepLineBreaks: 한글이 자동으로 꺾은 줄 위치(lineseg)에 Word 줄 나눔을 넣어 원본과 같은 자리에서 줄이 바뀌게 한다.
    /// 모양은 같아지지만 Word 에서 글을 고치면 그 줄 나눔이 남는다. 끄면 Word 가 자기 글꼴 폭으로 다시 꺾는다.
    static func docx(fromHWPX data: Data, keepLineBreaks: Bool = true) throws -> Data {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("convertly-hwpx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("in.hwpx")
        try data.write(to: src)
        let root = dir.appendingPathComponent("x")
        try runTool("/usr/bin/unzip", ["-qq", "-o", src.path, "-d", root.path], what: "hwpx 풀기")
        let parts = try HwpxConverter(root: root, keepLineBreaks: keepLineBreaks).build()
        return try zipParts(parts, in: dir.appendingPathComponent("docx"))
    }

    /// 파일이 zip(hwpx) 인지. 확장자가 hwpx 여도 실제로는 hwp 인 경우가 있어서 내용으로 본다.
    static func isZip(_ data: Data) -> Bool { data.starts(with: [0x50, 0x4B, 0x03, 0x04]) }

    static func runTool(_ path: String, _ args: [String], cwd: URL? = nil, what: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        // unzip 은 경고(1)만 있어도 풀린다
        guard p.terminationStatus == 0 || (path.hasSuffix("unzip") && p.terminationStatus == 1) else {
            throw ConvertError.writeFailed(what)
        }
    }

    static func zipParts(_ parts: [String: Data], in dir: URL) throws -> Data {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (path, data) in parts {
            let url = dir.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let out = dir.deletingLastPathComponent().appendingPathComponent("out.docx")
        let rest = Set(parts.keys.compactMap { $0.split(separator: "/").first.map(String.init) }).subtracting(["[Content_Types].xml"]).sorted()
        try runTool("/usr/bin/zip", ["-X", "-q", "-r", out.path, "[Content_Types].xml"] + rest, cwd: dir, what: "docx 묶기")
        guard let data = try? Data(contentsOf: out) else { throw ConvertError.writeFailed("docx 묶기") }
        return data
    }
}

// MARK: - XML 도우미

private extension XMLElement {
    var tag: String { localName ?? name ?? "" }
    var elems: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }
    func kids(_ n: String) -> [XMLElement] { elems.filter { $0.tag == n } }
    /// 바로 아래 자식. `hp:switch` 는 `hp:case`(HwpUnitChar, 실제 값) 쪽을 먼저 본다 — `hp:default` 는 옛 판용으로 값이 두 배다.
    func kid(_ n: String) -> XMLElement? {
        for e in elems {
            if e.tag == n { return e }
            if e.tag == "switch" {
                for branch in e.kids("case") + e.kids("default") {
                    if let hit = branch.elems.first(where: { $0.tag == n }) { return hit }
                }
            }
        }
        return nil
    }
    func find(_ n: String) -> XMLElement? {
        for e in elems {
            if e.tag == n { return e }
            if let hit = e.find(n) { return hit }
        }
        return nil
    }
    func a(_ n: String) -> String? { attribute(forName: n)?.stringValue }
    /// 정수 속성. rhwp 는 음수 오프셋을 uint32 로 감아 쓰므로(-4406 → 4294962890) 부호를 되돌리고, 범위 밖 값은 버린다.
    func i(_ n: String) -> Int? {
        guard let s = a(n) else { return nil }
        var v = Int(s)
        if v == nil, let d = Double(s), d.isFinite, abs(d) < 1e15 { v = Int(d) }
        guard var x = v else { return nil }
        if x > Int(Int32.max) && x <= Int(UInt32.max) { x -= 1 << 32 }
        return abs(x) <= Int(Int32.max) ? x : nil
    }
}

private enum Block {
    case p(String)
    case t(String)
}

// MARK: - 변환기

private final class HwpxConverter {
    let root: URL
    // header.xml
    var fonts: [String: [String: String]] = [:]       // 언어 → id → 글꼴 이름
    var charPr: [String: XMLElement] = [:]
    var paraPr: [String: XMLElement] = [:]
    var borderFill: [String: XMLElement] = [:]
    var tabPr: [String: XMLElement] = [:]
    var numbering: [String: XMLElement] = [:]
    var bullet: [String: XMLElement] = [:]
    var binHref: [String: String] = [:]               // 그림 id → zip 안 경로
    var sectionFiles: [String] = []

    // 출력
    var parts: [String: Data] = [:]
    var rels: [String: [(id: String, type: String, target: String)]] = [:]   // 파트 → 관계
    var curPart = "word/document.xml"
    var mediaByItem: [String: String] = [:]          // 그림 id → word/media 이름
    var footnotes: [String] = [], endnotes: [String] = []
    var hdrCount = 0, docPrID = 0, relSeq = 10
    var usedFonts = Set<String>()
    var rPrCache: [String: String] = [:]
    var counters: [String: [Int]] = [:]
    var sect = Sect()

    struct Sect {
        var width = 59528, height = 84188
        var left = 8504, right = 8504, top = 5668, bottom = 4252, header = 4252, footer = 4252, gutter = 0
        var cols = 1, colGap = 1134
        var headerRel: String?, footerRel: String?
        var pageStart = 0
        var outline = "1"
        var pageNum: (pos: String, side: String)?
        var startType = "nextPage"
        var hideFirst = false
        /// 쪽 배경 그림(쪽 테두리/배경의 그림 채우기). 한글은 구역 첫 쪽에만 그린다(rhwp task_m100_2102 한컴 실측).
        var background: (item: String, x: Int, y: Int, w: Int, h: Int)?
        /// 쪽 끝 보정. 한글 줄은 [글자][간격] 순이라 쪽 끝 줄의 간격은 쪽 높이에 안 들어가지만, Word 「고정」 줄은 간격까지
        /// 한 줄이라(간격을 글자 위에 둔다) 쪽 끝 줄이 다음 쪽으로 밀린다. 그만큼 아래 여백을 줄인다.
        /// 원본 쪽 나눔을 박는 모드에선 Word 가 먼저 넘기지만 않으면 되니 꼬리말 칸의 빈 곳을 다 쓴다(20pt 까지).
        /// 꼬리말 내용보다 더 줄이면 Word 가 꼬리말에 맞춰 본문을 다시 올리므로 꼬리말 칸 높이 − 꼬리말 내용 높이가 한도다.
        var extra = 0, footerUsed = 0
    }

    let keepLineBreaks: Bool
    init(root: URL, keepLineBreaks: Bool) { self.root = root; self.keepLineBreaks = keepLineBreaks }

    static let W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let nsAll = "xmlns:w=\"\(W)\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:wp=\"http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing\" xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:pic=\"http://schemas.openxmlformats.org/drawingml/2006/picture\" xmlns:m=\"\(HwpEquation.ns)\""
    static let relBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

    /// zip 안 경로를 실제 파일로. `../` 나 심볼릭 링크로 풀린 폴더 밖을 가리키면 nil.
    func safeURL(_ rel: String) -> URL? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let url = root.appendingPathComponent(rel).resolvingSymlinksInPath().standardizedFileURL
        return url.path.hasPrefix(base + "/") ? url : nil
    }

    func load(_ rel: String) throws -> XMLElement {
        guard let url = safeURL(rel), var data = try? Data(contentsOf: url) else { throw ConvertError.unreadable("hwpx: \(rel) 없음") }
        if rel.contains("section") { data = Self.protectSpaces(data) }
        let doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace])
        guard let r = doc.rootElement() else { throw ConvertError.unreadable("hwpx: \(rel)") }
        return r
    }

    /// Foundation 의 XMLDocument 는 `.nodePreserveWhitespace` 를 줘도 공백만 있는 글자 마디(`<hp:t> </hp:t>`)를 버린다.
    /// 한글은 글자 모양이 바뀔 때마다 마디를 나눠서 낱 공백이 흔하고, 버리면 「○ (총 괄) 전년」이 「○(총 괄)전년」이 된다.
    /// 그래서 읽기 전에 `<…:t>` 안 공백을 대신 글자로 바꿔 두고, 글자를 쓸 때(`esc`)·잴 때(`plain`) 공백으로 되돌린다.
    static let spaceMark: Character = "\u{E8E8}"

    static func protectSpaces(_ data: Data) -> Data {
        let mark = Array(String(spaceMark).utf8)
        var out: [UInt8] = []
        out.reserveCapacity(data.count + data.count / 8)
        let bytes = [UInt8](data)
        var i = 0, inT = false, inTag = false
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "<") {
                inTag = true
                // <xx:t> 또는 <xx:t …> 시작, </xx:t> 끝
                var j = i + 1
                let closing = j < bytes.count && bytes[j] == UInt8(ascii: "/")
                if closing { j += 1 }
                while j < bytes.count && bytes[j] != UInt8(ascii: ":") && bytes[j] != UInt8(ascii: ">") && bytes[j] != UInt8(ascii: " ") { j += 1 }
                if j + 1 < bytes.count && bytes[j] == UInt8(ascii: ":") && bytes[j + 1] == UInt8(ascii: "t") {
                    let k = j + 2
                    if k < bytes.count && (bytes[k] == UInt8(ascii: ">") || bytes[k] == UInt8(ascii: " ") || bytes[k] == UInt8(ascii: "/")) {
                        // <xx:t/> 는 빈 마디라 상태를 바꾸지 않는다
                        let selfClosing = bytes[k] == UInt8(ascii: "/") || (bytes[k] == UInt8(ascii: " ") && {
                            var m = k; while m < bytes.count && bytes[m] != UInt8(ascii: ">") { m += 1 }
                            return m > 0 && bytes[m - 1] == UInt8(ascii: "/")
                        }())
                        if !selfClosing { inT = !closing }
                    }
                }
            } else if b == UInt8(ascii: ">") {
                inTag = false
            } else if inT && !inTag && b == UInt8(ascii: " ") {
                out += mark
                i += 1
                continue
            }
            out.append(b)
            i += 1
        }
        return Data(out)
    }

    /// 마디 글자(대신 글자를 공백으로 되돌린 것)
    func plain(_ s: String) -> String { s.contains(Self.spaceMark) ? s.replacingOccurrences(of: String(Self.spaceMark), with: " ") : s }

    // MARK: 읽기

    func readManifest() {
        var spine: [String] = []
        if let opf = try? load("Contents/content.hpf") {
            var hrefByID: [String: String] = [:]
            if let manifest = opf.find("manifest") {
                for item in manifest.kids("item") {
                    guard let id = item.a("id"), let href = item.a("href") else { continue }
                    hrefByID[id] = href
                    if href.hasPrefix("BinData/") { binHref[id] = href }
                }
            }
            if let sp = opf.find("spine") {
                spine = sp.kids("itemref").compactMap { $0.a("idref").flatMap { hrefByID[$0] } }.filter { $0.contains("section") }
            }
            if spine.isEmpty { spine = hrefByID.values.filter { $0.hasPrefix("Contents/section") }.sorted(by: Self.bySectionNumber) }
        }
        if spine.isEmpty {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Contents").path)) ?? []
            spine = names.filter { $0.hasPrefix("section") && $0.hasSuffix(".xml") }.map { "Contents/" + $0 }.sorted(by: Self.bySectionNumber)
        }
        sectionFiles = spine
        // manifest 에 없는 그림도 BinData/<id>.* 로 찾는다
        let bins = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("BinData").path)) ?? []
        for f in bins {
            let id = (f as NSString).deletingPathExtension
            if binHref[id] == nil { binHref[id] = "BinData/" + f }
        }
    }

    static func bySectionNumber(_ a: String, _ b: String) -> Bool {
        let n = { (s: String) in Int(s.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 0 }
        return n(a) < n(b)
    }

    func readHeader() throws {
        let h = try load("Contents/header.xml")
        func walk(_ e: XMLElement) {
            for c in e.elems {
                let id = c.a("id") ?? ""
                switch c.tag {
                case "fontface":
                    let lang = c.a("lang") ?? ""
                    var m: [String: String] = [:]
                    for f in c.kids("font") { if let fid = f.a("id"), let face = f.a("face") { m[fid] = face } }
                    fonts[lang] = m
                case "charPr": charPr[id] = c
                case "paraPr": paraPr[id] = c
                case "borderFill": borderFill[id] = c
                case "tabPr": tabPr[id] = c
                case "numbering": numbering[id] = c
                case "bullet": bullet[id] = c
                default: walk(c)
                }
            }
        }
        walk(h)
    }

    // MARK: 짓기

    func build() throws -> [String: Data] {
        readManifest()
        try readHeader()
        guard !sectionFiles.isEmpty else { throw ConvertError.unreadable("hwpx: 본문(section) 없음") }

        var body = ""
        for (si, file) in sectionFiles.enumerated() {
            let sec = try load(file)
            sect = Sect()   // 머리말·꼬리말은 Word 도 앞 구역 것을 이어 쓴다
            var spacingCount: [Int: Int] = [:]
            for p in sec.kids("p") {
                for seg in p.kid("linesegarray")?.kids("lineseg") ?? [] {
                    if let sp = seg.i("spacing"), sp > 0, (seg.i("vertsize") ?? 0) <= 3000 { spacingCount[sp, default: 0] += 1 }
                }
            }
            let extra = keepLineBreaks ? 2000 : spacingCount.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? 0
            var blocks: [Block] = []
            // 쪽 추적: 한글 줄 정보(lineseg)의 세로 위치는 쪽마다 0 부터 다시 시작한다.
            var page = 0, pageStartBlock = 0
            var lastBreak = -1   // 마지막으로 구역을 끊은 블록 위치
            var prevBottom: Int?
            // 글자처럼 붙인 표 뒤 간격. 한글은 표 문단의 줄 정보(lineseg)에 표 높이·바깥 여백·줄간격이 다 들어 있는데,
            // Word 의 표에는 문단이 없어서 그 간격이 사라진다. 다음 문단의 세로 위치에서 거꾸로 구해 얇은 문단으로 채운다.
            // 줄간격이 음수면 다음 빈 문단들이 표 위에 겹쳐 그려진다(한글에선 안 보인다). 그런 빈 문단은 뺀다.
            var tableLine: (end: Int, visible: Int)?
            for (pi, p) in sec.kids("p").enumerated() {
                let segs = p.kid("linesegarray")?.kids("lineseg") ?? []
                var forceBreak = false
                if pi > 0, (p.a("pageBreak") == "1") || (segs.first?.i("vertpos")).map({ $0 < (prevBottom ?? 0) }) == true {
                    page += 1
                    pageStartBlock = blocks.count
                    tableLine = nil
                    // 줄바꿈 원본대로: 한글이 쪽을 넘긴 문단에서 Word 도 넘긴다(앞쪽 높이가 조금씩 달라도 쪽이 밀려 쌓이지 않게)
                    forceBreak = keepLineBreaks && p.a("pageBreak") != "1" && p.a("columnBreak") != "1" && sect.cols == 1
                }
                if let tl = tableLine, let top = segs.first?.i("vertpos") {
                    let empty = p.kids("run").allSatisfy { r in r.elems.allSatisfy { $0.tag == "t" && plain($0.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty } }
                    if empty && segs.count == 1 && top + (segs[0].i("vertsize") ?? 0) <= tl.end {
                        prevBottom = top
                        continue
                    }
                    let before = paraPr[p.a("paraPrIDRef") ?? "0"]?.kid("margin")?.kid("prev")?.i("value") ?? 0
                    let gap = top - tl.visible - max(0, before)
                    if gap >= 50 {
                        blocks.append(.p("<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"\(max(20, tw(gap)))\" w:lineRule=\"exact\"/><w:rPr><w:sz w:val=\"2\"/></w:rPr></w:pPr></w:p>"))
                    }
                    tableLine = nil
                }
                if let last = segs.last?.i("vertpos") { prevBottom = last }
                // 구역 정의는 첫 문단에 있다
                if let sp = p.kids("run").lazy.compactMap({ $0.kid("secPr") }).first { readSecPr(sp); sect.extra = extra }
                // 머리말·꼬리말은 한글에선 그 컨트롤이 있는 쪽부터 바뀐다. Word 는 구역 단위라, 첫 쪽이면 구역 전체에 주고
                // 뒤쪽이면 그 쪽 첫 문단 앞에서 이어지는 구역으로 끊는다(이 쪽에서 이미 끊었으면 그 구역에 준다).
                // 「감추기」(그 쪽만 머리말 숨김)는 새 구역의 첫 쪽 머리말을 비운다.
                let hides = p.find("pageHiding").map { $0.a("hideHeader") == "1" || $0.a("hideFooter") == "1" } ?? false
                if p.find("header") != nil || p.find("footer") != nil {
                    if page > 0 && pageStartBlock > 0 && lastBreak < pageStartBlock {
                        blocks.insert(.p(sectionBreakParagraph()), at: pageStartBlock)
                        lastBreak = pageStartBlock
                    }
                    if hides { sect.hideFirst = true }
                } else if hides && page == 0 {
                    sect.hideFirst = true
                }
                // 단 정의: 구역 처음이면 그대로, 중간에 바뀌면 거기서 이어지는 구역으로 끊는다
                if let col = p.kids("run").lazy.flatMap({ $0.kids("ctrl") }).compactMap({ $0.kid("colPr") }).first {
                    let n = max(1, min(20, col.i("colCount") ?? 1)), gap = col.i("sameGap") ?? sect.colGap
                    if pi > 0 && !blocks.isEmpty && n != sect.cols {
                        blocks.append(.p(sectionBreakParagraph()))
                        lastBreak = blocks.count - 1
                    }
                    sect.cols = n
                    sect.colGap = gap
                }
                let firstBlock = blocks.count
                paragraph(p, into: &blocks)
                if forceBreak && firstBlock < blocks.count {
                    if case .p(let x) = blocks[firstBlock], let r = x.range(of: "<w:pPr>"), !x.contains("<w:pageBreakBefore/>") {
                        // pPr 순서: keepNext, keepLines 다음이 pageBreakBefore
                        var at = r.upperBound
                        for k in ["<w:keepNext/>", "<w:keepLines/>"] where x[at...].hasPrefix(k) { at = x.index(at, offsetBy: k.count) }
                        var y = x
                        y.insert(contentsOf: "<w:pageBreakBefore/>", at: at)
                        blocks[firstBlock] = .p(y)
                    } else if case .t = blocks[firstBlock] {
                        blocks.insert(.p("<w:p><w:pPr><w:pageBreakBefore/><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/><w:rPr><w:sz w:val=\"2\"/></w:rPr></w:pPr></w:p>"), at: firstBlock)
                    }
                }
                // 글자처럼 붙인 표 하나만 든 문단이면 그 줄의 끝(겹침 판정)과 표가 보이는 끝(간격 계산)을 기억한다
                let objs = p.kids("run").flatMap { $0.elems }.filter { !["t", "secPr", "ctrl"].contains($0.tag) }
                if objs.count == 1, let tb = objs.first, tb.tag == "tbl", tb.kid("pos")?.a("treatAsChar") == "1",
                   let seg = segs.last, let vp = seg.i("vertpos"), let vs = seg.i("vertsize") {
                    tableLine = (vp + vs, vp + vs - max(0, tb.kid("outMargin")?.i("bottom") ?? 0))
                }
            }
            if let bg = sect.background, let run = backgroundRun(bg) {
                // 구역 첫 문단에 쪽 기준·글 뒤 그림으로 붙인다(첫 쪽에만 보인다). 첫 덩어리가 표면 얇은 문단을 하나 앞에 둔다.
                if case .p(let first) = blocks.first, let r = first.range(of: "</w:pPr>") ?? (first.hasPrefix("<w:p>") ? first.range(of: "<w:p>") : nil) {
                    blocks[0] = .p(first.replacingCharacters(in: r, with: first[r] + run))
                } else {
                    blocks.insert(.p("<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/><w:rPr><w:sz w:val=\"2\"/></w:rPr></w:pPr>\(run)</w:p>"), at: 0)
                }
                sect.background = nil
            }
            if si < sectionFiles.count - 1 {
                body += join(blocks, trailing: false) + sectionBreakParagraph()
            } else {
                // 문서 끝 빈 문단들: 한글에선 쪽 안에 들어가도 Word 에서 조금이라도 넘치면 빈 쪽이 생긴다. 끝에 하나(Word 필수)만 남긴다.
                while case .p(let x)? = blocks.last, blocks.count > 1, !x.contains("<w:r>"), !x.contains("<w:r "), !x.contains("<w:sectPr") { blocks.removeLast() }
                body += join(blocks, trailing: true) + sectPr()
            }
        }

        parts["word/document.xml"] = xml("<w:document \(Self.nsAll)><w:body>\(body)</w:body></w:document>")
        parts["word/styles.xml"] = xml(stylesXML())
        parts["word/settings.xml"] = xml(settingsXML())
        parts["word/fontTable.xml"] = xml(fontTableXML())
        addRel("word/document.xml", "styles", "styles.xml")
        addRel("word/document.xml", "settings", "settings.xml")
        addRel("word/document.xml", "fontTable", "fontTable.xml")
        if !footnotes.isEmpty {
            let sep = "<w:footnote w:type=\"separator\" w:id=\"-1\"><w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:type=\"continuationSeparator\" w:id=\"0\"><w:p><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>"
            parts["word/footnotes.xml"] = xml("<w:footnotes \(Self.nsAll)>\(sep)\(footnotes.joined())</w:footnotes>")
            addRel("word/document.xml", "footnotes", "footnotes.xml")
        }
        if !endnotes.isEmpty {
            let sep = "<w:endnote w:type=\"separator\" w:id=\"-1\"><w:p><w:r><w:separator/></w:r></w:p></w:endnote><w:endnote w:type=\"continuationSeparator\" w:id=\"0\"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:endnote>"
            parts["word/endnotes.xml"] = xml("<w:endnotes \(Self.nsAll)>\(sep)\(endnotes.joined())</w:endnotes>")
            addRel("word/document.xml", "endnotes", "endnotes.xml")
        }
        for (part, list) in rels {
            let dir = (part as NSString).deletingLastPathComponent, name = (part as NSString).lastPathComponent
            var s = "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            for r in list { s += "<Relationship Id=\"\(r.id)\" Type=\"\(Self.relBase)\(r.type)\" Target=\"\(esc(r.target))\"/>" }
            parts["\(dir)/_rels/\(name).rels"] = xml(s + "</Relationships>")
        }
        parts["_rels/.rels"] = xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"\(Self.relBase)officeDocument\" Target=\"word/document.xml\"/></Relationships>")
        parts["[Content_Types].xml"] = xml(contentTypes())
        // 깨진 XML 이 하나라도 있으면 Word 는 파일을 아예 못 연다. 여기서 걸러 예전 경로로 넘긴다.
        for (path, data) in parts where path.hasSuffix(".xml") || path.hasSuffix(".rels") {
            do { _ = try XMLDocument(data: data) } catch { throw ConvertError.writeFailed("docx XML 검사(\(path))") }
        }
        return parts
    }

    func xml(_ s: String) -> Data { Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" + s).utf8) }

    @discardableResult
    func addRel(_ part: String, _ type: String, _ target: String) -> String {
        if let hit = rels[part]?.first(where: { $0.type == type && $0.target == target }) { return hit.id }
        relSeq += 1
        let id = "rId\(relSeq)"
        rels[part, default: []].append((id, type, target))
        return id
    }

    // MARK: 구역

    func readSecPr(_ sp: XMLElement) {
        if let o = sp.a("outlineShapeIDRef") { sect.outline = o }
        if let pp = sp.kid("pagePr") {
            var w = pp.i("width") ?? sect.width, h = pp.i("height") ?? sect.height
            // NARROWLY = 가로 방향. 값이 세로로 적혀 있으면 돌린다.
            if pp.a("landscape") == "NARROWLY" && w < h { swap(&w, &h) }
            sect.width = w; sect.height = h
            if let m = pp.kid("margin") {
                sect.left = m.i("left") ?? sect.left; sect.right = m.i("right") ?? sect.right
                sect.top = m.i("top") ?? sect.top; sect.bottom = m.i("bottom") ?? sect.bottom
                sect.header = m.i("header") ?? sect.header; sect.footer = m.i("footer") ?? sect.footer
                sect.gutter = m.i("gutter") ?? 0
            }
        }
        if let sn = sp.kid("startNum"), let pg = sn.i("page"), pg > 0 { sect.pageStart = pg }
        sect.background = nil
        if let pbf = sp.kids("pageBorderFill").first(where: { ($0.a("type") ?? "BOTH") == "BOTH" }),
           let bf = borderFill[pbf.a("borderFillIDRef") ?? ""], let item = bf.find("imgBrush")?.find("img")?.a("binaryItemIDRef") {
            let o = pbf.kid("offset")
            let ol = o?.i("left") ?? 0, orr = o?.i("right") ?? 0, ot = o?.i("top") ?? 0, ob = o?.i("bottom") ?? 0
            switch pbf.a("fillArea") ?? "PAPER" {
            case "PAGE": sect.background = (item, sect.left, sect.top, sect.width - sect.left - sect.right, sect.height - sect.top - sect.bottom)
            case "BORDER": sect.background = (item, ol, ot, sect.width - ol - orr, sect.height - ot - ob)
            default: sect.background = (item, 0, 0, sect.width, sect.height)
            }
        }
        sect.colGap = sp.i("spaceColumns") ?? sect.colGap
    }

    /// 한글은 「위쪽 여백」 다음에 「머리말」 칸이 있고 그 아래서 본문이 시작한다. Word 는 본문까지의 거리가 top, 머리말 위치가 header.
    func sectPr() -> String {
        finishPageNumber()
        var s = "<w:sectPr>"
        if let h = sect.headerRel { s += "<w:headerReference w:type=\"default\" r:id=\"\(h)\"/>" }
        if sect.hideFirst { s += "<w:headerReference w:type=\"first\" r:id=\"\(emptyPart("header"))\"/>" }
        if let f = sect.footerRel { s += "<w:footerReference w:type=\"default\" r:id=\"\(f)\"/>" }
        if sect.hideFirst { s += "<w:footerReference w:type=\"first\" r:id=\"\(emptyPart("footer"))\"/>" }
        s += "<w:type w:val=\"\(sect.startType)\"/>"
        let w = tw(sect.width), h = tw(sect.height)
        s += "<w:pgSz w:w=\"\(w)\" w:h=\"\(h)\"\(w > h ? " w:orient=\"landscape\"" : "")/>"
        s += "<w:pgMar w:top=\"\(tw(sect.top + sect.header))\" w:right=\"\(tw(sect.right))\" w:bottom=\"\(tw(sect.bottom + sect.footer - min(sect.extra, max(0, sect.footer - sect.footerUsed))))\" w:left=\"\(tw(sect.left))\" w:header=\"\(tw(sect.top))\" w:footer=\"\(tw(sect.bottom))\" w:gutter=\"\(tw(sect.gutter))\"/>"
        if sect.pageStart > 0 { s += "<w:pgNumType w:start=\"\(sect.pageStart)\"/>"; sect.pageStart = 0 }   // 이어지는 구역에서 다시 시작하지 않게
        s += sect.cols > 1 ? "<w:cols w:num=\"\(sect.cols)\" w:space=\"\(tw(sect.colGap))\"/>" : "<w:cols w:space=\"\(tw(sect.colGap))\"/>"
        if sect.hideFirst { s += "<w:titlePg/>" }
        return s + "</w:sectPr>"
    }

    var emptyParts: [String: String] = [:]
    func emptyPart(_ kind: String) -> String {
        if let r = emptyParts[kind] { return r }
        let r = headerFooterPart(kind, body: "<w:p/>")
        emptyParts[kind] = r
        return r
    }

    func sectionBreakParagraph() -> String {
        let s = "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/><w:rPr><w:sz w:val=\"2\"/></w:rPr>\(sectPr())</w:pPr></w:p>"
        sect.startType = "continuous"
        sect.hideFirst = false
        return s
    }

    func finishPageNumber() {
        guard let pn = sect.pageNum, pn.pos != "NONE" else { return }
        let top = pn.pos.hasPrefix("TOP")
        if top ? sect.headerRel != nil : sect.footerRel != nil { return }
        let jc = pn.pos.contains("LEFT") ? "left" : pn.pos.contains("RIGHT") ? "right" : "center"
        let side = pn.side.isEmpty ? "" : esc(pn.side) + " "
        let sideR = pn.side.isEmpty ? "" : " " + esc(pn.side)
        var p = "<w:p><w:pPr><w:jc w:val=\"\(jc)\"/></w:pPr>"
        if !side.isEmpty { p += "<w:r><w:t xml:space=\"preserve\">\(side)</w:t></w:r>" }
        p += field("PAGE", rPr: "")
        if !sideR.isEmpty { p += "<w:r><w:t xml:space=\"preserve\">\(sideR)</w:t></w:r>" }
        p += "</w:p>"
        let rel = headerFooterPart(top ? "header" : "footer", body: p)
        if top { sect.headerRel = rel } else { sect.footerRel = rel; sect.footerUsed = max(sect.footerUsed, 1600) }
    }

    func field(_ instr: String, rPr: String) -> String {
        let r = rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>"
        return "<w:r>\(r)<w:fldChar w:fldCharType=\"begin\"/></w:r><w:r>\(r)<w:instrText xml:space=\"preserve\"> \(instr) </w:instrText></w:r><w:r>\(r)<w:fldChar w:fldCharType=\"separate\"/></w:r><w:r>\(r)<w:t>1</w:t></w:r><w:r>\(r)<w:fldChar w:fldCharType=\"end\"/></w:r>"
    }

    func headerFooterPart(_ kind: String, body: String) -> String {
        hdrCount += 1
        let name = "\(kind)\(hdrCount).xml"
        let root = kind == "header" ? "w:hdr" : "w:ftr"
        parts["word/\(name)"] = xml("<\(root) \(Self.nsAll)>\(body)</\(root)>")
        return addRel("word/document.xml", kind, name)
    }

    // MARK: 문단

    func paragraph(_ p: XMLElement, into out: inout [Block], lastInBox: Bool = false, boxWidth: Int? = nil) {
        let ppID = p.a("paraPrIDRef") ?? "0"
        let pp = paraPr[ppID]
        let runs = p.kids("run")
        let firstCP = runs.first?.a("charPrIDRef") ?? "0"
        var lastCP = firstCP
        var maxHeight = 0
        for r in runs {
            let cp = r.a("charPrIDRef") ?? "0"
            let hasText = r.kids("t").contains { !($0.stringValue ?? "").isEmpty }
            if hasText || runs.count == 1 { maxHeight = max(maxHeight, height(cp)) }
        }
        if maxHeight == 0 { maxHeight = height(lastCP) }

        // 원본 줄바꿈: 줄마다 이 맥 글꼴로 재서 한글 줄 폭에 들어가게 장평을 맞추고(80% 까지), 그 자리에 줄 나눔을 넣는다.
        // 80% 로도 안 들어가는 문단은 억지로 꺾으면 짧은 줄이 생기므로 Word 에 맡긴다.
        var breaks = Set<Int>()
        var squeeze = 100
        if keepLineBreaks, let fit = lineFit(p) {
            breaks = fit.breaks
            squeeze = fit.scale
        } else if let boxWidth {
            squeeze = fitSqueeze(p, pp: pp, boxWidth: boxWidth)
        }
        var pos = 0   // 한글 글자 위치(lineseg textpos 와 같은 셈: 글자 1, 컨트롤 8)
        var cur = numberPrefix(pp, firstCP: firstCP)
        var hasContent = !cur.isEmpty
        var inlineObject = false
        var emitted = false
        var pageBreak = p.a("pageBreak") == "1"
        var extra: [Block] = []
        let align = pp?.kid("align")?.a("horizontal") ?? "LEFT"
        let leftMargin = pp?.kid("margin")?.kid("left")?.i("value") ?? 0

        func flush(force: Bool) {
            guard hasContent || force else { return }
            let singleLine = lastInBox && (p.kid("linesegarray")?.kids("lineseg").count ?? 1) <= 1
            var x = "<w:p>" + pPr(pp, maxHeight: maxHeight, inlineObject: inlineObject, pageBreak: pageBreak && !emitted, markCP: lastCP, trimLast: singleLine)
            if p.a("columnBreak") == "1" && !emitted { x += "<w:r><w:br w:type=\"column\"/></w:r>" }
            out.append(.p(x + cur + "</w:p>"))
            emitted = true
            cur = ""; hasContent = false; inlineObject = false
        }
        func block(_ b: Block) {
            flush(force: false)
            if pageBreak && !emitted {
                out.append(.p("<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/><w:rPr><w:sz w:val=\"2\"/></w:rPr></w:pPr><w:r><w:rPr><w:sz w:val=\"2\"/></w:rPr><w:br w:type=\"page\"/></w:r></w:p>"))
                pageBreak = false
            }
            out.append(b)
            emitted = true
        }

        for r in runs {
            let cp = r.a("charPrIDRef") ?? "0"
            lastCP = cp
            for c in r.elems {
                switch c.tag {
                case "t":
                    let x = textRun(c, cp: cp, squeeze: squeeze, pos: &pos, breaks: breaks)
                    if !x.isEmpty { cur += x; hasContent = true }
                    continue
                case "ctrl":
                    pos += 8 * max(1, c.elems.count)
                    for x in c.elems { cur += control(x, cp: cp, hasContent: &hasContent) }
                    continue
                default:
                    pos += 8
                }
                switch c.tag {
                case "tbl":
                    block(.t(table(c, paraAlign: align, paraLeft: leftMargin)))
                case "pic":
                    let x = picture(c)
                    if !x.isEmpty { cur += x; hasContent = true; if isInline(c) { inlineObject = true } }
                case "container":
                    for pic in allPictures(c) { cur += picture(pic); hasContent = true }
                    for tb in textBoxes(c) { extra.append(.t(tb)) }
                case "rect", "ellipse", "polygon", "curve", "arc":
                    if let tb = textBox(c) {
                        if c.kid("pos")?.a("treatAsChar") == "1" { block(.t(tb)) } else { extra.append(.t(tb)) }
                    }
                case "equation":
                    let script = c.kid("script")?.stringValue ?? ""
                    if !script.isEmpty {
                        // baseUnit 은 HWPUNIT(1000 = 10pt) → w:sz 반 포인트
                        let size = c.a("baseUnit").flatMap(Int.init).map { max(2, $0 / 50) }
                        let color = c.a("textColor").map { $0.replacingOccurrences(of: "#", with: "") }.flatMap { $0.count == 6 ? $0 : nil }
                        cur += HwpEquation.omml(script, sizeHalfPt: size, color: color); hasContent = true
                    }
                case "footNote", "endNote", "pageNum", "header", "footer", "autoNum":
                    cur += control(c, cp: cp, hasContent: &hasContent)
                default:
                    break
                }
            }
        }
        if !emitted || hasContent { flush(force: true) }
        out += extra
    }

    func control(_ c: XMLElement, cp: String, hasContent: inout Bool) -> String {
        switch c.tag {
        case "header", "footer":
            let type = c.a("applyPageType") ?? "BOTH"
            guard type != "EVEN", let sub = c.kid("subList") else { return "" }
            let saved = curPart
            hdrCount += 1
            let name = "\(c.tag)\(hdrCount).xml"
            curPart = "word/\(name)"
            let body = join(subBlocks(sub), trailing: true)
            curPart = saved
            let root = c.tag == "header" ? "w:hdr" : "w:ftr"
            parts["word/\(name)"] = xml("<\(root) \(Self.nsAll)>\(body)</\(root)>")
            let rel = addRel("word/document.xml", c.tag, name)
            if c.tag == "header" { sect.headerRel = rel } else {
                sect.footerRel = rel
                // 꼬리말 내용 높이(줄 정보 기준, Word 고정 줄은 간격까지 한 줄)
                let used = sub.kids("p").compactMap { $0.kid("linesegarray")?.kids("lineseg").last }
                    .map { ($0.i("vertpos") ?? 0) + ($0.i("vertsize") ?? 0) + max(0, $0.i("spacing") ?? 0) }.max() ?? 0
                sect.footerUsed = max(sect.footerUsed, used)
            }
            return ""
        case "pageNum":
            sect.pageNum = (c.a("pos") ?? "BOTTOM_CENTER", c.a("sideChar") ?? "")
            return ""
        case "autoNum":
            switch c.a("numType") {
            case "PAGE": hasContent = true; return field("PAGE", rPr: rPr(cp))
            case "TOTAL_PAGE": hasContent = true; return field("NUMPAGES", rPr: rPr(cp))
            default: return ""
            }
        case "footNote", "endNote":
            guard let sub = c.kid("subList") else { return "" }
            let isFoot = c.tag == "footNote"
            let saved = curPart
            curPart = isFoot ? "word/footnotes.xml" : "word/endnotes.xml"
            var blocks = subBlocks(sub)
            curPart = saved
            let id = (isFoot ? footnotes.count : endnotes.count) + 1
            let ref = "<w:r><w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr><w:\(isFoot ? "footnoteRef" : "endnoteRef")/></w:r><w:r><w:t xml:space=\"preserve\"> </w:t></w:r>"
            if case .p(let first)? = blocks.first {
                if let r = first.range(of: "</w:pPr>") { blocks[0] = .p(first.replacingCharacters(in: r, with: "</w:pPr>" + ref)) }
                else { blocks[0] = .p(first.replacingOccurrences(of: "<w:p>", with: "<w:p>" + ref, options: [.anchored])) }
            } else {
                blocks.insert(.p("<w:p>\(ref)</w:p>"), at: 0)
            }
            let tag = isFoot ? "w:footnote" : "w:endnote"
            let note = "<\(tag) w:id=\"\(id)\">\(join(blocks, trailing: true))</\(tag)>"
            if isFoot { footnotes.append(note) } else { endnotes.append(note) }
            hasContent = true
            return "<w:r><w:rPr><w:vertAlign w:val=\"superscript\"/></w:rPr><w:\(isFoot ? "footnoteReference" : "endnoteReference") w:id=\"\(id)\"/></w:r>"
        default:
            return ""
        }
    }

    func subBlocks(_ sub: XMLElement, box: Bool = false, width: Int? = nil) -> [Block] {
        var blocks: [Block] = []
        let ps = sub.kids("p")
        for (i, p) in ps.enumerated() { paragraph(p, into: &blocks, lastInBox: box && i == ps.count - 1, boxWidth: width) }
        return blocks
    }

    // MARK: 좁은 칸 맞추기

    /// 한글이 한 줄로 앉힌 셀 문단이 대체 글꼴로는 칸을 넘으면(한글 전용 글꼴이 없으면 숫자·글자가 더 넓다) 줄이 꺾여
    /// 행이 두 배가 된다. 글자 너비를 CoreText 로 재서 넘치는 만큼 장평을 줄인다(65% 까지). 돌려주는 값은 장평 배율(%), 100 이면 그대로.
    func fitSqueeze(_ p: XMLElement, pp: XMLElement?, boxWidth: Int) -> Int {
        let segs = p.kid("linesegarray")?.kids("lineseg") ?? []
        guard segs.count <= 1 else { return 100 }
        var parts: [(String, String)] = []
        for r in p.kids("run") {
            let cp = r.a("charPrIDRef") ?? "0"
            for c in r.elems {
                if c.tag == "t" { parts.append((plain(c.stringValue ?? ""), cp)) }
                else if ["tbl", "pic", "container", "rect", "equation"].contains(c.tag) { return 100 }
            }
        }
        let chars = parts.reduce(0) { $0 + $1.0.count }
        guard chars >= 2 else { return 100 }
        let margin = pp?.kid("margin")
        let left = margin?.kid("left")?.i("value") ?? 0, right = margin?.kid("right")?.i("value") ?? 0
        let indent = margin?.kid("intent")?.i("value") ?? 0
        let avail = Double(boxWidth) / 20 - Double(left + right + max(0, indent)) / 100 - 1   // pt, 1pt 여유
        let need = parts.reduce(0.0) { $0 + measure($1.0, cp: $1.1) }
        guard avail > 0, need > avail else { return 100 }
        let scale = Int((avail / need * 100).rounded(.down))
        return scale >= 65 ? scale : 100
    }

    /// 원본 줄바꿈용: 줄 시작 위치들과, 모든 줄이 한글 줄 폭(lineseg horzsize)에 들어가는 장평 배율. 맞출 수 없으면 nil.
    func lineFit(_ p: XMLElement) -> (breaks: Set<Int>, scale: Int)? {
        let segs = p.kid("linesegarray")?.kids("lineseg") ?? []
        guard segs.count > 1 else { return nil }
        // 글자 위치 → (글자, 글자 모양)
        var chars: [(pos: Int, ch: Character, cp: String)] = []
        var pos = 0
        var afterLineBreak = Set<Int>()   // 줄 나눔(Shift+Enter) 바로 뒤 — 이미 줄이 바뀌므로 또 넣지 않는다
        for r in p.kids("run") {
            let cp = r.a("charPrIDRef") ?? "0"
            for c in r.elems {
                guard c.tag == "t" else { pos += c.tag == "ctrl" ? 8 * max(1, c.elems.count) : 8; continue }
                for node in c.children ?? [] {
                    if node.kind == .text {
                        for ch in plain(node.stringValue ?? "") { chars.append((pos, ch, cp)); pos += ch.utf16.count }
                    } else if let e = node as? XMLElement {
                        switch e.tag {
                        case "lineBreak": pos += 1; afterLineBreak.insert(pos)
                        case "hyphen": pos += 1
                        case "fwSpace", "nbSpace": chars.append((pos, " ", cp)); pos += 1
                        default: pos += 8
                        }
                    }
                }
            }
        }
        let starts = segs.map { $0.i("textpos") ?? 0 }
        var scale = 1.0
        for (k, seg) in segs.enumerated() {
            let lo = starts[k], hi = k + 1 < starts.count ? starts[k + 1] : Int.max
            var line = chars.filter { $0.pos >= lo && $0.pos < hi }
            while let last = line.last, last.ch == " " { line.removeLast() }
            guard !line.isEmpty, let width = seg.i("horzsize"), width > 0 else { continue }
            var need = 0.0
            var i = 0
            while i < line.count {   // 같은 글자 모양끼리 묶어 잰다
                var j = i
                while j < line.count && line[j].cp == line[i].cp { j += 1 }
                need += measure(String(line[i..<j].map(\.ch)), cp: line[i].cp)
                i = j
            }
            let avail = Double(width) / 100 - 1   // 1pt 여유(맞춤 정렬·커닝 차이)
            if need > avail { scale = min(scale, avail / need) }
        }
        guard scale >= 0.8 else { return nil }
        return (Set(starts.dropFirst().filter { $0 > 0 && !afterLineBreak.contains($0) }), Int((scale * 100).rounded(.down)))
    }

    var fontCache: [String: CTFont] = [:]

    /// 글자 폭(pt). 한글·한자는 한글 글꼴, 나머지는 영문 글꼴로, 장평·자간까지 넣어서 잰다.
    func measure(_ text: String, cp: String) -> Double {
        guard let e = charPr[cp], !text.isEmpty else { return 0 }
        let size = CGFloat(height(cp)) / 100
        let fr = e.kid("fontRef")
        let han = fr.flatMap { f in f.a("hangul").flatMap { fonts["HANGUL"]?[$0] } } ?? "Apple SD Gothic Neo"
        let lat = fr.flatMap { f in f.a("latin").flatMap { fonts["LATIN"]?[$0] } } ?? han
        let ratio = Double(e.kid("ratio")?.i("hangul") ?? 100) / 100
        let spacing = Double(e.kid("spacing")?.i("hangul") ?? 0) / 100 * Double(size)
        var width = 0.0
        var run = "", runHangul = false
        // 자간이 음수일 때 LibreOffice 는 한글↔문장부호·숫자 경계 글자에 자간을 안 먹인다(실측: 「서,」 +1.1pt, 「보·이」 +2.1pt @11pt 자간 -10%).
        // 그만큼 넓게 잡아야 원본 자리에서 넘치지 않는다. Word 처럼 다 먹이는 쪽에선 장평이 조금 더 좁아질 뿐이다.
        var edges = 0, prevHangul: Bool? = nil
        func flush() {
            guard !run.isEmpty else { return }
            let font = ctFont(runHangul ? han : lat, size: size, bold: e.kid("bold") != nil)
            let attr = NSAttributedString(string: run, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            width += Double(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil))
            run = ""
        }
        for ch in String(String.UnicodeScalarView(text.unicodeScalars.map(Self.mapPUA))) {
            let v = ch.unicodeScalars.first?.value ?? 0
            let isHangul = (0x1100...0x11FF).contains(v) || (0x3000...0x9FFF).contains(v) || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
            if isHangul != runHangul { flush(); runHangul = isHangul }
            run.append(ch)
            if ch != " " {
                if let p = prevHangul, p != isHangul { edges += 1 }
                prevHangul = isHangul
            }
        }
        flush()
        return width * ratio + spacing * Double(text.count) + max(0, -spacing) * Double(edges)
    }

    var resolvedNames: [String: String] = [:]

    /// 이 맥에 있는 글꼴이면 그 이름, 없으면 비슷한 계열의 맥 기본 글꼴(명조 계열 → AppleMyungjo, 나머지 → Apple SD Gothic Neo).
    func installedFont(_ name: String) -> String {
        if let r = resolvedNames[name] { return r }
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
        let r: String
        if CTFontDescriptorCreateMatchingFontDescriptor(desc, nil) != nil {
            r = name
        } else {
            let serif = ["명조", "바탕", "궁서", "Batang", "Myeongjo", "신명", "Times", "Serif"].contains { name.contains($0) }
            r = serif ? "AppleMyungjo" : "Apple SD Gothic Neo"
        }
        resolvedNames[name] = r
        return r
    }

    /// 문서에 적을 글꼴 이름. 「줄바꿈 원본대로」면 잰 글꼴과 그리는 글꼴이 같아야 줄이 같은 자리에서 꺾이므로,
    /// 이 맥에 없는 한컴 전용 글꼴은 잰 대체 글꼴 이름으로 적는다(있는 글꼴은 그대로).
    func docFont(_ name: String) -> String { keepLineBreaks ? installedFont(name) : name }

    func ctFont(_ name: String, size: CGFloat, bold: Bool = false) -> CTFont {
        let key = "\(name)|\(size)|\(bold)"
        if let f = fontCache[key] { return f }
        let desc = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: installedFont(name)] as CFDictionary)
        var font = CTFontCreateWithFontDescriptor(desc, size, nil)
        if bold, let b = CTFontCreateCopyWithSymbolicTraits(font, size, nil, .traitBold, .traitBold) { font = b }
        fontCache[key] = font
        return font
    }

    /// 표가 바로 이어지면 Word 는 한 표로 붙여 버려서 아주 얇은 문단을 끼운다. 셀·각주 끝은 문단이어야 한다.
    func join(_ blocks: [Block], trailing: Bool) -> String {
        let spacer = "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/><w:rPr><w:sz w:val=\"2\"/></w:rPr></w:pPr></w:p>"
        var s = ""
        var lastTable = false
        for b in blocks {
            switch b {
            case .p(let x): s += x; lastTable = false
            case .t(let x): if lastTable { s += spacer }; s += x; lastTable = true
            }
        }
        if trailing && (lastTable || blocks.isEmpty) { s += lastTable ? spacer : "<w:p/>" }
        return s
    }

    func height(_ cp: String) -> Int {
        guard let e = charPr[cp] else { return 1000 }
        let h = e.i("height") ?? 1000
        let rel = e.kid("relSz")?.i("hangul") ?? 100
        return h * rel / 100
    }

    /// trimLast: 셀·글상자의 마지막 한 줄 문단. 한글은 마지막 줄 뒤 줄간격을 셀 높이에 넣지 않아서, Word 에서 행이 늘지 않게 줄 높이를 글자 크기 가까이로 둔다.
    func pPr(_ pp: XMLElement?, maxHeight: Int, inlineObject: Bool, pageBreak: Bool, markCP: String, trimLast: Bool = false) -> String {
        var s = "<w:pPr>"
        let brk = pp?.kid("breakSetting")
        if brk?.a("keepWithNext") == "1" { s += "<w:keepNext/>" }
        if brk?.a("keepLines") == "1" { s += "<w:keepLines/>" }
        if pageBreak || brk?.a("pageBreakBefore") == "1" { s += "<w:pageBreakBefore/>" }
        s += brk?.a("widowOrphan") == "1" ? "<w:widowControl/>" : "<w:widowControl w:val=\"0\"/>"
        if let bfID = pp?.kid("border")?.a("borderFillIDRef"), let bf = borderFill[bfID] {
            let sides = ["top": "topBorder", "left": "leftBorder", "bottom": "bottomBorder", "right": "rightBorder"]
            var bdr = ""
            for side in ["top", "left", "bottom", "right"] {
                if let b = borderAttrs(bf.kid(sides[side]!)) { bdr += "<w:\(side) \(b.replacingOccurrences(of: "w:space=\"0\"", with: "w:space=\"1\""))/>" }
            }
            if !bdr.isEmpty { s += "<w:pBdr>\(bdr)</w:pBdr>" }
            if let fill = fillColor(bf) { s += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(fill)\"/>" }
        }
        if let tid = pp?.a("tabPrIDRef"), let tp = tabPr[tid] {
            var tabs = ""
            for item in tabItems(tp) {
                guard let pos = item.i("pos"), pos > 0 else { continue }
                let val = ["RIGHT": "right", "CENTER": "center", "DECIMAL": "decimal"][item.a("type") ?? ""] ?? "left"
                let leader = ["DOT": "dot", "DASH": "hyphen", "SOLID": "underscore", "DASH_DOT": "hyphen", "LONG_DASH": "hyphen", "CIRCLE": "dot"][item.a("leader") ?? ""]
                tabs += "<w:tab w:val=\"\(val)\"\(leader.map { " w:leader=\"\($0)\"" } ?? "") w:pos=\"\(tw(pos))\"/>"
            }
            if !tabs.isEmpty { s += "<w:tabs>\(tabs)</w:tabs>" }
        }
        // 줄간격: 한글의 160% 는 「글자 크기 × 1.6」 이 줄 높이다. Word 의 「배수」 는 글꼴 고유 줄높이(대개 1.2~1.3배)에 곱해져
        // 줄이 훨씬 벌어지므로, 같은 높이를 고정값으로 준다. 글자처럼 붙인 그림이 있으면 잘리지 않게 「최소」로.
        let margin = pp?.kid("margin")
        let prev = margin?.kid("prev")?.i("value") ?? 0, next = margin?.kid("next")?.i("value") ?? 0
        var spacing = "w:before=\"\(max(0, tw(prev)))\" w:after=\"\(max(0, tw(next)))\""
        let ls = pp?.kid("lineSpacing")
        let lsVal = ls?.i("value") ?? 160
        let rule = inlineObject ? "atLeast" : "exact"
        switch ls?.a("type") ?? "PERCENT" {
        case "FIXED": spacing += " w:line=\"\(max(20, tw(lsVal)))\" w:lineRule=\"\(rule)\""
        case "BETWEEN_LINES": spacing += " w:line=\"\(max(20, tw(maxHeight + lsVal)))\" w:lineRule=\"\(rule)\""
        case "AT_LEAST": spacing += " w:line=\"\(max(20, tw(lsVal)))\" w:lineRule=\"atLeast\""
        default:
            let pct = trimLast ? min(lsVal, 120) : lsVal
            spacing += " w:line=\"\(max(20, tw(maxHeight * pct / 100)))\" w:lineRule=\"\(rule)\""
        }
        s += "<w:spacing \(spacing)/>"
        // 한글: 왼쪽 여백 L, 첫 줄 I(음수면 내어쓰기 = 둘째 줄부터 |I| 만큼 더 들어감)
        let left = margin?.kid("left")?.i("value") ?? 0, right = margin?.kid("right")?.i("value") ?? 0
        let indent = margin?.kid("intent")?.i("value") ?? 0
        var ind = ""
        if indent < 0 { ind = "w:left=\"\(tw(left - indent))\" w:hanging=\"\(tw(-indent))\"" }
        else { ind = "w:left=\"\(tw(left))\"" + (indent > 0 ? " w:firstLine=\"\(tw(indent))\"" : "") }
        if right != 0 { ind += " w:right=\"\(tw(right))\"" }
        s += "<w:ind \(ind)/>"
        let jc = ["CENTER": "center", "RIGHT": "right", "JUSTIFY": "both", "DISTRIBUTE": "distribute", "DISTRIBUTE_SPACE": "distribute"][pp?.kid("align")?.a("horizontal") ?? "LEFT"] ?? "left"
        s += "<w:jc w:val=\"\(jc)\"/>"
        let mark = rPr(markCP)
        if !mark.isEmpty { s += "<w:rPr>\(mark)</w:rPr>" }
        return s + "</w:pPr>"
    }

    func tabItems(_ tp: XMLElement) -> [XMLElement] {
        var items: [XMLElement] = []
        for e in tp.elems {
            if e.tag == "tabItem" { items.append(e) }
            if e.tag == "switch", let branch = e.kids("case").first ?? e.kids("default").first { items += branch.kids("tabItem") }
        }
        return items
    }

    // MARK: 문단 번호·글머리표

    func numberPrefix(_ pp: XMLElement?, firstCP: String) -> String {
        guard let head = pp?.kid("heading"), let type = head.a("type"), type != "NONE" else { return "" }
        let level = max(0, min(9, head.i("level") ?? 0))
        if type == "BULLET" {
            guard let b = bullet[head.a("idRef") ?? ""], let ch = b.a("char"), !ch.isEmpty else { return "" }
            return plainRun(ch + " ", cp: firstCP)
        }
        let numID = type == "OUTLINE" ? sect.outline : (head.a("idRef") ?? "")
        guard let num = numbering[numID] else { return "" }
        let heads = num.kids("paraHead")
        func levelHead(_ lv: Int) -> XMLElement? { heads.first { $0.i("level") == lv + 1 } }
        var arr = counters[numID] ?? Array(repeating: -1, count: 10)   // -1 = 아직 안 나옴(시작 번호가 0 일 수 있어서)
        let start = { (lv: Int) in levelHead(lv)?.i("start") ?? 1 }
        arr[level] = arr[level] < 0 ? start(level) : arr[level] + 1
        for j in (level + 1)..<10 { arr[j] = -1 }
        counters[numID] = arr
        guard let ph = levelHead(level) else { return "" }
        var text = ph.stringValue ?? ""
        for lv in stride(from: 9, through: 0, by: -1) where text.contains("^\(lv + 1)") {
            let n = arr[lv] < 0 ? start(lv) : arr[lv]
            text = text.replacingOccurrences(of: "^\(lv + 1)", with: Self.format(n, levelHead(lv)?.a("numFormat") ?? "DIGIT"))
        }
        guard !text.isEmpty else { return "" }
        let cp = ph.a("charPrIDRef").flatMap { charPr[$0] != nil ? $0 : nil } ?? firstCP
        return plainRun(text + " ", cp: cp)
    }

    static func format(_ n: Int, _ f: String) -> String {
        func seq(_ s: String) -> String { let a = Array(s); return n >= 1 && n <= a.count ? String(a[n - 1]) : String(n) }
        func scalar(_ base: UInt32, _ count: Int) -> String {
            n >= 1 && n <= count ? String(UnicodeScalar(base + UInt32(n - 1)).map(Character.init) ?? "?") : String(n)
        }
        switch f {
        case "CIRCLED_DIGIT": return scalar(0x2460, 20)
        case "ROMAN_CAPITAL": return roman(n)
        case "ROMAN_SMALL": return roman(n).lowercased()
        case "LATIN_CAPITAL": return seq("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        case "LATIN_SMALL": return seq("abcdefghijklmnopqrstuvwxyz")
        case "CIRCLED_LATIN_CAPITAL": return scalar(0x24B6, 26)
        case "CIRCLED_LATIN_SMALL": return scalar(0x24D0, 26)
        case "HANGUL_SYLLABLE": return seq("가나다라마바사아자차카타파하")
        case "CIRCLED_HANGUL_SYLLABLE": return scalar(0x326E, 14)
        case "HANGUL_JAMO": return seq("ㄱㄴㄷㄹㅁㅂㅅㅇㅈㅊㅋㅌㅍㅎ")
        case "CIRCLED_HANGUL_JAMO": return scalar(0x3260, 14)
        case "HANGUL_PHONETIC": return seq("일이삼사오육칠팔구십")
        case "IDEOGRAPH": return seq("一二三四五六七八九十")
        case "CIRCLED_IDEOGRAPH": return scalar(0x3280, 10)
        default: return String(n)
        }
    }

    static func roman(_ n: Int) -> String {
        guard n > 0 && n < 4000 else { return String(n) }
        let t: [(Int, String)] = [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")]
        var n = n, s = ""
        for (v, r) in t { while n >= v { s += r; n -= v } }
        return s
    }

    // MARK: 글자

    func textRun(_ t: XMLElement, cp: String, squeeze: Int = 100, pos: inout Int, breaks: Set<Int> = []) -> String {
        var inner = ""
        var buf = ""
        func flushText() {
            if !buf.isEmpty { inner += "<w:t xml:space=\"preserve\">\(esc(buf))</w:t>"; buf = "" }
        }
        func breakHere() {
            if pos > 0 && breaks.contains(pos) { flushText(); inner += "<w:br/>" }
        }
        for node in t.children ?? [] {
            if node.kind == .text {
                for ch in node.stringValue ?? "" {
                    breakHere()
                    buf.append(ch)
                    pos += ch.utf16.count
                }
                continue
            }
            guard let e = node as? XMLElement else { continue }
            breakHere()
            switch e.tag {
            case "tab": flushText(); inner += "<w:tab/>"; pos += 8
            case "lineBreak": flushText(); inner += "<w:br/>"; pos += 1
            case "fwSpace": buf += "\u{2002}"; pos += 1
            case "nbSpace": buf += "\u{00A0}"; pos += 1
            case "hyphen": buf += "-"; pos += 1
            default: buf += e.stringValue ?? ""; pos += 8
            }
        }
        flushText()
        guard !inner.isEmpty else { return "" }
        let r = rPr(cp, squeeze: squeeze)
        return "<w:r>\(r.isEmpty ? "" : "<w:rPr>\(r)</w:rPr>")\(inner)</w:r>"
    }

    func plainRun(_ text: String, cp: String) -> String {
        let r = rPr(cp)
        return "<w:r>\(r.isEmpty ? "" : "<w:rPr>\(r)</w:rPr>")<w:t xml:space=\"preserve\">\(esc(text))</w:t></w:r>"
    }

    func rPr(_ id: String, squeeze: Int = 100) -> String {
        let cacheKey = squeeze == 100 ? id : "\(id)~\(squeeze)"
        if let c = rPrCache[cacheKey] { return c }
        guard let e = charPr[id] else { return "" }
        var s = ""
        let fr = e.kid("fontRef")
        let han = fr.flatMap { f in f.a("hangul").flatMap { fonts["HANGUL"]?[$0] } }.map(docFont)
        let lat = (fr.flatMap { f in f.a("latin").flatMap { fonts["LATIN"]?[$0] } } ?? han).map(docFont)
        if let han, let lat {
            usedFonts.insert(han); usedFonts.insert(lat)
            s += "<w:rFonts w:ascii=\"\(esc(lat))\" w:hAnsi=\"\(esc(lat))\" w:eastAsia=\"\(esc(han))\" w:cs=\"\(esc(lat))\"/>"
        }
        if e.kid("bold") != nil { s += "<w:b/><w:bCs/>" }
        if e.kid("italic") != nil { s += "<w:i/><w:iCs/>" }
        let ul = e.kid("underline")
        let strikeShape = e.kid("strikeout")?.a("shape")?.uppercased() ?? "NONE"
        if !["NONE", "3D"].contains(strikeShape) || ul?.a("type") == "CENTER" { s += "<w:strike/>" }
        if let o = e.kid("outline")?.a("type"), o != "NONE" { s += "<w:outline/>" }
        if let sh = e.kid("shadow")?.a("type"), sh != "NONE" { s += "<w:shadow/>" }
        if e.kid("emboss") != nil { s += "<w:emboss/>" }
        if e.kid("engrave") != nil { s += "<w:imprint/>" }
        if let c = e.a("textColor").flatMap(hex) { s += "<w:color w:val=\"\(c)\"/>" }
        let h = height(id)
        let sp = (e.kid("spacing")?.i("hangul") ?? 0) * h / 500   // 글자 크기의 % → 1/20pt
        if sp != 0 { s += "<w:spacing w:val=\"\(sp)\"/>" }
        let ratio = max(1, e.kid("ratio")?.i("hangul") ?? 100) * squeeze / 100
        if ratio != 100 { s += "<w:w w:val=\"\(min(600, ratio))\"/>" }
        let half = max(2, Int((Double(h) / 50).rounded()))
        s += "<w:sz w:val=\"\(half)\"/><w:szCs w:val=\"\(half)\"/>"
        if let ul, ul.a("type") == "BOTTOM" {
            let val = ["DASH": "dash", "DOT": "dotted", "DASH_DOT": "dotDash", "DASH_DOT_DOT": "dotDotDash", "LONG_DASH": "dashLong",
                       "DOUBLE_SLIM": "double", "WAVE": "wave", "DOUBLE_WAVE": "wavyDouble", "THICK_3D": "thick"][ul.a("shape") ?? ""] ?? "single"
            s += "<w:u w:val=\"\(val)\"\(ul.a("color").flatMap(hex).map { " w:color=\"\($0)\"" } ?? "")/>"
        }
        if let shade = e.a("shadeColor").flatMap(hex), shade != "FFFFFF" { s += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(shade)\"/>" }
        if e.kid("supscript") != nil { s += "<w:vertAlign w:val=\"superscript\"/>" }
        else if e.kid("subscript") != nil { s += "<w:vertAlign w:val=\"subscript\"/>" }
        rPrCache[cacheKey] = s
        return s
    }

    // MARK: 표

    static let maxCols = 1000, maxRows = 100_000

    struct TCell {
        let el: XMLElement
        let row: Int, col: Int, rs: Int, cs: Int, w: Int, h: Int
    }

    func table(_ t: XMLElement, paraAlign: String, paraLeft: Int) -> String {
        var cells: [TCell] = []
        for tr in t.kids("tr") {
            for tc in tr.kids("tc") {
                let addr = tc.kid("cellAddr"), span = tc.kid("cellSpan"), sz = tc.kid("cellSz")
                // 깨진 파일 방어: 한글 표는 열 수백 개를 넘지 않는다
                let col = max(0, min(Self.maxCols - 1, addr?.i("colAddr") ?? 0))
                let row = max(0, min(Self.maxRows - 1, addr?.i("rowAddr") ?? 0))
                cells.append(TCell(el: tc, row: row, col: col,
                                   rs: max(1, min(Self.maxRows - row, span?.i("rowSpan") ?? 1)),
                                   cs: max(1, min(Self.maxCols - col, span?.i("colSpan") ?? 1)),
                                   w: max(0, sz?.i("width") ?? 0), h: max(0, sz?.i("height") ?? 0)))
            }
        }
        guard !cells.isEmpty else { return "" }
        let ncols = min(Self.maxCols, max(t.i("colCnt") ?? 0, cells.map { $0.col + $0.cs }.max() ?? 1))
        let nrows = min(Self.maxRows, max(t.i("rowCnt") ?? 0, cells.map { $0.row + $0.rs }.max() ?? 1))

        // 열 경계: 각 셀의 너비가 「경계[c+cs] - 경계[c]」 라는 식을 한 칸짜리 셀부터 풀어 나간다.
        var b = [Int?](repeating: nil, count: ncols + 1)
        b[0] = 0
        let ordered = cells.sorted { $0.cs < $1.cs }
        func propagate() {
            var changed = true
            while changed {
                changed = false
                for c in ordered where c.w > 0 && c.col + c.cs <= ncols {
                    if let s = b[c.col], b[c.col + c.cs] == nil { b[c.col + c.cs] = s + c.w; changed = true }
                    else if b[c.col] == nil, let e = b[c.col + c.cs] { b[c.col] = e - c.w; changed = true }
                }
            }
        }
        propagate()
        if b[ncols] == nil {   // 오른쪽 끝을 표 너비로 정하고 거기서 다시 거꾸로 풀어 본다
            b[ncols] = (t.kid("sz")?.i("width")).flatMap { $0 > 0 ? $0 : nil } ?? (b.compactMap { $0 }.max() ?? 0) + 5000
            propagate()
        }
        var i = 1
        while i < ncols {   // 못 푼 경계는 앞뒤 경계 사이를 고르게
            if b[i] == nil {
                var j = i; while b[j] == nil { j += 1 }
                let s = b[i - 1]!, e = b[j]!
                for k in i..<j { b[k] = s + (e - s) * (k - i + 1) / (j - i + 1) }
                i = j
            }
            i += 1
        }
        var bounds = b.map { $0 ?? 0 }
        for k in 1...ncols where bounds[k] <= bounds[k - 1] { bounds[k] = bounds[k - 1] + 100 }
        let grid = (0..<ncols).map { max(20, tw(bounds[$0 + 1] - bounds[$0])) }
        let total = grid.reduce(0, +)

        let inM = t.kid("inMargin")
        var tblPr = "<w:tblPr><w:tblW w:w=\"\(total)\" w:type=\"dxa\"/>"
        let pos = t.kid("pos")
        if pos?.a("treatAsChar") == "1" {
            if paraAlign == "CENTER" { tblPr += "<w:jc w:val=\"center\"/>" }
            else if paraAlign == "RIGHT" { tblPr += "<w:jc w:val=\"right\"/>" }
            else if paraLeft > 0 { tblPr += "<w:tblInd w:w=\"\(tw(paraLeft))\" w:type=\"dxa\"/>" }
        } else {
            switch pos?.a("horzAlign") {
            case "CENTER": tblPr += "<w:jc w:val=\"center\"/>"
            case "RIGHT", "OUTSIDE": tblPr += "<w:jc w:val=\"right\"/>"
            default:
                let off = (pos?.a("horzRelTo") == "PARA" ? paraLeft : 0) + (pos?.i("horzOffset") ?? 0)
                if off > 0 { tblPr += "<w:tblInd w:w=\"\(tw(off))\" w:type=\"dxa\"/>" }
            }
        }
        tblPr += "<w:tblBorders><w:top w:val=\"nil\"/><w:left w:val=\"nil\"/><w:bottom w:val=\"nil\"/><w:right w:val=\"nil\"/><w:insideH w:val=\"nil\"/><w:insideV w:val=\"nil\"/></w:tblBorders>"
        tblPr += "<w:tblLayout w:type=\"fixed\"/>"
        tblPr += "<w:tblCellMar><w:top w:w=\"\(tw(inM?.i("top") ?? 141))\" w:type=\"dxa\"/><w:left w:w=\"\(tw(inM?.i("left") ?? 510))\" w:type=\"dxa\"/><w:bottom w:w=\"\(tw(inM?.i("bottom") ?? 141))\" w:type=\"dxa\"/><w:right w:w=\"\(tw(inM?.i("right") ?? 510))\" w:type=\"dxa\"/></w:tblCellMar>"
        tblPr += "<w:tblLook w:val=\"0000\" w:firstRow=\"0\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"1\" w:noVBand=\"1\"/></w:tblPr>"

        var x = "<w:tbl>" + tblPr + "<w:tblGrid>" + grid.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"
        var start: [Int: Int] = [:], cover: [Int: Int] = [:]
        for (idx, c) in cells.enumerated() {
            start[c.row * ncols + c.col] = idx
            if c.rs > 1 { for rr in (c.row + 1)..<min(nrows, c.row + c.rs) { cover[rr * ncols + c.col] = idx } }
        }
        let cantSplit = t.a("pageBreak") == "CELL"
        let repeatHeader = t.a("repeatHeader") == "1"
        let inheritMargin = inM
        for r in 0..<nrows {
            let rowCells = cells.filter { $0.row == r && $0.rs == 1 }
            let rowH = rowCells.map { $0.h }.max() ?? 0
            var trPr = ""
            if cantSplit { trPr += "<w:cantSplit/>" }
            // 한글 셀 높이는 위아래 안 여백·테두리까지 포함한 바깥 높이다. Word·LibreOffice 는 「최소」 행 높이에 여백·테두리를
            // 더 얹어 그려서(LibreOffice bug 155229 참고) 그만큼 빼 준다. 내용이 더 크면 행은 알아서 늘어난다.
            if rowH > 0 {
                let chrome = rowCells.map { verticalChrome($0, tableMargin: inheritMargin) }.max() ?? 0
                trPr += "<w:trHeight w:val=\"\(max(20, tw(rowH) - chrome))\" w:hRule=\"atLeast\"/>"
            }
            let isHeader = repeatHeader && !cells.filter({ $0.row == r }).isEmpty && cells.filter({ $0.row == r }).allSatisfy { $0.el.a("header") == "1" }
            if isHeader { trPr += "<w:tblHeader/>" }
            x += "<w:tr>" + (trPr.isEmpty ? "" : "<w:trPr>\(trPr)</w:trPr>")
            var c = 0
            while c < ncols {
                if let idx = start[r * ncols + c] {
                    let cell = cells[idx]
                    let span = min(cell.cs, ncols - c)
                    x += tc(cell, width: grid[c..<(c + span)].reduce(0, +), span: span, merge: cell.rs > 1 ? "restart" : nil, tableMargin: inheritMargin)
                    c += span
                } else if let idx = cover[r * ncols + c] {
                    let cell = cells[idx]
                    let span = min(cell.cs, ncols - c)
                    x += tc(cell, width: grid[c..<(c + span)].reduce(0, +), span: span, merge: "continue", tableMargin: inheritMargin)
                    c += span
                } else {
                    x += "<w:tc><w:tcPr><w:tcW w:w=\"\(grid[c])\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"
                    c += 1
                }
            }
            x += "</w:tr>"
        }
        return x + "</w:tbl>"
    }

    /// 셀 위아래 안 여백 + 위아래 테두리 두께(twip).
    func verticalChrome(_ cell: TCell, tableMargin: XMLElement?) -> Int {
        let m = cell.el.a("hasMargin") == "1" ? cell.el.kid("cellMargin") : tableMargin
        var v = tw((m?.i("top") ?? 0) + (m?.i("bottom") ?? 0))
        if let bf = borderFill[cell.el.a("borderFillIDRef") ?? ""] {
            for key in ["topBorder", "bottomBorder"] {
                if let attrs = borderAttrs(bf.kid(key)), let r = attrs.range(of: #"w:sz="(\d+)""#, options: .regularExpression) {
                    let n = Int(attrs[r].filter(\.isNumber)) ?? 0
                    v += n * 20 / 8 / 2   // 선 두께의 절반이 셀 안쪽
                }
            }
        }
        return v
    }

    func tc(_ cell: TCell, width: Int, span: Int, merge: String?, tableMargin: XMLElement?) -> String {
        var pr = "<w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>"
        if span > 1 { pr += "<w:gridSpan w:val=\"\(span)\"/>" }
        if let merge { pr += merge == "restart" ? "<w:vMerge w:val=\"restart\"/>" : "<w:vMerge/>" }
        if let bf = borderFill[cell.el.a("borderFillIDRef") ?? ""] {
            pr += "<w:tcBorders>"
            for (side, key) in [("top", "topBorder"), ("left", "leftBorder"), ("bottom", "bottomBorder"), ("right", "rightBorder")] {
                pr += "<w:\(side) \(borderAttrs(bf.kid(key)) ?? "w:val=\"nil\"")/>"
            }
            if bf.kid("backSlash")?.a("type").map({ $0 != "NONE" }) == true { pr += "<w:tl2br \(borderAttrs(bf.kid("diagonal"), force: true) ?? "w:val=\"single\" w:sz=\"4\"")/>" }
            if bf.kid("slash")?.a("type").map({ $0 != "NONE" }) == true { pr += "<w:tr2bl \(borderAttrs(bf.kid("diagonal"), force: true) ?? "w:val=\"single\" w:sz=\"4\"")/>" }
            pr += "</w:tcBorders>"
            if let fill = fillColor(bf) { pr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(fill)\"/>" }
        }
        let m = cell.el.a("hasMargin") == "1" ? cell.el.kid("cellMargin") : tableMargin
        if let m {
            pr += "<w:tcMar><w:top w:w=\"\(tw(m.i("top") ?? 0))\" w:type=\"dxa\"/><w:left w:w=\"\(tw(m.i("left") ?? 0))\" w:type=\"dxa\"/><w:bottom w:w=\"\(tw(m.i("bottom") ?? 0))\" w:type=\"dxa\"/><w:right w:w=\"\(tw(m.i("right") ?? 0))\" w:type=\"dxa\"/></w:tcMar>"
        }
        let sub = cell.el.kid("subList")
        if sub?.a("textDirection") == "VERTICAL" { pr += "<w:textDirection w:val=\"tbRl\"/>" }
        pr += "<w:vAlign w:val=\"\(["CENTER": "center", "BOTTOM": "bottom"][sub?.a("vertAlign") ?? ""] ?? "top")\"/>"
        let mar = cell.el.a("hasMargin") == "1" ? cell.el.kid("cellMargin") : tableMargin
        let inner = width - tw((mar?.i("left") ?? 0) + (mar?.i("right") ?? 0))
        let content = merge == "continue" || sub == nil ? "<w:p/>" : join(subBlocks(sub!, box: true, width: inner), trailing: true)
        return "<w:tc><w:tcPr>\(pr)</w:tcPr>\(content)</w:tc>"
    }

    /// 한글 선 → Word 테두리 속성. 선 없음이면 nil.
    func borderAttrs(_ e: XMLElement?, force: Bool = false) -> String? {
        guard let e else { return nil }
        let type = e.a("type") ?? "NONE"
        if type == "NONE" && !force { return nil }
        let val = ["SOLID": "single", "DASH": "dashed", "DOT": "dotted", "DASH_DOT": "dotDash", "DASH_DOT_DOT": "dotDotDash",
                   "LONG_DASH": "dashed", "CIRCLE": "dotted", "DOUBLE_SLIM": "double", "SLIM_THICK": "thinThickSmallGap",
                   "THICK_SLIM": "thickThinSmallGap", "SLIM_THICK_SLIM": "thinThickThinSmallGap", "WAVE": "wave",
                   "DOUBLE_WAVE": "doubleWave", "THICK_3D": "threeDEmboss", "THICK_3D_REVERS": "threeDEngrave",
                   "3D": "threeDEmboss", "3D_REVERS": "threeDEngrave"][type] ?? "single"
        let mm = Double((e.a("width") ?? "0.12").components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted).joined()) ?? 0.12
        let sz = max(2, min(96, Int((mm * 72 / 25.4 * 8).rounded())))
        let color = e.a("color").flatMap(hex) ?? "000000"
        return "w:val=\"\(val)\" w:sz=\"\(sz)\" w:space=\"0\" w:color=\"\(color)\""
    }

    func fillColor(_ bf: XMLElement) -> String? {
        guard let brush = bf.kid("fillBrush") else { return nil }
        if let win = brush.kid("winBrush"), let c = win.a("faceColor").flatMap(hex) { return c }
        if let g = brush.kid("gradation"), let c = g.kids("color").first?.a("value").flatMap(hex) { return c }
        return nil
    }

    // MARK: 그림·글상자

    func allPictures(_ e: XMLElement) -> [XMLElement] {
        var out: [XMLElement] = []
        for c in e.elems {
            if c.tag == "pic" { out.append(c) } else if c.tag == "container" { out += allPictures(c) }
        }
        return out
    }

    func textBoxes(_ e: XMLElement) -> [String] {
        var out: [String] = []
        for c in e.elems {
            if c.tag == "container" { out += textBoxes(c) } else if let tb = textBox(c) { out.append(tb) }
        }
        return out
    }

    /// 글상자(도형 안 글)는 한 칸짜리 표로 옮긴다 — 테두리·배경·크기가 비슷하게 남는다.
    func textBox(_ shape: XMLElement) -> String? {
        guard let dt = shape.kid("drawText"), let sub = dt.kid("subList") else { return nil }
        let text = join(subBlocks(sub, box: true), trailing: true)
        let w = shape.kid("sz")?.i("width") ?? shape.kid("curSz")?.i("width") ?? 20000
        let h = shape.kid("sz")?.i("height") ?? 0
        var borders = ""
        if let ln = shape.kid("lineShape"), (ln.a("style") ?? "SOLID") != "NONE", let lw = ln.i("width"), lw > 0 {
            let sz = max(2, min(96, lw * 8 * 72 / 7200))
            let color = ln.a("color").flatMap(hex) ?? "000000"
            let one = "w:val=\"single\" w:sz=\"\(sz)\" w:space=\"0\" w:color=\"\(color)\""
            borders = "<w:top \(one)/><w:left \(one)/><w:bottom \(one)/><w:right \(one)/>"
        } else {
            borders = "<w:top w:val=\"nil\"/><w:left w:val=\"nil\"/><w:bottom w:val=\"nil\"/><w:right w:val=\"nil\"/>"
        }
        var fill = ""
        if let brush = shape.kid("fillBrush"), let c = brush.kid("winBrush")?.a("faceColor").flatMap(hex) {
            fill = "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(c)\"/>"
        }
        let m = dt.kid("textMargin")
        let mar = "<w:tcMar><w:top w:w=\"\(tw(m?.i("top") ?? 283))\" w:type=\"dxa\"/><w:left w:w=\"\(tw(m?.i("left") ?? 283))\" w:type=\"dxa\"/><w:bottom w:w=\"\(tw(m?.i("bottom") ?? 283))\" w:type=\"dxa\"/><w:right w:w=\"\(tw(m?.i("right") ?? 283))\" w:type=\"dxa\"/></w:tcMar>"
        let va = ["CENTER": "center", "BOTTOM": "bottom"][sub.a("vertAlign") ?? ""] ?? "top"
        let width = max(200, tw(w))
        let jc = ["CENTER": "<w:jc w:val=\"center\"/>", "RIGHT": "<w:jc w:val=\"right\"/>"][shape.kid("pos")?.a("horzAlign") ?? ""] ?? ""
        return "<w:tbl><w:tblPr><w:tblW w:w=\"\(width)\" w:type=\"dxa\"/>\(jc)<w:tblLayout w:type=\"fixed\"/><w:tblLook w:val=\"0000\"/></w:tblPr><w:tblGrid><w:gridCol w:w=\"\(width)\"/></w:tblGrid><w:tr>"
            + (h > 0 ? "<w:trPr><w:trHeight w:val=\"\(tw(h))\" w:hRule=\"atLeast\"/></w:trPr>" : "")
            + "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/><w:tcBorders>\(borders)</w:tcBorders>\(fill)\(mar)<w:vAlign w:val=\"\(va)\"/></w:tcPr>\(text)</w:tc></w:tr></w:tbl>"
    }

    func imageRel(_ itemID: String) -> String? {
        let name: String
        if let n = mediaByItem[itemID] { name = n } else {
            guard let href = binHref[itemID], let url = safeURL(href), let data = try? Data(contentsOf: url) else { return nil }
            var ext = (href as NSString).pathExtension.lowercased()
            if ext == "jpeg" { ext = "jpg" }
            guard ["png", "jpg", "gif", "bmp", "tif", "tiff", "wmf", "emf"].contains(ext) else { return nil }
            name = "image\(mediaByItem.count + 1).\(ext)"
            mediaByItem[itemID] = name
            parts["word/media/\(name)"] = data
        }
        return addRel(curPart, "image", "media/\(name)")
    }

    /// 글자처럼 취급한 그림, 그리고 「위아래」 배치로 문단을 따라 흐르는 그림은 줄 안 그림으로 둔다.
    /// 표 셀 안에 떠 있는 그림은 Word·LibreOffice 가 엉뚱한 곳에 놓는 일이 잦고, 이 배치는 줄 안 그림과 보이는 모양이 같다.
    func isInline(_ pic: XMLElement) -> Bool {
        guard let pos = pic.kid("pos") else { return true }
        if pos.a("treatAsChar") == "1" { return true }
        return (pic.a("textWrap") ?? "TOP_AND_BOTTOM") == "TOP_AND_BOTTOM" && (pos.a("vertRelTo") ?? "PARA") == "PARA"
    }

    func picture(_ pic: XMLElement) -> String {
        guard let id = pic.find("img")?.a("binaryItemIDRef"), let rel = imageRel(id) else { return "" }
        let cur = pic.kid("curSz"), sz = pic.kid("sz")
        let w = (cur?.i("width")).flatMap { $0 > 0 ? $0 : nil } ?? sz?.i("width") ?? 7200
        let h = (cur?.i("height")).flatMap { $0 > 0 ? $0 : nil } ?? sz?.i("height") ?? 7200
        let cx = max(1, w) * 127, cy = max(1, h) * 127
        docPrID += 1
        let n = docPrID
        var crop = ""
        if let clip = pic.kid("imgClip"), let dim = pic.kid("imgDim"), let dw = dim.i("dimwidth"), let dh = dim.i("dimheight"), dw > 0, dh > 0 {
            let l = (clip.i("left") ?? 0) * 100000 / dw, r = (dw - (clip.i("right") ?? dw)) * 100000 / dw
            let t = (clip.i("top") ?? 0) * 100000 / dh, b = (dh - (clip.i("bottom") ?? dh)) * 100000 / dh
            if [l, r, t, b].contains(where: { $0 > 500 }) { crop = "<a:srcRect l=\"\(max(0, l))\" t=\"\(max(0, t))\" r=\"\(max(0, r))\" b=\"\(max(0, b))\"/>" }
        }
        let graphic = "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(n)\" name=\"그림 \(n)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(rel)\"/>\(crop)<a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>"
        if isInline(pic) {
            return "<w:r><w:drawing><wp:inline distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\"><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:docPr id=\"\(n)\" name=\"그림 \(n)\"/><wp:cNvGraphicFramePr/>\(graphic)</wp:inline></w:drawing></w:r>"
        }
        let p = pic.kid("pos")!
        let hRel = ["PAPER": "page", "PAGE": "margin", "COLUMN": "column", "PARA": "column"][p.a("horzRelTo") ?? ""] ?? "column"
        let vRel = ["PAPER": "page", "PAGE": "margin", "PARA": "paragraph"][p.a("vertRelTo") ?? ""] ?? "paragraph"
        func place(_ align: String?, _ offset: Int, _ map: [String: String]) -> String {
            if let al = align, let v = map[al], offset == 0 { return "<wp:align>\(v)</wp:align>" }
            return "<wp:posOffset>\(offset * 127)</wp:posOffset>"
        }
        let ph = place(p.a("horzAlign"), p.i("horzOffset") ?? 0, ["CENTER": "center", "RIGHT": "right", "INSIDE": "inside", "OUTSIDE": "outside"])
        let pv = place(p.a("vertAlign"), p.i("vertOffset") ?? 0, ["CENTER": "center", "BOTTOM": "bottom"])
        var behind = "0", wrap = "<wp:wrapTopAndBottom/>"
        switch pic.a("textWrap") ?? "TOP_AND_BOTTOM" {
        case "SQUARE", "TIGHT", "THROUGH": wrap = "<wp:wrapSquare wrapText=\"bothSides\"/>"
        case "BEHIND_TEXT": wrap = "<wp:wrapNone/>"; behind = "1"
        case "IN_FRONT_OF_TEXT": wrap = "<wp:wrapNone/>"
        default: break
        }
        let z = 251659264 + (pic.i("zOrder") ?? n)
        return "<w:r><w:drawing><wp:anchor distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\" simplePos=\"0\" relativeHeight=\"\(z)\" behindDoc=\"\(behind)\" locked=\"0\" layoutInCell=\"1\" allowOverlap=\"1\"><wp:simplePos x=\"0\" y=\"0\"/><wp:positionH relativeFrom=\"\(hRel)\">\(ph)</wp:positionH><wp:positionV relativeFrom=\"\(vRel)\">\(pv)</wp:positionV><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/>\(wrap)<wp:docPr id=\"\(n)\" name=\"그림 \(n)\"/><wp:cNvGraphicFramePr/>\(graphic)</wp:anchor></w:drawing></w:r>"
    }

    /// 쪽 배경 그림: 종이 기준 위치·크기로 글 뒤에 깐다.
    func backgroundRun(_ bg: (item: String, x: Int, y: Int, w: Int, h: Int)) -> String? {
        guard bg.w > 0, bg.h > 0, let rel = imageRel(bg.item) else { return nil }
        docPrID += 1
        let n = docPrID, cx = bg.w * 127, cy = bg.h * 127
        let graphic = "<a:graphic><a:graphicData uri=\"http://schemas.openxmlformats.org/drawingml/2006/picture\"><pic:pic><pic:nvPicPr><pic:cNvPr id=\"\(n)\" name=\"쪽 배경 \(n)\"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed=\"\(rel)\"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic>"
        return "<w:r><w:drawing><wp:anchor distT=\"0\" distB=\"0\" distL=\"0\" distR=\"0\" simplePos=\"0\" relativeHeight=\"251658240\" behindDoc=\"1\" locked=\"1\" layoutInCell=\"0\" allowOverlap=\"1\"><wp:simplePos x=\"0\" y=\"0\"/><wp:positionH relativeFrom=\"page\"><wp:posOffset>\(bg.x * 127)</wp:posOffset></wp:positionH><wp:positionV relativeFrom=\"page\"><wp:posOffset>\(bg.y * 127)</wp:posOffset></wp:positionV><wp:extent cx=\"\(cx)\" cy=\"\(cy)\"/><wp:effectExtent l=\"0\" t=\"0\" r=\"0\" b=\"0\"/><wp:wrapNone/><wp:docPr id=\"\(n)\" name=\"쪽 배경 \(n)\"/><wp:cNvGraphicFramePr/>\(graphic)</wp:anchor></w:drawing></w:r>"
    }

    // MARK: 문서 부속

    func stylesXML() -> String {
        let base = charPr["0"]
        let fr = base?.kid("fontRef")
        let han = docFont(fr.flatMap { f in f.a("hangul").flatMap { fonts["HANGUL"]?[$0] } } ?? "맑은 고딕")
        let lat = docFont(fr.flatMap { f in f.a("latin").flatMap { fonts["LATIN"]?[$0] } } ?? han)
        usedFonts.insert(han); usedFonts.insert(lat)
        let sz = max(2, (base?.i("height") ?? 1000) / 50)
        return "<w:styles xmlns:w=\"\(Self.W)\"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"\(esc(lat))\" w:hAnsi=\"\(esc(lat))\" w:eastAsia=\"\(esc(han))\" w:cs=\"\(esc(lat))\"/><w:sz w:val=\"\(sz)\"/><w:szCs w:val=\"\(sz)\"/><w:lang w:val=\"en-US\" w:eastAsia=\"ko-KR\" w:bidi=\"ar-SA\"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:autoSpaceDE w:val=\"0\"/><w:autoSpaceDN w:val=\"0\"/><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
            + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"a\"><w:name w:val=\"Normal\"/><w:qFormat/></w:style>"
            + "<w:style w:type=\"character\" w:default=\"1\" w:styleId=\"a0\"><w:name w:val=\"Default Paragraph Font\"/><w:uiPriority w:val=\"1\"/><w:semiHidden/></w:style>"
            + "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"a1\"><w:name w:val=\"Normal Table\"/><w:uiPriority w:val=\"99\"/><w:semiHidden/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
            + "</w:styles>"
    }

    func settingsXML() -> String {
        var s = "<w:settings xmlns:w=\"\(Self.W)\"><w:defaultTabStop w:val=\"800\"/><w:characterSpacingControl w:val=\"doNotCompress\"/>"
        if !footnotes.isEmpty { s += "<w:footnotePr><w:footnote w:id=\"-1\"/><w:footnote w:id=\"0\"/></w:footnotePr>" }
        if !endnotes.isEmpty { s += "<w:endnotePr><w:endnote w:id=\"-1\"/><w:endnote w:id=\"0\"/></w:endnotePr>" }
        return s + "<w:compat><w:doNotExpandShiftReturn/><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>"
    }

    /// 한글 전용 글꼴(함초롬·HY·한컴 등)이 없는 PC 에서도 Word 가 한글 글꼴로 바꿔 쓰도록 문자집합(81=한글)과 대체 이름을 적는다.
    func fontTableXML() -> String {
        var s = "<w:fonts xmlns:w=\"\(Self.W)\">"
        for f in usedFonts.sorted() {
            let korean = f.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }
                || f.hasPrefix("HY") || f.hasPrefix("Hancom") || f.hasPrefix("Ham")
            if korean {
                let serif = ["바탕", "명조", "궁서", "Batang", "Myeongjo", "신명"].contains { f.contains($0) }
                s += "<w:font w:name=\"\(esc(f))\"><w:altName w:val=\"\(serif ? "바탕" : "맑은 고딕")\"/><w:charset w:val=\"81\"/><w:family w:val=\"\(serif ? "roman" : "swiss")\"/><w:pitch w:val=\"variable\"/></w:font>"
            } else {
                s += "<w:font w:name=\"\(esc(f))\"><w:charset w:val=\"00\"/><w:family w:val=\"auto\"/><w:pitch w:val=\"variable\"/></w:font>"
            }
        }
        return s + "</w:fonts>"
    }

    func contentTypes() -> String {
        var s = "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        let media = ["png": "image/png", "jpg": "image/jpeg", "gif": "image/gif", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff", "wmf": "image/x-wmf", "emf": "image/x-emf"]
        let used = Set(parts.keys.filter { $0.hasPrefix("word/media/") }.map { ($0 as NSString).pathExtension })
        for ext in used.sorted() { if let ct = media[ext] { s += "<Default Extension=\"\(ext)\" ContentType=\"\(ct)\"/>" } }
        let ov = "application/vnd.openxmlformats-officedocument.wordprocessingml."
        s += "<Override PartName=\"/word/document.xml\" ContentType=\"\(ov)document.main+xml\"/>"
        s += "<Override PartName=\"/word/styles.xml\" ContentType=\"\(ov)styles+xml\"/>"
        s += "<Override PartName=\"/word/settings.xml\" ContentType=\"\(ov)settings+xml\"/>"
        s += "<Override PartName=\"/word/fontTable.xml\" ContentType=\"\(ov)fontTable+xml\"/>"
        if parts["word/footnotes.xml"] != nil { s += "<Override PartName=\"/word/footnotes.xml\" ContentType=\"\(ov)footnotes+xml\"/>" }
        if parts["word/endnotes.xml"] != nil { s += "<Override PartName=\"/word/endnotes.xml\" ContentType=\"\(ov)endnotes+xml\"/>" }
        for p in parts.keys.sorted() where p.hasPrefix("word/header") || p.hasPrefix("word/footer") {
            s += "<Override PartName=\"/\(p)\" ContentType=\"\(ov)\(p.hasPrefix("word/header") ? "header" : "footer")+xml\"/>"
        }
        return s + "</Types>"
    }

    // MARK: 단위·문자

    /// HWPUNIT(1/7200 인치) → twip(1/1440 인치)
    func tw(_ v: Int) -> Int { Int((Double(v) / 5).rounded()) }

    func hex(_ v: String) -> String? {
        var s = v.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 8 { s = String(s.suffix(6)) }   // #AARRGGBB
        guard s.count == 6, s.allSatisfy(\.isHexDigit) else { return nil }
        return s.uppercased()
    }

    /// 한글은 Wingdings 기호를 사용자 영역 글자(U+F000+코드)로, 한컴 전용 기호를 U+F0000 대 글자로 저장한다.
    /// 맥·Word 글꼴엔 그 글자가 없어 빈칸·두부로 나오므로 표준 글자로 바꾼다.
    /// 표는 rhwp `map_pua_bullet_char`(MIT, © Edward Kim — src/renderer/layout/paragraph_layout.rs)를 옮긴 것.
    static let puaMap: [UInt32: UInt32] = [
        0xF003B: 0x2193, 0xF02EF: 0x00B7, 0xF0854: 0x300A, 0xF0855: 0x300B, 0xF00DA: 0x25B8,
        0xF080F: 0x2501, 0xF0811: 0x250C, 0xF0817: 0x2514, 0xF081A: 0x2500, 0xF0827: 0x2550,
        0xF06C: 0x25CF, 0xF06D: 0x25CF, 0xF06E: 0x25A0, 0xF06F: 0x25A1, 0xF070: 0x25A1, 0xF071: 0x25A1, 0xF072: 0x25A1,
        0xF073: 0x2B27, 0xF074: 0x29EB, 0xF075: 0x25C6, 0xF076: 0x2756, 0xF077: 0x2B25,
        0xF09E: 0x00B7, 0xF09F: 0x2022, 0xF0A0: 0x00B7, 0xF0A1: 0x26AA, 0xF0A2: 0x25CB, 0xF0A3: 0x25CB, 0xF0A4: 0x25C9,
        0xF0A5: 0x25CE, 0xF0A7: 0x25AA, 0xF0A8: 0x25FB, 0xF0AA: 0x2726, 0xF0AB: 0x2605, 0xF0AC: 0x2736, 0xF0AD: 0x2734, 0xF0AE: 0x2739,
        0xF045: 0x261C, 0xF046: 0x261E, 0xF047: 0x261D, 0xF048: 0x261F,
        0xF0FB: 0x2717, 0xF0FC: 0x2714, 0xF0FD: 0x2612, 0xF0FE: 0x2611,
        0xF0E8: 0x2794, 0xF0EF: 0x21E6, 0xF0F0: 0x21E8, 0xF0F1: 0x21E7, 0xF0F2: 0x21E9,
        0xF022: 0x2702, 0xF036: 0x231B, 0xF04A: 0x263A, 0xF04E: 0x2620, 0xF052: 0x263C, 0xF054: 0x2744, 0xF058: 0x2720, 0xF059: 0x2721,
    ]
    static func mapPUA(_ u: Unicode.Scalar) -> Unicode.Scalar {
        guard u.value >= 0xF000, let m = puaMap[u.value], let r = Unicode.Scalar(m) else { return u }
        return r
    }

    func esc(_ s: String) -> String {
        var o = ""
        o.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": o += "&amp;"
            case "<": o += "&lt;"
            case ">": o += "&gt;"
            case "\"": o += "&quot;"
            case "\u{E8E8}": o += " "
            default:
                let v = u.value
                if v < 0x20 && v != 0x9 && v != 0xA && v != 0xD { continue }
                if v == 0xFFFE || v == 0xFFFF { continue }
                let m = Self.mapPUA(u)
                o.unicodeScalars.append(m)
                // 바꾼 기호가 컬러 이모지 글꼴로 그려지지 않게 글자 모양 선택자(VS15)를 붙인다
                if m != u, (0x2600...0x27BF).contains(m.value) || (0x2B00...0x2BFF).contains(m.value) || m.value == 0x231B { o += "\u{FE0E}" }
            }
        }
        return o
    }
}
