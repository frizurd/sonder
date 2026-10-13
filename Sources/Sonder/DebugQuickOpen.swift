import AppKit

/// Development aid for `--debug-open-quickly`: presses ⌘P many times through the real event queue,
/// starting from different places (the note, the notes list, nothing focused, right after closing),
/// and logs every time the search field didn't have the keyboard or a typed letter didn't reach it.
extension QuickOpen {
    static func stressTest(rounds: Int = 72) {
        guard let model = WindowRegistry.shared.activeModel, let window = WindowRegistry.shared.window(for: model) else {
            print("no window"); fflush(stdout); return
        }
        var failures = 0
        func post(_ key: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: characters, isARepeat: false, keyCode: key) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
        }
        func fieldHasFocus() -> Bool {
            guard let editor = window.firstResponder as? NSText, let field = editor.delegate as? NSTextField else { return false }
            return field.placeholderString == QuickSearch.placeholder
        }
        func tables(in view: NSView) -> [NSView] {
            (view is NSTableView || view is NSOutlineView ? [view] : []) + view.subviews.flatMap(tables)
        }
        func round(_ i: Int) {
            guard i < rounds else {
                print("open quickly stress: \(failures) failures in \(rounds) rounds"); fflush(stdout)
                return
            }
            // Where focus is before ⌘P.
            let start = i % 6
            switch start {
            case 0: if let textView = model.editor?.textView { window.makeFirstResponder(textView) }
            case 1: if let table = tables(in: window.contentView!).first { window.makeFirstResponder(table) }
            case 2: window.makeFirstResponder(nil)
            case 4: model.showLibrary.toggle() // the columns are still animating
            default: break // straight after the last close
            }
            let noteBefore = model.editor?.textView?.string
            post(35, "p", .command)
            // Typing at once, before the palette has drawn.
            if start == 5 { post(0, "a") }
            let checks: [Double] = [0.05, 0.15, 0.4]
            for delay in checks {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if model.quickOpen != nil, !fieldHasFocus() {
                        print("round \(i) (start \(start)): field not focused after \(delay)s, first responder: \(String(describing: window.firstResponder.map { type(of: $0) }))")
                        if delay == checks.last { failures += 1 }
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                post(start == 5 ? 11 : 0, start == 5 ? "b" : "a")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    if model.editor?.textView?.string != noteBefore { print("round \(i): the letter went into the note"); failures += 1 }
                    let expected = start == 5 ? "ab" : "a"
                    if model.quickOpen?.query != expected {
                        print("round \(i): typed “\(expected)” but the query is “\(model.quickOpen?.query ?? "closed")”")
                        failures += 1
                    }
                    post(53, "\u{1b}")
                    DispatchQueue.main.asyncAfter(deadline: .now() + (start == 2 ? 0.02 : 0.25)) { round(i + 1) }
                }
            }
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        round(0)
    }
}
