import AppKit
import Combine
import CoreServices

/// A file or folder shown in the File List.
struct LibraryItem: Identifiable, Hashable {
    let url: URL
    let isFolder: Bool
    let modified: Date
    var excerpt: String = ""

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var kind: String { isFolder ? "" : url.pathExtension.lowercased() }

    func title(showExtension: Bool) -> String {
        isFolder || showExtension ? name : url.deletingPathExtension().lastPathComponent
    }
}

struct SmartFolder: Codable, Hashable, Identifiable {
    var name: String
    var query: String
    var id: String { name }
}

/// What is selected in the Organizer.
enum OrganizerItem: Hashable {
    case folder(URL)
    case recents
    case smartFolder(SmartFolder)
    case hashtag(String)
}

/// The shared index of everything in the Library's locations: files, contents, hashtags.
final class Library: ObservableObject {
    static let shared = Library()

    static let textExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt", "text"]

    @Published private(set) var locations: [URL]
    @Published private(set) var favorites: [URL]
    @Published private(set) var recents: [URL]
    @Published private(set) var smartFolders: [SmartFolder]
    /// Hashtag (without `#`) → files using it.
    @Published private(set) var hashtags: [String: Set<URL>] = [:]
    /// Every text file under a location.
    @Published private(set) var textFiles: [URL] = []
    /// Every non-text file under a location, for content blocks.
    @Published private(set) var otherFiles: [URL] = []
    /// Every folder under a location, for Open Quickly.
    @Published private(set) var folders: [URL] = []
    /// Bumps whenever something on disk changes, so file lists reload.
    @Published private(set) var revision = 0

    private var contents: [URL: String] = [:]
    /// Lowercased copies of `contents`, so searches don't lowercase every note for every keystroke.
    private var lowered: [URL: String] = [:]
    private var tagsByFile: [URL: Set<String>] = [:]
    private var watcher: FolderWatcher?
    private let queue = DispatchQueue(label: "library.index", qos: .utility)
    private var pendingScan: DispatchWorkItem?
    private let defaults = Preferences.store

    static let defaultLocation = ProcessInfo.processInfo.environment["SONDER_LIBRARY"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/Sonder", isDirectory: true)

    private init() {
        locations = (defaults.stringArray(forKey: "library.locations") ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath() }
        favorites = (defaults.stringArray(forKey: "library.favorites") ?? []).map { URL(fileURLWithPath: $0) }
        recents = (defaults.stringArray(forKey: "library.recents") ?? []).map { URL(fileURLWithPath: $0) }
        smartFolders = (defaults.data(forKey: "library.smartFolders"))
            .flatMap { try? JSONDecoder().decode([SmartFolder].self, from: $0) } ?? []

        if locations.isEmpty {
            locations = [Self.defaultLocation.resolvingSymlinksInPath()]
            createDefaultLocation()
            saveLists()
        }
        restartWatcher()
        scheduleScan(delay: 0)
    }

    private func createDefaultLocation() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Self.defaultLocation.path) else { return }
        try? fm.createDirectory(at: Self.defaultLocation, withIntermediateDirectories: true)
        if let welcome = Theme.resourceURL("Welcome.md") {
            try? fm.copyItem(at: welcome, to: Self.defaultLocation.appendingPathComponent("Welcome.md"))
        }
    }

    // MARK: Locations & favorites

    func addLocation(_ url: URL) {
        let url = url.resolvingSymlinksInPath()
        guard !locations.contains(where: { $0.resolvingSymlinksInPath() == url }) else { return }
        locations.append(url)
        saveLists()
        restartWatcher()
        scheduleScan(delay: 0)
    }

    func removeLocation(_ url: URL) {
        guard locations.count > 1 else { return }
        locations.removeAll { $0 == url }
        saveLists()
        restartWatcher()
        scheduleScan(delay: 0)
    }

    func toggleFavorite(_ url: URL) {
        if favorites.contains(url) { favorites.removeAll { $0 == url } } else { favorites.append(url) }
        saveLists()
    }

    func addSmartFolder(_ folder: SmartFolder) {
        smartFolders.removeAll { $0.name == folder.name }
        smartFolders.append(folder)
        saveLists()
    }

    func removeSmartFolder(_ folder: SmartFolder) {
        smartFolders.removeAll { $0 == folder }
        saveLists()
    }

    func noteOpened(_ url: URL) {
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        if recents.count > 25 { recents.removeLast(recents.count - 25) }
        saveLists()
    }

    private func saveLists() {
        defaults.set(locations.map(\.path), forKey: "library.locations")
        defaults.set(favorites.map(\.path), forKey: "library.favorites")
        defaults.set(recents.map(\.path), forKey: "library.recents")
        defaults.set(try? JSONEncoder().encode(smartFolders), forKey: "library.smartFolders")
    }

    func location(containing url: URL) -> URL? {
        let path = Self.canonicalPath(url.path)
        return locations.first {
            let root = Self.canonicalPath($0.path)
            return path.hasPrefix(root + "/") || path == root
        }
    }

    /// The same path whichever way the system spelled it: /tmp and /var are links into /private,
    /// and file system events report the /private form.
    static func canonicalPath(_ path: String) -> String {
        for prefix in ["/private/var/", "/private/tmp/", "/private/etc/"] where path.hasPrefix(prefix) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    // MARK: Listing

    /// What listing and searching need from the index, as plain values that can go to another thread.
    struct Snapshot {
        let textFiles: [URL]
        let contents: [URL: String]
        let lowered: [URL: String]
        let recents: [URL]
        let hashtags: [String: Set<URL>]
    }

    var snapshot: Snapshot {
        Snapshot(textFiles: textFiles, contents: contents, lowered: lowered, recents: recents, hashtags: hashtags)
    }

    private static let listingQueue = DispatchQueue(label: "library.listing", qos: .userInitiated, attributes: .concurrent)

    /// Lists a folder (or smart folder, hashtag, Recents) off the main thread; calls back on the main queue.
    func loadItems(for selection: OrganizerItem, completion: @escaping ([LibraryItem]) -> Void) {
        let snapshot = snapshot
        let sort = Preferences.shared.librarySort, foldersOnTop = Preferences.shared.foldersOnTop
        Self.listingQueue.async {
            let items = Self.items(for: selection, in: snapshot, sort: sort, foldersOnTop: foldersOnTop)
            DispatchQueue.main.async { completion(items) }
        }
    }

    func loadItems(for selection: OrganizerItem) async -> [LibraryItem] {
        await withCheckedContinuation { continuation in
            loadItems(for: selection) { continuation.resume(returning: $0) }
        }
    }

    func search(_ query: String) async -> [URL] {
        await withCheckedContinuation { continuation in
            search(query) { continuation.resume(returning: $0) }
        }
    }

    /// Searches off the main thread; calls back on the main queue.
    func search(_ query: String, completion: @escaping ([URL]) -> Void) {
        let snapshot = snapshot
        Self.listingQueue.async {
            let urls = Self.search(query, in: snapshot)
            DispatchQueue.main.async { completion(urls) }
        }
    }

    func items(for selection: OrganizerItem) -> [LibraryItem] {
        Self.items(for: selection, in: snapshot, sort: Preferences.shared.librarySort, foldersOnTop: Preferences.shared.foldersOnTop)
    }

    static func items(for selection: OrganizerItem, in snapshot: Snapshot, sort: LibrarySort, foldersOnTop: Bool) -> [LibraryItem] {
        var items: [LibraryItem]
        switch selection {
        case .folder(let folder):
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .isPackageKey],
                options: [.skipsHiddenFiles])) ?? []
            items = urls.compactMap { item(for: $0, in: snapshot) }
        case .recents:
            return snapshot.recents.compactMap { item(for: $0, in: snapshot) }
        case .smartFolder(let folder):
            items = search(folder.query, in: snapshot).compactMap { item(for: $0, in: snapshot) }
        case .hashtag(let tag):
            items = (snapshot.hashtags[tag] ?? []).compactMap { item(for: $0, in: snapshot) }
        }
        return sorted(items, by: sort, foldersOnTop: foldersOnTop)
    }

    func item(for url: URL) -> LibraryItem? {
        Self.item(for: url, in: snapshot)
    }

    static func item(for url: URL, in snapshot: Snapshot) -> LibraryItem? {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .isPackageKey])
        else { return nil }
        let isFolder = values.isDirectory == true && values.isPackage != true
        if !isFolder && !textExtensions.contains(url.pathExtension.lowercased()) { return nil }
        var item = LibraryItem(url: url, isFolder: isFolder, modified: values.contentModificationDate ?? .distantPast)
        if !isFolder { item.excerpt = excerpt(for: url, text: snapshot.contents[url]) }
        return item
    }

    private static func sorted(_ items: [LibraryItem], by sort: LibrarySort, foldersOnTop: Bool) -> [LibraryItem] {
        items.sorted { a, b in
            if foldersOnTop, a.isFolder != b.isFolder { return a.isFolder }
            switch sort {
            case .modified: return a.modified > b.modified
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .kind:
                return a.kind == b.kind ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.kind < b.kind
            }
        }
    }

    /// The first couple of lines of text, without markdown syntax or a title heading.
    static func excerpt(for url: URL, text known: String?) -> String {
        let text = known ?? (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(600)) } ?? ""
        var lines = Annotations.parse(String(text.prefix(600))).body.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.first == "---", let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "..." }) {
            lines.removeSubrange(0...end)
        }
        let title = url.deletingPathExtension().lastPathComponent
        if let first = lines.first, Self.plain(first) == title { lines.removeFirst() }
        return lines.prefix(4).map(Self.plain).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private static func plain(_ line: Substring) -> String {
        line.replacingOccurrences(of: #"^\s*(#{1,6}\s+|>\s?|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_~=`]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: Search

    /// Files whose name or contents contain every word of `query`, best matches (name hits) first.
    func search(_ query: String) -> [URL] {
        Self.search(query, in: snapshot)
    }

    static func search(_ query: String, in snapshot: Snapshot) -> [URL] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var nameHits: [URL] = [], contentHits: [URL] = []
        for url in snapshot.textFiles {
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            if words.allSatisfy({ name.contains($0) }) {
                nameHits.append(url)
            } else if let text = snapshot.lowered[url], words.allSatisfy({ name.contains($0) || text.contains($0) }) {
                contentHits.append(url)
            }
        }
        return nameHits + contentHits
    }

    func text(of url: URL) -> String? { contents[url] }

    /// Keeps a note's text and its lowercased copy together.
    private func setContents(_ text: String?, for url: URL) {
        contents[url] = text
        lowered[url] = text?.lowercased()
    }

    // MARK: Wikilinks

    /// Resolves `[[target]]` from `source`: same folder first, then subfolders, then parent folders.
    func resolve(wikilink target: String, from source: URL?) -> URL? {
        var name = target
        var candidates = textFiles
        if let colon = target.firstIndex(of: ":"),
           let location = locations.first(where: { $0.lastPathComponent == target[..<colon].trimmingCharacters(in: .whitespaces) }) {
            name = target[target.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            candidates = candidates.filter { $0.path.hasPrefix(location.path + "/") }
        }
        let lower = name.lowercased()
        let matches = candidates.filter { url in
            let path = url.path.lowercased()
            let withoutExtension = url.deletingPathExtension().path.lowercased()
            return path.hasSuffix("/" + lower) || withoutExtension.hasSuffix("/" + lower)
        }
        guard !matches.isEmpty else { return nil }
        let base = source?.deletingLastPathComponent().path ?? ""
        func distance(_ url: URL) -> Int {
            let folder = url.deletingLastPathComponent().path
            if folder == base { return 0 }
            if folder.hasPrefix(base + "/") { return folder.split(separator: "/").count - base.split(separator: "/").count }
            return 100 + base.split(separator: "/").count - folder.split(separator: "/").count
        }
        return matches.min { distance($0) < distance($1) }
    }

    /// The shortest unique wikilink for `url`: name, or name with extension, or folder/name.
    func wikilink(for url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        let sameName = textFiles.filter { $0.deletingPathExtension().lastPathComponent == name }
        if sameName.count <= 1 { return name }
        if sameName.filter({ $0.lastPathComponent == url.lastPathComponent }).count == 1 { return url.lastPathComponent }
        return url.deletingLastPathComponent().lastPathComponent + "/" + name
    }

    // MARK: File operations

    @discardableResult
    func newFile(in folder: URL, named base: String = "Untitled", contents: String = "") -> URL? {
        let url = uniqueURL(in: folder, base: base, extension: Preferences.shared.defaultExtension)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8)) else { return nil }
        changed()
        return url
    }

    @discardableResult
    func newFolder(in folder: URL) -> URL? {
        let url = uniqueURL(in: folder, base: "New Folder", extension: nil)
        guard (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)) != nil else { return nil }
        changed()
        return url
    }

    func rename(_ url: URL, to newName: String) -> URL? {
        let clean = Self.sanitizedFileName(newName)
        guard !clean.isEmpty else { return nil }
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let ext = url.pathExtension
        let name = isFolder || ext.isEmpty || clean.lowercased().hasSuffix("." + ext.lowercased()) ? clean : clean + "." + ext
        let destination = url.deletingLastPathComponent().appendingPathComponent(name)
        guard destination != url else { return url }
        // A case-only rename of the same file is fine; anything else must not overwrite.
        guard !FileManager.default.fileExists(atPath: destination.path) ||
              destination.path.lowercased() == url.path.lowercased() else { return nil }
        guard (try? FileManager.default.moveItem(at: url, to: destination)) != nil else { return nil }
        moved(from: url, to: destination)
        return destination
    }

    /// Moves an item within the Library. Files from elsewhere (dragged in from Finder) are copied instead.
    func move(_ url: URL, into folder: URL) -> URL? {
        guard url != folder, !folder.path.hasPrefix(url.path + "/") else { return nil }
        let destination = uniqueURL(in: folder, base: url.deletingPathExtension().lastPathComponent,
                                    extension: url.pathExtension.isEmpty ? nil : url.pathExtension)
        if location(containing: url) == nil {
            guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { return nil }
            changed()
            return destination
        }
        guard (try? FileManager.default.moveItem(at: url, to: destination)) != nil else { return nil }
        moved(from: url, to: destination)
        return destination
    }

    func duplicate(_ url: URL) -> URL? {
        let destination = uniqueURL(in: url.deletingLastPathComponent(),
                                    base: url.deletingPathExtension().lastPathComponent + " copy",
                                    extension: url.pathExtension.isEmpty ? nil : url.pathExtension)
        guard (try? FileManager.default.copyItem(at: url, to: destination)) != nil else { return nil }
        changed()
        return destination
    }

    func trash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        moved(from: url, to: nil)
    }

    /// Drops a file that no longer exists from Recents and Favorites.
    func forget(_ url: URL) {
        moved(from: url, to: nil)
    }

    /// Updates references to a moved (or, with `to` nil, removed) item and tells every window.
    private func moved(from old: URL, to new: URL?) {
        func remap(_ url: URL) -> URL? {
            if url == old { return new }
            guard url.path.hasPrefix(old.path + "/") else { return url }
            return new.map { URL(fileURLWithPath: $0.path + url.path.dropFirst(old.path.count)) }
        }
        recents = recents.compactMap(remap)
        favorites = favorites.compactMap(remap)
        saveLists()
        var info: [String: URL] = ["from": old]
        if let new { info["to"] = new }
        NotificationCenter.default.post(name: .libraryItemMoved, object: self, userInfo: info)
        changed()
    }

    func uniqueURL(in folder: URL, base: String, extension ext: String?) -> URL {
        func make(_ name: String) -> URL {
            let url = folder.appendingPathComponent(name)
            return ext.map { url.appendingPathExtension($0) } ?? url
        }
        var url = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = make("\(base) \(n)")
            n += 1
        }
        return url
    }

    static func sanitizedFileName(_ name: String) -> String {
        String(name.replacingOccurrences(of: "[/:\\\\\\n\\r\\t]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")).prefix(80))
    }

    // MARK: Indexing

    /// Something changed on disk; file lists reload. The index follows through file system events.
    func changed() {
        revision += 1
    }

    /// Keeps the index in sync with a document that is being edited, without waiting for disk.
    func updateContents(_ text: String, for url: URL) {
        setContents(text, for: url)
    }

    private func restartWatcher() {
        watcher = FolderWatcher(paths: locations.map(\.path)) { [weak self] events in
            DispatchQueue.main.async { self?.handle(events) }
        }
    }

    /// Re-reads just the files that changed; folder-level changes trigger a full scan.
    private func handle(_ events: [FolderWatcher.Event]) {
        let needsFullScan = events.contains { $0.isDirectory || $0.mustRescan }
        if needsFullScan {
            scheduleScan(delay: 0.3)
            revision += 1
            return
        }
        let urls = Set(events.map { URL(fileURLWithPath: $0.path) })
        queue.async { [weak self] in
            let results = urls.map { url -> (URL, FileIndex?) in (url, Self.index(url)) }
            DispatchQueue.main.async {
                guard let self else { return }
                for (url, index) in results {
                    self.apply(index, for: url)
                }
                self.rebuildHashtags()
                self.revision += 1
            }
        }
    }

    private func apply(_ index: FileIndex?, for url: URL) {
        textFiles.removeAll { $0 == url }
        otherFiles.removeAll { $0 == url }
        setContents(nil, for: url)
        tagsByFile[url] = nil
        guard let index, location(containing: url) != nil else { return }
        if index.isText {
            textFiles.append(url)
            setContents(index.text, for: url)
            tagsByFile[url] = index.tags
        } else {
            otherFiles.append(url)
        }
    }

    private func rebuildHashtags() {
        var hashtags: [String: Set<URL>] = [:]
        for (url, tags) in tagsByFile {
            for tag in tags { hashtags[tag, default: []].insert(url) }
        }
        if hashtags != self.hashtags { self.hashtags = hashtags }
    }

    private func scheduleScan(delay: TimeInterval) {
        pendingScan?.cancel()
        let roots = locations
        let work = DispatchWorkItem { [weak self] in
            let result = Self.scan(roots)
            let lowered = result.contents.mapValues { $0.lowercased() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.textFiles = result.text
                self.otherFiles = result.other
                self.folders = result.folders
                self.contents = result.contents
                self.lowered = lowered
                self.tagsByFile = result.tags
                self.rebuildHashtags()
                self.revision += 1
            }
        }
        pendingScan = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static let hashtagPattern = MarkdownStyler.hashtag

    struct FileIndex {
        var isText: Bool
        var text: String?
        var tags: Set<String> = []
    }

    /// What the index keeps for one file; nil if it doesn't exist (or is hidden or a folder).
    private static func index(_ url: URL) -> FileIndex? {
        guard !url.lastPathComponent.hasPrefix("."),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else { return nil }
        guard textExtensions.contains(url.pathExtension.lowercased()) else { return FileIndex(isText: false) }
        guard (values.fileSize ?? 0) < 2_000_000, let data = try? Data(contentsOf: url) else { return FileIndex(isText: true) }
        let body = TextDecoding.decode(data)
        var tags = Set<String>()
        let ns = body as NSString
        for m in hashtagPattern.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            tags.insert(ns.substring(with: m.range).dropFirst().lowercased())
        }
        return FileIndex(isText: true, text: body, tags: tags)
    }

    private static func scan(_ roots: [URL]) -> (text: [URL], other: [URL], folders: [URL], contents: [URL: String], tags: [URL: Set<String>]) {
        var text: [URL] = [], other: [URL] = [], folders: [URL] = []
        var contents: [URL: String] = [:]
        var tags: [URL: Set<String>] = [:]
        let fm = FileManager.default
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey, .isPackageKey],
                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                   values.isDirectory == true, values.isPackage != true {
                    folders.append(url)
                    continue
                }
                guard let index = index(url) else { continue }
                if index.isText {
                    text.append(url)
                    contents[url] = index.text
                    tags[url] = index.tags
                } else {
                    other.append(url)
                }
            }
        }
        return (text, other, folders, contents, tags)
    }
}

/// Reports (on a background queue) which paths below the given folders changed.
final class FolderWatcher {
    struct Event {
        let path: String
        let isDirectory: Bool
        let mustRescan: Bool
    }

    private var stream: FSEventStreamRef?
    private let callback: ([Event]) -> Void

    init?(paths: [String], callback: @escaping ([Event]) -> Void) {
        self.callback = callback
        guard !paths.isEmpty else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let handler: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let events = (0..<min(count, list.count)).map { i -> Event in
                let flag = Int(flags[i])
                return Event(path: list[i],
                             isDirectory: flag & kFSEventStreamEventFlagItemIsDir != 0,
                             mustRescan: flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                                                 | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0)
            }
            watcher.callback(events)
        }
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes
        guard let stream = FSEventStreamCreate(nil, handler, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4,
                                               FSEventStreamCreateFlags(flags))
        else { return nil }
        self.stream = stream
        // The main queue serializes callbacks with deinit, so the stream never calls into a freed watcher.
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
