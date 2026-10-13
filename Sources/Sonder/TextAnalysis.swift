import Foundation
import NaturalLanguage

/// Language-aware passes over the document: focus ranges, parts of speech, style check and stats.
enum TextAnalysis {
    // MARK: Focus

    /// The sentence containing `location`, trimmed of surrounding whitespace.
    static func sentence(in text: NSString, at location: Int) -> NSRange {
        let paragraph = self.paragraph(in: text, at: location)
        guard paragraph.length > 0 else { return paragraph }
        let tokenizer = NLTokenizer(unit: .sentence)
        let string = text as String
        let paragraphRange = Range(paragraph, in: string)!
        tokenizer.string = string
        tokenizer.setLanguage(.english)
        var result = paragraph
        tokenizer.enumerateTokens(in: paragraphRange) { tokenRange, _ in
            let r = NSRange(tokenRange, in: string)
            // The caret right after a sentence's final period (or its trailing space) still belongs to it.
            guard location >= r.location && location <= NSMaxRange(r) else { return true }
            result = r
            return false
        }
        return trimmed(result, in: text)
    }

    /// The line (markdown paragraph as written) containing `location`, without its terminator.
    static func paragraph(in text: NSString, at location: Int) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let line = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        var end = NSMaxRange(line)
        while end > line.location, isNewline(text, at: end - 1) { end -= 1 }
        return NSRange(location: line.location, length: end - line.location)
    }

    private static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var start = range.location, end = NSMaxRange(range)
        while start < end, isWhitespace(text, at: start) { start += 1 }
        while end > start, isWhitespace(text, at: end - 1) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isWhitespace(_ text: NSString, at i: Int) -> Bool {
        guard i < text.length else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(text.character(at: i)) ?? "x")
    }

    private static func isNewline(_ text: NSString, at i: Int) -> Bool {
        CharacterSet.newlines.contains(Unicode.Scalar(text.character(at: i)) ?? "x")
    }

    // MARK: Syntax Highlight

    static func partsOfSpeech(in string: String, include: Set<PartOfSpeech>) -> [(NSRange, PartOfSpeech)] {
        guard !include.isEmpty, !string.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = string
        var result: [(NSRange, PartOfSpeech)] = []
        tagger.enumerateTags(in: string.startIndex..<string.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .omitOther]) { tag, range in
            let part: PartOfSpeech? = switch tag {
            case .adjective: .adjectives
            case .noun: .nouns
            case .adverb: .adverbs
            case .verb: .verbs
            case .conjunction: .conjunctions
            default: nil
            }
            if let part, include.contains(part) {
                result.append((NSRange(range, in: string), part))
            }
            return true
        }
        return result
    }

    // MARK: Style Check

    struct StyleMatch: Equatable {
        let range: NSRange
        let category: StyleCategory
    }

    static func styleCheck(_ string: String, categories: Set<StyleCategory>, customPatterns: String) -> [StyleMatch] {
        let custom = CustomPatterns(customPatterns)
        var matches: [StyleMatch] = []
        for category in StyleCategory.allCases where categories.contains(category) {
            let regexes = category == .custom ? custom.rules : StyleCheckPatterns.regexes(for: category)
            for rule in regexes {
                for m in rule.regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)) {
                    let phrase = (string as NSString).substring(with: m.range)
                    if custom.isException(phrase) { continue }
                    let strike = rule.strikeGroup.map { m.range(at: $0) } ?? m.range
                    if strike.location != NSNotFound { matches.append(StyleMatch(range: strike, category: category)) }
                }
            }
        }
        return matches
    }

    struct Rule {
        let regex: NSRegularExpression
        /// Capture group to strike instead of the whole match (`custom ~~part~~` patterns).
        var strikeGroup: Int?
    }

    /// Settings → Editor → Custom Patterns: one rule per line, `-rule` for an exception,
    /// `/regex/` for a regular expression, `phrase ~~part~~` to strike only part of a phrase.
    struct CustomPatterns {
        var rules: [Rule] = []
        private var exceptions: [NSRegularExpression] = []

        init(_ source: String) {
            for raw in source.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("//") else { continue }
                if line.hasPrefix("-") {
                    if let regex = Self.compile(String(line.dropFirst())) { exceptions.append(regex) }
                } else if let tilde = line.range(of: #"~~(.+?)~~"#, options: .regularExpression) {
                    let before = NSRegularExpression.escapedPattern(for: String(line[..<tilde.lowerBound]))
                    let part = NSRegularExpression.escapedPattern(for: String(line[tilde].dropFirst(2).dropLast(2)))
                    let after = NSRegularExpression.escapedPattern(for: String(line[tilde.upperBound...]))
                    if let regex = try? NSRegularExpression(pattern: #"\b"# + before + "(" + part + ")" + after + #"\b"#,
                                                            options: .caseInsensitive) {
                        rules.append(Rule(regex: regex, strikeGroup: 1))
                    }
                } else if let regex = Self.compile(line) {
                    rules.append(Rule(regex: regex))
                }
            }
        }

        func isException(_ phrase: String) -> Bool {
            exceptions.contains { $0.firstMatch(in: phrase, range: NSRange(location: 0, length: (phrase as NSString).length)) != nil }
        }

        private static func compile(_ line: String) -> NSRegularExpression? {
            if line.count > 2, line.hasPrefix("/"), line.hasSuffix("/") {
                return try? NSRegularExpression(pattern: String(line.dropFirst().dropLast()), options: .caseInsensitive)
            }
            return StyleCheckPatterns.phraseRegex(line)
        }
    }

    // MARK: Stats

    struct Stats: Equatable {
        var words = 0
        var characters = 0
        var sentences = 0
        var paragraphs = 0
        var tasks = 0
        var completedTasks = 0

        var readingMinutes: Int { words == 0 ? 0 : max(1, Int((Double(words) / 230).rounded())) }

        func formatted(_ stat: Stat) -> String {
            switch stat {
            case .words: "\(words.formatted()) \(words == 1 ? "Word" : "Words")"
            case .characters: "\(characters.formatted()) \(characters == 1 ? "Character" : "Characters")"
            case .sentences: "\(sentences.formatted()) \(sentences == 1 ? "Sentence" : "Sentences")"
            case .paragraphs: "\(paragraphs.formatted()) \(paragraphs == 1 ? "Paragraph" : "Paragraphs")"
            case .readingTime: "\(readingMinutes) min Reading Time"
            case .tasks: tasks == 0 ? "No Tasks" : "\(completedTasks) of \(tasks) Tasks"
            }
        }
    }

    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}][\p{L}\p{N}'’\-]*"#)
    private static let taskPattern = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+\[([ xX])\]"#, options: .anchorsMatchLines)

    static func stats(_ string: String) -> Stats {
        let ns = string as NSString
        let full = NSRange(location: 0, length: ns.length)
        var stats = Stats()
        stats.words = wordPattern.numberOfMatches(in: string, range: full)
        stats.characters = string.filter { !$0.isNewline }.count

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = string
        tokenizer.enumerateTokens(in: string.startIndex..<string.endIndex) { range, _ in
            if string[range].contains(where: { $0.isLetter || $0.isNumber }) { stats.sentences += 1 }
            return true
        }

        var inParagraph = false
        string.enumerateLines { line, _ in
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if !blank && !inParagraph { stats.paragraphs += 1 }
            inParagraph = !blank
        }

        for m in taskPattern.matches(in: string, range: full) {
            stats.tasks += 1
            if ns.substring(with: m.range(at: 1)) != " " { stats.completedTasks += 1 }
        }
        return stats
    }
}
