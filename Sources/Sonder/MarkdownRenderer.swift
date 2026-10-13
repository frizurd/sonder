import Foundation
import cmark_gfm
import cmark_gfm_extensions

/// Turns a document into HTML with cmark-gfm (CommonMark + GitHub Flavored Markdown).
///
/// Before parsing, a few conventions beyond CommonMark are rewritten into standard markdown or HTML:
/// content blocks (a file reference on its own line), `[[wikilinks]]`, `==highlights==`,
/// `#hashtags`, and `$math$`, which is shielded from the parser so KaTeX can render it.
struct MarkdownRenderer {
    struct Options {
        var smartPunctuation = true
        var hardBreaks = false
        var resolveContentBlocks = true
    }

    var options = Options()
    /// The document's folder; relative paths and content blocks resolve against it.
    var baseURL: URL?
    /// The Library location containing the document, for content blocks starting with `/`.
    var locationURL: URL?

    struct Output {
        var html: String
        var title: String?
        var hasMath: Bool
    }

    func render(_ markdown: String) -> Output {
        var (body, metadata) = Self.splitFrontMatter(markdown)
        var math: [String] = []
        body = preprocess(body, math: &math)
        var html = Self.cmark(body, smart: options.smartPunctuation, hardBreaks: options.hardBreaks)
        for (i, tex) in math.enumerated() {
            html = html.replacingOccurrences(of: "MATHPLACEHOLDER\(i)X", with: tex)
        }
        let title = metadata["title"] ?? Self.firstHeading(in: body)
        return Output(html: html, title: title, hasMath: !math.isEmpty)
    }

    /// Markdown with content blocks replaced by their contents (⌃⌘C, Markdown export).
    func resolvingContentBlocks(_ markdown: String) -> String {
        var inFence = false
        return markdown.components(separatedBy: "\n").map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                inFence.toggle()
            }
            guard !inFence, let block = contentBlock(line) else { return line }
            switch block.kind {
            case .image: return "![\(block.caption ?? "")](\(block.url.path))"
            case .text, .code, .table: return (try? String(contentsOf: block.url, encoding: .utf8)) ?? line
            }
        }.joined(separator: "\n")
    }

    // MARK: Preprocessing

    private func preprocess(_ markdown: String, math: inout [String]) -> String {
        var out: [String] = []
        var fence: String?
        var inDisplayMath = false
        var displayMath: [String] = []

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                out.append(line)
                if trimmed.hasPrefix(open) && trimmed.trimmingCharacters(in: CharacterSet(charactersIn: String(open.first!))).isEmpty {
                    fence = nil
                }
                continue
            }
            if let m = trimmed.range(of: #"^(`{3,}|~{3,})"#, options: .regularExpression) {
                fence = String(trimmed[m])
                out.append(line)
                continue
            }
            if inDisplayMath {
                if trimmed.hasSuffix("$$") {
                    displayMath.append(String(trimmed.dropLast(2)))
                    out.append(mathPlaceholder("$$" + displayMath.joined(separator: "\n") + "$$", display: true, &math))
                    inDisplayMath = false
                    displayMath = []
                } else {
                    displayMath.append(line)
                }
                continue
            }
            if trimmed.hasPrefix("$$") && !(trimmed.count > 4 && trimmed.hasSuffix("$$")) {
                inDisplayMath = true
                displayMath = [String(trimmed.dropFirst(2))]
                continue
            }
            if options.resolveContentBlocks, let block = contentBlock(line) {
                out.append(render(block))
                continue
            }
            out.append(inline(line, math: &math))
        }
        if inDisplayMath { out.append(contentsOf: displayMath) }
        return out.joined(separator: "\n")
    }

    private func mathPlaceholder(_ tex: String, display: Bool, _ math: inout [String]) -> String {
        let escaped = Self.escape(tex)
        math.append(display ? "<div class=\"math\">\(escaped)</div>" : "<span class=\"math\">\(escaped)</span>")
        return "MATHPLACEHOLDER\(math.count - 1)X"
    }

    private static let codeSpan = try! NSRegularExpression(pattern: #"(`+)(?!`).+?(?<!`)\1(?!`)"#)
    private static let inlineMath = try! NSRegularExpression(pattern: #"(?<![\\$\w])\$\$?(?=\S)([^$\n]+?)(?<=\S)\$\$?(?![\w$])"#)
    private static let wikilink = try! NSRegularExpression(pattern: #"\[\[([^\[\]\n]+)\]\]"#)
    private static let highlight = try! NSRegularExpression(pattern: #"==(?=\S)(.+?)(?<=\S)=="#)
    private static let hashtag = try! NSRegularExpression(pattern: #"(?<![\w#&/(\[])#([\p{L}\p{N}_\-]*\p{L}[\p{L}\p{N}_\-]*)"#)

    /// Rewrites the inline extensions outside of code spans.
    private func inline(_ line: String, math: inout [String]) -> String {
        let ns = line as NSString
        var result = ""
        var cursor = 0
        let spans = Self.codeSpan.matches(in: line, range: NSRange(location: 0, length: ns.length))
        for span in spans + [nil] {
            let end = span?.range.location ?? ns.length
            result += rewrite(ns.substring(with: NSRange(location: cursor, length: end - cursor)), math: &math)
            if let span {
                result += ns.substring(with: span.range)
                cursor = NSMaxRange(span.range)
            }
        }
        return result
    }

    private func rewrite(_ text: String, math: inout [String]) -> String {
        var s = text
        s = replace(Self.inlineMath, in: s) { m, ns in
            mathPlaceholder(ns.substring(with: m.range), display: ns.substring(with: m.range).hasPrefix("$$"), &math)
        }
        s = replace(Self.wikilink, in: s) { m, ns in
            let inner = ns.substring(with: m.range(at: 1))
            let target = Wikilink.target(of: inner).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
            return "<a class=\"wikilink\" href=\"wikilink:\(target)\">\(Self.escape(Wikilink.title(of: inner)))</a>"
        }
        s = replace(Self.highlight, in: s) { m, ns in "<mark>\(ns.substring(with: m.range(at: 1)))</mark>" }
        // Hashtags at the start of a line are only tags when not followed by a space (`# Heading` is a heading).
        s = replace(Self.hashtag, in: s) { m, ns in "<span class=\"hashtag\">\(ns.substring(with: m.range))</span>" }
        return s
    }

    private func replace(_ regex: NSRegularExpression, in string: String,
                         with transform: (NSTextCheckingResult, NSString) -> String) -> String {
        let ns = string as NSString
        var result = ""
        var cursor = 0
        for m in regex.matches(in: string, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            result += transform(m, ns)
            cursor = NSMaxRange(m.range)
        }
        return result + ns.substring(from: cursor)
    }

    // MARK: Content blocks

    struct ContentBlock {
        enum Kind { case image, text, code, table }
        var kind: Kind
        var url: URL
        var caption: String?
    }

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "tif", "tiff"]
    private static let textExtensions: Set<String> = ["txt", "text", "md", "markdown", "mdown"]

    /// A line that is just a reference to an existing file, optionally followed by a caption.
    func contentBlock(_ line: String) -> ContentBlock? {
        let ns = line as NSString
        guard let m = MarkdownStyler.contentBlock.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let path = ns.substring(with: m.range(at: 1))
        let rest = ns.substring(from: NSMaxRange(m.range(at: 1))).trimmingCharacters(in: .whitespaces)
        let caption = rest.count >= 2 ? String(rest.dropFirst().dropLast()) : nil
        let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let decoded = relative.removingPercentEncoding ?? relative
        let candidates = [baseURL, locationURL].compactMap { $0?.appendingPathComponent(decoded) }
            + (path.hasPrefix("/") ? [URL(fileURLWithPath: path)] : [])
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        let ext = url.pathExtension.lowercased()
        let kind: ContentBlock.Kind = Self.imageExtensions.contains(ext) ? .image
            : ext == "csv" ? .table
            : Self.textExtensions.contains(ext) ? .text : .code
        return ContentBlock(kind: kind, url: url, caption: caption)
    }

    private func render(_ block: ContentBlock) -> String {
        switch block.kind {
        case .image:
            let alt = Self.escape(block.caption ?? block.url.deletingPathExtension().lastPathComponent)
            let caption = block.caption.map { "<figcaption>\(Self.escape($0))</figcaption>" } ?? ""
            return "<figure><img src=\"\(block.url.absoluteString)\" alt=\"\(alt)\">\(caption)</figure>\n"
        case .text:
            return (try? String(contentsOf: block.url, encoding: .utf8)) ?? ""
        case .code:
            let code = (try? String(contentsOf: block.url, encoding: .utf8)) ?? ""
            return "```\(block.url.pathExtension)\n\(code)\n```"
        case .table:
            let csv = (try? String(contentsOf: block.url, encoding: .utf8)) ?? ""
            return Self.table(fromCSV: csv, caption: block.caption) + "\n"
        }
    }

    static func table(fromCSV csv: String, caption: String?) -> String {
        let rows = parseCSV(csv)
        guard let header = rows.first else { return "" }
        var html = "<table>"
        if let caption { html += "<caption>\(escape(caption))</caption>" }
        html += "<thead><tr>" + header.map { "<th>\(escape($0))</th>" }.joined() + "</tr></thead><tbody>"
        for row in rows.dropFirst() {
            html += "<tr>" + row.map { "<td>\(escape($0))</td>" }.joined() + "</tr>"
        }
        return html + "</tbody></table>"
    }

    static func parseCSV(_ csv: String) -> [[String]] {
        let separator: Character = csv.split(separator: "\n").first.map { $0.filter { $0 == ";" }.count > $0.filter { $0 == "," }.count } == true ? ";" : ","
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false
        var iterator = csv.makeIterator()
        var pending: Character? = nil
        while let c = pending ?? iterator.next() {
            pending = nil
            if quoted {
                if c == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                    } else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" {
                quoted = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" {
                row.append(field); field = ""
                if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
                row = []
            } else if c != "\r" {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    // MARK: Front matter

    /// Splits off a YAML front matter block and reads its simple `key: value` pairs.
    static func splitFrontMatter(_ markdown: String) -> (String, [String: String]) {
        guard markdown.hasPrefix("---\n") else { return (markdown, [:]) }
        let lines = markdown.components(separatedBy: "\n")
        guard let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) else { return (markdown, [:]) }
        var metadata: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            metadata[key] = value
        }
        return (lines[(end + 1)...].joined(separator: "\n"), metadata)
    }

    static func firstHeading(in markdown: String) -> String? {
        for line in markdown.split(separator: "\n") where line.hasPrefix("# ") {
            return line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: cmark

    static func cmark(_ markdown: String, smart: Bool, hardBreaks: Bool) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        var options = CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES | CMARK_OPT_GITHUB_PRE_LANG
        if smart { options |= CMARK_OPT_SMART }
        if hardBreaks { options |= CMARK_OPT_HARDBREAKS }
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        markdown.withCString { cmark_parser_feed(parser, $0, strlen($0)) }
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let html = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(html) }
        return String(cString: html)
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
