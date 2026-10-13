import AppKit

extension NSAttributedString.Key {
    /// Destination of a markdown link or autolink, opened with ⌘-click or ⌘⏎.
    static let mdLink = NSAttributedString.Key("md.link")
    /// Target of a `[[wikilink]]`.
    static let mdWikilink = NSAttributedString.Key("md.wikilink")
    /// Path of a content block line (an embedded file reference).
    static let mdContentBlock = NSAttributedString.Key("md.contentBlock")
    /// Author of a run of text; value is an `Author` id. Survives restyling.
    static let mdAuthor = NSAttributedString.Key("md.author")
}

/// What the styler needs to know about the current editor settings. Fonts are resolved once here,
/// not on every line: font lookups are slow.
struct EditorStyle: Equatable {
    let typeface: Typeface
    let size: CGFloat
    let highlight: HighlightColor
    let completedTasks: CompletedTaskStyle
    /// Space left of the text column where heading and quote markers hang.
    let gutter: CGFloat
    let body: NSFont
    let bold: NSFont
    let italic: NSFont
    let boldItalic: NSFont
    let code: NSFont
    let lineHeight: CGFloat
    let baselineOffset: CGFloat
    /// Width of one monospaced character: the unit for line length.
    let characterWidth: CGFloat
    let baseAttributes: [NSAttributedString.Key: Any]

    init(typeface: Typeface = .duo, size: CGFloat = 17, highlight: HighlightColor = .yellow,
         completedTasks: CompletedTaskStyle = .both, gutter: CGFloat = 0) {
        self.typeface = typeface
        self.size = size
        self.highlight = highlight
        self.completedTasks = completedTasks
        self.gutter = gutter
        body = Theme.font(typeface, size: size)
        bold = Theme.font(typeface, size: size, bold: true)
        italic = Theme.font(typeface, size: size, italic: true)
        boldItalic = Theme.font(typeface, size: size, bold: true, italic: true)
        code = Theme.codeFont(size: size)
        lineHeight = Theme.lineHeight(size: size)
        characterWidth = Theme.characterWidth(size: size)
        // Centers glyphs vertically in the fixed line height.
        baselineOffset = ((lineHeight - (body.ascender - body.descender)) / 2 - 1).rounded()
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.firstLineHeadIndent = gutter
        paragraph.headIndent = gutter
        paragraph.tailIndent = -gutter
        baseAttributes = [.font: body, .foregroundColor: Theme.text, .paragraphStyle: paragraph, .baselineOffset: baselineOffset]
    }

    static func current(_ prefs: Preferences = .shared) -> EditorStyle {
        EditorStyle(typeface: prefs.typeface, size: CGFloat(prefs.textSize), highlight: prefs.highlightColor,
                    completedTasks: prefs.completedTasks,
                    gutter: Theme.characterWidth(size: CGFloat(prefs.textSize)) * 5)
    }

    static func == (a: EditorStyle, b: EditorStyle) -> Bool {
        a.typeface == b.typeface && a.size == b.size && a.highlight == b.highlight
            && a.completedTasks == b.completedTasks && a.gutter == b.gutter
    }

    func font(bold isBold: Bool, italic isItalic: Bool) -> NSFont {
        switch (isBold, isItalic) {
        case (true, true): boldItalic
        case (true, false): bold
        case (false, true): italic
        case (false, false): body
        }
    }

    func paragraph(first: CGFloat? = nil, head: CGFloat? = nil) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.firstLineHeadIndent = first ?? gutter
        style.headIndent = head ?? gutter
        style.tailIndent = -gutter
        return style
    }
}

/// Styles the editor: all markdown syntax stays visible in a light gray,
/// headings are body-sized and bold with their `#` hanging in the left margin, and emphasis
/// is shown with real bold and italic faces. Characters are never changed.
final class MarkdownStyler {
    private struct Line {
        let range: NSRange      // without the line terminator
        let enclosing: NSRange  // with the line terminator
    }

    private static let managedKeys: [NSAttributedString.Key] = [
        .font, .foregroundColor, .backgroundColor, .strikethroughStyle, .underlineStyle, .paragraphStyle,
        .baselineOffset, .kern, .link, .mdLink, .mdWikilink, .mdContentBlock,
    ]

    private var storage: NSTextStorage!
    private var string = ""
    private var text: NSString = ""
    private var style = EditorStyle()
    private var protected = IndexSet()

    /// Character ranges of the multi-line blocks (fenced code, tables, front matter) found by the last full
    /// pass, kept in step with edits. Edits outside them, that can't start a new one, restyle only their lines.
    private var specialRanges: [NSRange] = []
    private var lastStyle: EditorStyle?

    /// Styles the storage. With `edited` (the changed characters) and `delta` (how much the text grew since
    /// the last pass), only the touched lines are restyled when that can't change a multi-line block;
    /// otherwise the whole document is.
    func style(_ storage: NSTextStorage, with style: EditorStyle, edited: NSRange? = nil, delta: Int = 0) {
        self.storage = storage
        self.style = style
        text = storage.mutableString
        string = text as String
        defer { self.storage = nil }

        if let edited, style == lastStyle, NSMaxRange(edited) <= text.length, restyleLines(around: edited, delta: delta) {
            return
        }

        let full = NSRange(location: 0, length: text.length)
        var lines: [Line] = []
        text.enumerateSubstrings(in: full, options: [.byLines, .substringNotRequired]) { _, range, enclosing, _ in
            lines.append(Line(range: range, enclosing: enclosing))
        }
        let kinds = blockStructure(lines)

        storage.beginEditing()
        for key in Self.managedKeys { storage.removeAttribute(key, range: full) }
        storage.addAttributes(style.baseAttributes, range: full)
        for (i, line) in lines.enumerated() {
            switch kinds[i] {
            case .normal: styleLine(line)
            case .frontMatter: storage.addAttribute(.foregroundColor, value: Theme.marker, range: line.range)
            case .fence:
                storage.addAttributes([.font: style.code, .foregroundColor: Theme.marker], range: line.enclosing)
            case .code:
                storage.addAttributes([.font: style.code, .foregroundColor: Theme.secondary], range: line.enclosing)
            case .table: styleTableRow(line)
            }
        }
        storage.endEditing()

        specialRanges = []
        for (i, line) in lines.enumerated() where kinds[i] != .normal {
            if let last = specialRanges.last, NSMaxRange(last) == line.enclosing.location {
                specialRanges[specialRanges.count - 1] = NSUnionRange(last, line.enclosing)
            } else {
                specialRanges.append(line.enclosing)
            }
        }
        lastStyle = style
    }

    /// The fast path for typing: restyles just the lines around `edited`. Returns false when the edit may
    /// have changed a multi-line block, so the caller does a full pass.
    private func restyleLines(around edited: NSRange, delta: Int) -> Bool {
        // Keep the known blocks in step with the text, and bail out near one.
        let oldEnd = NSMaxRange(edited) - delta
        specialRanges = specialRanges.map { range in
            range.location >= oldEnd ? NSRange(location: range.location + delta, length: range.length) : range
        }
        // The lines the edit touched, including the one it ends in (splitting a line moves its attributes).
        var lines = text.lineRange(for: edited)
        if NSMaxRange(edited) < text.length {
            lines = NSUnionRange(lines, text.lineRange(for: NSRange(location: NSMaxRange(edited), length: 0)))
        }
        let probe = NSRange(location: max(0, lines.location - 1), length: min(text.length, NSMaxRange(lines) + 1) - max(0, lines.location - 1))
        if specialRanges.contains(where: { NSIntersectionRange($0, probe).length > 0 || NSLocationInRange(probe.location, $0) }) {
            return false
        }

        var touched: [Line] = []
        text.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, range, enclosing, _ in
            touched.append(Line(range: range, enclosing: enclosing))
        }
        if touched.isEmpty { touched = [Line(range: NSRange(location: lines.location, length: 0), enclosing: lines)] }
        // Could any of them start a code fence, a table or front matter?
        for line in touched {
            if line.range.location == 0, text.hasPrefix("---") { return false }
            if Self.fence.firstMatch(in: string, range: line.range) != nil { return false }
            if text.range(of: "|", options: .literal, range: line.range).location != NSNotFound { return false }
        }

        storage.beginEditing()
        for line in touched {
            for key in Self.managedKeys { storage.removeAttribute(key, range: line.enclosing) }
            storage.addAttributes(style.baseAttributes, range: line.enclosing)
            styleLine(line)
        }
        storage.endEditing()
        return true
    }

    private enum LineKind { case normal, frontMatter, fence, code, table }

    /// Classifies every line by the multi-line block it belongs to.
    private func blockStructure(_ lines: [Line]) -> [LineKind] {
        var kinds = [LineKind](repeating: .normal, count: lines.count)
        var i = 0
        if let end = frontMatterEnd(lines) {
            for j in 0...end { kinds[j] = .frontMatter }
            i = end + 1
        }
        while i < lines.count {
            if let open = Self.fence.firstMatch(in: string, range: lines[i].range) {
                let token = text.substring(with: open.range(at: 1))
                let close = lines[(i + 1)...].firstIndex { isClosingFence($0.range, opening: token) }
                let last = close ?? lines.count - 1
                kinds[i] = .fence
                if i + 1 <= last { for j in (i + 1)...last { kinds[j] = .code } }
                if let close { kinds[close] = .fence }
                i = last + 1
            } else if isTableStart(lines, at: i) {
                var last = i + 1
                while last + 1 < lines.count, lines[last + 1].range.length > 0,
                      text.substring(with: lines[last + 1].range).contains("|") {
                    last += 1
                }
                for j in i...last { kinds[j] = .table }
                i = last + 1
            } else {
                i += 1
            }
        }
        return kinds
    }

    // MARK: Blocks

    private func frontMatterEnd(_ lines: [Line]) -> Int? {
        guard let first = lines.first, text.substring(with: first.range) == "---" else { return nil }
        return lines.indices.dropFirst().first {
            let s = text.substring(with: lines[$0].range)
            return s == "---" || s == "..."
        }
    }

    private func isTableStart(_ lines: [Line], at i: Int) -> Bool {
        guard i + 1 < lines.count, text.substring(with: lines[i].range).contains("|") else { return false }
        return Self.tableDelimiter.firstMatch(in: string, range: lines[i + 1].range) != nil
    }

    private func styleTableRow(_ line: Line) {
        let r = line.range
        if Self.tableDelimiter.firstMatch(in: string, range: r) != nil {
            storage.addAttribute(.foregroundColor, value: Theme.marker, range: r)
            return
        }
        inline(r)
        for m in Self.pipe.matches(in: string, range: r) {
            storage.addAttribute(.foregroundColor, value: Theme.marker, range: m.range)
        }
    }

    private func styleLine(_ line: Line) {
        let r = line.range
        guard r.length > 0 else { return }

        if let m = Self.heading.firstMatch(in: string, range: r) {
            storage.addAttribute(.font, value: style.bold, range: r)
            hang(m.range, line: line, font: style.bold)
            storage.addAttribute(.foregroundColor, value: Theme.marker, range: m.range)
            inline(rest(after: m.range, in: r))
            return
        }

        if Self.rule.firstMatch(in: string, range: r) != nil {
            storage.addAttribute(.foregroundColor, value: Theme.marker, range: r)
            return
        }

        if let m = Self.quote.firstMatch(in: string, range: r) {
            hang(m.range, line: line, font: style.body)
            storage.addAttribute(.foregroundColor, value: Theme.secondary, range: r)
            storage.addAttribute(.foregroundColor, value: Theme.marker, range: m.range)
            inline(rest(after: m.range, in: r))
            return
        }

        if let m = Self.task.firstMatch(in: string, range: r) {
            let markerRange = NSRange(location: m.range(at: 2).location,
                                      length: NSMaxRange(m.range(at: 3)) - m.range(at: 2).location)
            let box = m.range(at: 3)
            let checked = text.character(at: box.location + 1) != 0x20
            let content = rest(after: m.range, in: r)
            storage.addAttribute(.foregroundColor, value: Theme.marker, range: markerRange)
            hangingIndent(prefix: NSRange(location: r.location, length: NSMaxRange(m.range) - r.location), line: line)
            inline(content)
            if checked {
                if style.completedTasks != .faded {
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: content)
                }
                if style.completedTasks != .strikethrough {
                    storage.addAttribute(.foregroundColor, value: Theme.marker, range: content)
                }
            }
            return
        }

        if let m = Self.bullet.firstMatch(in: string, range: r) ?? Self.ordered.firstMatch(in: string, range: r) {
            storage.addAttribute(.foregroundColor, value: Theme.marker, range: m.range(at: 2))
            hangingIndent(prefix: NSRange(location: r.location, length: NSMaxRange(m.range) - r.location), line: line)
            inline(rest(after: m.range, in: r))
            return
        }

        if let m = Self.footnoteDefinition.firstMatch(in: string, range: r) {
            storage.addAttribute(.foregroundColor, value: Theme.marker, range: m.range)
            inline(rest(after: m.range, in: r))
            return
        }

        if let m = Self.contentBlock.firstMatch(in: string, range: r) {
            let path = m.range(at: 1)
            storage.addAttributes([.foregroundColor: Theme.link,
                                   .mdContentBlock: text.substring(with: path)], range: path)
            if NSMaxRange(path) < NSMaxRange(r) {
                storage.addAttribute(.foregroundColor, value: Theme.secondary,
                                     range: NSRange(location: NSMaxRange(path), length: NSMaxRange(r) - NSMaxRange(path)))
            }
            return
        }

        inline(r)
    }

    /// Lets a block marker (`## `, `> `) hang in the gutter so the text starts on the column edge.
    private func hang(_ marker: NSRange, line: Line, font: NSFont) {
        let width = ceil(text.substring(with: marker).size(withAttributes: [.font: font]).width)
        storage.addAttribute(.paragraphStyle,
                             value: style.paragraph(first: max(0, style.gutter - width)),
                             range: line.enclosing)
    }

    /// Wrapped lines of a list item line up with the item's text, not its marker.
    private func hangingIndent(prefix: NSRange, line: Line) {
        let width = ceil(storage.attributedSubstring(from: prefix).size().width)
        storage.addAttribute(.paragraphStyle, value: style.paragraph(head: style.gutter + width), range: line.enclosing)
    }

    // MARK: Inline

    private func inline(_ range: NSRange) {
        guard range.length > 0 else { return }
        protected = IndexSet()
        // One pass over the characters decides which patterns can match at all; most lines need few.
        var has = Set<unichar>()
        let buffer = UnsafeMutablePointer<unichar>.allocate(capacity: range.length)
        defer { buffer.deallocate() }
        text.getCharacters(buffer, range: range)
        for i in 0..<range.length {
            switch buffer[i] {
            case 0x60, 0x3C, 0x5B, 0x5E, 0x3A, 0x23, 0x2A, 0x5F, 0x7E, 0x3D: has.insert(buffer[i])  // ` < [ ^ : # * _ ~ =
            default: break
            }
        }
        let contains = { (c: Character) in has.contains(c.utf16.first!) }

        for m in contains("`") ? Self.inlineCode.matches(in: string, range: range) : [] {
            protect(m.range)
            let ticks = m.range(at: 1).length
            storage.addAttributes([.font: style.code, .foregroundColor: Theme.secondary], range: m.range)
            marker(NSRange(location: m.range.location, length: ticks))
            marker(NSRange(location: NSMaxRange(m.range) - ticks, length: ticks))
        }

        for m in contains("<") ? Self.htmlComment.matches(in: string, range: range) : [] where !isProtected(m.range) {
            protect(m.range)
            marker(m.range)
        }

        for m in contains("[") ? Self.wikilink.matches(in: string, range: range) : [] where !isProtected(m.range) {
            protect(m.range)
            marker(NSRange(location: m.range.location, length: 2))
            marker(NSRange(location: NSMaxRange(m.range) - 2, length: 2))
            let inner = NSRange(location: m.range.location + 2, length: m.range.length - 4)
            storage.addAttributes([.foregroundColor: Theme.link,
                                   .mdWikilink: Wikilink.target(of: text.substring(with: inner))], range: inner)
        }

        for m in contains("^") ? Self.footnoteReference.matches(in: string, range: range) : [] where !isProtected(m.range) {
            protect(m.range)
            marker(m.range)
        }

        for m in contains("[") ? Self.link.matches(in: string, range: range) : [] where !isProtected(m.range) {
            let open = m.range(at: 1), label = m.range(at: 2), destination = m.range(at: 3)
            protect(open)
            protect(destination)
            marker(open)
            marker(destination)
            let url = text.substring(with: m.range(at: 4))
            storage.addAttribute(.mdLink, value: url, range: m.range)
            storage.addAttribute(.foregroundColor, value: Theme.link, range: label)
        }

        for m in contains(":") ? Self.autolink.matches(in: string, range: range) : [] where !isProtected(m.range) {
            protect(m.range)
            storage.addAttributes([.foregroundColor: Theme.link, .mdLink: text.substring(with: m.range)], range: m.range)
        }

        for m in contains("#") ? Self.hashtag.matches(in: string, range: range) : [] where !isProtected(m.range) {
            storage.addAttribute(.foregroundColor, value: Theme.secondary, range: m.range)
        }

        let star = contains("*"), underscore = contains("_")
        if star || underscore {
            delimited(Self.boldItalic, in: range) {
                self.setFont(bold: true, italic: true, $0)
            }
            delimited(Self.bold, in: range) { self.setFont(bold: true, italic: nil, $0) }
        }
        if star { delimited(Self.italicStar, length: 1, in: range) { self.setFont(bold: nil, italic: true, $0) } }
        if underscore { delimited(Self.italicUnderscore, length: 1, in: range) { self.setFont(bold: nil, italic: true, $0) } }
        if contains("~") {
            delimited(Self.strike, length: 2, in: range) {
                self.storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: $0)
            }
        }
        if contains("=") {
            delimited(Self.highlight, length: 2, in: range) {
                self.storage.addAttribute(.backgroundColor, value: Theme.highlight(self.style.highlight), range: $0)
            }
        }
    }

    /// Styles a `<delim>content<delim>` span. `length` nil means the delimiter is capture group 1.
    private func delimited(_ regex: NSRegularExpression, length: Int? = nil, in range: NSRange,
                           apply: (NSRange) -> Void) {
        for m in regex.matches(in: string, range: range) {
            let d = length ?? m.range(at: 1).length
            let open = NSRange(location: m.range.location, length: d)
            let close = NSRange(location: NSMaxRange(m.range) - d, length: d)
            guard !isProtected(open), !isProtected(close) else { continue }
            protect(open)
            protect(close)
            marker(open)
            marker(close)
            apply(NSRange(location: NSMaxRange(open), length: close.location - NSMaxRange(open)))
        }
    }

    // MARK: Helpers

    private func marker(_ range: NSRange) {
        guard range.length > 0 else { return }
        storage.addAttribute(.foregroundColor, value: Theme.marker, range: range)
    }

    private func isClosingFence(_ range: NSRange, opening: String) -> Bool {
        guard let m = Self.closingFence.firstMatch(in: string, range: range) else { return false }
        let token = text.substring(with: m.range(at: 1))
        return token.first == opening.first && token.count >= opening.count
    }

    private func rest(after match: NSRange, in line: NSRange) -> NSRange {
        NSRange(location: NSMaxRange(match), length: NSMaxRange(line) - NSMaxRange(match))
    }

    private func protect(_ range: NSRange) {
        protected.insert(integersIn: range.location..<NSMaxRange(range))
    }

    private func isProtected(_ range: NSRange) -> Bool {
        protected.intersects(integersIn: range.location..<NSMaxRange(range))
    }

    /// Swaps in the bold/italic face of the editor typeface, keeping traits already applied.
    private func setFont(bold: Bool?, italic: Bool?, _ range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, r, _ in
            guard let font = value as? NSFont else { return }
            let traits = font.fontDescriptor.symbolicTraits
            let newFont = style.font(bold: bold ?? traits.contains(.bold), italic: italic ?? traits.contains(.italic))
            storage.addAttribute(.font, value: newFont, range: r)
        }
    }

    // MARK: Patterns

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    static let fence = regex(#"^ {0,3}(`{3,}|~{3,})(.*)$"#)
    static let closingFence = regex(#"^ {0,3}(`{3,}|~{3,})[ \t]*$"#)
    static let heading = regex(#"^ {0,3}#{1,6}(?:[ \t]+|$)"#)
    static let rule = regex(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    static let quote = regex(#"^ {0,3}>[ \t]?(?:>[ \t]?)*"#)
    static let task = regex(#"^([ \t]*)((?:[-*+]|\d{1,9}[.)])[ \t]+)(\[[ xX]\])(?:[ \t]+|$)"#)
    static let bullet = regex(#"^([ \t]*)([-*+])[ \t]+"#)
    static let ordered = regex(#"^([ \t]*)(\d{1,9}[.)])[ \t]+"#)
    static let tableDelimiter = regex(#"^\|?[ \t]*:?-+:?[ \t]*(\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$"#)
    static let pipe = regex(#"(?<!\\)\|"#)
    static let footnoteDefinition = regex(#"^\[\^[^\]\s]+\]:"#)
    static let footnoteReference = regex(#"\[\^[^\]\s]+\]"#)
    static let contentBlock = regex(
        #"^((?:/[^\s/][^\t\n]*?|[^\s/]\S*?)\.(?:png|jpe?g|gif|svg|webp|heic|tiff?|csv|txt|text|md|markdown|mdown|swift|py|js|ts|json|html|css|c|h|m|rb|go|rs|java|kt|sh|ya?ml))(?:[ \t]+(?:"[^"]*"|'[^']*'|\([^)]*\)))?[ \t]*$"#,
        .caseInsensitive)
    static let inlineCode = regex(#"(`+)(?!`).+?(?<!`)\1(?!`)"#)
    static let htmlComment = regex(#"<!--.*?-->"#)
    static let wikilink = regex(#"\[\[[^\[\]\n]+\]\]"#)
    static let link = regex(#"(!?\[)([^\]\n]*)(\]\(([^)\s]*)(?:[ \t]+"[^"\n]*")?\))"#)
    static let autolink = regex(#"<?https?://[^\s<>()\[\]]*[^\s<>()\[\].,;:!?'"]>?"#)
    static let hashtag = regex(#"(?<![\w#&/])#[\p{L}\p{N}_\-]*\p{L}[\p{L}\p{N}_\-]*"#)
    static let boldItalic = regex(#"(\*\*\*|___)(?=\S)(.+?)(?<=\S)\1"#)
    static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    static let italicStar = regex(#"(?<![*\\])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?!\*)"#)
    static let italicUnderscore = regex(#"(?<![\w_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\w_])"#)
    static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    static let highlight = regex(#"==(?=\S)(.+?)(?<=\S)=="#)
}

enum Wikilink {
    /// `destination | title` links to `destination`.
    static func target(of inner: String) -> String {
        let destination = inner.split(separator: "|", maxSplits: 1).first.map(String.init) ?? inner
        return destination.trimmingCharacters(in: .whitespaces)
    }

    static func title(of inner: String) -> String {
        let parts = inner.split(separator: "|", maxSplits: 1)
        return (parts.count == 2 ? String(parts[1]) : inner).trimmingCharacters(in: .whitespaces)
    }
}
