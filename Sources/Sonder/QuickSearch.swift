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

// MARK: - Panel

/// The floating key window Open Quickly lives in. Navigation keys are handled here, before the
/// search field sees them.
final class QuickOpenPanel: NSPanel {
    private let controller: QuickOpenController
    private weak var parentModel: WindowModel?

    private init(controller: QuickOpenController, model: WindowModel) {
        self.controller = controller
        parentModel = model
        super.init(contentRect: NSRect(x: 0, y: 0, width: 580, height: 440),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        // A child window of the writing window: above it, but never above other apps.
        isFloatingPanel = false
        level = .normal
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        let host = NSHostingView(rootView: QuickSearch(controller: controller))
        host.sceneBridgingOptions = []
        contentView = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handle(event) { return }
        super.sendEvent(event)
    }

    private func handle(_ event: NSEvent) -> Bool {
        let control = event.modifierFlags.contains(.control)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch event.keyCode {
        case 125: controller.move(1); return true                                   // ↓
        case 126: controller.move(-1); return true                                  // ↑
        case 36, 76: controller.openSelected(newWindow: event.modifierFlags.contains(.shift)); return true  // Return
        case 53: dismiss(); return true                                             // Esc
        default: break
        }
        if control && (key == "n" || key == "j") { controller.move(1); return true }
        if control && (key == "p" || key == "k") { controller.move(-1); return true }
        // ⌘P while open keeps it open (the shortcut can arrive twice); Esc closes it.
        if event.modifierFlags.contains(.command) && key == "p" { return true }
        return false
    }

    /// Closes on a click anywhere outside the panel. (Not on losing key status: right after a menu
    /// shortcut AppKit can hand key status back to the main window for a moment.)
    private var clickMonitor: Any?
    /// Switching to another app closes it.
    private var resignObserver: NSObjectProtocol?

    private func watchOutsideClicks() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if event.window !== self { self.dismiss(restoreFocus: false) }
            return event
        }
    }

    static let tracing = CommandLine.arguments.contains("--trace-open-quickly")

    func dismiss(restoreFocus: Bool = true) {
        if Self.tracing { print("dismiss visible=\(isVisible) from:", Thread.callStackSymbols.dropFirst(1).prefix(4).joined(separator: " | ")); fflush(stdout) }
        guard isVisible else { return }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        parent?.removeChildWindow(self)
        orderOut(nil)
        parentModel?.showQuickSearch = false
        Self.current = nil
        if restoreFocus, let model = parentModel, let window = WindowRegistry.shared.window(for: model) {
            window.makeKeyAndOrderFront(nil)
            if let textView = model.editor?.textView { window.makeFirstResponder(textView) }
        }
    }

    private static var current: QuickOpenPanel?

    /// Shows Open Quickly over the top of `window`, taking the keyboard.
    static func show(for model: WindowModel, in window: NSWindow) {
        if tracing {
            print("show")
            for delay in [0.1, 0.6, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    print("after \(delay)s: key=\(NSApp.keyWindow.map { String(describing: type(of: $0)) } ?? "nil") responder=\(NSApp.keyWindow?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") active=\(NSApp.isActive)")
                    fflush(stdout)
                }
            }
        }
        current?.dismiss(restoreFocus: false)
        let controller = QuickOpenController(model: model)
        let panel = QuickOpenPanel(controller: controller, model: model)
        controller.close = { [weak panel] in panel?.dismiss(restoreFocus: false) }
        let frame = window.frame
        let origin = NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - 90 - panel.frame.height)
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.watchOutsideClicks()
        panel.resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak panel] _ in
            panel?.dismiss(restoreFocus: false)
        }
        current = panel
        // A menu shortcut is still being handled; take the keyboard once it has finished.
        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible else { return }
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    static func hide() {
        current?.dismiss()
    }
}

// MARK: - View

struct QuickSearch: View {
    @ObservedObject var controller: QuickOpenController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Open note or folder…", text: $controller.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .focused($focused)
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
                        .frame(maxHeight: 360)
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
            .glassPanel(cornerRadius: 22)
            .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
            .padding(.top, 4)
            Spacer(minLength: 0)
        }
        .frame(width: 580, height: 440, alignment: .top)
        .onAppear {
            // The panel is key by now; give the field the keyboard.
            DispatchQueue.main.async { focused = true }
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
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Color.accentColor : .clear))
        .contentShape(Rectangle())
    }

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
