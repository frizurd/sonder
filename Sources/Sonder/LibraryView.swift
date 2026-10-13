import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Organizer

/// What a sidebar row stands for: a place to list in the File List, or a favorite file to open.
enum SidebarItem: Hashable {
    case organizer(OrganizerItem)
    case file(URL)
}

/// The sidebar: Locations, Favorites, Smart Folders and Hashtags, as a native source list.
struct Organizer: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var library = Library.shared

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                // A location stays selected while one of its subfolders is shown.
                if case .folder(let folder) = model.selection, !library.locations.contains(folder),
                   !library.favorites.contains(folder), let location = library.location(containing: folder) {
                    return .organizer(.folder(location))
                }
                return .organizer(model.selection)
            },
            set: { item in
                model.fileListActive = false
                switch item {
                case .organizer(let organizer)?: model.selection = organizer
                case .file(let url)?: model.open(url)
                case nil: break
                }
            })
    }

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(library.locations, id: \.self) { url in
                    Label(url.lastPathComponent, systemImage: "folder")
                        .tag(SidebarItem.organizer(.folder(url)))
                        .contextMenu {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            if library.locations.count > 1 {
                                Button("Remove Location") { library.removeLocation(url) }
                            }
                        }
                }
            } header: {
                HStack {
                    Text("Locations")
                    Spacer()
                    Button(action: addLocation) { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .padding(.trailing, 10)
                        .help("Add Location…")
                }
            }

            if !library.favorites.isEmpty {
                Section("Favorites") {
                    ForEach(Array(library.favorites.enumerated()), id: \.element) { index, url in
                        favoriteRow(url, index: index)
                    }
                }
            }

            Section("Smart Folders") {
                Label("Recents", systemImage: "clock")
                    .tag(SidebarItem.organizer(.recents))
                ForEach(library.smartFolders) { folder in
                    Label(folder.name, systemImage: "gearshape")
                        .tag(SidebarItem.organizer(.smartFolder(folder)))
                        .contextMenu { Button("Remove Smart Folder") { library.removeSmartFolder(folder) } }
                }
            }

            if !library.hashtags.isEmpty {
                Section("Hashtags") {
                    ForEach(library.hashtags.keys.sorted(), id: \.self) { tag in
                        Label(tag, systemImage: "number")
                            .badge(library.hashtags[tag]?.count ?? 0)
                            .tag(SidebarItem.organizer(.hashtag(tag)))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        // The window buttons sit in the panel's top strip, as in a macOS 26 sidebar.
        // A flat column; the window buttons sit in its top strip.
        .safeAreaInset(edge: .top, spacing: 0) { Color.clear.frame(height: Chrome.barHeight) }
        .background(Color.sidebarBackground)
    }

    private func favoriteRow(_ url: URL, index: Int) -> some View {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        return Label(isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent,
                     systemImage: isFolder ? "folder" : "doc.text")
            .tag(isFolder ? SidebarItem.organizer(.folder(url)) : .file(url))
            .help(index < 9 ? "⌃\(index + 1)" : "")
            .contextMenu { Button("Remove from Favorites") { Library.shared.toggleFavorite(url) } }
    }

    private func addLocation() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Add Location"
        if panel.runModal() == .OK, let url = panel.url {
            library.addLocation(url)
            model.selection = .folder(url.resolvingSymlinksInPath())
        }
    }
}

// MARK: - File List

struct FileList: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var library = Library.shared
    @ObservedObject private var prefs = Preferences.shared
    @State private var items: [LibraryItem] = []
    @State private var filteredItems: [LibraryItem] = []
    @State private var filter = ""
    @State private var renaming: URL?
    @State private var newName = ""
    @FocusState private var renameFocused: Bool

    private var refreshKey: String {
        "\(model.selection)|\(library.revision)|\(prefs.librarySort)|\(prefs.foldersOnTop)"
    }

    /// The open document is the selected row; picking a row opens it (or enters the folder).
    private var selection: Binding<URL?> {
        Binding(
            get: { model.fileURL },
            set: { url in
                guard let url, let item = filteredItems.first(where: { $0.url == url }) else { return }
                model.fileListActive = true
                if item.isFolder { model.selection = .folder(url) } else { model.open(url) }
                // The list now has the writer's attention: keys go to it, not into the note.
                if let window = WindowRegistry.shared.window(for: model), window.firstResponder is NSText {
                    window.makeFirstResponder(nil)
                }
            })
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: selection) {
                ForEach(filteredItems) { item in
                    fileRow(item)
                        .tag(item.url)
                        .id(item.url)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            // Delete key on the selected note; ⌘D does the same from the menu.
            .onDeleteCommand { model.trashCurrentNote() }
            .onChange(of: model.fileURL) { _, url in
                if let url { withAnimation { proxy.scrollTo(url) } }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                // The header itself lives in the title bar (WindowHeader), on the window buttons' line.
                Color.clear.frame(height: Chrome.barHeight)
                searchField
            }
        }
        .background(Color.fileListBackground)
        .contextMenu { folderMenu }
        .dropDestination(for: URL.self) { urls, _ in
            guard case .folder(let folder) = model.selection else { return false }
            return move(urls, into: folder)
        }
        .task(id: refreshKey) { await reload() }
        .task(id: filter) { await applyFilter() }
    }

    /// Recomputed only when the folder, the disk, or the filter changes, not on every redraw, and read
    /// from disk off the main thread.
    private func reload() async {
        let loaded = await library.loadItems(for: model.selection)
        guard !Task.isCancelled else { return }
        if loaded != items { items = loaded }
        await applyFilter()
    }

    private func applyFilter() async {
        guard !filter.isEmpty else {
            if filteredItems != items { filteredItems = items }
            return
        }
        let query = filter
        let matches = Set(await library.search(query))
        guard !Task.isCancelled, query == filter else { return }
        filteredItems = items.filter { $0.name.localizedCaseInsensitiveContains(query) || matches.contains($0.url) }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !filter.isEmpty {
                Button {
                    library.addSmartFolder(SmartFolder(name: filter, query: filter))
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .help("Save as Smart Folder")
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .glassCapsule()
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    // MARK: Rows

    @ViewBuilder
    private func fileRow(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if item.isFolder {
                    Image(systemName: "folder.fill").font(.system(size: 12)).foregroundStyle(Color.accentColor)
                }
                if renaming == item.url {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .focused($renameFocused)
                        .onSubmit { commitRename(item) }
                        .onExitCommand { renaming = nil }
                        .onChange(of: renameFocused) { _, focused in if !focused { renaming = nil } }
                } else {
                    Text(item.title(showExtension: prefs.showExtensions))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if library.favorites.contains(item.url) {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if item.isFolder {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                }
            }
            if !item.isFolder {
                if prefs.showExcerpts, !item.excerpt.isEmpty {
                    Text(item.excerpt)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(item.modified, format: .relative(presentation: .named))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu { menu(for: item) }
        .draggable(item.url)
        .dropDestination(for: URL.self) { urls, _ in
            item.isFolder ? move(urls, into: item.url) : false
        }
    }

    @ViewBuilder
    private func menu(for item: LibraryItem) -> some View {
        if !item.isFolder {
            Button("Open") { model.open(item.url) }
            Button("Open in New Window") { WindowRegistry.shared.openWindow?(item.url) }
            Divider()
        }
        Button("Rename…") { startRename(item) }
        if !item.isFolder {
            Button("Duplicate") {
                if let copy = library.duplicate(item.url) { model.open(copy) }
            }
        }
        Button(library.favorites.contains(item.url) ? "Remove from Favorites" : "Add to Favorites") {
            library.toggleFavorite(item.url)
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        Divider()
        Button("Move to Trash") {
            if item.url == model.fileURL { model.save() }
            library.trash(item.url)
        }
        Divider()
        folderMenu
    }

    @ViewBuilder
    private var folderMenu: some View {
        Button("New Note") { model.newDocument() }
        if case .folder(let folder) = model.selection {
            Button("New Folder") {
                if let url = library.newFolder(in: folder) {
                    newName = url.lastPathComponent
                    renaming = url
                    renameFocused = true
                }
            }
        }
    }

    private func startRename(_ item: LibraryItem) {
        newName = item.title(showExtension: prefs.showExtensions)
        renaming = item.url
        renameFocused = true
    }

    private func commitRename(_ item: LibraryItem) {
        defer { renaming = nil }
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != item.title(showExtension: prefs.showExtensions) else { return }
        if item.url == model.fileURL {
            model.rename(to: trimmed)
        } else if library.rename(item.url, to: trimmed) == nil {
            NSSound.beep()
        }
    }

    private func move(_ urls: [URL], into folder: URL) -> Bool {
        var moved = false
        for url in urls where url.deletingLastPathComponent() != folder && url != folder {
            if url == model.fileURL { model.save() }
            if library.move(url, into: folder) != nil { moved = true }
        }
        return moved
    }
}

/// The File List's title-bar header: folder name and note count, sort and new note.
struct FileListHeader: View {
    @ObservedObject var model: WindowModel
    @ObservedObject private var library = Library.shared
    @ObservedObject private var prefs = Preferences.shared
    @State private var noteCount = 0

    private var title: String {
        switch model.selection {
        case .folder(let url): url.lastPathComponent
        case .recents: "Recents"
        case .smartFolder(let folder): folder.name
        case .hashtag(let tag): "#" + tag
        }
    }

    private var parentFolder: URL? {
        guard case .folder(let url) = model.selection, !library.locations.contains(url),
              library.location(containing: url) != nil else { return nil }
        return url.deletingLastPathComponent()
    }

    var body: some View {
        HStack(spacing: 10) {
            // With the sidebar hidden, this header starts under the window buttons.
            if !model.showSidebar { Spacer().frame(width: Chrome.windowButtonsWidth - 14) }
            if let parent = parentFolder {
                GlassIconButton(symbol: "chevron.left", help: "Go to \(parent.lastPathComponent)") {
                    model.selection = .folder(parent)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(noteCount == 1 ? "1 note" : "\(noteCount) notes")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            GlassButtonGroup {
                Menu {
                    Picker("Sort By", selection: $prefs.librarySort) {
                        ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Toggle("Folders on Top", isOn: $prefs.foldersOnTop)
                    Toggle("Show Excerpts", isOn: $prefs.showExcerpts)
                    Toggle("Show File Extensions", isOn: $prefs.showExtensions)
                } label: {
                    GroupIconLabel(symbol: "arrow.up.arrow.down")
                }
                .menuStyle(.button)
                .buttonStyle(HeaderButtonStyle(shape: .capsule))
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Sort and display")
                GroupIconButton(symbol: "square.and.pencil", help: "New Note (⌘N)") {
                    model.newDocument()
                }
            }
        }
        .padding(.horizontal, 14)
        .task(id: "\(model.selection)|\(library.revision)") {
            let items = await library.loadItems(for: model.selection)
            guard !Task.isCancelled else { return }
            let count = items.filter { !$0.isFolder }.count
            if count != noteCount { noteCount = count }
        }
    }
}
