import AppKit
import UniformTypeIdentifiers
import WebKit

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf, html, word, markdown
    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: "PDF"
        case .html: "HTML"
        case .word: "Microsoft Word (.docx)"
        case .markdown: "Markdown"
        }
    }

    var type: UTType {
        switch self {
        case .pdf: .pdf
        case .html: .html
        case .word: UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        case .markdown: .markdownText
        }
    }
}

/// Export, print and the alternative copy commands, all rendered through the Preview template.
@MainActor
final class Exporter: NSObject, WKNavigationDelegate {
    static let shared = Exporter()

    private var webView: WKWebView?
    private var onLoad: ((WKWebView) -> Void)?

    // MARK: Rendering

    private func renderer(for fileURL: URL?) -> MarkdownRenderer {
        let prefs = Preferences.shared
        var renderer = MarkdownRenderer(options: .init(smartPunctuation: prefs.smartPunctuation, hardBreaks: prefs.singleReturn))
        renderer.baseURL = fileURL?.deletingLastPathComponent()
        renderer.locationURL = fileURL.flatMap { Library.shared.location(containing: $0) }
        return renderer
    }

    func htmlPage(markdown: String, fileURL: URL?, forPrint: Bool = false) -> String {
        let output = renderer(for: fileURL).render(markdown)
        var settings = Templates.Settings.current()
        if forPrint { settings.invertInDarkMode = false }
        let title = output.title ?? fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        return Templates.page(body: output.html, title: title, settings: settings, hasMath: output.hasMath)
    }

    func htmlFragment(markdown: String, fileURL: URL?) -> String {
        renderer(for: fileURL).render(markdown).html
    }

    // MARK: Export

    /// ⇧⌘E: asks for a format and a destination, then writes the document there.
    func export(markdown: String, fileURL: URL?, window: NSWindow?) {
        let panel = NSSavePanel()
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        ExportFormat.allCases.forEach { popup.addItem(withTitle: $0.title) }
        let last = Preferences.store.string(forKey: "export.format").flatMap(ExportFormat.init(rawValue:)) ?? .pdf
        popup.selectItem(at: ExportFormat.allCases.firstIndex(of: last) ?? 0)
        let label = NSTextField(labelWithString: "Format:")
        let accessory = NSStackView(views: [label, popup])
        accessory.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        panel.accessoryView = accessory

        let base = fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
        func apply(_ format: ExportFormat) {
            panel.allowedContentTypes = [format.type]
            panel.nameFieldStringValue = base + "." + (format.type.preferredFilenameExtension ?? format.rawValue)
        }
        apply(last)
        let handler = PopupHandler { index in apply(ExportFormat.allCases[index]) }
        popup.target = handler
        popup.action = #selector(PopupHandler.changed(_:))

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            _ = handler
            guard response == .OK, let url = panel.url else { return }
            let format = ExportFormat.allCases[popup.indexOfSelectedItem]
            Preferences.store.set(format.rawValue, forKey: "export.format")
            self.write(markdown: markdown, fileURL: fileURL, format: format, to: url, window: window)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) } else { completion(panel.runModal()) }
    }

    func write(markdown: String, fileURL: URL?, format: ExportFormat, to url: URL, window: NSWindow?) {
        do {
            switch format {
            case .markdown:
                try Data(renderer(for: fileURL).resolvingContentBlocks(markdown).utf8).write(to: url)
            case .html:
                try Data(htmlPage(markdown: markdown, fileURL: fileURL, forPrint: true).utf8).write(to: url)
            case .word:
                try wordData(markdown: markdown, fileURL: fileURL).write(to: url)
            case .pdf:
                withLoadedPage(markdown: markdown, fileURL: fileURL) { webView in
                    let info = self.printInfo()
                    info.jobDisposition = .save
                    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
                    self.runPrint(webView, info: info, showPanels: false, window: window)
                }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func wordData(markdown: String, fileURL: URL?) throws -> Data {
        let html = htmlPage(markdown: markdown, fileURL: fileURL, forPrint: true)
        let attributed = try NSAttributedString(data: Data(html.utf8),
                                                options: [.documentType: NSAttributedString.DocumentType.html,
                                                          .characterEncoding: String.Encoding.utf8.rawValue],
                                                documentAttributes: nil)
        return try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    }

    // MARK: Print

    /// ⌘P: prints the document as the Preview shows it.
    func print(markdown: String, fileURL: URL?, window: NSWindow?) {
        withLoadedPage(markdown: markdown, fileURL: fileURL) { webView in
            self.runPrint(webView, info: self.printInfo(), showPanels: true, window: window)
        }
    }

    /// ⌥⌘P: prints the raw markdown in the editor font.
    func printPlainText(_ text: String, window: NSWindow?) {
        let info = printInfo()
        let size = info.paperSize
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: size.width - info.leftMargin - info.rightMargin, height: 100))
        view.string = text
        view.font = Theme.font(Preferences.shared.typeface, size: 11)
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        if let window { operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil) } else { operation.run() }
    }

    /// ⇧⌘P
    func pageSetup(window: NSWindow?) {
        let layout = NSPageLayout()
        if let window {
            layout.beginSheet(using: NSPrintInfo.shared, on: window, completionHandler: nil)
        } else {
            layout.runModal()
        }
    }

    private func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        return info
    }

    private func runPrint(_ webView: WKWebView, info: NSPrintInfo, showPanels: Bool, window: NSWindow?) {
        let operation = webView.printOperation(with: info)
        operation.showsPrintPanel = showPanels
        operation.showsProgressPanel = showPanels
        operation.view?.frame = NSRect(origin: .zero, size: info.paperSize)
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    /// Loads the document in an offscreen web view, then hands it over once rendering finished.
    private func withLoadedPage(markdown: String, fileURL: URL?, then action: @escaping (WKWebView) -> Void) {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 1000), configuration: PreviewWebView.configuration())
        webView.navigationDelegate = self
        self.webView = webView
        onLoad = action
        let html = htmlPage(markdown: markdown, fileURL: fileURL, forPrint: true)
            .replacingOccurrences(of: "<head>", with: "<head>\n<base href=\"\(fileURL?.deletingLastPathComponent().absoluteString ?? "")\">")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).html")
        try? Data(html.utf8).write(to: file)
        webView.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            MathSupport.render(in: webView)
            // Give KaTeX and images a moment to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let action = self.onLoad else { return }
                self.onLoad = nil
                action(webView)
            }
        }
    }

    // MARK: Copy

    /// ⇧⌘C: the selection as HTML source.
    func copyAsHTML(_ markdown: String, fileURL: URL?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(htmlFragment(markdown: markdown, fileURL: fileURL), forType: .string)
    }

    /// ⌥⌘C: the selection as rich text, for pasting into mail or word processors.
    func copyFormatted(_ markdown: String, fileURL: URL?) {
        let html = htmlPage(markdown: markdown, fileURL: fileURL, forPrint: true)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(html, forType: .html)
        if let attributed = try? NSAttributedString(data: Data(html.utf8),
                                                    options: [.documentType: NSAttributedString.DocumentType.html,
                                                              .characterEncoding: String.Encoding.utf8.rawValue],
                                                    documentAttributes: nil),
           let rtf = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                          documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(markdown, forType: .string)
    }

    /// ⌃⌘C: the selection as markdown, with content blocks replaced by what they embed.
    func copyAsMarkdown(_ markdown: String, fileURL: URL?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(renderer(for: fileURL).resolvingContentBlocks(markdown), forType: .string)
    }
}

private final class PopupHandler: NSObject {
    let onChange: (Int) -> Void
    init(_ onChange: @escaping (Int) -> Void) { self.onChange = onChange }
    @objc func changed(_ sender: NSPopUpButton) { onChange(sender.indexOfSelectedItem) }
}
