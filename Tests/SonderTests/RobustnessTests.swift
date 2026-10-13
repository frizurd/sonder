import AppKit
import XCTest
@testable import Sonder

final class IncrementalStylingTests: XCTestCase {
    private let style = EditorStyle(gutter: 40)

    /// Styling only the edited lines must give exactly what a full pass gives.
    private func assertIncrementalMatchesFull(_ source: String, replacing target: String, with replacement: String,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let storage = NSTextStorage(string: source)
        let styler = MarkdownStyler()
        styler.style(storage, with: style)
        let range = (source as NSString).range(of: target)
        storage.replaceCharacters(in: range, with: replacement)
        styler.style(storage, with: style, edited: NSRange(location: range.location, length: (replacement as NSString).length),
                     delta: (replacement as NSString).length - range.length)

        let expected = NSTextStorage(string: storage.string)
        MarkdownStyler().style(expected, with: style)
        XCTAssertTrue(storage.isEqual(to: expected), "Incremental styling differs for edit \(target) → \(replacement)",
                      file: file, line: line)
    }

    func testEditsInsideNormalLines() {
        let doc = "# Title\n\nSome *text* here.\n\n- item one\n- item two\n"
        assertIncrementalMatchesFull(doc, replacing: "text", with: "**bold** words")
        assertIncrementalMatchesFull(doc, replacing: "item one", with: "item [[link]]")
    }

    func testSplittingAHeadingLine() {
        assertIncrementalMatchesFull("# Hello world\nnext", replacing: " world", with: "\nworld")
    }

    func testCreatingAndRemovingBlocks() {
        let doc = "Intro\n\ncode below\nlet x = 1\nend\n"
        assertIncrementalMatchesFull(doc, replacing: "code below", with: "```")
        assertIncrementalMatchesFull("```\ncode\n```\nafter", replacing: "```\nafter", with: "``\nafter")
        assertIncrementalMatchesFull("Title\nname | qty\nrows", replacing: "rows", with: "--- | ---")
    }

    /// Edits before a code block move it; an edit inside it afterwards must still be seen as inside.
    func testBlocksMoveWithEdits() {
        let storage = NSTextStorage(string: "Intro line\n\n```\ncode\n```\nafter")
        let styler = MarkdownStyler()
        styler.style(storage, with: style)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Longer ")
        styler.style(storage, with: style, edited: NSRange(location: 0, length: 7), delta: 7)
        let fence = (storage.string as NSString).range(of: "```\nafter")
        storage.replaceCharacters(in: NSRange(location: fence.location, length: 3), with: "``")
        styler.style(storage, with: style, edited: NSRange(location: fence.location, length: 2), delta: -1)
        let expected = NSTextStorage(string: storage.string)
        MarkdownStyler().style(expected, with: style)
        XCTAssertTrue(storage.isEqual(to: expected))
    }

    func testTypingAtTheEnd() {
        assertIncrementalMatchesFull("Line one\n## Head", replacing: "Head", with: "Heading")
    }
}

final class AuthorshipDiffTests: XCTestCase {
    func testOnlyChangedWordsAreAttributed() {
        let old = NSMutableAttributedString(string: "The cat sat on the mat.")
        old.addAttribute(.mdAuthor, value: "@Jane", range: NSRange(location: 0, length: old.length))
        let merged = AuthorshipDiff.merge(old: old, new: "The dog sat on the mat.", author: .ai, base: [:])
        XCTAssertEqual(merged.string, "The dog sat on the mat.")
        var authors: [String: String] = [:]
        merged.enumerateAttribute(.mdAuthor, in: NSRange(location: 0, length: merged.length)) { value, range, _ in
            authors[(merged.string as NSString).substring(with: range)] = value as? String
        }
        XCTAssertEqual(authors["dog"], "&AI")
        XCTAssertEqual(authors["The "], "@Jane")
        XCTAssertEqual(authors[" sat on the mat."], "@Jane")
    }
}

final class DecodingTests: XCTestCase {
    func testNonUTF8FilesKeepTheirCharacters() {
        let latin1 = "Café crème brûlée".data(using: .isoLatin1)!
        XCTAssertEqual(TextDecoding.decode(latin1), "Café crème brûlée")
        XCTAssertEqual(TextDecoding.decode(Data("plain ✓".utf8)), "plain ✓")
    }
}

final class AIRunTests: XCTestCase {
    private func tool(_ path: String, input: AIProvider.Input = .stdin) -> AIToolbox.Installed {
        let provider = AIProvider(id: "test", name: "Test", executables: [], input: input, placeholderModel: "",
                                  arguments: { _, _ in [] })
        return AIToolbox.Installed(provider: provider, executable: URL(fileURLWithPath: path))
    }

    private func run(_ installed: AIToolbox.Installed, prompt: String) -> AIRun.Event? {
        let done = expectation(description: "finished")
        var result: AIRun.Event?
        let run = AIRun(installed, prompt: prompt, model: nil) { event in
            switch event {
            case .output: break
            case .finished, .failed:
                result = event
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 10)
        _ = run
        return result
    }

    func testStreamsAnswerFromStandardInput() {
        let prompt = String(repeating: "A long prompt line.\n", count: 20_000)  // bigger than a pipe buffer
        guard case .finished(let answer)? = run(tool("/bin/cat"), prompt: prompt) else { return XCTFail("no answer") }
        XCTAssertEqual(answer, prompt.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testPromptAsArgument() {
        guard case .finished(let answer)? = run(tool("/bin/echo", input: .argument), prompt: "hello") else {
            return XCTFail("no answer")
        }
        XCTAssertEqual(answer, "hello")
    }

    func testFailureIsReported() {
        guard case .failed(let message)? = run(tool("/usr/bin/false"), prompt: "x") else { return XCTFail("expected failure") }
        XCTAssertTrue(message.contains("exited with code 1"), message)
    }

    func testMissingExecutable() {
        guard case .failed? = run(tool("/nonexistent/tool"), prompt: "x") else { return XCTFail("expected failure") }
    }

    func testCancel() {
        let done = expectation(description: "stopped")
        var stopped = false
        let run = AIRun(tool("/bin/sleep", input: .argument), prompt: "30", model: nil) { event in
            if case .failed(let message) = event { stopped = message == "Stopped."; done.fulfill() }
        }
        run.cancel()
        wait(for: [done], timeout: 10)
        XCTAssertTrue(stopped)
    }

    func testCleansTerminalCodes() {
        XCTAssertEqual(AIRun.clean("\u{1B}[1mbold\u{1B}[0m\r\nnext"), "bold\nnext")
    }
}

/// Runs the real installed tools; only when `AI_E2E` lists them, e.g. `AI_E2E=claude,codex swift test`.
final class AIEndToEndTests: XCTestCase {
    func testInstalledTools() throws {
        let ids = (ProcessInfo.processInfo.environment["AI_E2E"] ?? "").split(separator: ",").map(String.init)
        try XCTSkipIf(ids.isEmpty, "set AI_E2E to run")
        let path = AIToolbox.loginShellPath()
        for id in ids {
            guard let provider = AIProvider.all.first(where: { $0.id == id }),
                  let executable = provider.executables.lazy.compactMap({ name in
                      path.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
                          .first { FileManager.default.isExecutableFile(atPath: $0.path) }
                  }).first else { XCTFail("\(id) not installed"); continue }
            let done = expectation(description: id)
            var result = ""
            let run = AIRun(AIToolbox.Installed(provider: provider, executable: executable),
                            prompt: "Reply with exactly the word: pineapple", model: nil) { event in
                switch event {
                case .output: break
                case .finished(let answer): result = answer; done.fulfill()
                case .failed(let error): result = "FAILED: " + error; done.fulfill()
                }
            }
            wait(for: [done], timeout: 180)
            _ = run
            print("[\(id)] \(result)")
            XCTAssertTrue(result.lowercased().contains("pineapple"), "\(id): \(result)")
        }
    }
}

final class FuzzyFinderTests: XCTestCase {
    func testSubsequenceMatching() {
        XCTAssertNotNil(FuzzyFinder.score("grc", "Notes/Groceries.md"))
        XCTAssertNil(FuzzyFinder.score("xyz", "Notes/Groceries.md"))
        XCTAssertEqual(FuzzyFinder.score("gro", "Groceries")?.positions, [0, 1, 2])
    }

    func testWordStartsAndBasenameRankHigher() {
        let candidates = ["Archive/old progress.md", "Notes/Groceries.md", "Project ideas.md"]
        XCTAssertEqual(FuzzyFinder.builtIn("gro", candidates).first, 1)
        XCTAssertEqual(FuzzyFinder.builtIn("pi", candidates).first, 2)
    }

    func testSmartCase() {
        XCTAssertNotNil(FuzzyFinder.score("welcome", "Welcome.md"))
        XCTAssertNil(FuzzyFinder.score("WELCOME", "Welcome.md"))
    }
}
