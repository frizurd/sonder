import AppKit
import XCTest
@testable import Sonder

final class AnnotationTests: XCTestCase {
    func testRoundTrip() {
        let body = "Hello world, 👋🏽 there\n"
        let runs = [
            Annotations.Run(author: "@Jane", range: NSRange(location: 0, length: 5)),
            Annotations.Run(author: "&AI", range: (body as NSString).range(of: "👋🏽 there")),
        ]
        let file = Annotations.serialize(body: body, runs: runs)
        XCTAssertTrue(file.hasPrefix(body + "\n---\nAnnotations: 0,"))
        XCTAssertTrue(file.hasSuffix("...\n"))
        let parsed = Annotations.parse(file)
        XCTAssertEqual(parsed.body, body)
        XCTAssertEqual(parsed.runs, runs)
    }

    func testGraphemeRanges() {
        // The emoji with a skin tone is one grapheme but four UTF-16 units.
        let body = "a👋🏽b"
        let file = Annotations.serialize(body: body, runs: [Annotations.Run(author: "&AI", range: NSRange(location: 5, length: 1))])
        XCTAssertTrue(file.contains("&AI: 2\n"), file)
    }

    func testEditedTextDropsAnnotations() {
        let file = Annotations.serialize(body: "Hello\n", runs: [Annotations.Run(author: "&AI", range: NSRange(location: 0, length: 5))])
        let tampered = file.replacingOccurrences(of: "Hello", with: "Jello")
        let parsed = Annotations.parse(tampered)
        XCTAssertEqual(parsed.body, "Jello\n")
        XCTAssertTrue(parsed.runs.isEmpty)
    }

    func testNoRunsWritesPlainText() {
        XCTAssertEqual(Annotations.serialize(body: "Just text", runs: []), "Just text")
        XCTAssertEqual(Annotations.parse("Just text\n---\nnot annotations").body, "Just text\n---\nnot annotations")
    }
}

final class AnalysisTests: XCTestCase {
    func testStyleCheckFindsBuiltInPhrases() {
        let text = "It was basically a game changer, and we combine together the end result."
        let matches = TextAnalysis.styleCheck(text, categories: [.fillers, .cliches, .redundancies], customPatterns: "")
        let phrases = Set(matches.map { (text as NSString).substring(with: $0.range).lowercased() })
        XCTAssertTrue(phrases.isSuperset(of: ["basically", "game changer", "combine together", "end result"]), "\(phrases)")
    }

    func testCustomPatternsAndExceptions() {
        let text = "We utilize this as well as that, very much."
        let custom = "utilize\n-very\nas ~~well~~ as"
        let matches = TextAnalysis.styleCheck(text, categories: [.fillers, .custom], customPatterns: custom)
        let phrases = Set(matches.map { (text as NSString).substring(with: $0.range) })
        XCTAssertEqual(phrases, ["utilize", "well"])
    }

    func testStats() {
        let stats = TextAnalysis.stats("# Title\n\nOne two three. Four five!\n\n- [x] done\n- [ ] open\n")
        XCTAssertEqual(stats.words, 9)
        XCTAssertEqual(stats.tasks, 2)
        XCTAssertEqual(stats.completedTasks, 1)
        XCTAssertEqual(stats.paragraphs, 3)
    }

    func testSentenceFocus() {
        let text = "First sentence here. Second one is this. Third." as NSString
        let range = TextAnalysis.sentence(in: text, at: text.range(of: "one").location)
        XCTAssertEqual(text.substring(with: range), "Second one is this.")
    }
}

final class RendererTests: XCTestCase {
    func testGitHubFlavoredMarkdown() {
        let html = MarkdownRenderer().render("| a | b |\n|---|---|\n| 1 | 2 |\n\n- [x] done\n\n~~gone~~ https://apple.com").html
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("checkbox"))
        XCTAssertTrue(html.contains("<del>gone</del>"))
        XCTAssertTrue(html.contains("<a href=\"https://apple.com\">"))
    }

    func testWriterExtensions() {
        let html = MarkdownRenderer().render("See [[Other Note|the note]], ==this== and #idea. `==code==`").html
        XCTAssertTrue(html.contains("href=\"wikilink:Other%20Note\">the note</a>"), html)
        XCTAssertTrue(html.contains("<mark>this</mark>"))
        XCTAssertTrue(html.contains("<span class=\"hashtag\">#idea</span>"))
        XCTAssertTrue(html.contains("<code>==code==</code>"))
    }

    func testHashWithoutSpaceIsNotAHeading() {
        let html = MarkdownRenderer().render("#notaheading\n\n# Heading").html
        XCTAssertFalse(html.contains("<h1>notaheading"))
        XCTAssertTrue(html.contains("<h1>Heading</h1>"))
    }

    func testFrontMatterTitle() {
        let output = MarkdownRenderer().render("---\ntitle: Hello\n---\nBody")
        XCTAssertEqual(output.title, "Hello")
        XCTAssertFalse(output.html.contains("title:"))
    }

    func testContentBlocks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "name,qty\napple,3\n".write(to: folder.appendingPathComponent("fruit.csv"), atomically: true, encoding: .utf8)
        var renderer = MarkdownRenderer()
        renderer.baseURL = folder
        let html = renderer.render("Before\n\n/fruit.csv \"Fruit\"\n").html
        XCTAssertTrue(html.contains("<td>apple</td>"), html)
        XCTAssertTrue(html.contains("<caption>Fruit</caption>"))
    }

    func testMathIsShieldedFromMarkdown() {
        let html = MarkdownRenderer().render("Euler: $e^{i\\pi} + 1 = 0$ and $a_1 * b_2$").html
        XCTAssertTrue(html.contains("<span class=\"math\">$a_1 * b_2$</span>"), html)
    }
}

final class EditingTests: XCTestCase {
    private func textView(_ source: String, selection: NSRange) -> MarkdownTextView {
        let tv = MarkdownTextView.make()
        tv.string = source
        tv.setSelectedRange(selection)
        return tv
    }

    func testHeadingToggles() {
        let tv = textView("Title", selection: NSRange(location: 2, length: 0))
        tv.setHeading(2)
        XCTAssertEqual(tv.string, "## Title")
        tv.setHeading(1)
        XCTAssertEqual(tv.string, "# Title")
        tv.setHeading(1)
        XCTAssertEqual(tv.string, "Title")
    }

    func testTaskToggle() {
        let tv = textView("- [ ] Buy milk", selection: NSRange(location: 8, length: 0))
        tv.toggleTaskDone(nil)
        XCTAssertEqual(tv.string, "- [x] Buy milk")
    }

    func testMoveLines() {
        let tv = textView("one\ntwo\nthree", selection: NSRange(location: 5, length: 0))
        tv.moveLinesUp(nil)
        XCTAssertEqual(tv.string, "two\none\nthree")
        tv.moveLinesDown(nil)
        tv.moveLinesDown(nil)
        XCTAssertEqual(tv.string, "one\nthree\ntwo")
    }

    func testBoldWrapsWordUnderCaret() {
        let tv = textView("make this bold", selection: NSRange(location: 6, length: 0))
        tv.toggleBold(nil)
        XCTAssertEqual(tv.string, "make **this** bold")
        tv.toggleBold(nil)
        XCTAssertEqual(tv.string, "make this bold")
    }

    func testOrderedListNumbersLines() {
        let tv = textView("a\nb\nc", selection: NSRange(location: 0, length: 5))
        tv.toggleOrderedList(nil)
        XCTAssertEqual(tv.string, "1. a\n2. b\n3. c")
    }

    func testFootnote() {
        let tv = textView("Claim.", selection: NSRange(location: 5, length: 0))
        tv.insertFootnote(nil)
        XCTAssertEqual(tv.string, "Claim[^1].\n\n[^1]: ")
    }
}
