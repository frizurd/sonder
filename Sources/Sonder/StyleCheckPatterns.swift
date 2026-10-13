import Foundation

/// Built-in English Style Check phrases.
enum StyleCheckPatterns {
    static let fillers = [
        "actually", "absolutely", "basically", "certainly", "clearly", "definitely", "essentially",
        "extremely", "fairly", "frankly", "generally", "honestly", "hopefully", "just", "kind of",
        "literally", "mostly", "obviously", "of course", "particularly", "perhaps", "pretty much",
        "quite", "rather", "really", "relatively", "seriously", "simply", "so to speak", "somehow",
        "somewhat", "sort of", "surely", "totally", "truly", "utterly", "very", "virtually",
        "in order to", "needless to say", "it is important to note that", "as a matter of fact",
        "at the end of the day", "for all intents and purposes", "in my opinion", "I think",
        "I believe", "I feel", "to be honest", "the fact that", "in terms of", "a bit", "a little",
        "anyway", "anyhow", "practically", "significantly", "incredibly", "awfully", "highly",
    ]

    static let cliches = [
        "against all odds", "all in all", "at the end of the day", "avoid like the plague",
        "back to square one", "beat around the bush", "better late than never", "bite the bullet",
        "brass tacks", "by the same token", "calm before the storm", "cutting edge", "dead as a doornail",
        "easier said than done", "every cloud has a silver lining", "few and far between",
        "fit as a fiddle", "game changer", "go the extra mile", "hit the ground running",
        "in the nick of time", "it goes without saying", "last but not least", "low-hanging fruit",
        "long and short of it", "move the needle", "needle in a haystack", "only time will tell",
        "paradigm shift", "par for the course", "piece of cake", "plain as day", "raining cats and dogs",
        "read between the lines", "think outside the box", "tip of the iceberg", "touch base",
        "when all is said and done", "win-win", "at this point in time", "best of both worlds",
        "crystal clear", "the bottom line", "time will tell", "the elephant in the room",
        "in a nutshell", "ballpark figure", "on the same page", "level playing field",
        "push the envelope", "the writing on the wall", "a perfect storm", "the whole nine yards",
        "food for thought", "a blessing in disguise", "add insult to injury", "cry over spilled milk",
        "the ball is in your court", "let the cat out of the bag", "jump on the bandwagon",
    ]

    static let redundancies = [
        "absolutely essential", "actual facts", "add an additional", "added bonus", "advance planning",
        "advance warning", "all-time record", "basic fundamentals", "close proximity", "collaborate together",
        "combine together", "completely eliminate", "completely finished", "consensus of opinion",
        "continue on", "current trend", "end result", "estimated at about", "exact same", "fall down",
        "final outcome", "first and foremost", "free gift", "future plans", "general public",
        "join together", "merge together", "mutual cooperation", "new innovation", "past history",
        "past experience", "personal opinion", "plan ahead", "postpone until later", "repeat again",
        "return back", "revert back", "same identical", "sudden impulse", "sum total",
        "true facts", "unexpected surprise", "unintended mistake", "very unique", "whether or not",
        "each and every", "over exaggerate", "period of time", "reason why", "refer back",
        "safe haven", "start off", "still remains", "ATM machine", "PIN number", "HIV virus",
        "close scrutiny", "foreign imports", "join up", "kneel down", "lift up", "mix together",
        "protest against", "reply back", "shut down completely", "spell out in detail",
    ]

    private static var cache: [StyleCategory: [TextAnalysis.Rule]] = [:]

    static func regexes(for category: StyleCategory) -> [TextAnalysis.Rule] {
        if let cached = cache[category] { return cached }
        let phrases: [String] = switch category {
        case .fillers: fillers
        case .cliches: cliches
        case .redundancies: redundancies
        case .custom: []
        }
        // One alternation per category keeps matching fast; longer phrases win over their prefixes.
        let alternation = phrases.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: " ", with: #"\s+"#) }
            .joined(separator: "|")
        let rules = (try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(?:"# + alternation + #")(?![\p{L}\p{N}])"#,
                                              options: .caseInsensitive))
            .map { [TextAnalysis.Rule(regex: $0)] } ?? []
        cache[category] = rules
        return rules
    }

    static func phraseRegex(_ phrase: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: phrase).replacingOccurrences(of: " ", with: #"\s+"#)
        return try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])"# + escaped + #"(?![\p{L}\p{N}])"#,
                                        options: .caseInsensitive)
    }
}
