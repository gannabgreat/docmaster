import Foundation

/// rhwp 가 뽑은 HTML(문단·표)을 docx 로 쓴다.
/// 맥 기본 docx 저장(NSAttributedString → officeOpenXML)은 표를 버려서 한글 양식이 다 풀리기 때문에 직접 만든다.
/// 담는 것: 문단 정렬·줄간격·들여쓰기, 글꼴·크기·굵게·기울임·밑줄·색, 표(셀 병합·배경색·세로 정렬·중첩 표).
/// 그림·글상자 위치는 옮기지 않는다.
enum DocxWriter {
    static let pageWidthTwips = 11906, pageHeightTwips = 16838, marginTwips = 1134   // A4, 여백 20mm

    static func docx(fromHTML html: String) throws -> Data {
        let doc = try XMLDocument(xmlString: html, options: [.documentTidyHTML])
        let body = (try? doc.nodes(forXPath: "//body").first) ?? doc.rootElement()
        var xml = ""
        if let body { xml = blocks(body, inherited: [:], width: pageWidthTwips - marginTwips * 2) }
        if xml.isEmpty { xml = "<w:p/>" }
        return try package(documentXML: wrap(xml))
    }

    // MARK: - 블록

    static func blocks(_ node: XMLNode, inherited: [String: String], width: Int) -> String {
        var out = ""
        var pendingRuns = ""
        func flush() {
            if !pendingRuns.isEmpty { out += "<w:p>\(pendingRuns)</w:p>"; pendingRuns = "" }
        }
        for child in node.children ?? [] {
            if let el = child as? XMLElement, let name = el.name?.lowercased() {
                switch name {
                case "p", "h1", "h2", "h3", "h4", "h5", "h6", "li":
                    flush(); out += paragraph(el, inherited: inherited)
                case "table":
                    flush(); out += table(el, width: width)
                case "div", "section", "article", "tbody", "ul", "ol", "center", "body":
                    flush(); out += blocks(el, inherited: merge(inherited, style(el)), width: width)
                case "br":
                    pendingRuns += "<w:r><w:br/></w:r>"
                case "img", "script", "style", "head", "meta":
                    continue
                default:
                    pendingRuns += runs(el, inherited: inherited)
                }
            } else if child.kind == .text, let t = child.stringValue, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pendingRuns += run(t, inherited)
            }
        }
        flush()
        return out
    }

    static func paragraph(_ el: XMLElement, inherited: [String: String]) -> String {
        let st = merge(inherited, style(el))
        var ppr = ""
        if let a = st["text-align"] {
            let jc = ["center": "center", "right": "right", "justify": "both", "left": "left"][a] ?? "left"
            ppr += "<w:jc w:val=\"\(jc)\"/>"
        }
        var spacing = "w:before=\"0\" w:after=\"0\""
        if let lh = st["line-height"], lh.hasSuffix("%"), let pct = Double(lh.dropLast()) {
            spacing += " w:line=\"\(Int(240 * pct / 100))\" w:lineRule=\"auto\""
        }
        ppr += "<w:spacing \(spacing)/>"
        if let ti = st["text-indent"].flatMap(points) {
            ppr += ti >= 0 ? "<w:ind w:firstLine=\"\(Int(ti * 20))\"/>" : "<w:ind w:hanging=\"\(Int(-ti * 20))\"/>"
        }
        var inner = ""
        for child in el.children ?? [] { inner += runs(child, inherited: st) }
        return "<w:p><w:pPr>\(ppr)</w:pPr>\(inner)</w:p>"
    }

    static func runs(_ node: XMLNode, inherited: [String: String]) -> String {
        if node.kind == .text { return run(node.stringValue ?? "", inherited) }
        guard let el = node as? XMLElement else { return "" }
        switch el.name?.lowercased() {
        case "br": return "<w:r><w:br/></w:r>"
        case "img": return ""
        default:
            var st = merge(inherited, style(el))
            switch el.name?.lowercased() {
            case "b", "strong": st["font-weight"] = "bold"
            case "i", "em": st["font-style"] = "italic"
            case "u": st["text-decoration"] = "underline"
            default: break
            }
            return (el.children ?? []).map { runs($0, inherited: st) }.joined()
        }
    }

    static func run(_ text: String, _ st: [String: String]) -> String {
        guard !text.isEmpty else { return "" }
        var rpr = ""
        if let fam = st["font-family"]?.split(separator: ",").first {
            let f = escape(fam.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")))
            rpr += "<w:rFonts w:ascii=\"\(f)\" w:hAnsi=\"\(f)\" w:eastAsia=\"\(f)\" w:cs=\"\(f)\"/>"
        }
        if let w = st["font-weight"], w == "bold" || (Int(w) ?? 400) >= 600 { rpr += "<w:b/>" }
        if st["font-style"] == "italic" { rpr += "<w:i/>" }
        if st["text-decoration"]?.contains("underline") == true { rpr += "<w:u w:val=\"single\"/>" }
        if st["text-decoration"]?.contains("line-through") == true { rpr += "<w:strike/>" }
        if let c = st["color"].flatMap(hex) { rpr += "<w:color w:val=\"\(c)\"/>" }
        if let pt = st["font-size"].flatMap(points) { rpr += "<w:sz w:val=\"\(Int((pt * 2).rounded()))\"/><w:szCs w:val=\"\(Int((pt * 2).rounded()))\"/>" }
        let t = escape(text.replacingOccurrences(of: "\n", with: " "))
        return "<w:r>\(rpr.isEmpty ? "" : "<w:rPr>\(rpr)</w:rPr>")<w:t xml:space=\"preserve\">\(t)</w:t></w:r>"
    }

    // MARK: - 표

    struct Cell { let el: XMLElement; let row: Int; let col: Int; let colspan: Int; let rowspan: Int }

    static func table(_ tableEl: XMLElement, width: Int) -> String {
        // 이 표의 행만(중첩 표의 행은 빼고)
        let rows = directRows(tableEl)
        guard !rows.isEmpty else { return "" }
        var cells: [Cell] = []
        var occupied = Set<[Int]>()
        var ncols = 0
        for (r, tr) in rows.enumerated() {
            var c = 0
            for td in tr.children?.compactMap({ $0 as? XMLElement }).filter({ ["td", "th"].contains($0.name?.lowercased() ?? "") }) ?? [] {
                while occupied.contains([r, c]) { c += 1 }
                let cs = max(1, Int(td.attribute(forName: "colspan")?.stringValue ?? "") ?? 1)
                let rs = max(1, Int(td.attribute(forName: "rowspan")?.stringValue ?? "") ?? 1)
                cells.append(Cell(el: td, row: r, col: c, colspan: cs, rowspan: rs))
                for dr in 0..<rs { for dc in 0..<cs { occupied.insert([r + dr, c + dc]) } }
                c += cs
                ncols = max(ncols, c)
            }
        }
        guard ncols > 0 else { return "" }
        let colW = max(1, width / ncols)
        var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"\(width)\" w:type=\"dxa\"/><w:tblBorders>"
        for side in ["top", "left", "bottom", "right", "insideH", "insideV"] {
            xml += "<w:\(side) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"808080\"/>"
        }
        xml += "</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblCellMar><w:left w:w=\"85\" w:type=\"dxa\"/><w:right w:w=\"85\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
        xml += String(repeating: "<w:gridCol w:w=\"\(colW)\"/>", count: ncols) + "</w:tblGrid>"

        let nrows = rows.count
        for r in 0..<nrows {
            xml += "<w:tr>"
            var c = 0
            while c < ncols {
                if let cell = cells.first(where: { $0.row == r && $0.col == c }) {
                    xml += tc(cell, colW: colW, merge: cell.rowspan > 1 ? "restart" : nil)
                    c += cell.colspan
                } else if let above = cells.first(where: { $0.col == c && $0.row < r && $0.row + $0.rowspan > r }) {
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(colW * above.colspan)\" w:type=\"dxa\"/>"
                        + (above.colspan > 1 ? "<w:gridSpan w:val=\"\(above.colspan)\"/>" : "")
                        + "<w:vMerge/></w:tcPr><w:p/></w:tc>"
                    c += above.colspan
                } else {
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(colW)\" w:type=\"dxa\"/></w:tcPr><w:p/></w:tc>"
                    c += 1
                }
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl><w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/></w:pPr></w:p>"
    }

    static func tc(_ cell: Cell, colW: Int, merge: String?) -> String {
        let st = style(cell.el)
        var pr = "<w:tcW w:w=\"\(colW * cell.colspan)\" w:type=\"dxa\"/>"
        if cell.colspan > 1 { pr += "<w:gridSpan w:val=\"\(cell.colspan)\"/>" }
        if let merge { pr += "<w:vMerge w:val=\"\(merge)\"/>" }
        if let bg = st["background-color"].flatMap(hex) { pr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(bg)\"/>" }
        if let va = st["vertical-align"] {
            pr += "<w:vAlign w:val=\"\(["middle": "center", "bottom": "bottom"][va] ?? "top")\"/>"
        }
        var content = blocks(cell.el, inherited: [:], width: colW * cell.colspan)
        if !content.hasSuffix("</w:p>") && !content.hasSuffix("<w:p/>") { content += "<w:p/>" }
        return "<w:tc><w:tcPr>\(pr)</w:tcPr>\(content)</w:tc>"
    }

    static func directRows(_ table: XMLElement) -> [XMLElement] {
        var rows: [XMLElement] = []
        for child in table.children?.compactMap({ $0 as? XMLElement }) ?? [] {
            switch child.name?.lowercased() {
            case "tr": rows.append(child)
            case "tbody", "thead", "tfoot": rows += child.children?.compactMap { $0 as? XMLElement }.filter { $0.name?.lowercased() == "tr" } ?? []
            default: break
            }
        }
        return rows
    }

    // MARK: - CSS 조각

    static func style(_ el: XMLElement) -> [String: String] {
        var out: [String: String] = [:]
        for decl in (el.attribute(forName: "style")?.stringValue ?? "").split(separator: ";") {
            let kv = decl.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if kv.count == 2, !kv[0].isEmpty { out[kv[0]] = kv[0] == "font-family" ? decl.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces) : kv[1] }
        }
        return out
    }

    /// 글자 모양만 물려준다(배경·테두리·여백은 그 요소에만).
    static func merge(_ parent: [String: String], _ own: [String: String]) -> [String: String] {
        let inheritable: Set<String> = ["font-family", "font-size", "font-weight", "font-style", "color", "text-align", "line-height", "text-decoration"]
        var out = parent.filter { inheritable.contains($0.key) }
        for (k, v) in own { out[k] = v }
        return out
    }

    static func points(_ v: String) -> Double? {
        let s = v.trimmingCharacters(in: .whitespaces)
        if s.hasSuffix("pt") { return Double(s.dropLast(2)) }
        if s.hasSuffix("px") { return Double(s.dropLast(2)).map { $0 * 0.75 } }
        return Double(s)
    }

    static func hex(_ v: String) -> String? {
        var s = v.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            s.removeFirst()
            if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
            return s.count == 6 ? s.uppercased() : nil
        }
        if s.hasPrefix("rgb") {
            let n = s.components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted).compactMap(Int.init)
            return n.count >= 3 ? String(format: "%02X%02X%02X", n[0], n[1], n[2]) : nil
        }
        return ["black": "000000", "white": "FFFFFF", "red": "FF0000", "blue": "0000FF"][s]
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - 패키지

    static func wrap(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr><w:pgSz w:w="\(pageWidthTwips)" w:h="\(pageHeightTwips)"/><w:pgMar w:top="\(marginTwips)" w:right="\(marginTwips)" w:bottom="\(marginTwips)" w:left="\(marginTwips)" w:header="567" w:footer="567" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
    }

    static func package(documentXML: String) throws -> Data {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("convertly-docx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("word"), withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
        """.write(to: dir.appendingPathComponent("[Content_Types].xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
        """.write(to: dir.appendingPathComponent("_rels/.rels"), atomically: true, encoding: .utf8)
        try documentXML.write(to: dir.appendingPathComponent("word/document.xml"), atomically: true, encoding: .utf8)

        let out = fm.temporaryDirectory.appendingPathComponent("convertly-\(UUID().uuidString).docx")
        defer { try? fm.removeItem(at: out) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir
        zip.arguments = ["-X", "-q", "-nw", "-r", out.path, "[Content_Types].xml", "_rels", "word"]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0, let data = try? Data(contentsOf: out) else {
            throw ConvertError.writeFailed("docx 묶기")
        }
        return data
    }
}
