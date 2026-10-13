import AppKit
import Combine

enum AppearanceSetting: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum Typeface: String, CaseIterable, Identifiable {
    case mono, duo, quattro
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum FocusScope: String, CaseIterable, Identifiable {
    case sentence, paragraph, typewriter
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum PartOfSpeech: String, CaseIterable, Identifiable {
    case adjectives, nouns, adverbs, verbs, conjunctions
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum StyleCategory: String, CaseIterable, Identifiable {
    case fillers, cliches, redundancies, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fillers: "Fillers"
        case .cliches: "Clichés"
        case .redundancies: "Redundancies"
        case .custom: "Custom Patterns"
        }
    }
}

enum HighlightColor: String, CaseIterable, Identifiable {
    case yellow, orange, pink, purple, blue, green
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum CompletedTaskStyle: String, CaseIterable, Identifiable {
    case strikethrough, faded, both
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum ChromeVisibility: String, CaseIterable, Identifiable {
    case fade, always, hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fade: "Fade In/Out"
        case .always: "Always Show"
        case .hidden: "Hide"
        }
    }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case modified, name, kind
    var id: String { rawValue }
    var title: String {
        switch self {
        case .modified: "Date Modified"
        case .name: "Name"
        case .kind: "Kind"
        }
    }
}

enum Stat: String, CaseIterable, Identifiable {
    case words, characters, sentences, paragraphs, readingTime, tasks
    var id: String { rawValue }
    var title: String {
        switch self {
        case .words: "Words"
        case .characters: "Characters"
        case .sentences: "Sentences"
        case .paragraphs: "Paragraphs"
        case .readingTime: "Reading Time"
        case .tasks: "Tasks"
        }
    }
}

enum PreviewTemplate: String, CaseIterable, Identifiable {
    case modern, classic, manuscriptMono, manuscriptDuo, manuscriptQuattro, github
    var id: String { rawValue }
    var title: String {
        switch self {
        case .modern: "Modern (Sans)"
        case .classic: "Classic (Serif)"
        case .manuscriptMono: "Manuscript (Mono)"
        case .manuscriptDuo: "Manuscript (Duo)"
        case .manuscriptQuattro: "Manuscript (Quattro)"
        case .github: "GitHub"
        }
    }
}

/// App-wide settings, persisted in UserDefaults. Every window observes the shared instance.
final class Preferences: ObservableObject {
    static let shared = Preferences()

    /// Settings storage; `SONDER_DEFAULTS_SUITE` points it elsewhere (snapshots, tests).
    static let store: UserDefaults = ProcessInfo.processInfo.environment["SONDER_DEFAULTS_SUITE"]
        .flatMap { UserDefaults(suiteName: $0) } ?? .standard
    private let defaults = Preferences.store

    // General
    @Published var appearance: AppearanceSetting { didSet { save(appearance.rawValue, "appearance"); applyAppearance() } }
    @Published var toolbar: ChromeVisibility { didSet { save(toolbar.rawValue, "toolbar") } }

    // Files
    @Published var defaultExtension: String { didSet { save(defaultExtension, "defaultExtension") } }

    // Library
    @Published var librarySort: LibrarySort { didSet { save(librarySort.rawValue, "librarySort") } }
    @Published var showExcerpts: Bool { didSet { save(showExcerpts, "showExcerpts") } }
    @Published var showExtensions: Bool { didSet { save(showExtensions, "showExtensions") } }
    @Published var foldersOnTop: Bool { didSet { save(foldersOnTop, "foldersOnTop") } }

    // Editor
    @Published var textSize: Double { didSet { save(textSize, "textSize") } }
    @Published var typeface: Typeface { didSet { save(typeface.rawValue, "typeface") } }
    @Published var lineLength: Int { didSet { save(lineLength, "lineLength") } }
    @Published var highlightColor: HighlightColor { didSet { save(highlightColor.rawValue, "highlightColor") } }
    @Published var completedTasks: CompletedTaskStyle { didSet { save(completedTasks.rawValue, "completedTasks") } }
    @Published var focusMode: Bool { didSet { save(focusMode, "focusMode") } }
    @Published var focusScope: FocusScope { didSet { save(focusScope.rawValue, "focusScope") } }
    @Published var syntaxHighlight: Bool { didSet { save(syntaxHighlight, "syntaxHighlight") } }
    @Published var syntaxParts: Set<PartOfSpeech> { didSet { save(syntaxParts.map(\.rawValue), "syntaxParts") } }
    @Published var styleCheck: Bool { didSet { save(styleCheck, "styleCheck") } }
    @Published var styleCategories: Set<StyleCategory> { didSet { save(styleCategories.map(\.rawValue), "styleCategories") } }
    @Published var customPatterns: String { didSet { save(customPatterns, "customPatterns") } }
    @Published var showAuthors: Bool { didSet { save(showAuthors, "showAuthors") } }
    @Published var authorName: String { didSet { save(authorName, "authorName") } }
    @Published var smartQuotes: Bool { didSet { save(smartQuotes, "smartQuotes") } }
    @Published var smartDashes: Bool { didSet { save(smartDashes, "smartDashes") } }
    @Published var pairBrackets: Bool { didSet { save(pairBrackets, "pairBrackets") } }
    @Published var spellCheck: Bool { didSet { save(spellCheck, "spellCheck") } }
    @Published var stat: Stat { didSet { save(stat.rawValue, "stat") } }

    // Preview & templates
    @Published var template: PreviewTemplate { didSet { save(template.rawValue, "template") } }
    @Published var centerHeadings: Bool { didSet { save(centerHeadings, "centerHeadings") } }
    @Published var numberHeadings: Bool { didSet { save(numberHeadings, "numberHeadings") } }
    @Published var indentParagraphs: Bool { didSet { save(indentParagraphs, "indentParagraphs") } }
    @Published var invertPreview: Bool { didSet { save(invertPreview, "invertPreview") } }
    @Published var smartPunctuation: Bool { didSet { save(smartPunctuation, "smartPunctuation") } }
    @Published var singleReturn: Bool { didSet { save(singleReturn, "singleReturn") } }

    static let defaultTextSize: Double = 17
    static let textSizes: ClosedRange<Double> = 11...32
    static let lineLengths = [64, 72, 80]

    private init() {
        let d = Preferences.store
        func value<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
            d.string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        func set<T: RawRepresentable>(_ key: String, _ fallback: Set<T>) -> Set<T> where T.RawValue == String {
            guard let raw = d.stringArray(forKey: key) else { return fallback }
            return Set(raw.compactMap(T.init(rawValue:)))
        }

        appearance = value("appearance", .system)
        toolbar = value("toolbar", .fade)
        defaultExtension = d.string(forKey: "defaultExtension") ?? "md"
        librarySort = value("librarySort", .modified)
        showExcerpts = bool("showExcerpts", true)
        showExtensions = bool("showExtensions", false)
        foldersOnTop = bool("foldersOnTop", true)
        textSize = d.object(forKey: "textSize") as? Double ?? Self.defaultTextSize
        typeface = value("typeface", .duo)
        lineLength = d.object(forKey: "lineLength") as? Int ?? 72
        highlightColor = value("highlightColor", .yellow)
        completedTasks = value("completedTasks", .both)
        focusMode = bool("focusMode", false)
        focusScope = value("focusScope", .sentence)
        syntaxHighlight = bool("syntaxHighlight", false)
        syntaxParts = set("syntaxParts", Set(PartOfSpeech.allCases))
        styleCheck = bool("styleCheck", false)
        styleCategories = set("styleCategories", Set(StyleCategory.allCases))
        customPatterns = d.string(forKey: "customPatterns") ?? ""
        showAuthors = bool("showAuthors", false)
        authorName = d.string(forKey: "authorName") ?? NSFullUserName()
        smartQuotes = bool("smartQuotes", false)
        smartDashes = bool("smartDashes", false)
        pairBrackets = bool("pairBrackets", true)
        spellCheck = bool("spellCheck", true)
        stat = value("stat", .words)
        template = value("template", .modern)
        centerHeadings = bool("centerHeadings", false)
        numberHeadings = bool("numberHeadings", false)
        indentParagraphs = bool("indentParagraphs", false)
        invertPreview = bool("invertPreview", true)
        smartPunctuation = bool("smartPunctuation", true)
        singleReturn = bool("singleReturn", false)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    func applyAppearance() {
        switch appearance {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    /// ⌃⌘N: flips to the opposite of what is currently on screen.
    func toggleAppearance() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        appearance = isDark ? .light : .dark
    }

    func adjustTextSize(by delta: Double) {
        textSize = min(Self.textSizes.upperBound, max(Self.textSizes.lowerBound, textSize + delta))
    }
}
