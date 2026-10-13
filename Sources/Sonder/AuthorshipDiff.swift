import AppKit

/// Merges a revised text into an attributed original word by word, so only what changed
/// is attributed to the reviser.
enum AuthorshipDiff {
    static func merge(old: NSAttributedString, new: String, author: Author,
                      base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let oldTokens = tokens(old.string)
        let newTokens = tokens(new)
        let difference = newTokens.map(\.text).difference(from: oldTokens.map(\.text))
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        var plain = base
        plain[.mdAuthor] = nil
        let result = NSMutableAttributedString()
        var oldIndex = 0
        for (index, token) in newTokens.enumerated() {
            var attributes = plain
            if inserted.contains(index) {
                attributes[.mdAuthor] = author.key
            } else {
                while removed.contains(oldIndex) { oldIndex += 1 }
                if oldIndex < oldTokens.count {
                    let location = oldTokens[oldIndex].location
                    if location < old.length, let original = old.attribute(.mdAuthor, at: location, effectiveRange: nil) {
                        attributes[.mdAuthor] = original
                    }
                }
                oldIndex += 1
            }
            result.append(NSAttributedString(string: token.text, attributes: attributes))
        }
        return result
    }

    struct Token {
        let text: String
        let location: Int  // UTF-16 offset in the source string
    }

    /// Words, runs of whitespace, and single punctuation marks.
    static func tokens(_ string: String) -> [Token] {
        let ns = string as NSString
        return pattern.matches(in: string, range: NSRange(location: 0, length: ns.length)).map {
            Token(text: ns.substring(with: $0.range), location: $0.range.location)
        }
    }

    private static let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}'’_]+|\s+|."#, options: [.dotMatchesLineSeparators])
}
