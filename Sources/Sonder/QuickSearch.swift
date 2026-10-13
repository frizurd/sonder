import AppKit
import Combine
import SwiftUI

/// ⌘P Open Quickly: fuzzy-find any note or folder in the Library by name or path, and notes by
/// their text. A folder opens in the File List; a note opens with its folder listed beside it.
///
/// It runs in its own floating panel that becomes the key window, so it has the keyboard to itself:
/// typing goes to the search field, ↑↓ (or ⌃N/⌃P, ⌃J/⌃K) move, Return opens, Esc or a click
/// elsewhere closes, and focus returns to the note.
final class QuickOpenController: ObservableObject {
    struct Result: Identifiable, Equatable {
        let url: URL
        let isFolder: Bool
        /// Shown in bold; the folder path shows beneath.
        let name: String
        let path: String
        /// Offsets into `name` to highlight.
        var highlights: [Int] = []
        /// For notes found by their text: the line that matched.
        var snippet: String?
        var id: URL { url }
    }

    @Published var query = "" { didSet { if query != oldValue { search() } } }
    @Published private(set) var results: [Result] = []
    @Published var selected = 0

    private weak var model: WindowModel?
    private let library = Library.shared
    private var generation = 0
    var close: () -> Void = {}

    init(model: WindowModel) {
        self.model = model
        search()
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = min(max(0, selected + delta), results.count - 1)
    }

    // MARK: Searching

    private struct Candidate {
        let url: URL
        let isFolder: Bool
        /// What fzf and the matcher see: the path from the Library location, e.g. `Projects/Ideas.md`.
        let key: String
    }

    /// The path from the Library location, e.g. `Projects/Ideas.md` (with the location's name in front
    /// when there are several).
    private func key(_ url: URL) -> String {
        guard let root = library.location(containing: url) else { return url.lastPathComponent }
        let relative = String(Library.canonicalPath(url.path).dropFirst(Library.canonicalPath(root.path).count + 1))
        return library.locations.count > 1 ? root.lastPathComponent + "/" + relative : relative
    }

    private var candidates: [Candidate] {
        library.folders.map { Candidate(url: $0, isFolder: true, key: key($0) + "/") }
            + library.textFiles.map { Candidate(url: $0, isFolder: false, key: key($0)) }
    }

    private func result(for url: URL, isFolder: Bool, key: String) -> Result {
        let name = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let folder = key.split(separator: "/").dropLast().joined(separator: "/")
        let highlights = query.isEmpty ? [] : FuzzyFinder.score(query, name)?.positions ?? []
        return Result(url: url, isFolder: isFolder, name: name, path: folder.isEmpty ? "Library" : folder, highlights: highlights)
    }

    private func search() {
        generation += 1
        let current = generation
        let text = query.trimmingCharacters(in: .whitespaces)
        if text.isEmpty {
            results = library.recents.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(12).map {
                result(for: $0, isFolder: false, key: key($0))
            }
            selected = 0
            return
        }
        let all = candidates
        FuzzyFinder.rank(text, in: all.map(\.key)) { [weak self] ranked in
            guard let self, current == self.generation else { return }
            let found = ranked.map { all[$0] }.map { self.result(for: $0.url, isFolder: $0.isFolder, key: $0.key) }
            self.results = found
            self.selected = 0
            // Then notes whose text mentions the query, searched off the main thread.
            self.library.search(text) { [weak self] urls in
                guard let self, current == self.generation else { return }
                let named = Set(found.map(\.url))
                var keys: [URL: String] = [:]
                for candidate in all where !candidate.isFolder { keys[candidate.url] = candidate.key }
                var more: [Result] = []
                for url in urls where !named.contains(url) {
                    guard found.count + more.count < 50 else { break }
                    var item = self.result(for: url, isFolder: false, key: keys[url] ?? url.lastPathComponent)
                    item.snippet = self.snippet(for: url, matching: text)
                    more.append(item)
                }
                if !more.isEmpty { self.results = found + more }
            }
        }
    }

    private func snippet(for url: URL, matching query: String) -> String? {
        guard let word = query.split(separator: " ").first, let text = library.text(of: url),
              let range = text.range(of: word, options: .caseInsensitive) else { return nil }
        let line = text[text.lineRange(for: range)].trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? nil : String(line.prefix(120))
    }

    // MARK: Opening

    func openSelected(newWindow: Bool = false) {
        guard results.indices.contains(selected), let model else { return }
        let result = results[selected]
        close()
        if result.isFolder {
            model.selection = .folder(result.url)
            model.showLibrary = true
        } else if newWindow {
            WindowRegistry.shared.openWindow?(result.url)
        } else {
            model.open(result.url)
            // Show the note among the others in its folder.
            if library.location(containing: result.url) != nil {
                model.selection = .folder(result.url.deletingLastPathComponent())
                model.showLibrary = true
            }
        }
    }
}

// MARK: - Presenting

/// Opens and closes Open Quickly as an overlay inside the writing window: the window dims behind a
/// glass card. The app-wide key monitor (KeyCommands) sends it ⌘P and the navigation keys, so it
/// works whatever has focus.
enum QuickOpen {
    /// Shows Open Quickly in `model`'s window (the front window if nil). While it's open, this puts the
    /// cursor back in its search field. Returns false if there's no window.
    @discardableResult
    static func present(for model: WindowModel? = nil) -> Bool {
        guard let model = model ?? WindowRegistry.shared.activeModel else { return false }
        if model.quickOpen == nil {
            let controller = QuickOpenController(model: model)
            controller.close = { [weak model] in model.map { hide(for: $0) } }
            model.quickOpen = controller
        }
        if let window = WindowRegistry.shared.window(for: model) {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        // The overlay appears on a later pass, sometimes a few frames on when the window is busy;
        // keep trying until its field has the keyboard.
        func focusSoon(_ attempt: Int) {
            guard model.quickOpen != nil, !focusField(of: model), attempt < 60 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { focusSoon(attempt + 1) }
        }
        DispatchQueue.main.async { focusSoon(0) }
        return true
    }

    static func hide(for model: WindowModel? = nil) {
        guard let model = model ?? WindowRegistry.shared.activeModel, model.quickOpen != nil else { return }
        model.quickOpen = nil
        // Back to writing.
        if let window = WindowRegistry.shared.window(for: model), let textView = model.editor?.textView {
            window.makeFirstResponder(textView)
        }
    }

    /// Gives the search field the keyboard, with the cursor after what's typed so far. Returns false
    /// while the field isn't on screen yet.
    @discardableResult
    static func focusField(of model: WindowModel) -> Bool {
        guard model.quickOpen != nil, let window = WindowRegistry.shared.window(for: model), let content = window.contentView else { return false }
        func field(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.isEditable, field.placeholderString == QuickSearch.placeholder { return field }
            for subview in view.subviews { if let found = field(in: subview) { return found } }
            return nil
        }
        guard let field = field(in: content) else { return false }
        if let editor = field.currentEditor(), window.firstResponder === editor { return true }
        guard window.makeFirstResponder(field), let editor = field.currentEditor() else { return false }
        // Taking focus selects the whole field; the next letter would replace what's there.
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        return true
    }

    /// Navigation while it's open. Returns true if the key was used.
    static func handle(_ event: NSEvent) -> Bool {
        guard let model = WindowRegistry.shared.activeModel, let controller = model.quickOpen else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let control = modifiers.contains(.control)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 125: controller.move(1); return true                                   // ↓
        case 126: controller.move(-1); return true                                  // ↑
        case 36, 76: controller.openSelected(newWindow: modifiers.contains(.shift)); return true  // Return
        case 53: hide(for: model); return true                                      // Esc
        default: break
        }
        if control && (key == "n" || key == "j") { controller.move(1); return true }
        if control && (key == "p" || key == "k") { controller.move(-1); return true }
        if modifiers.contains(.command) { return false }
        if event.keyCode == 48 { return true }                                      // Tab: the field keeps the keyboard
        // Anything typed goes to the search field, wherever focus had wandered.
        if focusField(of: model) { return false }
        // Typed before the field is on screen (straight after ⌘P): add it to the query here, so it
        // never lands in the note.
        if event.keyCode == 51 {                                                    // Delete
            controller.query = String(controller.query.dropLast())
        } else if !control, let characters = event.characters, characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            controller.query += characters
        }
        return true
    }
}

// MARK: - View

struct QuickSearch: View {
    static let placeholder = "Open note or folder…"
    @ObservedObject var controller: QuickOpenController

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField(Self.placeholder, text: $controller.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                    if AIToolbox.shared.executable(named: "fzf") != nil {
                        Text("fzf").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary)
                            .help("Ranked by fzf")
                    }
                }
                .padding(.horizontal, 16)
                .frame(height: 52)

                if !controller.results.isEmpty {
                    Divider().opacity(0.5)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(controller.results.enumerated()), id: \.element.id) { index, result in
                                    row(result, selected: index == controller.selected)
                                        .id(result.id)
                                        .onTapGesture {
                                            controller.selected = index
                                            controller.openSelected()
                                        }
                                }
                            }
                            .padding(6)
                        }
                        // As tall as the results, up to a limit: a short list makes a short card.
                        .frame(height: min(CGFloat(controller.results.count) * (Self.rowHeight + 2) + 12, 360))
                        .onChange(of: controller.selected) { _, index in
                            guard controller.results.indices.contains(index) else { return }
                            proxy.scrollTo(controller.results[index].id)
                        }
                    }
                } else if !controller.query.isEmpty {
                    Divider().opacity(0.5)
                    Text("No notes or folders match “\(controller.query)”")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
            }
            .frame(width: 560)
            .glassPanel(cornerRadius: 18)
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        }
    }

    private func row(_ result: QuickOpenController.Result, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: result.isFolder ? "folder.fill" : "doc.text")
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.white : result.isFolder ? Color.accentColor : .secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                highlighted(result.name, result.highlights, selected: selected)
                    .font(.system(size: 13.5))
                    .lineLimit(1)
                Text(result.snippet ?? result.path)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if selected {
                Text(result.isFolder ? "Show Folder ↩" : "Open ↩")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

    static let rowHeight: CGFloat = 44

    /// The name with the fuzzy-matched characters in bold.
    private func highlighted(_ name: String, _ positions: [Int], selected: Bool) -> Text {
        let marks = Set(positions)
        var text = Text("")
        for (i, character) in name.enumerated() {
            let piece = Text(String(character))
            text = text + (marks.contains(i)
                ? piece.fontWeight(.bold).foregroundColor(selected ? .white : .accentColor)
                : piece.foregroundColor(selected ? .white : .primary))
        }
        return text
    }
}
