import CryptoKit
import Foundation

/// Who wrote a run of text. Stored in the file as Markdown Annotations (v0.2):
/// a block at the end of the file that maps grapheme ranges to authors.
struct Author: Hashable {
    enum Kind: Character {
        case human = "@"
        case ai = "&"
        case reference = "*"
    }

    var kind: Kind
    var name: String

    /// The annotation key, e.g. `@Jane`, `&AI`; also the `.mdAuthor` attribute value.
    var key: String { String(kind.rawValue) + name }

    init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }

    init?(key: String) {
        guard let first = key.first, let kind = Kind(rawValue: first) else { return nil }
        self.init(kind: kind, name: String(key.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    static var me: Author { Author(kind: .human, name: Preferences.shared.authorName) }
    static let ai = Author(kind: .ai, name: "AI")
    static let reference = Author(kind: .reference, name: "Reference")
}

enum Annotations {
    struct Run: Equatable {
        var author: String
        var range: NSRange  // UTF-16, in the document body
    }

    /// Splits file contents into the body shown in the editor and its author runs.
    static func parse(_ contents: String) -> (body: String, runs: [Run]) {
        guard let blockStart = contents.range(of: "\n---\nAnnotations:", options: .backwards) else {
            return (contents, [])
        }
        let block = contents[blockStart.upperBound...]
        let trimmedBlock = block.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBlock.hasSuffix("\n...") || trimmedBlock.hasSuffix("...") else { return (contents, []) }

        // `blockStart` begins at the empty line the writer leaves between the text and the block.
        let body = String(contents[..<blockStart.lowerBound])

        let lines = ("Annotations:" + block).split(separator: "\n").map(String.init)
        guard let header = lines.first else { return (body, []) }
        let headerParts = header.dropFirst("Annotations:".count).split(separator: " ")
        let index = GraphemeIndex(body)
        // If the text changed outside the app, the ranges no longer line up: drop them.
        guard headerParts.count >= 3, let hashRange = parseRange(String(headerParts[0])),
              let range = index.utf16Range(hashRange),
              hash((body as NSString).substring(with: range)).hasPrefix(String(headerParts[2]).lowercased())
        else { return (body, []) }

        var runs: [Run] = []
        for line in lines.dropFirst() where line != "..." {
            guard let first = line.first, Author.Kind(rawValue: first) != nil,
                  let colon = line.range(of: ":") else { continue }
            let key = String(line[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            let author = key.replacingOccurrences(of: #"\s*<[^>]*>"#, with: "", options: .regularExpression)
            for token in line[colon.upperBound...].split(separator: " ") {
                guard let g = parseRange(String(token)), let r = index.utf16Range(g) else { continue }
                runs.append(Run(author: author, range: r))
            }
        }
        return (body, runs)
    }

    /// Appends the annotation block to `body`; returns `body` unchanged when there are no runs.
    static func serialize(body: String, runs: [Run]) -> String {
        guard !runs.isEmpty else { return body }
        let index = GraphemeIndex(body)
        var order: [String] = []
        var ranges: [String: [String]] = [:]
        for run in runs {
            guard let g = index.graphemeRange(run.range), g.length > 0 else { continue }
            if ranges[run.author] == nil { order.append(run.author) }
            ranges[run.author, default: []].append(g.length == 1 ? "\(g.location)" : "\(g.location),\(g.length)")
        }
        guard !order.isEmpty else { return body }

        let total = index.count
        var out = body
        if !out.hasSuffix("\n") { out += "\n" }
        out += "\n---\n"
        out += "Annotations: 0,\(total) SHA-256 \(hash(body).prefix(32))\n"
        for author in order {
            out += "\(author.replacingOccurrences(of: ":", with: "\\:")): \(ranges[author]!.joined(separator: " "))\n"
        }
        out += "...\n"
        return out
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func parseRange(_ token: String) -> NSRange? {
        let parts = token.split(separator: ",")
        guard let location = parts.first.flatMap({ Int($0) }) else { return nil }
        let length = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
        return NSRange(location: location, length: length)
    }
}

/// Converts between grapheme cluster indexes (used by the file format) and UTF-16 offsets (used by AppKit).
struct GraphemeIndex {
    /// UTF-16 offset of each grapheme's start, plus the end of the string.
    private let offsets: [Int]

    init(_ string: String) {
        var offsets: [Int] = []
        offsets.reserveCapacity(string.count + 1)
        var utf16 = 0
        for character in string {
            offsets.append(utf16)
            utf16 += character.utf16.count
        }
        offsets.append(utf16)
        self.offsets = offsets
    }

    var count: Int { offsets.count - 1 }

    func utf16Range(_ graphemes: NSRange) -> NSRange? {
        let end = NSMaxRange(graphemes)
        guard graphemes.location >= 0, end < offsets.count else { return nil }
        return NSRange(location: offsets[graphemes.location], length: offsets[end] - offsets[graphemes.location])
    }

    func graphemeRange(_ utf16: NSRange) -> NSRange? {
        let start = grapheme(atOrAfter: utf16.location)
        let end = grapheme(atOrAfter: NSMaxRange(utf16))
        return NSRange(location: start, length: end - start)
    }

    private func grapheme(atOrAfter offset: Int) -> Int {
        var low = 0, high = offsets.count - 1
        while low < high {
            let mid = (low + high) / 2
            if offsets[mid] < offset { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
