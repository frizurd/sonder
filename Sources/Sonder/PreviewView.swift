import Combine
import SwiftUI
import WebKit

struct PreviewWebView: NSViewRepresentable {
    let model: WindowModel
    @ObservedObject var prefs: Preferences
    @ObservedObject private var source: PreviewSource

    init(model: WindowModel, prefs: Preferences) {
        self.model = model
        self.prefs = prefs
        source = model.preview
    }

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: PreviewWebView.configuration())
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        if #available(macOS 26.0, *) {
            // The page scrolls under the header; WebKit keeps its top clear of it.
            webView.obscuredContentInsets = NSEdgeInsets(top: Chrome.barHeight, left: 0, bottom: 0, right: 0)
        }
        context.coordinator.webView = webView
        return webView
    }

    /// Documents can't run scripts: a downloaded file must not be able to read other files.
    /// The app's own code (body updates, scrolling, math) still runs through `evaluateJavaScript`.
    static func configuration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.isElementFullscreenEnabled = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.update(source: source.text, fileURL: model.fileURL,
                                   settings: .current(prefs), smart: prefs.smartPunctuation, hardBreaks: prefs.singleReturn)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private let model: WindowModel
        private var renderKey: String?
        private var loadedPageKey: String?
        private var lastBody: String?
        private var lastFraction: CGFloat = -1
        private var isLoaded = false
        private var pageFile: URL?
        private var scrollSubscription: AnyCancellable?

        init(model: WindowModel) {
            self.model = model
            super.init()
            scrollSubscription = model.status.scroll
                .throttle(for: .milliseconds(16), scheduler: RunLoop.main, latest: true)
                .sink { [weak self] in self?.scroll(to: $0) }
        }

        deinit {
            if let pageFile { try? FileManager.default.removeItem(at: pageFile) }
        }

        func update(source: String, fileURL: URL?, settings: Templates.Settings, smart: Bool, hardBreaks: Bool) {
            guard let webView else { return }
            // SwiftUI calls this for any change in the window; only render when the inputs changed.
            let key = "\(Templates.bodyClasses(settings))|\(smart)|\(hardBreaks)|\(fileURL?.path ?? "")|\(source.hashValue)|\(source.utf16.count)"
            guard key != renderKey else { return }
            renderKey = key

            var renderer = MarkdownRenderer(options: .init(smartPunctuation: smart, hardBreaks: hardBreaks))
            renderer.baseURL = fileURL?.deletingLastPathComponent()
            renderer.locationURL = fileURL.flatMap { Library.shared.location(containing: $0) }
            // Rendering (and reading embedded files) happens off the main thread; only the newest result is shown.
            renderGeneration += 1
            let generation = renderGeneration
            Self.renderQueue.async { [weak self] in
                let output = renderer.render(source)
                DispatchQueue.main.async {
                    guard let self, generation == self.renderGeneration, let webView = self.webView else { return }
                    self.show(output, fileURL: fileURL, settings: settings, in: webView)
                }
            }
        }

        private var renderGeneration = 0
        private static let renderQueue = DispatchQueue(label: "preview.render", qos: .userInitiated)

        private func show(_ output: MarkdownRenderer.Output, fileURL: URL?, settings: Templates.Settings, in webView: WKWebView) {
            // Template or options changed: reload the whole page. Otherwise swap the body in place.
            let pageKey = "\(Templates.bodyClasses(settings))|\(output.hasMath)|\(fileURL?.path ?? "")"
            if pageKey != loadedPageKey {
                loadedPageKey = pageKey
                lastBody = output.html
                isLoaded = false
                load(Templates.page(body: output.html, title: output.title ?? "", settings: settings, hasMath: output.hasMath),
                     base: fileURL?.deletingLastPathComponent(), in: webView)
            } else if output.html != lastBody {
                lastBody = output.html
                // A page still loading would drop the update; didFinish applies the latest body instead.
                if isLoaded { replaceBody(output.html, in: webView) }
            }
        }

        private func replaceBody(_ html: String, in webView: WKWebView) {
            let json = (try? String(data: JSONEncoder().encode(html), encoding: .utf8)) ?? "\"\""
            webView.evaluateJavaScript("document.getElementById('content').innerHTML = \(json);") { _, _ in
                MathSupport.render(in: webView)
            }
        }

        /// The page goes through a temporary file so local images can load.
        private func load(_ html: String, base: URL?, in webView: WKWebView) {
            // Before macOS 26 the page itself leaves room for the header.
            var classes = "preview "
            if #unavailable(macOS 26.0) { classes += "preview-header " }
            var page = html.replacingOccurrences(of: "<body class=\"", with: "<body class=\"" + classes)
            if let base {
                page = page.replacingOccurrences(of: "<head>", with: "<head>\n<base href=\"\(base.absoluteString)\">")
            }
            let file = pageFile ?? FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).html")
            pageFile = file
            do {
                try Data(page.utf8).write(to: file, options: .atomic)
            } catch {
                webView.loadHTMLString(page, baseURL: base)
                return
            }
            webView.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        }

        func scroll(to fraction: CGFloat) {
            guard abs(fraction - lastFraction) > 0.001 else { return }
            lastFraction = fraction
            guard isLoaded else { return }
            webView?.evaluateJavaScript("window.scrollTo(0, \(fraction) * (document.documentElement.scrollHeight - window.innerHeight));")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            if let lastBody { replaceBody(lastBody, in: webView) }
            let fraction = lastFraction
            lastFraction = -1
            if fraction >= 0 { scroll(to: fraction) }
            MathSupport.render(in: webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { return decisionHandler(.cancel) }
            // Only the preview page itself loads here; subframes (iframes in raw HTML) never navigate.
            // WebKit reports the temporary folder with symlinks resolved (/private/var/…), so compare that way.
            let isPage = url.isFileURL && pageFile.map {
                url.resolvingSymlinksInPath().path == $0.resolvingSymlinksInPath().path
            } == true
            if navigationAction.navigationType == .other {
                return decisionHandler(isPage || url.absoluteString == "about:blank" ? .allow : .cancel)
            }
            // Footnote and other in-page anchors scroll the preview.
            if url.fragment != nil, isPage {
                return decisionHandler(.allow)
            }
            decisionHandler(.cancel)
            guard navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame != false else { return }
            if url.scheme == "wikilink" {
                model.follow(link: url.absoluteString)
            } else if url.isFileURL {
                model.follow(link: url.path)
            } else {
                model.follow(link: url.absoluteString)
            }
        }
    }
}

/// Renders `$math$` with KaTeX. The script is injected by the app (pages can't run their own),
/// fetched once and kept in memory; without a network connection math stays as TeX.
enum MathSupport {
    private static var script: String?
    private static var loading = false
    private static var waiting: [() -> Void] = []

    static func render(in webView: WKWebView) {
        webView.evaluateJavaScript("document.querySelector('.math') !== null") { result, _ in
            guard result as? Bool == true else { return }
            withScript { source in
                webView.evaluateJavaScript(source + ";" + renderer) { _, _ in }
            }
        }
    }

    private static func withScript(_ action: @escaping (String) -> Void) {
        if let script { return action(script) }
        waiting.append { if let script { action(script) } }
        guard !loading, let url = URL(string: "https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js") else { return }
        loading = true
        URLSession.shared.dataTask(with: url) { data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                loading = false
                if ok, let data, let source = String(data: data, encoding: .utf8) { script = source }
                let callbacks = waiting
                waiting = []
                callbacks.forEach { $0() }
            }
        }.resume()
    }

    private static let renderer = """
    document.querySelectorAll('.math').forEach(function (el) {
      if (el.dataset.rendered) return;
      var tex = el.textContent, display = tex.startsWith('$$') || el.tagName === 'DIV';
      tex = tex.replace(/^\\$\\$?|\\$\\$?$/g, '');
      try { katex.render(tex, el, { displayMode: display, throwOnError: false }); el.dataset.rendered = '1'; } catch (e) {}
    });
    """
}
