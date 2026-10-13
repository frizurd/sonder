import AppKit
import XCTest
@testable import Sonder

/// Timings for the hot paths on a large document. Run with `PERF=1 swift test --filter PerformanceTests`.
final class PerformanceTests: XCTestCase {
    static let document: String = {
        let paragraph = """
        ## Section heading

        This is **bold** and *italic* text with a [link](https://example.com), some `code`, a #tag and ==highlight==.
        - [ ] A task item that is long enough to wrap across a couple of lines in the editor column
        - Another list item with [[Wikilink]] and a footnote[^1]
        > A quote line with ~~strike~~ text.

        Plain prose sentence one. Plain prose sentence two, basically with a filler. Another one here.

        """
        return String(repeating: paragraph, count: 600)
    }()

    private func time(_ label: String, iterations: Int = 1, _ work: () -> Void) {
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations { work() }
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000 / Double(iterations)
        print(String(format: "PERF %-38@ %8.2f ms", label as NSString, ms))
    }

    func testTimings() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["PERF"] == nil, "set PERF=1")
        let doc = Self.document
        print("PERF document: \((doc as NSString).length) UTF-16 units, \(doc.split(separator: "\n").count) lines")
        let style = EditorStyle.current()
        let storage = NSTextStorage(string: doc)
        let styler = MarkdownStyler()
        time("full style") { styler.style(storage, with: style) }

        // A keystroke in the middle of the document.
        let middle = (doc as NSString).length / 2
        time("keystroke restyle (incremental)", iterations: 50) {
            storage.replaceCharacters(in: NSRange(location: middle, length: 0), with: "a")
            styler.style(storage, with: style, edited: NSRange(location: middle, length: 1))
        }
        time("style check (whole doc)") { _ = TextAnalysis.styleCheck(doc, categories: Set(StyleCategory.allCases), customPatterns: "") }
        time("parts of speech (whole doc)") { _ = TextAnalysis.partsOfSpeech(in: doc, include: Set(PartOfSpeech.allCases)) }
        time("stats (whole doc)") { _ = TextAnalysis.stats(doc) }
        time("render preview (cmark)") { _ = MarkdownRenderer().render(doc) }
        // The text system: opening the document, and one typed character with relayout.
        let textView = MarkdownTextView.make()
        textView.setFrameSize(NSSize(width: 800, height: 900))
        time("open: set text + style + full layout") {
            textView.string = doc
            styler.style(textView.textStorage!, with: style)
            textView.layoutManager!.ensureLayout(for: textView.textContainer!)
        }
        let lm = textView.layoutManager!
        time("keystroke: insert + restyle + relayout", iterations: 50) {
            textView.textStorage!.replaceCharacters(in: NSRange(location: middle, length: 0), with: "a")
            styler.style(textView.textStorage!, with: style, edited: NSRange(location: middle, length: 1), delta: 1)
            lm.ensureLayout(forCharacterRange: NSRange(location: middle, length: 2000))
        }
        var width: CGFloat = 800
        time("width change frame (scrolled to middle)", iterations: 10) {
            width -= 7
            textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            lm.ensureLayout(forCharacterRange: NSRange(location: middle, length: 3000))
        }
        let names = (0..<5000).map { "Folder \($0 % 40)/Note number \($0).md" }
        time("fuzzy rank 5000 (built-in)") { _ = FuzzyFinder.builtIn("nonu12", names) }
        let contents = Dictionary(uniqueKeysWithValues: (0..<2000).map { (URL(fileURLWithPath: "/tmp/n\($0).md"), doc.prefix(3000).description) })
        time("content search 2000 notes") {
            _ = contents.filter { $0.value.lowercased().contains("prose") && $0.value.lowercased().contains("filler") }
        }
    }
}
