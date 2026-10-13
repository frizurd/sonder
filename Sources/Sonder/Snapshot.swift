import AppKit
import SwiftUI

/// Renders the main window to PNGs without showing it, in a few configurations:
/// `Sonder --snapshot <file.md> <output-dir>`.
///
/// Run with `SONDER_DEFAULTS_SUITE` set so the snapshot's settings don't touch yours.
enum Snapshot {
    static func run(input: String, outputDirectory: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let url = URL(fileURLWithPath: input).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            FileHandle.standardError.write(Data("Cannot read \(input)\n".utf8))
            exit(1)
        }
        try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

        let prefs = Preferences.shared
        let library = Library.shared
        library.addLocation(url.deletingLastPathComponent())

        struct Variant {
            let name: String
            var focus = false
            var scope = FocusScope.sentence
            var syntax = false
            var style = false
            var library = true
            var assistant = false
            var caret = 0
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let middle = (text as NSString).range(of: "As a matter of fact").location
        let variants = [
            Variant(name: "library"),
            Variant(name: "focus", focus: true, library: false, caret: middle == NSNotFound ? 0 : middle + 5),
            Variant(name: "syntax-style", syntax: true, style: true, library: false),
            Variant(name: "assistant", library: false, assistant: true),
        ]

        for (appearanceName, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let appearance = NSAppearance(named: appearanceName)!
            app.appearance = appearance
            for variant in variants {
                prefs.focusMode = variant.focus
                prefs.focusScope = variant.scope
                prefs.syntaxHighlight = variant.syntax
                prefs.styleCheck = variant.style

                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                      backing: .buffered, defer: false)
                window.appearance = appearance
                window.toolbarStyle = .unified
                let host = NSHostingView(rootView: ContentView(windowURL: .constant(url)))
                host.sceneBridgingOptions = [.toolbars, .title]
                window.contentView = host
                pump(0.6)
                let model = WindowRegistry.shared.activeModel
                model?.showLibrary = variant.library
                model?.showAI = variant.assistant
                if variant.assistant, let assistant = model?.assistant {
                    assistant.messages = [
                        .init(role: .user, text: "Critique"),
                        .init(role: .assistant, text: "The opening promises *portable* files but never says why that matters. Lead with the benefit.", provider: "Claude"),
                    ]
                }
                model?.open(url)
                if let textView = model?.editor?.textView {
                    textView.window?.makeFirstResponder(textView)
                    textView.setSelectedRange(NSRange(location: variant.caret, length: 0))
                }
                pump(1.2)

                // The frame view includes the title bar, window buttons and toolbar.
                let view = window.contentView!.superview ?? window.contentView!
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                appearance.performAsCurrentDrawingAppearance {
                    view.cacheDisplay(in: view.bounds, to: rep)
                }
                let path = (outputDirectory as NSString).appendingPathComponent("\(variant.name)-\(suffix).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print(path)
                window.close()
            }
        }
    }

    /// Reports which view receives a click at points along the header row, to check that the
    /// title bar doesn't swallow clicks meant for the header buttons: `Sonder --hit-test <file.md>`.
    static func hitTest(input: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let url = URL(fileURLWithPath: input).standardizedFileURL
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ContentView(windowURL: .constant(url)))
        // On screen as far as AppKit is concerned (events are processed), but outside every display.
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.makeKey()
        pump(1.5)
        let frameView = window.contentView!.superview!
        let height = frameView.bounds.height
        var blocked = 0, total = 0
        for x in stride(from: 300, through: 1220, by: 20) {
            let point = NSPoint(x: CGFloat(x), y: height - 26)
            guard let hit = frameView.hitTest(point) else { continue }
            total += 1
            let inContent = hit.isDescendant(of: window.contentView!)
            if !inContent { blocked += 1 }
            print("x=\(x) \(inContent ? "content" : "BLOCKED") drags=\(hit.mouseDownCanMoveWindow) \(String(describing: type(of: hit)).prefix(60))")
        }
        print("buttons line: \(blocked) of \(total) points blocked by the title bar")

        if let textView = WindowRegistry.shared.activeModel?.editor?.textView, let scrollView = textView.enclosingScrollView {
            print("editor before clicks: clip origin y=\(scrollView.contentView.bounds.origin.y) insets top=\(scrollView.contentInsets.top)")
        }
        // Click the editor header's Library button and see whether it acts.
        if let model = WindowRegistry.shared.activeModel {
            let selectionBefore = model.selection
            click(window, at: NSPoint(x: Chrome.sidebarWidth + 150, y: height - 120))
            pump(0.5)
            print("control: click on first file list row changed selection: \(model.selection != selectionBefore) (\(model.selection))")
            // Now inside the folder, the first row is a note.
            click(window, at: NSPoint(x: Chrome.sidebarWidth + 150, y: height - 120))
            pump(0.5)
            print("clicked note row: open=\(model.fileURL?.lastPathComponent ?? "nil")")
            print("file list focused after clicking it (⌘D deletes): \(model.fileListHasFocus) [\(String(describing: window.firstResponder.map { type(of: $0) }))]")
            if let textView = model.editor?.textView {
                window.makeFirstResponder(textView)
                pump(0.3)
                print("file list focused after clicking the editor (⌘D is Focus Mode): \(model.fileListHasFocus)")
            }
            let probe = NSPoint(x: Chrome.sidebarWidth + Chrome.fileListWidth + 1 + 12 + Chrome.buttonSize / 2, y: height - Chrome.barHeight / 2)
            print("view under Library button:", frameView.hitTest(probe).map { String(describing: type(of: $0)) } ?? "nil")
            let before = model.showLibrary
            let x = Chrome.sidebarWidth + Chrome.fileListWidth + 1 + 12 + Chrome.buttonSize / 2
            click(window, at: NSPoint(x: x, y: height - Chrome.barHeight / 2))
            pump(0.5)
            print("click on Library button toggled it: \(model.showLibrary != before)")
            // And the middle of a grouped button (Preview).
            let previewBefore = model.showPreview
            let editorRight = window.frame.width - (model.showAI ? 341 : 0)
            click(window, at: NSPoint(x: editorRight - 12 - 3 - 34 - 17, y: height - Chrome.barHeight / 2))
            pump(0.5)
            print("click on Preview button toggled it: \(model.showPreview != previewBefore)")
        }
        if let textView = WindowRegistry.shared.activeModel?.editor?.textView, let scrollView = textView.enclosingScrollView {
            let originInWindow = scrollView.convert(NSPoint.zero, to: nil)
            print("editor scroll view frame in window: y(top)=\(height - originInWindow.y - scrollView.frame.height) height=\(scrollView.frame.height) flipped=\(scrollView.isFlipped)")
            print("editor contentInsets top=\(scrollView.contentInsets.top) bottom=\(scrollView.contentInsets.bottom) clip origin y=\(scrollView.contentView.bounds.origin.y) container inset=\(textView.textContainerInset.height) auto=\(scrollView.automaticallyAdjustsContentInsets)")
            let first = textView.layoutManager!.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
            let firstInWindow = textView.convert(NSPoint(x: 0, y: first.minY + textView.textContainerOrigin.y), to: nil)
            print("first line top from window top: \(height - firstInWindow.y)")
        }
        if let textView = WindowRegistry.shared.activeModel?.editor?.textView {
            func caretLineTop() -> CGFloat {
                let lm = textView.layoutManager!
                let glyph = lm.glyphIndexForCharacter(at: min(textView.selectedRange().location, max(0, textView.string.utf16.count - 1)))
                let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let p = textView.convert(NSPoint(x: 0, y: rect.midY + textView.textContainerOrigin.y), to: nil)
                return height - p.y
            }
            // The long document, whichever note earlier steps opened.
            WindowRegistry.shared.activeModel?.open(url)
            pump(0.5)
            print("document for focus/scroll checks: \(textView.string.utf16.count) characters")
            Preferences.shared.focusMode = true
            pump(0.5)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            pump(0.3)
            print("focus, caret at start: caret line center from top \(caretLineTop())")
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count / 2, length: 0))
            pump(0.5)
            print("focus, caret mid-document: caret line center from top \(caretLineTop()) (visible center \(Chrome.barHeight + (height - Chrome.barHeight) / 2))")
            Preferences.shared.focusMode = false
            pump(0.5)
        }
        if let model = WindowRegistry.shared.activeModel, let textView = model.editor?.textView,
           let scrollView = textView.enclosingScrollView {
            func scroll(by delta: Int32) {
                let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
                cg.location = CGPoint(x: 900, y: 400)
                if let event = NSEvent(cgEvent: cg) { scrollView.scrollWheel(with: event) }
            }
            let start = scrollView.contentView.bounds.origin.y
            scroll(by: -300)
            pump(0.1)
            let afterScroll = scrollView.contentView.bounds.origin.y
            pump(0.6)
            let settled = scrollView.contentView.bounds.origin.y
            print("scroll: start \(start), after wheel \(afterScroll), after 0.6s \(settled) (moved: \(afterScroll != start), stayed: \(abs(settled - afterScroll) < 1))")
            scroll(by: Int32(afterScroll - (-30)))
            pump(0.6)
            print("scroll into the top margin: origin \(scrollView.contentView.bounds.origin.y) (should stay near -30, not snap to -52)")
            scroll(by: 1000)
            pump(0.6)
            print("after scrolling up past the top: origin \(scrollView.contentView.bounds.origin.y)")
            print("caret at \(textView.selectedRange().location) of \(textView.string.utf16.count), text height \(textView.frame.height)")
            model.showLibrary.toggle()
            for i in 0..<6 {
                pump(0.1)
                print("  t=\(i) origin \(scrollView.contentView.bounds.origin.y) width \(textView.frame.width) height \(textView.frame.height)")
            }
            print("resize at top: origin \(scrollView.contentView.bounds.origin.y) (want \(-scrollView.contentInsets.top))")
            model.showLibrary.toggle()
            pump(0.4)
        }
        // Open Quickly: type into the palette, pick with Return.
        if let model = WindowRegistry.shared.activeModel {
            // Keys go to whichever window has the keyboard, as they would for real.
            func press(_ chars: String, keyCode: UInt16) {
                // The test app is never active, so nothing is key; send to the open panel directly.
                let target = NSApp.windows.first { $0 is QuickOpenPanel && $0.isVisible } ?? NSApp.keyWindow ?? window
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: target.windowNumber, context: nil, characters: chars,
                                                 charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
                    target.sendEvent(event)
                }
                pump(0.05)
            }
            func type(_ text: String) {
                for character in text {
                    let chars = String(character)
                    press(chars, keyCode: chars == "\r" ? 36 : 0)
                }
            }
            model.selection = .recents
            model.showQuickSearch = true
            pump(0.6)
            let panel = NSApp.windows.first { $0 is QuickOpenPanel && $0.isVisible }
            print("palette panel shown: \(panel != nil), child of the window: \(panel?.parent === window)")
            type("e")
            pump(0.6)
            press(String(UnicodeScalar(NSDownArrowFunctionKey)!), keyCode: 125)
            pump(0.2)
            print("down arrow handled by the panel (not typed): \(model.editor?.textView?.string.contains("\u{F701}") == false)")
            press("\u{1b}", keyCode: 53)
            pump(0.4)
            print("esc closed it: \(!model.showQuickSearch), focus back in note: \(window.firstResponder === model.editor?.textView)")
            model.showQuickSearch = true
            pump(0.6)
            type("groc")
            pump(0.8)
            type("\r")
            pump(0.6)
            print("palette note: open=\(model.fileURL?.lastPathComponent ?? "nil") list=\(model.selection) library=\(model.showLibrary) closed=\(!model.showQuickSearch)")
            model.showQuickSearch = true
            pump(0.6)
            type("note")
            pump(0.8)
            type("\r")
            pump(0.6)
            print("palette folder: list=\(model.selection) closed=\(!model.showQuickSearch)")
        }
        let close = window.standardWindowButton(.closeButton)!
        let center = close.convert(NSPoint(x: close.bounds.midX, y: close.bounds.midY), to: frameView)
        print("window buttons center from top: \(height - center.y)")
    }

    private static func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            pump(0.05)
        }
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
