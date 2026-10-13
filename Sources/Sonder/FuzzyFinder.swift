import Foundation

/// Fuzzy matching for Open Quickly. Uses fzf's ranking when fzf is installed, and a built-in
/// fzf-style matcher otherwise; the built-in matcher also finds the characters to highlight.
enum FuzzyFinder {
    struct Match {
        let index: Int
        let score: Int
    }

    /// Ranks `candidates` against `query`, best first, on a background queue; calls back on the main queue.
    static func rank(_ query: String, in candidates: [String], limit: Int = 40,
                     completion: @escaping ([Int]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ranked = fzf(query, candidates) ?? builtIn(query, candidates)
            DispatchQueue.main.async { completion(Array(ranked.prefix(limit))) }
        }
    }

    static func builtIn(_ query: String, _ candidates: [String]) -> [Int] {
        var matches: [Match] = []
        for i in candidates.indices {
            if let result = score(query, candidates[i]) { matches.append(Match(index: i, score: result.score)) }
        }
        matches.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return candidates[a.index].count < candidates[b.index].count
        }
        return matches.map(\.index)
    }

    // MARK: fzf

    /// `fzf --filter` prints the matching lines, best first, without its interactive interface.
    private static func fzf(_ query: String, _ candidates: [String]) -> [Int]? {
        guard let executable = AIToolbox.shared.executable(named: "fzf") else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--filter", query, "--scheme=path"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        DispatchQueue.global(qos: .userInitiated).async {
            input.fileHandleForWriting.write(Data(candidates.joined(separator: "\n").utf8))
            try? input.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Exit status 1 just means "no match".
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else { return nil }
        var indexByLine: [String: Int] = [:]
        for (i, candidate) in candidates.enumerated() where indexByLine[candidate] == nil { indexByLine[candidate] = i }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { indexByLine[String($0)] }
    }

    // MARK: Built-in matcher

    /// Scores `candidate` for `query` the way fzf's v1 algorithm does: every query character must appear in
    /// order; matches at word starts and runs of consecutive characters score higher, gaps cost a little.
    /// Matching ignores case unless the query has capitals. Returns the matched character offsets too.
    static func score(_ query: String, _ candidate: String) -> (score: Int, positions: [Int])? {
        let pattern = Array(query.filter { !$0.isWhitespace })
        guard !pattern.isEmpty else { return (0, []) }
        let text = Array(candidate)
        let caseSensitive = query.contains { $0.isUppercase }
        func same(_ a: Character, _ b: Character) -> Bool {
            caseSensitive ? a == b : a.lowercased() == b.lowercased()
        }

        // Forward: the earliest place the whole pattern fits. Backward: tighten it to the shortest window.
        var p = 0, end = -1
        for (i, c) in text.enumerated() where same(c, pattern[p]) {
            p += 1
            if p == pattern.count { end = i; break }
        }
        guard end >= 0 else { return nil }
        p = pattern.count - 1
        var start = end
        for i in stride(from: end, through: 0, by: -1) where same(text[i], pattern[p]) {
            if p == 0 { start = i; break }
            p -= 1
        }

        var positions: [Int] = []
        var score = 0, streak = 0, inGap = false
        p = 0
        let basenameStart = (text.lastIndex(of: "/").map { $0 + 1 }) ?? 0
        for i in start...end {
            guard p < pattern.count, same(text[i], pattern[p]) else {
                score -= inGap ? 1 : 3
                inGap = true
                streak = 0
                continue
            }
            var bonus = boundaryBonus(text, at: i)
            if streak > 0 { bonus = max(bonus, 4) }
            if p == 0 { bonus *= 2 }
            score += 16 + bonus + (i >= basenameStart ? 2 : 0)
            positions.append(i)
            streak += 1
            inGap = false
            p += 1
        }
        return (score, positions)
    }

    private static func boundaryBonus(_ text: [Character], at i: Int) -> Int {
        guard i > 0 else { return 8 }
        let previous = text[i - 1], current = text[i]
        if previous == "/" { return 9 }
        if previous == " " || previous == "-" || previous == "_" || previous == "." { return 8 }
        if previous.isLowercase && current.isUppercase { return 7 }
        if !previous.isLetter && !previous.isNumber && (current.isLetter || current.isNumber) { return 7 }
        return 0
    }
}
