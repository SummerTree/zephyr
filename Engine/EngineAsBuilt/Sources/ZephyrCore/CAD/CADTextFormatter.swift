import Foundation

// =========================================================================
// MARK: - CADTextFormatter
//
// Handles AutoCAD-style MText layout: word wrapping at a maximum width,
// underline ranges (%%u...%%u), and special character codes (%%c=diameter,
// %%d=degree, %%p=plus/minus).
//
// Used by the engine's text rendering pipeline to break long text into
// lines and generate underline primitives for %%u spans.

public enum CADTextFormatter {
    public struct Glyph: Sendable {
        public let text: String
        public let underline: Bool
        public let bold: Bool
        public let italic: Bool

        public init(
            _ text: String,
            underline: Bool,
            bold: Bool = false,
            italic: Bool = false
        ) {
            self.text = text
            self.underline = underline
            self.bold = bold
            self.italic = italic
        }
    }

    public struct Line: Sendable {
        public let glyphs: [Glyph]

        public var text: String {
            glyphs.map { $0.text }.joined()
        }

        public var isEmpty: Bool {
            glyphs.isEmpty || text.isEmpty
        }
    }

    public static func layout(
        formatted: FormattedText,
        maxWidth: Double?,
        measure: (String) -> Double
    ) -> [Line] {
        let paragraphs = formatted.paragraphs.map { paragraph in
            paragraph.runs.flatMap { run -> [Glyph] in
                let value: String
                if let stack = run.stack {
                    value = "\(stack.numerator)/\(stack.denominator)"
                } else {
                    value = run.text
                }
                return value.map {
                    Glyph(
                        String($0),
                        underline: run.underline,
                        bold: run.bold,
                        italic: run.italic)
                }
            }
        }
        return layoutParagraphs(paragraphs, maxWidth: maxWidth, measure: measure)
    }

    public static func layout(
        _ raw: String,
        maxWidth: Double?,
        measure: (String) -> Double
    ) -> [Line] {
        layoutParagraphs(parse(raw), maxWidth: maxWidth, measure: measure)
    }

    private static func layoutParagraphs(
        _ paragraphs: [[Glyph]],
        maxWidth: Double?,
        measure: (String) -> Double
    ) -> [Line] {
        guard let maxWidth, maxWidth > 0 else {
            return paragraphs.map { Line(glyphs: $0) }
        }

        var lines: [Line] = []

        for paragraph in paragraphs {
            let words = splitWords(paragraph)

            if words.isEmpty {
                lines.append(Line(glyphs: []))
                continue
            }

            var current: [Glyph] = []

            for word in words {
                let candidate: [Glyph]
                if current.isEmpty {
                    candidate = word
                } else {
                    let left = current.last
                    let right = word.first
                    let separator = Glyph(
                        " ",
                        underline: left?.underline == true && right?.underline == true,
                        bold: left?.bold == true && right?.bold == true,
                        italic: left?.italic == true && right?.italic == true)
                    candidate = current + [separator] + word
                }

                if !current.isEmpty && measure(string(from: candidate)) > maxWidth {
                    lines.append(Line(glyphs: current))
                    current = word
                } else {
                    current = candidate
                }
            }

            if !current.isEmpty {
                lines.append(Line(glyphs: current))
            }
        }

        return lines.isEmpty ? [Line(glyphs: [])] : lines
    }

    public static func underlineRanges(
        for line: Line,
        measure: (String) -> Double
    ) -> [(x: Double, width: Double)] {
        var ranges: [(x: Double, width: Double)] = []
        var x = 0.0
        var start: Double?

        for glyph in line.glyphs {
            let w = measure(glyph.text)

            if glyph.underline {
                if start == nil { start = x }
            } else if let s = start {
                if x > s { ranges.append((s, x - s)) }
                start = nil
            }

            x += w
        }

        if let s = start, x > s {
            ranges.append((s, x - s))
        }

        return ranges
    }

    private static func parse(_ raw: String) -> [[Glyph]] {
        let chars = Array(raw)
        var paragraphs: [[Glyph]] = [[]]
        var underline = false
        var i = 0

        func add(_ s: String) {
            paragraphs[paragraphs.count - 1].append(Glyph(s, underline: underline))
        }

        func newline() {
            paragraphs.append([])
        }

        func skipToSemicolon() {
            while i < chars.count && chars[i] != ";" {
                i += 1
            }
            if i < chars.count && chars[i] == ";" {
                i += 1
            }
        }

        while i < chars.count {
            let c = chars[i]

            if c == "%", i + 2 < chars.count, chars[i + 1] == "%" {
                let code = String(chars[i + 2]).lowercased()

                switch code {
                case "u":
                    underline.toggle()
                    i += 3
                    continue
                case "d":
                    add("°")
                    i += 3
                    continue
                case "p":
                    add("±")
                    i += 3
                    continue
                case "c":
                    add("Ø")
                    i += 3
                    continue
                case "%":
                    add("%")
                    i += 3
                    continue
                default:
                    add(String(c))
                    i += 1
                    continue
                }
            }

            if c == "\\" || c == "¥" {
                guard i + 1 < chars.count else {
                    i += 1
                    continue
                }

                let next = chars[i + 1]

                switch next {
                case "P":
                    newline()
                    i += 2
                    continue
                case "p":
                    i += 2
                    skipToSemicolon()
                    continue
                case "L":
                    underline = true
                    i += 2
                    continue
                case "l":
                    underline = false
                    i += 2
                    continue
                case "O", "o", "K", "k":
                    i += 2
                    continue
                case "\\", "{", "}":
                    add(String(next))
                    i += 2
                    continue
                case "F", "f", "H", "h", "W", "w", "Q", "q", "T", "t", "A", "a", "C", "c":
                    i += 2
                    skipToSemicolon()
                    continue
                case "S":
                    i += 2
                    var top = ""
                    var bottom = ""
                    var isBottom = false

                    while i < chars.count && chars[i] != ";" {
                        if chars[i] == "^" || chars[i] == "/" || chars[i] == "#" {
                            isBottom = true
                        } else if isBottom {
                            bottom.append(chars[i])
                        } else {
                            top.append(chars[i])
                        }
                        i += 1
                    }

                    if i < chars.count && chars[i] == ";" {
                        i += 1
                    }

                    if !top.isEmpty && !bottom.isEmpty {
                        add("\(top)/\(bottom)")
                    } else {
                        add(top + bottom)
                    }
                    continue
                default:
                    add(String(next))
                    i += 2
                    continue
                }
            }

            if c == "{" || c == "}" {
                i += 1
                continue
            }

            if c == "\n" || c == "\r" {
                newline()
                i += 1
                continue
            }

            add(String(c))
            i += 1
        }

        return paragraphs
    }

    private static func splitWords(_ glyphs: [Glyph]) -> [[Glyph]] {
        var words: [[Glyph]] = []
        var current: [Glyph] = []

        for glyph in glyphs {
            if glyph.text == " " || glyph.text == "\t" {
                if !current.isEmpty {
                    words.append(current)
                    current.removeAll()
                }
            } else {
                current.append(glyph)
            }
        }

        if !current.isEmpty {
            words.append(current)
        }

        return words
    }

    private static func string(from glyphs: [Glyph]) -> String {
        glyphs.map { $0.text }.joined()
    }
}