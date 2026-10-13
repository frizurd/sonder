import AppKit
import Combine
import SwiftUI

/// What the editor needs to load when the window switches documents.
struct LoadedDocument {
    var text: String
    var runs: [Annotations.Run]
    var selection: NSRange
}

/// The editor surface the window model drives; implemented by the editor coordinator.
protocol EditorHost: AnyObject {
    var textView: MarkdownTextView? { get }
    func load(_ document: LoadedDocument)
    func currentText() -> String
    func authorRuns() -> [Annotations.Run]
    func selectedText() -> String?
    func reveal(_ range: NSRange)
}

final class PreviewSource: ObservableObject {
    @Published var text = ""
}

/// Fast-changing editor state, kept apart from `WindowModel` so typing and scrolling
/// only redraw the views that show it, not the Library.
final class EditorStatus: ObservableObject {
    @Published var stats = TextAnalysis.Stats()
    /// True while the user is typing; chrome fades out.
    @Published var isTyping = false
    /// Editor scroll position (0...1), mirrored by the Preview.
    let scroll = CurrentValueSubject<CGFloat, Never>(0)
}

extension Notification.Name {
    /// A file or folder in the Library moved; `userInfo` has `from` and `to` URLs (`to` is absent when trashed).
    static let libraryItemMoved = Notification.Name("libraryItemMoved")
}

/// State of one window: which document is open, what the Library shows, and which panes are visible.
final class WindowModel: ObservableObject {
    @Published var selection: OrganizerItem
    @Published var showLibrary: Bool { didSet { Preferences.store.set(showLibrary, forKey: "window.showLibrary") } }
    /// The sidebar (locations, favorites, smart folders, hashtags), hidden on its own with ⌥⌘S.
    @Published var showSidebar: Bool { didSet { Preferences.store.set(showSidebar, forKey: "window.showSidebar") } }
    @Published var showPreview: Bool { didSet { Preferences.store.set(showPreview, forKey: "window.showPreview"); refreshPreview() } }
    @Published var showAI: Bool { didSet { Preferences.store.set(showAI, forKey: "window.showAI") } }
    @Published var showQuickSearch = false
    @Published private(set) var fileURL: URL?
    /// The text the Preview shows. Kept apart from the window's state so a pause in typing only
    /// redraws the Preview, not the Library and headers.
    @Published private(set) var back: [URL] = []
    @Published private(set) var forward: [URL] = []

    let status = EditorStatus()
    let preview = PreviewSource()
    lazy var assistant = AssistantModel(window: self)
    weak var editor: EditorHost?

    private var lastWritten: String?
    private var lastModified: Date?
    private var isDirty = false
    /// The last save failed; one alert per failure streak, not one per autosave.
    private var saveFailing = false
    /// Created in this session and still named "Untitled": named after its first line, deleted if left empty.
    private var isFresh = false
    private var saveTimer: Timer?
    private var analysisTimer: Timer?
    private var statsTimer: Timer?
    private var typingTimer: Timer?
    private var statsGeneration = 0
    private var subscriptions: Set<AnyCancellable> = []
    private let library = Library.shared
    private var pendingURL: URL?

    var onFileChange: ((URL?) -> Void)?

    init(url: URL? = nil) {
        let defaults = Preferences.store
        showLibrary = defaults.object(forKey: "window.showLibrary") as? Bool ?? true
        showSidebar = defaults.object(forKey: "window.showSidebar") as? Bool ?? true
        showPreview = defaults.object(forKey: "window.showPreview") as? Bool ?? false
        showAI = defaults.object(forKey: "window.showAI") as? Bool ?? false
        selection = .folder(Library.shared.locations.first ?? Library.defaultLocation)
        pendingURL = url

        library.$revision.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.checkForExternalChanges() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.checkForExternalChanges() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in self?.finishEditing() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .libraryItemMoved)
            .sink { [weak self] note in
                guard let from = note.userInfo?["from"] as? URL else { return }
                self?.itemMoved(from: from, to: note.userInfo?["to"] as? URL)
            }
            .store(in: &subscriptions)
    }

    /// Called once the editor exists.
    func attach(_ editor: EditorHost) {
        self.editor = editor
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        let firstFile = library.items(for: selection).first { !$0.isFolder }?.url
        if let url = pendingURL ?? library.recents.first(where: exists) ?? firstFile {
            pendingURL = nil
            open(url, recordHistory: false)
        } else {
            newDocument()
        }
    }

    var title: String {
        guard let fileURL else { return "Untitled" }
        return Preferences.shared.showExtensions ? fileURL.lastPathComponent : fileURL.deletingPathExtension().lastPathComponent
    }

    var currentFolder: URL {
        switch selection {
        case .folder(let url): url
        default: fileURL?.deletingLastPathComponent() ?? library.locations.first ?? Library.defaultLocation
        }
    }

    // MARK: Opening

    func open(_ url: URL, recordHistory: Bool = true, selection: NSRange? = nil) {
        guard url != fileURL else { return }
        guard editor != nil else {
            // The window is still being built; `attach` opens it.
            pendingURL = url
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        // Never switch away from edits that couldn't be saved.
        guard finishEditing() else { return }
        if let current = fileURL, recordHistory, current != url {
            back.append(current)
            forward.removeAll()
        }
        let contents = TextDecoding.decode(data)
        let parsed = Annotations.parse(contents)
        fileURL = url
        lastWritten = contents
        lastModified = modificationDate(url)
        isDirty = false
        isFresh = false
        saveFailing = false
        editor?.load(LoadedDocument(text: parsed.body, runs: parsed.runs, selection: selection ?? NSRange(location: 0, length: 0)))
        library.noteOpened(url)
        onFileChange?(url)
        textChanged(parsed.body, userEdit: false)
        if case .folder(let folder) = self.selection, url.deletingLastPathComponent() != folder,
           library.location(containing: url) != nil {
            self.selection = .folder(url.deletingLastPathComponent())
        }
    }

    /// ⌘N: a new file in the folder the Library shows.
    func newDocument(in folder: URL? = nil) {
        let folder = folder ?? currentFolder
        guard let url = library.newFile(in: folder) else {
            NSSound.beep()
            return
        }
        open(url)
        guard fileURL == url else { return }
        isFresh = true
        selection = .folder(folder)
    }

    func goBack() {
        guard let url = back.last else { return }
        let current = fileURL
        open(url, recordHistory: false)
        guard fileURL == url else { return }
        back.removeLast()
        if let current { forward.append(current) }
    }

    func goForward() {
        guard let url = forward.last else { return }
        let current = fileURL
        open(url, recordHistory: false)
        guard fileURL == url else { return }
        forward.removeLast()
        if let current { back.append(current) }
    }

    /// ⌃⌘↑ / ⌃⌘↓: previous or next document in the File List.
    func goToAdjacent(_ offset: Int) {
        let files = library.items(for: selection).filter { !$0.isFolder }
        guard !files.isEmpty else { return }
        let index = files.firstIndex { $0.url == fileURL } ?? (offset > 0 ? -1 : files.count)
        let next = index + offset
        guard files.indices.contains(next) else { return }
        open(files[next].url)
    }

    // MARK: Editing

    /// Called after every edit (and with the text when a document loads). The search index is brought up
    /// to date on save, not on every keystroke.
    func textChanged(_ text: String? = nil, userEdit: Bool = true) {
        if let text, let fileURL { library.updateContents(text, for: fileURL) }
        if userEdit {
            isDirty = true
            scheduleSave()
            if !status.isTyping { status.isTyping = true }
            typingTimer?.invalidate()
            typingTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
                self?.status.isTyping = false
            }
        }
        analysisTimer?.invalidate()
        analysisTimer = Timer.scheduledTimer(withTimeInterval: userEdit ? 0.3 : 0, repeats: false) { [weak self] _ in
            self?.refreshStats()
            self?.refreshPreview()
        }
    }

    func selectionChanged() {
        // Selection moves with every keystroke; count once things settle.
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.refreshStats()
        }
    }

    /// Counts words, sentences and tasks of the selection (or the document) off the main thread.
    func refreshStats() {
        guard let editor else { return }
        let text = editor.selectedText() ?? editor.currentText()
        statsGeneration += 1
        let generation = statsGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let stats = TextAnalysis.stats(text)
            DispatchQueue.main.async {
                guard let self, generation == self.statsGeneration, stats != self.status.stats else { return }
                self.status.stats = stats
            }
        }
    }

    func refreshPreview() {
        guard showPreview, let editor else { return }
        let text = editor.currentText()
        if text != preview.text { preview.text = text }
    }

    // MARK: Saving

    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in self?.save() }
    }

    /// Writes the document if it changed, with its author annotations appended.
    /// Returns false if the edits could not be written.
    @discardableResult
    func save() -> Bool {
        saveTimer?.invalidate()
        guard let fileURL, let editor else { return true }
        let body = editor.currentText()
        let contents = Annotations.serialize(body: body, runs: editor.authorRuns())
        guard contents != lastWritten else {
            isDirty = false
            return true
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: fileURL, options: .atomic)
            library.updateContents(body, for: fileURL)
            lastWritten = contents
            lastModified = modificationDate(fileURL)
            isDirty = false
            saveFailing = false
            if isFresh, body.contains("\n") { nameAfterFirstLine() }
            return true
        } catch {
            isDirty = true
            if !saveFailing {
                saveFailing = true
                let alert = NSAlert(error: error)
                alert.informativeText = "Your text is still in the window. Use Save As… (⌥⇧⌘S) to keep it somewhere else."
                alert.runModal()
            }
            return false
        }
    }

    /// Saves, and tidies up a fresh untitled document: named after its first line, or removed if empty.
    /// Returns false if there are edits that could not be saved.
    @discardableResult
    func finishEditing() -> Bool {
        guard let fileURL, let editor else { return true }
        let body = editor.currentText()
        if isFresh && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // An empty file nobody wrote in: remove it outright rather than filling the Trash.
            try? FileManager.default.removeItem(at: fileURL)
            library.forget(fileURL)
            self.fileURL = nil
            isFresh = false
            isDirty = false
            saveTimer?.invalidate()
            return true
        }
        if isDirty || saveTimer?.isValid == true {
            guard save() else { return false }
        }
        if isFresh { nameAfterFirstLine() }
        isFresh = false
        return true
    }

    private func nameAfterFirstLine() {
        guard let url = fileURL, let editor,
              url.deletingPathExtension().lastPathComponent.hasPrefix("Untitled") else { return }
        let firstLine = editor.currentText().split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let firstLine else { return }
        let title = firstLine.replacingOccurrences(of: #"^\s*(#{1,6}\s+|>\s?|[-*+]\s+)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_~=`\[\]]"#, with: "", options: .regularExpression)
        let name = Library.sanitizedFileName(String(title.prefix(60)))
        guard !name.isEmpty else { return }
        let target = library.uniqueURL(in: url.deletingLastPathComponent(), base: name, extension: url.pathExtension)
        _ = library.rename(url, to: target.lastPathComponent)
    }

    func rename(to name: String) {
        guard fileURL != nil, save() else { return }
        if let url = fileURL, library.rename(url, to: name) != nil {
            isFresh = false
        } else {
            NSSound.beep()
        }
    }

    /// Whether the File List has keyboard focus (⌘D then deletes the selected note instead of
    /// toggling Focus Mode). The focused view is the list's table when it sits in the File List column.
    /// SwiftUI's list doesn't take keyboard focus when a row is clicked, so this tracks the last place the
    /// writer worked: a click in the File List sets it, typing focus anywhere else clears it.
    var fileListHasFocus: Bool {
        guard showLibrary, fileListActive, let window = WindowRegistry.shared.window(for: self) else { return false }
        return !(window.firstResponder is NSText)
    }

    /// Set when a row in the File List is clicked; cleared when the editor (or a text field) takes focus.
    var fileListActive = false

    /// ⌘D in the File List (and ⌫ there): moves the selected note to the Trash; the next one opens.
    func trashCurrentNote() {
        guard let url = fileURL else { return }
        // Saved first, so the Trash holds the latest text.
        save()
        Library.shared.trash(url)
    }

    /// File > Rename…: asks for a new name for the open document.
    func promptRename(window: NSWindow?) {
        guard fileURL != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Document"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: title)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, name != self?.title { self?.rename(to: name) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    /// Keeps the open document's location in sync when it, or a folder above it, moves or is trashed.
    private func itemMoved(from: URL, to: URL?) {
        guard let current = fileURL else { return }
        let path = current.path
        let isInside = path == from.path || path.hasPrefix(from.path + "/")
        guard isInside else {
            back = back.map { remap($0, from: from, to: to) }.compactMap { $0 }
            forward = forward.map { remap($0, from: from, to: to) }.compactMap { $0 }
            return
        }
        guard let to, let moved = remap(current, from: from, to: to) else {
            fileRemoved(current)
            return
        }
        fileURL = moved
        lastModified = modificationDate(moved)
        onFileChange?(moved)
        back = back.compactMap { remap($0, from: from, to: to) }
        forward = forward.compactMap { remap($0, from: from, to: to) }
    }

    private func remap(_ url: URL, from: URL, to: URL?) -> URL? {
        if url.path == from.path { return to }
        guard url.path.hasPrefix(from.path + "/") else { return url }
        guard let to else { return nil }
        return URL(fileURLWithPath: to.path + url.path.dropFirst(from.path.count))
    }

    /// The open file was trashed from the Library.
    func fileRemoved(_ url: URL) {
        guard fileURL == url else { return }
        saveTimer?.invalidate()
        isDirty = false
        fileURL = nil
        isFresh = false
        if let next = library.items(for: selection).first(where: { !$0.isFolder && $0.url != url }) {
            open(next.url, recordHistory: false)
        } else {
            editor?.load(LoadedDocument(text: "", runs: [], selection: NSRange(location: 0, length: 0)))
            onFileChange?(nil)
        }
    }

    /// Reloads the open document if another app changed it and there are no unsaved edits here.
    func checkForExternalChanges() {
        guard let fileURL, !isDirty, let editor else { return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        guard let modified = modificationDate(fileURL), let known = lastModified, modified > known,
              let data = try? Data(contentsOf: fileURL) else { return }
        let contents = TextDecoding.decode(data)
        lastModified = modified
        guard contents != lastWritten else { return }
        lastWritten = contents
        let parsed = Annotations.parse(contents)
        let selection = editor.textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        let clamped = NSRange(location: min(selection.location, (parsed.body as NSString).length), length: 0)
        editor.load(LoadedDocument(text: parsed.body, runs: parsed.runs, selection: clamped))
        textChanged(parsed.body, userEdit: false)
    }

    private func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    // MARK: Files

    /// ⇧⌘S: duplicates the open file and switches to the copy.
    func duplicate() {
        guard let fileURL, save() else { return }
        if let copy = library.duplicate(fileURL) { open(copy) }
    }

    /// ⌥⇧⌘S: writes the document somewhere else and continues editing there.
    func saveAs(window: NSWindow?) {
        guard let editor else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.markdownText, .plainText]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Untitled.\(Preferences.shared.defaultExtension)"
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            let contents = Annotations.serialize(body: editor.currentText(), runs: editor.authorRuns())
            do {
                try Data(contents.utf8).write(to: url, options: .atomic)
                // The old file keeps its last saved state; editing continues in the new one.
                self.isDirty = false
                self.saveTimer?.invalidate()
                self.isFresh = false
                self.library.changed()
                self.open(url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) } else { completion(panel.runModal()) }
    }

    /// ⌘O: opens any text file, in or outside the Library.
    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.markdownText, .plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    /// Wikilink or markdown link activated in the editor or Preview.
    func follow(link: String) {
        if link.hasPrefix("wikilink:") {
            let target = String(link.dropFirst("wikilink:".count)).removingPercentEncoding ?? ""
            followWikilink(target)
            return
        }
        if let url = URL(string: link), let scheme = url.scheme, scheme != "file" {
            if ["http", "https", "mailto"].contains(scheme.lowercased()) { NSWorkspace.shared.open(url) } else { NSSound.beep() }
            return
        }
        // A relative link to another document.
        let path = link.removingPercentEncoding ?? link
        let base = fileURL?.deletingLastPathComponent() ?? currentFolder
        let target = path.hasPrefix("file:") ? URL(string: path) : URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        guard let target, FileManager.default.fileExists(atPath: target.path) else { NSSound.beep(); return }
        if Library.textExtensions.contains(target.pathExtension.lowercased()) {
            open(target)
        } else {
            // Show other files rather than launching them: a link must never run an app or script.
            NSWorkspace.shared.activateFileViewerSelecting([target])
        }
    }

    func followWikilink(_ target: String) {
        guard !target.isEmpty else { return }
        if let url = library.resolve(wikilink: target, from: fileURL) {
            open(url)
            return
        }
        // A link to a document that doesn't exist yet creates it, as in a wiki.
        let name = Library.sanitizedFileName(target)
        guard !name.isEmpty, let url = library.newFile(in: fileURL?.deletingLastPathComponent() ?? currentFolder,
                                                       named: name, contents: "# \(target)\n\n") else { return }
        open(url)
    }
}

/// Reads text files in whatever encoding they use; everything is written back as UTF-8.
enum TextDecoding {
    static func decode(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        var converted: NSString?
        let encoding = NSString.stringEncoding(for: data, encodingOptions: [.allowLossyKey: false],
                                               convertedString: &converted, usedLossyConversion: nil)
        if encoding != 0, let converted { return converted as String }
        // Latin-1 maps every byte, so nothing is ever replaced or lost.
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }
}
