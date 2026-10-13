import AppKit
import SwiftUI

/// Shared geometry of the window chrome. The empty unified toolbar makes the title bar `barHeight`
/// tall with the window buttons centered in it; every column header uses the same height, so all
/// controls sit on the window buttons' center line.
enum Chrome {
    static let barHeight: CGFloat = 52
    static let buttonSize: CGFloat = 32
    /// Room for the close, minimize and zoom buttons when nothing else is under them.
    static let windowButtonsWidth: CGFloat = 84
    static let sidebarWidth: CGFloat = 220
    static let fileListWidth: CGFloat = 300
    /// With the sidebar hidden the notes list also sits under the window buttons, so it gets wider.
    static let fileListWidthAlone: CGFloat = 360

    static func fileListWidth(sidebar: Bool) -> CGFloat { sidebar ? fileListWidth : fileListWidthAlone }
}

/// One writing window: a floating glass Organizer, the File List, the Editor with optional Preview,
/// and the Assistant on the right.
struct ContentView: View {
    @Binding var windowURL: URL?
    @StateObject private var model: WindowModel
    @ObservedObject private var prefs = Preferences.shared
    @Environment(\.openWindow) private var openWindow

    init(windowURL: Binding<URL?>) {
        _windowURL = windowURL
        _model = StateObject(wrappedValue: WindowModel(url: windowURL.wrappedValue))
    }

    var body: some View {
        HStack(spacing: 0) {
            if model.showLibrary {
                if model.showSidebar {
                    Organizer(model: model)
                        .frame(width: Chrome.sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider().ignoresSafeArea()
                }
                FileList(model: model)
                    .frame(width: Chrome.fileListWidth(sidebar: model.showSidebar))
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider().ignoresSafeArea()
            }
            EditorArea(model: model)
                .frame(minWidth: 380, maxWidth: .infinity)
            if model.showAI {
                Divider().ignoresSafeArea()
                AssistantPane(model: model)
                    .frame(width: 340)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.28), value: model.showLibrary)
        .animation(.smooth(duration: 0.28), value: model.showSidebar)
        .animation(.smooth(duration: 0.28), value: model.showAI)
        .background(Color.editorBackground)
        .ignoresSafeArea()
        .overlay(alignment: .top) {
            if let controller = model.quickOpen {
                // The whole window dims behind Open Quickly; clicking the dimmed part closes it.
                ZStack(alignment: .top) {
                    QuickOpenScrim { QuickOpen.hide(for: model) }
                    QuickSearch(controller: controller)
                        .padding(.top, 86)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: model.quickOpen != nil)
        .frame(minWidth: 640, minHeight: 400)
        .background(WindowConfigurator(model: model))
        .focusedSceneObject(model)
        .onAppear {
            model.onFileChange = { url in windowURL = url }
            WindowRegistry.shared.register(model)
            WindowRegistry.shared.openWindow = { url in openWindow(value: url) }
        }
        .onDisappear { model.finishEditing() }
    }
}

/// Content under a transparent title bar, with an empty unified toolbar so the title bar has the
/// standard toolbar height and the window buttons sit centered in it.
private struct WindowConfigurator: NSViewRepresentable {
    let model: WindowModel

    func makeNSView(context: Context) -> NSView {
        ConfiguratorView(model: model)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.title = model.title
        nsView.window?.representedURL = model.fileURL
    }

    /// Configures its window as soon as it is added to one.
    final class ConfiguratorView: NSView {
        let model: WindowModel
        private var observers: [NSObjectProtocol] = []

        init(model: WindowModel) {
            self.model = model
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            if window.toolbar == nil {
                let toolbar = NSToolbar(identifier: "Sonder.window")
                toolbar.showsBaselineSeparator = false
                toolbar.allowsUserCustomization = false
                // Icons only, always; names show as tooltips. No Icon/Text menu on right-click.
                toolbar.displayMode = .iconOnly
                if #available(macOS 15.0, *) { toolbar.allowsDisplayModeCustomization = false }
                window.toolbar = toolbar
            }
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = Theme.background
            window.tabbingMode = .preferred
            WindowRegistry.shared.associate(window, with: model)
            TitlebarHeader.install(in: window, model: model)
            observers.forEach(NotificationCenter.default.removeObserver)
            // Full screen moves the title bar into another window; put the header back afterwards.
            observers = [NSWindow.didExitFullScreenNotification, NSWindow.didEnterFullScreenNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    guard let self, let window else { return }
                    TitlebarHeader.install(in: window, model: self.model)
                }
            }
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
        }
    }
}

/// Finds the window model for app-level actions (opening files from Finder, menu commands without focus).
final class WindowRegistry {
    static let shared = WindowRegistry()

    private struct Entry {
        weak var model: WindowModel?
        weak var window: NSWindow?
    }

    private var entries: [Entry] = []
    var openWindow: ((URL?) -> Void)?
    var pendingURLs: [URL] = []

    func register(_ model: WindowModel) {
        entries.removeAll { $0.model == nil }
        entries.append(Entry(model: model))
        if !pendingURLs.isEmpty {
            let urls = pendingURLs
            pendingURLs = []
            DispatchQueue.main.async { urls.forEach { model.open($0) } }
        }
    }

    func associate(_ window: NSWindow, with model: WindowModel) {
        if let i = entries.firstIndex(where: { $0.model === model }) { entries[i].window = window }
    }

    var activeModel: WindowModel? {
        // A panel (Open Quickly) stands in for the window it belongs to.
        for candidate in [NSApp.keyWindow, NSApp.keyWindow?.parent, NSApp.mainWindow] {
            if let candidate, let model = entries.first(where: { $0.window === candidate && $0.model != nil })?.model {
                return model
            }
        }
        return entries.last { $0.model != nil }?.model
    }

    func window(for model: WindowModel) -> NSWindow? {
        entries.first { $0.model === model }?.window
    }

    /// Opens files from Finder in the front window, or a new one if none is open.
    func open(_ urls: [URL]) {
        if let model = activeModel {
            urls.forEach { model.open($0) }
            window(for: model)?.makeKeyAndOrderFront(nil)
        } else if let openWindow {
            urls.forEach { openWindow($0) }
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }
}

// MARK: - Editor area

/// The editor (and Preview beside it) under a glass header: Library toggle and history on the left,
/// the document title in the middle, Focus, Preview and Assistant on the right.
struct EditorArea: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        HSplitView {
            EditorColumn(model: model)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            if model.showPreview {
                // Runs under the header like the editor; the page leaves room for it (body.preview).
                PreviewWebView(model: model, prefs: prefs)
                    .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.editorBackground)
                    .ignoresSafeArea()
            }
        }
        // Both panes run under the header (which lives in the title bar); their own insets keep text clear.
        .ignoresSafeArea()
        // Text scrolling up under the header blurs out progressively, all the way to the window's
        // top edge and behind the header's controls, like the notes list under its bar.
        .overlay(alignment: .top) {
            ZStack {
                ProgressiveBlur()
                LinearGradient(stops: ProgressiveBlur.fadeStops(from: .editorBackground, maxOpacity: 0.35),
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(height: Chrome.barHeight + 8)
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }
}

/// The editor's title-bar header: Library toggle and history on the left, the document title in the
/// middle, Focus, Template, Preview and Assistant on the right.
struct EditorHeader: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        ZStack {
            HStack(spacing: 10) {
                if !model.showLibrary { Spacer().frame(width: Chrome.windowButtonsWidth - 10) }
                GlassIconButton(symbol: "sidebar.left", help: "Show or hide the Library (⌃⌘S)") {
                    model.showLibrary.toggle()
                }
                GlassButtonGroup {
                    GroupIconButton(symbol: "chevron.left", help: "Back (⌃⌘←)") { model.goBack() }
                        .disabled(model.back.isEmpty)
                    GroupIconButton(symbol: "chevron.right", help: "Forward (⌃⌘→)") { model.goForward() }
                        .disabled(model.forward.isEmpty)
                }
                Spacer(minLength: 12)
                GlassButtonGroup {
                    FocusMenu()
                    if model.showPreview {
                        Menu {
                            Picker("Template", selection: $prefs.template) {
                                ForEach(PreviewTemplate.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            GroupIconLabel(symbol: "textformat")
                        }
                        .menuStyle(.button)
                        .buttonStyle(HeaderButtonStyle(shape: .capsule))
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Preview template")
                    }
                    GroupIconButton(symbol: "doc.richtext", help: "Preview (⌘R)", isOn: model.showPreview) {
                        model.showPreview.toggle()
                    }
                    GroupIconButton(symbol: "sparkles", help: "Assistant (⌥⌘I)", isOn: model.showAI) {
                        model.showAI.toggle()
                    }
                }
            }
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: 280)
                .onTapGesture(count: 2) { model.promptRename(window: NSApp.keyWindow) }
                .help("Double-click to rename")
        }
        .padding(.horizontal, 12)
    }
}

/// Every column's header in one row, laid out over the same column widths as the window content.
/// It is installed inside the window's title bar (see `TitlebarHeader`): content views under the
/// title bar never get clicks there, so the controls have to live in it.
struct WindowHeader: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        HStack(spacing: 0) {
            if model.showLibrary {
                if model.showSidebar { Color.clear.frame(width: Chrome.sidebarWidth + 1) }
                FileListHeader(model: model).frame(width: Chrome.fileListWidth(sidebar: model.showSidebar))
                Color.clear.frame(width: 1)
            }
            EditorHeader(model: model).frame(maxWidth: .infinity)
            if model.showAI {
                Color.clear.frame(width: 1)
                AssistantHeader(assistant: model.assistant).frame(width: 340)
            }
        }
        .frame(height: Chrome.barHeight)
        .background(WindowDragArea())
        // The header row dims with the rest of the window while Open Quickly is up.
        .overlay {
            if model.quickOpen != nil {
                QuickOpenScrim { QuickOpen.hide(for: model) }
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.14), value: model.quickOpen != nil)
        .animation(.smooth(duration: 0.28), value: model.showLibrary)
        .animation(.smooth(duration: 0.28), value: model.showSidebar)
        .animation(.smooth(duration: 0.28), value: model.showAI)
    }
}

/// Hosts `WindowHeader` inside the title bar view, under the window buttons.
enum TitlebarHeader {
    private static let identifier = NSUserInterfaceItemIdentifier("Sonder.titlebarHeader")

    static func install(in window: NSWindow, model: WindowModel) {
        guard let titlebar = window.standardWindowButton(.closeButton)?.superview else { return }
        if titlebar.subviews.contains(where: { $0.identifier == identifier }) { return }
        let host = HeaderHostingView(rootView: WindowHeader(model: model))
        host.identifier = identifier
        host.frame = titlebar.bounds
        host.autoresizingMask = [.width, .height]
        host.sceneBridgingOptions = []
        titlebar.addSubview(host, positioned: .below, relativeTo: window.standardWindowButton(.closeButton))
    }
}

struct EditorColumn: View {
    let model: WindowModel
    @ObservedObject private var status: EditorStatus
    @ObservedObject private var prefs = Preferences.shared

    init(model: WindowModel) {
        self.model = model
        status = model.status
    }

    private var statusVisible: Bool {
        switch prefs.toolbar {
        case .always: true
        case .hidden: false
        case .fade: !status.isTyping
        }
    }

    var body: some View {
        MarkdownEditor(model: model)
            .ignoresSafeArea()
            .overlay(alignment: .bottomTrailing) {
                StatusBar(model: model)
                    .padding(14)
                    .opacity(statusVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.35), value: statusVisible)
            }
            .background(Color.editorBackground)
            .onContinuousHover { phase in
                if case .active = phase, status.isTyping { status.isTyping = false }
            }
    }
}

struct SoftTopEdge: ViewModifier {
    let height: CGFloat
    let color: Color
    /// Off for a list: the fade only shows once rows have scrolled up under the header, so it never
    /// veils the top rows at rest.
    var showsAtRest = true
    private let tail: CGFloat = 28
    @State private var scrolled = false

    func body(content: Content) -> some View {
        trackScroll(hideSystemEdge(content))
            .overlay(alignment: .top) {
                let total = height + tail
                let solid = height / total
                // Solid under the header (covering the system's own title-bar edge), then blur that fades out.
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    LinearGradient(stops: [.init(color: color, location: 0), .init(color: color, location: solid),
                                           .init(color: color.opacity(0.4), location: 1)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                             .init(color: .black, location: solid),
                                             .init(color: .black.opacity(0.6), location: solid + (1 - solid) * 0.4),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: total)
                .opacity(showsAtRest || scrolled ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: scrolled)
                // At rest only the plain strip under the header stays, still covering the system's edge.
                .background(alignment: .top) { color.frame(height: height + 1) }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
    }

    @ViewBuilder
    private func trackScroll(_ content: some View) -> some View {
        if #available(macOS 15.0, *), !showsAtRest {
            content.onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 0.5 } action: { _, now in
                scrolled = now
            }
        } else {
            content
        }
    }

    @ViewBuilder
    private func hideSystemEdge(_ content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .top)
        } else {
            content
        }
    }
}

/// The dimmed layer behind Open Quickly.
struct QuickOpenScrim: View {
    let dismiss: () -> Void

    var body: some View {
        Color.black.opacity(0.32)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: dismiss)
    }
}

// MARK: - Glass controls

/// A round glass button with an icon, the size of a toolbar item.
struct GlassIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: Chrome.buttonSize, height: Chrome.buttonSize)
                .contentShape(Circle())
        }
        .buttonStyle(HeaderButtonStyle(shape: .circle))
        .glassCircle()
        .help(help)
    }
}

/// Several icon buttons sharing one glass capsule, like grouped toolbar items.
struct GlassButtonGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(.horizontal, 3)
            .frame(height: Chrome.buttonSize)
            .glassCapsule(interactive: true)
    }
}

struct GroupIconLabel: View {
    let symbol: String
    var isOn = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(isOn ? Color.accentColor : Color.primary.opacity(0.75))
            .frame(width: 34, height: Chrome.buttonSize - 4)
            .contentShape(Rectangle())
    }
}

struct GroupIconButton: View {
    let symbol: String
    let help: String
    var isOn = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            GroupIconLabel(symbol: symbol, isOn: isOn)
                .opacity(isEnabled ? 1 : 0.35)
        }
        .buttonStyle(HeaderButtonStyle(shape: .capsule))
        .help(help)
    }
}

/// The Focus dropdown: Focus Mode, Syntax Highlight, Style Check and Authors.
struct FocusMenu: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Menu {
            FocusMenuItems()
        } label: {
            GroupIconLabel(symbol: prefs.focusMode ? "scope" : "circle.dashed", isOn: prefs.focusMode)
        }
        .menuStyle(.button)
        .buttonStyle(HeaderButtonStyle(shape: .capsule))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Focus (⌘D)")
    }
}

/// Shared by the Focus dropdown and the Focus menu in the menu bar.
struct FocusMenuItems: View {
    /// In the menu bar, the items carry their keyboard shortcuts, and ⌘D in the File List deletes
    /// the selected note instead.
    var model: WindowModel?
    var inMenuBar = false
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        if inMenuBar {
            Toggle("Focus Mode", isOn: Binding(
                get: { prefs.focusMode },
                set: { on in
                    if let model, model.fileListHasFocus {
                        model.trashCurrentNote()
                    } else {
                        prefs.focusMode = on
                    }
                }))
                .keyboardShortcut("d")
        } else {
            Toggle("Focus Mode", isOn: $prefs.focusMode)
        }
        Picker("Focus On", selection: $prefs.focusScope) {
            ForEach(FocusScope.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        Divider()
        Toggle("Syntax Highlight", isOn: $prefs.syntaxHighlight)
            .keyboardShortcut("d", modifiers: [.command, .shift])
        Menu("Highlight") {
            ForEach(PartOfSpeech.allCases) { part in
                Toggle(part.title, isOn: Binding(
                    get: { prefs.syntaxParts.contains(part) },
                    set: { on in if on { prefs.syntaxParts.insert(part) } else { prefs.syntaxParts.remove(part) } }))
            }
        }
        Divider()
        Toggle("Style Check", isOn: $prefs.styleCheck)
            .keyboardShortcut("d", modifiers: [.command, .shift, .option])
        Menu("Check For") {
            ForEach(StyleCategory.allCases) { category in
                Toggle(category.title, isOn: Binding(
                    get: { prefs.styleCategories.contains(category) },
                    set: { on in if on { prefs.styleCategories.insert(category) } else { prefs.styleCategories.remove(category) } }))
            }
        }
        Divider()
        Toggle("Show Authors", isOn: $prefs.showAuthors)
            .keyboardShortcut("a", modifiers: [.command, .shift])
    }
}

/// The selected statistic, floating over the bottom corner of the editor.
struct StatusBar: View {
    @ObservedObject private var status: EditorStatus
    @ObservedObject private var prefs = Preferences.shared

    init(model: WindowModel) {
        status = model.status
    }

    var body: some View {
        Menu {
            Picker("Statistic", selection: $prefs.stat) {
                ForEach(Stat.allCases) { stat in
                    Text(status.stats.formatted(stat)).tag(stat)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(status.stats.formatted(prefs.stat))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassCapsule()
        .help("Statistics for the document, or the selection")
    }
}

/// Header buttons light up under the pointer and dim while pressed, like toolbar items.
struct HeaderButtonStyle: ButtonStyle {
    enum Shape { case circle, capsule }
    let shape: Shape

    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, shape: shape)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyle.Configuration
        let shape: Shape
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(.primary.opacity(0.8))
                .background {
                    let fill = Color.primary.opacity(configuration.isPressed ? 0.16 : hovering && isEnabled ? 0.08 : 0)
                    switch shape {
                    case .circle: Circle().fill(fill)
                    case .capsule: Capsule().fill(fill)
                    }
                }
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// The empty parts of the header move the window, and a double-click zooms it, like a title bar.
/// It sits behind the header's controls, which get their own clicks.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
            } else {
                window.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Hosts the header in the title bar. Clicks on it are never taken as window drags, so SwiftUI's
/// buttons get them; `WindowDragArea` behind the controls handles moving the window instead.
private final class HeaderHostingView: NSHostingView<WindowHeader> {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Liquid Glass

extension View {
    /// Liquid Glass on macOS 26 and later; a material on earlier systems.
    @ViewBuilder
    func glassCapsule(interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: Capsule())
        } else {
            background(.regularMaterial, in: Capsule())
        }
    }

    /// Rows scrolling up under a column's header blur and fade out smoothly: a blur material and the
    /// column's own color, both fading from the top of the column to `height` plus a soft tail. The
    /// system's hard title-bar edge (with its line) is turned off so only this shows.
    func softTopEdge(height: CGFloat, color: Color, showsAtRest: Bool = true) -> some View {
        modifier(SoftTopEdge(height: height, color: color, showsAtRest: showsAtRest))
    }

    /// A bar pinned over the top of a scrolling list. On macOS 26 the list keeps scrolling under it
    /// with the system's progressive (soft) blur; before that, a fading material stands in.
    @ViewBuilder
    func topBar<Bar: View>(height: CGFloat, color: Color, @ViewBuilder _ bar: () -> Bar) -> some View {
        if #available(macOS 26.0, *) {
            safeAreaBar(edge: .top, spacing: 0, content: bar)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            softTopEdge(height: height, color: color)
                .safeAreaInset(edge: .top, spacing: 0, content: bar)
        }
    }

    @ViewBuilder
    func glassCircle() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Circle())
        } else {
            background(.regularMaterial, in: Circle())
        }
    }

    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(Color.primary.opacity(0.08)))
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}
