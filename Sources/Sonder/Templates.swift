import Foundation

/// HTML pages for Preview, export and printing, styled by the chosen template.
enum Templates {
    struct Settings {
        var template: PreviewTemplate
        var centerHeadings: Bool
        var numberHeadings: Bool
        var indentParagraphs: Bool
        var invertInDarkMode: Bool

        static func current(_ prefs: Preferences = .shared) -> Settings {
            Settings(template: prefs.template, centerHeadings: prefs.centerHeadings, numberHeadings: prefs.numberHeadings,
                     indentParagraphs: prefs.indentParagraphs, invertInDarkMode: prefs.invertPreview)
        }
    }

    /// A complete standalone HTML document.
    static func page(body: String, title: String, settings: Settings, hasMath: Bool, forExport: Bool = false) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(MarkdownRenderer.escape(title))</title>
        <style>
        \(forExport ? "" : fontFaces)
        \(css(for: settings))
        </style>
        \(hasMath ? katex : "")
        </head>
        <body class="\(bodyClasses(settings))">
        <article id="content">
        \(body)
        </article>
        \(hasMath ? "<script>renderMath && renderMath()</script>" : "")
        </body>
        </html>
        """
    }

    static func bodyClasses(_ settings: Settings) -> String {
        var classes = [settings.template.rawValue]
        if settings.template != .github {
            if settings.centerHeadings { classes.append("center-headings") }
            if settings.numberHeadings { classes.append("number-headings") }
            if settings.indentParagraphs { classes.append("indent-paragraphs") }
        }
        if settings.invertInDarkMode { classes.append("invert") }
        return classes.joined(separator: " ")
    }

    // MARK: Fonts

    /// The bundled Plex fonts as data URLs; the web view can't see fonts registered only for this process.
    static let fontFaces: String = {
        guard let directory = Theme.resourceURL("Fonts") else { return "" }
        let faces: [(String, String, String, String)] = [
            ("PlexMono", "IBMPlexMono-Regular", "400", "normal"), ("PlexMono", "IBMPlexMono-Bold", "700", "normal"),
            ("PlexMono", "IBMPlexMono-Italic", "400", "italic"), ("PlexMono", "IBMPlexMono-BoldItalic", "700", "italic"),
            ("PlexSans", "IBMPlexSans-Regular", "400", "normal"), ("PlexSans", "IBMPlexSans-Bold", "700", "normal"),
            ("PlexSans", "IBMPlexSans-Italic", "400", "italic"), ("PlexSans", "IBMPlexSans-BoldItalic", "700", "italic"),
        ]
        return faces.compactMap { family, file, weight, style in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(file + ".ttf")) else { return nil }
            return "@font-face{font-family:'\(family)';src:url(data:font/ttf;base64,\(data.base64EncodedString())) format('truetype');font-weight:\(weight);font-style:\(style);}"
        }.joined(separator: "\n")
    }()

    private static let katex = """
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
    <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
    <script>
    function renderMath() {
      if (!window.katex) return;
      document.querySelectorAll('.math').forEach(function (el) {
        var tex = el.textContent, display = tex.startsWith('$$');
        tex = tex.replace(/^\\$\\$?|\\$\\$?$/g, '');
        try { katex.render(tex, el, { displayMode: display || el.tagName === 'DIV', throwOnError: false }); } catch (e) {}
      });
    }
    </script>
    """

    // MARK: CSS

    static func css(for settings: Settings) -> String {
        base + (templateCSS[settings.template] ?? "") + options
    }

    private static let base = """
    :root { --text: #1e1e1e; --muted: #77776f; --rule: #dddddb; --bg: #f7f7f5; --code-bg: #f3f3f1; --link: #2e83c4; --mark: #fff09a; }
    @media (prefers-color-scheme: dark) {
      body.invert { --text: #d2d2d2; --muted: #8c8c8c; --rule: #3a3a3a; --bg: #1a1a1a; --code-bg: #242424; --link: #58a9e6; --mark: #6b5f12; }
    }
    html { -webkit-text-size-adjust: 100%; }
    body { margin: 0; background: var(--bg); color: var(--text); -webkit-font-smoothing: antialiased; }
    #content { max-width: 40em; margin: 0 auto; padding: 3.5em 2em 6em; }
    /* In the app the first line sits as far below the header as the editor's does. */
    body.preview #content { padding-top: 28px; }
    body.preview-header #content { padding-top: 80px; }
    body.preview #content > :first-child { margin-top: 0; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    a.wikilink { border-bottom: 1px dotted var(--link); }
    .hashtag { color: var(--muted); }
    mark { background: var(--mark); color: inherit; padding: 0 .1em; border-radius: 2px; }
    img { max-width: 100%; height: auto; }
    figure { margin: 1.5em 0; text-align: center; }
    figcaption { color: var(--muted); font-size: .85em; margin-top: .5em; }
    hr { border: 0; border-top: 1px solid var(--rule); margin: 2em 0; }
    blockquote { margin: 1.2em 0; padding: 0 0 0 1.2em; border-left: 3px solid var(--rule); color: var(--muted); }
    code, pre { font-family: 'iA Writer Mono S', 'PlexMono', 'IBM Plex Mono', ui-monospace, Menlo, monospace; font-size: .86em; }
    code { background: var(--code-bg); padding: .1em .3em; border-radius: 3px; }
    pre { background: var(--code-bg); padding: 1em 1.2em; border-radius: 4px; overflow-x: auto; line-height: 1.45; }
    pre code { background: none; padding: 0; font-size: 1em; }
    table { border-collapse: collapse; margin: 1.5em 0; width: 100%; font-size: .92em; }
    th, td { border-bottom: 1px solid var(--rule); padding: .45em .7em; text-align: left; vertical-align: top; }
    th { font-weight: 700; border-bottom-width: 2px; }
    caption { caption-side: bottom; color: var(--muted); font-size: .85em; padding-top: .5em; }
    ul.contains-task-list, li.task-list-item { list-style: none; }
    ul.contains-task-list { padding-left: 1.2em; }
    li.task-list-item input { margin: 0 .5em 0 -1.4em; }
    /* cmark-gfm marks task items only by their checkbox; in loose lists the text follows in a <p>. */
    li:has(> input[type=checkbox]) { list-style: none; }
    li > input[type=checkbox] { margin: 0 .55em 0 -1.35em; vertical-align: -0.1em; }
    li > input[type=checkbox] + p { display: inline; }
    .footnotes { margin-top: 3em; font-size: .85em; color: var(--muted); }
    .footnotes hr { margin: 1em 0; }
    .math { font-size: 1.05em; }
    div.math { text-align: center; margin: 1.2em 0; overflow-x: auto; }
    @media print {
      body { background: #fff; color: #000; }
      #content { max-width: none; padding: 0; }
      a { color: inherit; }
      pre, blockquote, table, figure { break-inside: avoid; }
      h1, h2, h3, h4 { break-after: avoid; }
    }
    @page { margin: 2.2cm 2.4cm; }

    """

    private static let templateCSS: [PreviewTemplate: String] = [
        .modern: """
        body.modern { font-family: 'iA Writer Quattro S', 'PlexSans', 'IBM Plex Sans', -apple-system, sans-serif; font-size: 18px; line-height: 1.6; }
        .modern h1, .modern h2, .modern h3, .modern h4, .modern h5, .modern h6 { line-height: 1.25; margin: 1.8em 0 .6em; }
        .modern h1 { font-size: 2em; margin-top: 0; }
        .modern h2 { font-size: 1.45em; }
        .modern h3 { font-size: 1.2em; }
        .modern h4, .modern h5, .modern h6 { font-size: 1em; }
        .modern p, .modern ul, .modern ol { margin: 0 0 1em; }

        """,
        .classic: """
        body.classic { font-family: 'Iowan Old Style', 'Palatino', 'Charter', Georgia, serif; font-size: 20px; line-height: 1.55; }
        .classic h1, .classic h2, .classic h3, .classic h4, .classic h5, .classic h6 { font-weight: 600; line-height: 1.25; margin: 1.8em 0 .6em; }
        .classic h1 { font-size: 2.1em; font-weight: 500; margin-top: 0; }
        .classic h2 { font-size: 1.5em; font-weight: 500; }
        .classic h3 { font-size: 1.2em; font-style: italic; font-weight: 500; }
        .classic h4, .classic h5, .classic h6 { font-size: 1em; }
        .classic p, .classic ul, .classic ol { margin: 0 0 1em; hyphens: auto; }

        """,
        .manuscriptMono: manuscript("manuscriptMono", "'iA Writer Mono S', 'PlexMono', 'IBM Plex Mono', monospace"),
        .manuscriptDuo: manuscript("manuscriptDuo", "'iA Writer Duo S', 'PlexMono', 'IBM Plex Mono', monospace"),
        .manuscriptQuattro: manuscript("manuscriptQuattro", "'iA Writer Quattro S', 'PlexSans', 'IBM Plex Sans', sans-serif"),
        .github: """
        body.github { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif; font-size: 16px; line-height: 1.5; }
        .github #content { max-width: 980px; padding: 45px; box-sizing: border-box; }
        .github h1, .github h2, .github h3, .github h4, .github h5, .github h6 { margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
        .github h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--rule); }
        .github h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--rule); }
        .github h3 { font-size: 1.25em; }
        .github h4 { font-size: 1em; }
        .github h5 { font-size: .875em; }
        .github h6 { font-size: .85em; color: var(--muted); }
        .github p, .github blockquote, .github ul, .github ol, .github table, .github pre { margin: 0 0 16px; }
        .github blockquote { border-left: .25em solid var(--rule); padding: 0 1em; }
        .github code { font-size: 85%; padding: .2em .4em; border-radius: 6px; }
        .github pre { padding: 16px; border-radius: 6px; font-size: 85%; }
        .github th, .github td { border: 1px solid var(--rule); padding: 6px 13px; }
        .github tr:nth-child(2n) { background: var(--code-bg); }
        .github ul, .github ol { padding-left: 2em; }

        """,
    ]

    private static func manuscript(_ name: String, _ family: String) -> String {
        """
        body.\(name) { font-family: \(family); font-size: 17px; line-height: 1.65; }
        .\(name) #content { max-width: 36em; }
        .\(name) h1, .\(name) h2, .\(name) h3, .\(name) h4, .\(name) h5, .\(name) h6 { font-size: 1em; font-weight: 700; margin: 2em 0 .8em; }
        .\(name) h1 { text-transform: uppercase; letter-spacing: .04em; margin-top: 0; }
        .\(name) p, .\(name) ul, .\(name) ol { margin: 0 0 1.1em; }

        """
    }

    private static let options = """
    body.center-headings h1, body.center-headings h2, body.center-headings h3 { text-align: center; }
    body.indent-paragraphs p { margin-bottom: 0; }
    body.indent-paragraphs p + p { text-indent: 1.6em; }
    body.number-headings { counter-reset: h2; }
    body.number-headings h2 { counter-reset: h3; }
    body.number-headings h3 { counter-reset: h4; }
    body.number-headings h2::before { counter-increment: h2; content: counter(h2) ". "; }
    body.number-headings h3::before { counter-increment: h3; content: counter(h2) "." counter(h3) ". "; }
    body.number-headings h4::before { counter-increment: h4; content: counter(h2) "." counter(h3) "." counter(h4) ". "; }

    """
}
