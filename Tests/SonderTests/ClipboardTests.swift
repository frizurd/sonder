import AppKit
import XCTest
@testable import Sonder

final class ClipboardTests: XCTestCase {
    private let pasteboard = NSPasteboard.withUniqueName()

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    private func textView(_ source: String) -> MarkdownTextView {
        let textView = MarkdownTextView.make()
        textView.string = source
        MarkdownStyler().style(textView.textStorage!, with: EditorStyle())
        return textView
    }

    private func copied(_ source: String, selecting visible: String) -> String {
        let textView = textView(source)
        textView.pasteboard = pasteboard
        textView.setSelectedRange((source as NSString).range(of: visible))
        textView.copy(nil)
        return pasteboard.string(forType: .string) ?? ""
    }

    func testCopyKeepsRawMarkdown() {
        XCTAssertEqual(copied("This is **bold** text", selecting: "**bold**"), "**bold**")
        XCTAssertEqual(copied("# Hello world", selecting: "# Hello world"), "# Hello world")
        XCTAssertEqual(copied("A [link](https://example.com) here", selecting: "[link](https://example.com)"),
                       "[link](https://example.com)")
    }

    func testCopyIsExactSelection() {
        XCTAssertEqual(copied("This is **bold** text", selecting: "bold"), "bold")
    }

    func testCopyPutsOnlyPlainTextOnPasteboard() {
        _ = copied("This is **bold** text", selecting: "bold")
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(.string))
        XCTAssertFalse(types.contains(.rtf) || types.contains(.html) || types.contains(.rtfd))
    }

    func testStylingNeverChangesCharacters() {
        let source = "# Title\n\n- [x] Done ==mark== [[Link]] #tag\n\n```\ncode\n```\n"
        XCTAssertEqual(textView(source).string, source)
    }

    func testHashWithoutSpaceIsNotAHeading() {
        let tv = textView("#hello\n# Heading")
        let tagFont = tv.textStorage!.attribute(.font, at: 2, effectiveRange: nil) as! NSFont
        let headingFont = tv.textStorage!.attribute(.font, at: 10, effectiveRange: nil) as! NSFont
        XCTAssertFalse(tagFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(headingFont.fontDescriptor.symbolicTraits.contains(.bold))
    }
}
