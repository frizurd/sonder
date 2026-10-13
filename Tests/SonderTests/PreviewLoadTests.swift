import WebKit
import XCTest
@testable import Sonder

final class PreviewLoadTests: XCTestCase, WKNavigationDelegate {
    private var finished: XCTestExpectation?
    private var log: [String] = []

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        log.append("policy \(action.navigationType.rawValue) \(action.request.url?.absoluteString ?? "-")")
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished?.fulfill() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { log.append("fail \(error)"); finished?.fulfill() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { log.append("failp \(error)"); finished?.fulfill() }

    func testPreviewPageRenders() throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: PreviewWebView.configuration())
        webView.navigationDelegate = self
        let html = Templates.page(body: "<h1>Hi</h1><p>Body text</p>", title: "T", settings: .current(), hasMath: false)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("preview-test.html")
        try Data(html.utf8).write(to: file)
        finished = expectation(description: "load")
        webView.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        wait(for: [finished!], timeout: 15)
        let text = expectation(description: "text")
        var body = ""
        webView.evaluateJavaScript("document.body.innerText") { result, error in
            body = (result as? String) ?? "error: \(String(describing: error))"
            text.fulfill()
        }
        wait(for: [text], timeout: 5)
        print("LOG", log, "BODY", body, "FILE", file.path)
        XCTAssertTrue(body.contains("Body text"))
    }
}

final class PreviewCoordinatorTests: XCTestCase {
    func testCoordinatorRendersMarkdown() throws {
        let model = WindowModel()
        let coordinator = PreviewWebView.Coordinator(model: model)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: PreviewWebView.configuration())
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        let folder = FileManager.default.temporaryDirectory
        coordinator.update(source: "# Hi\n\nBody text", fileURL: folder.appendingPathComponent("x.md"),
                           settings: .current(), smart: true, hardBreaks: false)
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let text = expectation(description: "text")
        var body = ""
        webView.evaluateJavaScript("document.body ? document.body.innerText : 'NO BODY ' + location.href") { result, error in
            body = (result as? String) ?? "error: \(String(describing: error))"
            text.fulfill()
        }
        wait(for: [text], timeout: 5)
        print("BODY", body, "URL", webView.url?.absoluteString ?? "nil")
        XCTAssertTrue(body.contains("Body text"))
    }
}

final class PreviewRaceTests: XCTestCase {
    /// The document's text usually arrives while the first (empty) page is still loading.
    func testUpdateDuringLoadIsNotLost() {
        let model = WindowModel()
        let coordinator = PreviewWebView.Coordinator(model: model)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: PreviewWebView.configuration())
        webView.navigationDelegate = coordinator
        coordinator.webView = webView
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("x.md")
        coordinator.update(source: "", fileURL: file, settings: .current(), smart: true, hardBreaks: false)
        coordinator.update(source: "Arrived late", fileURL: file, settings: .current(), smart: true, hardBreaks: false)
        RunLoop.main.run(until: Date().addingTimeInterval(2))
        let done = expectation(description: "text")
        var body = ""
        webView.evaluateJavaScript("document.body.innerText") { result, _ in body = result as? String ?? ""; done.fulfill() }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(body.contains("Arrived late"), body)
    }
}
