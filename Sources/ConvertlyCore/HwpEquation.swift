import Foundation

/// 한글 수식 스크립트(hp:equation/hp:script)를 Word 수식(OMML)으로 바꾼다.
/// 지원: { } 묶음, _ ^ 첨자, over, sqrt·root, LEFT/RIGHT 괄호, sum·int 같은 큰 연산자, 그리스 문자·기호 키워드, ` ~ 공백.
/// 모르는 낱말은 글자 그대로 둔다.
public enum HwpEquation {
    public static let ns = "http://schemas.openxmlformats.org/officeDocument/2006/math"

    /// `sizeHalfPt` 는 w:sz 값(반 포인트), `color` 는 RRGGBB.
    public static func omml(_ script: String, sizeHalfPt: Int? = nil, color: String? = nil) -> String {
        var p = Parser(tokens: tokenize(script))
        p.rpr = "<w:rPr><w:rFonts w:ascii=\"Cambria Math\" w:hAnsi=\"Cambria Math\"/>"
            + (color.map { "<w:color w:val=\"\($0)\"/>" } ?? "")
            + (sizeHalfPt.map { "<w:sz w:val=\"\($0)\"/><w:szCs w:val=\"\($0)\"/>" } ?? "")
            + "</w:rPr>"
        let body = p.parseSeq(until: [])
        return "<m:oMath>\(body)</m:oMath>"
    }

    // MARK: 낱말 표

    static let greek: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ",
        "omicron": "ο", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ",
        "chi": "χ", "psi": "ψ", "omega": "ω",
        "ALPHA": "Α", "BETA": "Β", "GAMMA": "Γ", "DELTA": "Δ", "EPSILON": "Ε", "ZETA": "Ζ", "ETA": "Η",
        "THETA": "Θ", "IOTA": "Ι", "KAPPA": "Κ", "LAMBDA": "Λ", "MU": "Μ", "NU": "Ν", "XI": "Ξ",
        "OMICRON": "Ο", "PI": "Π", "RHO": "Ρ", "SIGMA": "Σ", "TAU": "Τ", "UPSILON": "Υ", "PHI": "Φ",
        "CHI": "Χ", "PSI": "Ψ", "OMEGA": "Ω",
    ]

    /// 대소문자 구분 없이 찾는 기호.
    static let symbols: [String: String] = [
        "bullet": "∙", "cdot": "·", "times": "×", "div": "÷", "pm": "±", "mp": "∓",
        "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "sim": "∼",
        "simeq": "≃", "equiv": "≡", "cong": "≅", "propto": "∝", "doteq": "≐",
        "<<": "≪", ">>": "≫", "ll": "≪", "gg": "≫",
        "rarrow": "→", "larrow": "←", "uparrow": "↑", "downarrow": "↓", "lrarrow": "↔",
        "rightarrow": "→", "leftarrow": "←", "drarrow": "⇒", "dlarrow": "⇐", "dlrarrow": "⇔",
        "->": "→", "<-": "←", "=>": "⇒",
        "inf": "∞", "infinity": "∞", "partial": "∂", "nabla": "∇", "therefore": "∴", "because": "∵",
        "forall": "∀", "exist": "∃", "exists": "∃", "in": "∈", "notin": "∉", "ni": "∋", "owns": "∋",
        "subset": "⊂", "supset": "⊃", "subseteq": "⊆", "supseteq": "⊇", "cup": "∪", "cap": "∩",
        "emptyset": "∅", "angle": "∠", "deg": "°", "prime": "′", "cdots": "⋯", "ldots": "…",
        "vdots": "⋮", "ddots": "⋱", "circ": "∘", "bigcirc": "◯", "star": "⋆", "dagger": "†",
        "perp": "⊥", "vert": "|", "and": "∧", "or": "∨", "not": "¬", "neg": "¬", "hbar": "ℏ",
        "triangle": "△", "dline": "‖", "aleph": "ℵ", "wp": "℘", "imag": "ℑ", "real": "ℜ",
    ]

    static let nary: [String: String] = [
        "sum": "∑", "prod": "∏", "coprod": "∐", "int": "∫", "dint": "∬", "tint": "∭",
        "oint": "∮", "odint": "∯", "otint": "∰", "bigcup": "⋃", "bigcap": "⋂",
    ]

    static let funcs: Set<String> = [
        "sin", "cos", "tan", "cot", "sec", "csc", "sinh", "cosh", "tanh", "coth", "arcsin", "arccos",
        "arctan", "log", "ln", "lg", "exp", "lim", "max", "min", "det", "mod", "gcd", "sup", "inf",
    ]

    static let fontWords: Set<String> = ["rm", "it", "bold", "bf"]

    // MARK: 낱말 나누기

    enum Tok: Equatable { case open, close, sub, sup, space(String), word(String), num(String), ch(String) }

    static func tokenize(_ s: String) -> [Tok] {
        var out: [Tok] = []
        let cs = Array(s)
        var i = 0
        func isLatin(_ c: Character) -> Bool { c.isASCII && c.isLetter }
        while i < cs.count {
            let c = cs[i]
            switch c {
            case "{": out.append(.open); i += 1
            case "}": out.append(.close); i += 1
            case "_": out.append(.sub); i += 1
            case "^": out.append(.sup); i += 1
            case "`": out.append(.space("\u{2005}")); i += 1
            case "~": out.append(.space(" ")); i += 1
            case " ", "\t", "\n", "\r": i += 1
            case "\"":
                var j = i + 1; var t = ""
                while j < cs.count, cs[j] != "\"" { t.append(cs[j]); j += 1 }
                out.append(.word("\"" + t)); i = j + 1
            default:
                if isLatin(c) {
                    var j = i; var t = ""
                    while j < cs.count, isLatin(cs[j]) { t.append(cs[j]); j += 1 }
                    out.append(.word(t)); i = j
                } else if c.isASCII && c.isNumber || (c == "." && i + 1 < cs.count && cs[i + 1].isNumber) {
                    var j = i; var t = ""
                    while j < cs.count, cs[j].isASCII && cs[j].isNumber || cs[j] == "." { t.append(cs[j]); j += 1 }
                    out.append(.num(t)); i = j
                } else if i + 1 < cs.count, ["<<", ">>", "->", "<-", "=>", "<=", ">=", "!="].contains(String([c, cs[i + 1]])) {
                    let t = String([c, cs[i + 1]])
                    let m = ["<=": "≤", ">=": "≥", "!=": "≠"][t] ?? symbols[t] ?? t
                    out.append(.ch(m)); i += 2
                } else if !c.isASCII && !(c.unicodeScalars.first.map { $0.value >= 0x370 && $0.value < 0x3FF } ?? false) && c.isLetter {
                    // 한글 등 — 이어진 글자를 한 덩어리로
                    var j = i; var t = ""
                    while j < cs.count, !cs[j].isASCII, cs[j].isLetter { t.append(cs[j]); j += 1 }
                    out.append(.word("\"" + t)); i = j
                } else {
                    out.append(.ch(String(c))); i += 1
                }
            }
        }
        return out
    }

    // MARK: 파서

    struct Parser {
        var tokens: [Tok]
        var i = 0
        var rpr = ""
        var style = "i"   // rm 이면 p

        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func run(_ t: String, plain: Bool = false) -> String {
            let sty = plain || style == "p" ? "<m:rPr><m:sty m:val=\"p\"/></m:rPr>" : ""
            return "<m:r>\(sty)\(rpr)<m:t xml:space=\"preserve\">\(esc(t))</m:t></m:r>"
        }
        var peek: Tok? { i < tokens.count ? tokens[i] : nil }

        func peekWord(_ w: String) -> Bool {
            if case .word(let x)? = peek { return x.lowercased() == w }
            return false
        }

        /// 끝 낱말(RIGHT, `}` 등)이 나올 때까지 이어 읽는다. `over` 는 앞뒤 덩어리로 분수를 만든다.
        mutating func parseSeq(until stops: Set<String>) -> String {
            var items: [String] = []
            while let t = peek {
                if t == .close { if stops.contains("}") { break }; i += 1; continue }
                if case .word(let w) = t, stops.contains(w.uppercased()) { break }
                if case .word(let w) = t, w.lowercased() == "over" || w.lowercased() == "atop" {
                    i += 1
                    let num = items.popLast() ?? ""
                    let den = parseScripted()
                    let bar = w.lowercased() == "atop" ? "<m:fPr><m:type m:val=\"noBar\"/></m:fPr>" : ""
                    items.append("<m:f>\(bar)<m:num>\(num)</m:num><m:den>\(den)</m:den></m:f>")
                    continue
                }
                items.append(parseScripted())
            }
            return items.joined()
        }

        /// 덩어리 하나 + 뒤따르는 _ ^.
        mutating func parseScripted() -> String {
            // 큰 연산자: sum_{a}^{b} 본문
            if case .word(let w)? = peek, let op = HwpEquation.nary[w.lowercased()] {
                i += 1
                var sub = "", sup = ""
                while let t = peek, t == .sub || t == .sup {
                    i += 1
                    let a = parseAtom()
                    if t == .sub { sub = a } else { sup = a }
                }
                let body = parseScripted()
                let lim = op == "∑" || op == "∏" || op == "∐" || op == "⋃" || op == "⋂" ? "undOvr" : "subSup"
                let hide = (sub.isEmpty ? "<m:subHide m:val=\"1\"/>" : "") + (sup.isEmpty ? "<m:supHide m:val=\"1\"/>" : "")
                return "<m:nary><m:naryPr><m:chr m:val=\"\(op)\"/><m:limLoc m:val=\"\(lim)\"/>\(hide)</m:naryPr><m:sub>\(sub)</m:sub><m:sup>\(sup)</m:sup><m:e>\(body)</m:e></m:nary>"
            }
            let base = parseAtom()
            var sub: String?, sup: String?
            while let t = peek, t == .sub || t == .sup {
                i += 1
                let a = parseAtom()
                if t == .sub { sub = a } else { sup = a }
            }
            switch (sub, sup) {
            case let (s?, p?): return "<m:sSubSup><m:e>\(base)</m:e><m:sub>\(s)</m:sub><m:sup>\(p)</m:sup></m:sSubSup>"
            case let (s?, nil): return "<m:sSub><m:e>\(base)</m:e><m:sub>\(s)</m:sub></m:sSub>"
            case let (nil, p?): return "<m:sSup><m:e>\(base)</m:e><m:sup>\(p)</m:sup></m:sSup>"
            default: return base
            }
        }

        mutating func parseAtom() -> String {
            guard let t = peek else { return "" }
            i += 1
            switch t {
            case .open:
                let inner = parseSeq(until: ["}"])
                if peek == .close { i += 1 }
                return inner
            case .close: return ""
            case .sub, .sup: return ""
            case .space(let s): return run(s, plain: true)
            case .num(let n): return run(n, plain: true)
            case .ch(let c): return run(c, plain: true)
            case .word(let w):
                if w.hasPrefix("\"") { return run(String(w.dropFirst()), plain: true) }
                let lw = w.lowercased()
                if HwpEquation.fontWords.contains(lw) {
                    let saved = style
                    style = lw == "rm" ? "p" : "i"
                    let a = parseScripted()
                    style = saved
                    return a
                }
                if lw == "sqrt" {
                    return "<m:rad><m:radPr><m:degHide m:val=\"1\"/></m:radPr><m:deg/><m:e>\(parseAtom())</m:e></m:rad>"
                }
                if lw == "root" {
                    let deg = parseAtom()
                    if peekWord("of") { i += 1 }
                    return "<m:rad><m:deg>\(deg)</m:deg><m:e>\(parseAtom())</m:e></m:rad>"
                }
                if lw == "left" {
                    let l = delim()
                    let inner = parseSeq(until: ["RIGHT"])
                    var r = ""
                    if peekWord("right") { i += 1; r = delim() }
                    return "<m:d><m:dPr><m:begChr m:val=\"\(esc(l))\"/><m:endChr m:val=\"\(esc(r))\"/></m:dPr><m:e>\(inner)</m:e></m:d>"
                }
                if ["bar", "hat", "vec", "dot", "ddot", "tilde", "under", "overline"].contains(lw) {
                    let a = parseAtom()
                    if lw == "bar" || lw == "overline" { return "<m:bar><m:barPr><m:pos m:val=\"top\"/></m:barPr><m:e>\(a)</m:e></m:bar>" }
                    if lw == "under" { return "<m:bar><m:barPr><m:pos m:val=\"bot\"/></m:barPr><m:e>\(a)</m:e></m:bar>" }
                    let chr = ["hat": "\u{302}", "vec": "\u{20D7}", "dot": "\u{307}", "ddot": "\u{308}", "tilde": "\u{303}"][lw]!
                    return "<m:acc><m:accPr><m:chr m:val=\"\(chr)\"/></m:accPr><m:e>\(a)</m:e></m:acc>"
                }
                if let g = HwpEquation.greek[w] ?? HwpEquation.greek[lw] { return run(g) }
                if let s = HwpEquation.symbols[lw] { return run(s, plain: true) }
                if HwpEquation.funcs.contains(lw) { return run(w, plain: true) }
                return run(w)
            }
        }

        mutating func delim() -> String {
            guard let t = peek else { return "" }
            i += 1
            switch t {
            case .ch(let c): return c
            case .open: return "{"
            case .close: return "}"
            case .word(let w):
                switch w.lowercased() {
                case "lbrace": return "{"
                case "rbrace": return "}"
                case "langle": return "⟨"
                case "rangle": return "⟩"
                case "vert": return "|"
                case "dline": return "‖"
                default: return ""
                }
            default: return ""
            }
        }
    }
}
