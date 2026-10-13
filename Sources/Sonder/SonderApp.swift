import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let markdownText = UTType(importedAs: "net.daringfireball.markdown")
}

@main
enum Main {
    static func main() {
        migrateSettings()
        Theme.registerBundledFonts()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--hit-test"), args.count > i + 1 {
            Snapshot.hitTest(input: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), args.count > i + 2 {
            Snapshot.run(input: args[i + 1], outputDirectory: args[i + 2])
            return
        }
        SonderApp.main()
    }
}

extension Main {
    /// The app used to be called Markdown (com.frizurd.markdown). Its settings, Library locations,
    /// favorites and recents come along once, the first time Sonder runs.
    static func migrateSettings() {
        guard ProcessInfo.processInfo.environment["SONDER_DEFAULTS_SUITE"] == nil,
              let id = Bundle.main.bundleIdentifier, id != "com.frizurd.markdown" else { return }
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "sonder.migratedSettings") == nil else { return }
        if let old = defaults.persistentDomain(forName: "com.frizurd.markdown"), !old.isEmpty,
           defaults.persistentDomain(forName: id)?.isEmpty ?? true {
            defaults.setPersistentDomain(old, forName: id)
        }
        defaults.set(true, forKey: "sonder.migratedSettings")
    }
}

/// Shortcuts that must work no matter what has focus.
enum KeyCommands {
    private static var monitor: Any?

    /// ⌘P opens Open Quickly from anywhere in the app: caught before menus, text views or panels see
    /// it, so focus, SwiftUI state or a duplicate key event can't get in the way.
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
            guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "p" else { return event }
            if !QuickOpenPanel.present() { NSSound.beep() }
            return nil
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        KeyCommands.install()
        Preferences.shared.applyAppearance()
        _ = AIToolbox.shared
        // Development aid: `--debug-menus` prints every menu item with a shortcut, and whether it's enabled.
        if CommandLine.arguments.contains("--debug-menus") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                func dump(_ menu: NSMenu, _ path: String) {
                    menu.update()
                    for item in menu.items {
                        if let sub = item.submenu { dump(sub, path + " > " + item.title) }
                        guard !item.keyEquivalent.isEmpty else { continue }
                        let mods = item.keyEquivalentModifierMask
                        let symbol = (mods.contains(.control) ? "⌃" : "") + (mods.contains(.option) ? "⌥" : "")
                            + (mods.contains(.shift) ? "⇧" : "") + (mods.contains(.command) ? "⌘" : "")
                        print("\(symbol)\(item.keyEquivalent)\t\(item.isEnabled ? "on " : "OFF")\t\(path) > \(item.title)")
                    }
                }
                if let main = NSApp.mainMenu { dump(main, "") }
                fflush(stdout)
            }
        }
        // Development aid: `--debug-open-quickly` opens the palette shortly after launch and logs its state.
        if CommandLine.arguments.contains("--debug-open-quickly") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                guard let model = WindowRegistry.shared.activeModel else { return print("no window") }
                model.showQuickSearch = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    let panel = NSApp.windows.first { $0 is QuickOpenPanel && $0.isVisible }
                    print("open quickly: visible=\(panel != nil) key=\(panel?.isKeyWindow == true) appActive=\(NSApp.isActive) fieldFocused=\(panel?.firstResponder is NSText) flag=\(model.showQuickSearch)")
                    fflush(stdout)
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        WindowRegistry.shared.open(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

struct SonderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main", for: URL.self) { $url in
            ContentView(windowURL: $url)
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1180, height: 760)
        .commands { AppCommands() }

        Settings { SettingsView() }
    }
}

struct AppCommands: Commands {
    @FocusedObject private var model: WindowModel?
    @ObservedObject private var prefs = Preferences.shared
    /// Not observed: the Library changes on every save, and the menus don't need rebuilding for that.
    private var library: Library { Library.shared }
    @Environment(\.openWindow) private var openWindow

    private var window: NSWindow? { model.flatMap { WindowRegistry.shared.window(for: $0) } }

    var body: some Commands {
        // MARK: File
        CommandGroup(replacing: .newItem) {
            Button("New File") { model?.newDocument() }
                .keyboardShortcut("n")
            Button("New Window") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Folder") {
                if let model, let url = library.newFolder(in: model.currentFolder) { model.selection = .folder(url) }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open…") { model?.openWithPanel() }
                .keyboardShortcut("o")
            Button("Open Quickly…") { QuickOpenPanel.present(for: model) }
                .keyboardShortcut("p")
            Button("Search Notes…") { QuickOpenPanel.present(for: model) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { model?.save() }
                .keyboardShortcut("s")
            Button("Duplicate") { model?.duplicate() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Save As…") { model?.saveAs(window: window) }
                .keyboardShortcut("s", modifiers: [.command, .shift, .option])
            Button("Rename…") { model?.promptRename(window: window) }
            Divider()
            Button("Show in Finder") {
                if let url = model?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            Button(model?.fileURL.map { library.favorites.contains($0) } == true ? "Remove from Favorites" : "Add to Favorites") {
                if let url = model?.fileURL { library.toggleFavorite(url) }
            }
            // ⌘D also does this while the File List has focus (see FocusMenuItems).
            Button("Move to Trash") { model?.trashCurrentNote() }
                .disabled(model?.fileURL == nil)
        }
        CommandGroup(replacing: .importExport) {
            Button("Export…") { withText { Exporter.shared.export(markdown: $0, fileURL: model?.fileURL, window: window) } }
                .keyboardShortcut("e", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") { Exporter.shared.pageSetup(window: window) }
            // ⌘P opens Open Quickly; printing moves to ⇧⌘P.
            Button("Print…") { withText { Exporter.shared.print(markdown: $0, fileURL: model?.fileURL, window: window) } }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Print Plain Text…") { withText { Exporter.shared.printPlainText($0, window: window) } }
                .keyboardShortcut("p", modifiers: [.command, .option])
        }

        // MARK: Edit
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy Formatted") { withSelection { Exporter.shared.copyFormatted($0, fileURL: model?.fileURL) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("Copy as HTML") { withSelection { Exporter.shared.copyAsHTML($0, fileURL: model?.fileURL) } }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Button("Copy as Markdown") { withSelection { Exporter.shared.copyAsMarkdown($0, fileURL: model?.fileURL) } }
                .keyboardShortcut("c", modifiers: [.command, .control])
            Menu("Paste As") {
                Button("Paste as \(Author.ai.name)") { textView?.paste(as: .ai) }
                Button("Paste as \(Author.reference.name)") { textView?.paste(as: .reference) }
                Button("Paste as \(Author.me.name)") { textView?.paste(as: .me) }
                Divider()
                Button("Paste Edits from AI") { textView?.pasteEditsFromAI(nil) }
            }
            Divider()
            Menu("Find") {
                Button("Find…") { find(.showFindInterface) }.keyboardShortcut("f")
                Button("Find and Replace…") { find(.showReplaceInterface) }.keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find Next") { find(.nextMatch) }.keyboardShortcut("g")
                Button("Find Previous") { find(.previousMatch) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { find(.setSearchString) }.keyboardShortcut("e")
            }
            Divider()
            Button("Move Line Up") { textView?.moveLinesUp(nil) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Move Line Down") { textView?.moveLinesDown(nil) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }

        // MARK: Format
        CommandMenu("Format") {
            Menu("Heading") {
                ForEach(1...6, id: \.self) { level in
                    Button("Heading \(level)") { textView?.setHeading(level) }
                        .keyboardShortcut(KeyEquivalent(Character("\(level)")))
                }
            }
            Divider()
            Button("Bold") { textView?.toggleBold(nil) }.keyboardShortcut("b")
            Button("Italic") { textView?.toggleItalic(nil) }.keyboardShortcut("i")
            Button("Strikethrough") { textView?.toggleStrikethrough(nil) }.keyboardShortcut("u", modifiers: [.command, .option])
            Button("Highlight") { textView?.toggleHighlight(nil) }.keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Code") { textView?.toggleInlineCode(nil) }.keyboardShortcut("j")
            Button("Code Block") { textView?.toggleCodeBlock(nil) }.keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button("Link") { textView?.insertLink(nil) }.keyboardShortcut("k")
            Button("Image") { textView?.insertImageLink(nil) }.keyboardShortcut("k", modifiers: [.command, .option])
            Button("Wikilink") { textView?.insertWikilink(nil) }.keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Footnote") { textView?.insertFootnote(nil) }.keyboardShortcut("k", modifiers: [.command, .control])
            Divider()
            Button("List") { textView?.toggleBulletList(nil) }.keyboardShortcut("l")
            Button("Task List") { textView?.toggleTaskList(nil) }.keyboardShortcut("l", modifiers: [.command, .option])
            Button("Ordered List") { textView?.toggleOrderedList(nil) }.keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Ordered Task List") { textView?.toggleOrderedTaskList(nil) }
                .keyboardShortcut("l", modifiers: [.command, .option, .shift])
            Button("Mark Task as Completed") { textView?.toggleTaskDone(nil) }.keyboardShortcut("x", modifiers: [.command, .option])
            Divider()
            Button("Indent") { textView?.insertTab(nil) }
            Button("Outdent") { textView?.insertBacktab(nil) }
        }

        // MARK: Focus
        CommandMenu("Focus") {
            FocusMenuItems(model: model, inMenuBar: true)
        }

        // MARK: View
        // SwiftUI's own Toggle Sidebar (⌥⌘S) is replaced by Show/Hide Sidebar below.
        CommandGroup(replacing: .sidebar) {}
        CommandGroup(before: .toolbar) {
            Button(model?.showSidebar == true ? "Hide Sidebar" : "Show Sidebar") {
                model?.showSidebar.toggle()
                if model?.showSidebar == true { model?.showLibrary = true }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Button(model?.showLibrary == true ? "Hide Library" : "Show Library") { model?.showLibrary.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button(model?.showPreview == true ? "Hide Preview" : "Show Preview") { model?.showPreview.toggle() }
                .keyboardShortcut("r")
            Button(model?.showAI == true ? "Hide Assistant" : "Show Assistant") { model?.showAI.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Button("Toggle Dark Mode") { prefs.toggleAppearance() }
                .keyboardShortcut("n", modifiers: [.command, .control])
            Divider()
            Button("Larger Text") { prefs.adjustTextSize(by: 1) }.keyboardShortcut("=")
            Button("Smaller Text") { prefs.adjustTextSize(by: -1) }.keyboardShortcut("-")
            Button("Default Text Size") { prefs.textSize = Preferences.defaultTextSize }.keyboardShortcut("0")
            Picker("Line Length", selection: $prefs.lineLength) {
                ForEach(Preferences.lineLengths, id: \.self) { Text("\($0) Characters").tag($0) }
            }
            Picker("Typeface", selection: $prefs.typeface) {
                ForEach(Typeface.allCases) { Text($0.title).tag($0) }
            }
            Picker("Template", selection: $prefs.template) {
                ForEach(PreviewTemplate.allCases) { Text($0.title).tag($0) }
            }
            Divider()
        }

        // MARK: Assistant
        CommandMenu("Assistant") {
            Button(model?.showAI == true ? "Hide Assistant" : "Show Assistant") { model?.showAI.toggle() }
            Divider()
            ForEach(AssistantModel.Action.allCases) { action in
                Button(action.title) {
                    model?.showAI = true
                    model?.assistant.perform(action)
                }
            }
            Divider()
            Button("Stop") { model?.assistant.stop() }
                .keyboardShortcut(".", modifiers: .command)
            Button("Look for AI Tools Again") { AIToolbox.shared.rescan() }
        }

        // MARK: Go
        CommandMenu("Go") {
            Button("Back") { model?.goBack() }.keyboardShortcut(.leftArrow, modifiers: [.command, .control])
            Button("Forward") { model?.goForward() }.keyboardShortcut(.rightArrow, modifiers: [.command, .control])
            Button("Previous Document") { model?.goToAdjacent(-1) }.keyboardShortcut(.upArrow, modifiers: [.command, .control])
            Button("Next Document") { model?.goToAdjacent(1) }.keyboardShortcut(.downArrow, modifiers: [.command, .control])
            Button("Open Link") { textView?.openLinkAtCaret(nil) }.keyboardShortcut(.return)
            Divider()
            Button("Recents") { model?.selection = .recents }
            ForEach(Array(library.favorites.prefix(9).enumerated()), id: \.element) { index, url in
                Button(url.deletingPathExtension().lastPathComponent) {
                    if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        model?.selection = .folder(url)
                        model?.showLibrary = true
                    } else {
                        model?.open(url)
                    }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
            Divider()
            Button("Add Location…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url {
                    library.addLocation(url)
                    model?.selection = .folder(url)
                }
            }
        }
    }

    private var textView: MarkdownTextView? { model?.editor?.textView }

    private func withText(_ action: (String) -> Void) {
        guard let text = model?.editor?.currentText() else { return }
        action(text)
    }

    /// The selection, or the whole document when nothing is selected.
    private func withSelection(_ action: (String) -> Void) {
        guard let editor = model?.editor else { return }
        action(editor.selectedText() ?? editor.currentText())
    }

    private func find(_ action: NSTextFinder.Action) {
        guard let textView else { return }
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.window?.makeFirstResponder(textView)
        textView.performTextFinderAction(item)
    }
}
