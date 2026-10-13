import AppKit
import Combine
import SwiftUI

struct MarkdownEditor: NSViewRepresentable {
    @ObservedObject var model: WindowModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownTextView.make()
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.background
        scrollView.documentView = textView
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        ScrollPocket.hideTop(of: scrollView)

        let coordinator = context.coordinator
        textView.delegate = coordinator
        textView.markdownDelegate = coordinator
        coordinator.attach(textView, scrollView: scrollView)
        model.attach(coordinator)

        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {}

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, EditorHost, MarkdownTextViewDelegate {
        weak var textView: MarkdownTextView?
        private weak var scrollView: NSScrollView?
        private let model: WindowModel
        private let prefs = Preferences.shared
        private let styler = MarkdownStyler()
        private var style = EditorStyle.current()
        private var subscriptions: Set<AnyCancellable> = []

        /// Results of the slower language passes, recomputed in the background after edits.
        private var partsOfSpeech: [(NSRange, PartOfSpeech)] = []
        private var styleMatches: [TextAnalysis.StyleMatch] = []
        private var analysisGeneration = 0
        private let analysisQueue = DispatchQueue(label: "editor.analysis", qos: .userInitiated)
        private var analysisWork: DispatchWorkItem?
        private var isLoading = false
        /// Characters changed since the last restyle, so only those lines are restyled.
        private var pendingEdit: NSRange?
        /// How much the text grew (or shrank) since the last restyle.
        private var pendingDelta = 0
        /// The characters the drawing-only layers were last applied to (the visible part, with a margin).
        private var overlayRange = NSRange(location: 0, length: 0)
        /// The characters the language passes last covered.
        private var analyzedRange = NSRange(location: NSNotFound, length: 0)

        init(model: WindowModel) {
            self.model = model
        }

        func attach(_ textView: MarkdownTextView, scrollView: NSScrollView) {
            self.textView = textView
            self.scrollView = scrollView
            textView.textStorage?.delegate = self
            applyPreferences()

            prefs.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.applyPreferences() }
                .store(in: &subscriptions)

            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification, object: scrollView.contentView)
                .sink { [weak self] _ in self?.scrolled() }
                .store(in: &subscriptions)
            NotificationCenter.default.publisher(for: NSView.frameDidChangeNotification, object: scrollView.contentView)
                .sink { [weak self] _ in self?.fitWidth() }
                .store(in: &subscriptions)
            scrollView.contentView.postsFrameChangedNotifications = true
            fitWidth()
        }

        /// The text view always spans the visible width, so lines wrap at the window edge.
        /// The text view always spans the visible width, so lines wrap at the window edge.
        /// (MarkdownTextView keeps the scroll position steady while the width changes.)
        private func fitWidth() {
            guard let textView, let scrollView else { return }
            let width = scrollView.contentSize.width
            if abs(textView.frame.width - width) > 0.5 {
                textView.setFrameSize(NSSize(width: width, height: textView.frame.height))
            } else {
                textView.updateInsets()
            }
        }

        // MARK: Preferences

        private func applyPreferences() {
            guard let textView else { return }
            let newStyle = EditorStyle.current(prefs)
            let restyleNeeded = newStyle != style
            style = newStyle
            textView.editorStyle = newStyle
            textView.lineLength = prefs.lineLength
            let typewriterChanged = textView.typewriter != prefs.focusMode
            textView.typewriter = prefs.focusMode
            textView.pairBrackets = prefs.pairBrackets
            textView.isAutomaticQuoteSubstitutionEnabled = prefs.smartQuotes
            textView.isAutomaticDashSubstitutionEnabled = prefs.smartDashes
            textView.isContinuousSpellCheckingEnabled = prefs.spellCheck
            if restyleNeeded { restyle() }
            analyze()
            applyOverlays()
            if typewriterChanged || restyleNeeded {
                // The margins just changed: lay the text out at its new size before scrolling,
                // or the old height limits the scroll and the text ends up low on the screen.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let textView = self.textView else { return }
                    if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
                    textView.sizeToFit()
                    if self.prefs.focusMode {
                        self.centerCaret(animated: false)
                    } else {
                        textView.scrollRangeToVisible(textView.selectedRange())
                    }
                }
            }
        }

        // MARK: EditorHost

        func load(_ document: LoadedDocument) {
            guard let textView, let storage = textView.textStorage else { return }
            isLoading = true
            defer { isLoading = false }
            // Loaded text belongs to whoever the file says wrote it, never to the person typing.
            textView.typingAttributes = style.baseAttributes
            textView.string = document.text
            storage.removeAttribute(.mdAuthor, range: NSRange(location: 0, length: storage.length))
            for run in document.runs where NSMaxRange(run.range) <= storage.length {
                storage.addAttribute(.mdAuthor, value: run.author, range: run.range)
            }
            pendingEdit = nil
            pendingDelta = 0
            analyzedRange = NSRange(location: NSNotFound, length: 0)
            partsOfSpeech = []
            styleMatches = []
            restyle()
            textView.undoManager?.removeAllActions()
            let length = storage.length
            textView.setSelectedRange(NSRange(location: min(document.selection.location, length), length: 0))
            textView.updateInsets()
            if let scrollView {
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: -scrollView.contentInsets.top))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            if prefs.focusMode { centerCaret(animated: false) }
            analyze()
            applyOverlays()
        }

        func currentText() -> String {
            textView?.string ?? ""
        }

        func selectedText() -> String? {
            guard let textView, textView.selectedRange().length > 0 else { return nil }
            return textView.liveText.substring(with: textView.selectedRange())
        }

        func authorRuns() -> [Annotations.Run] {
            guard let storage = textView?.textStorage else { return [] }
            var runs: [Annotations.Run] = []
            storage.enumerateAttribute(.mdAuthor, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard let author = value as? String else { return }
                runs.append(Annotations.Run(author: author, range: range))
            }
            return runs
        }

        func reveal(_ range: NSRange) {
            guard let textView else { return }
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
        }

        // MARK: MarkdownTextViewDelegate

        var documentURL: URL? { model.fileURL }

        func follow(link: String) {
            model.follow(link: link)
        }

        func editorDidBecomeFocused() {
            model.fileListActive = false
        }

        /// Pasted text is not attributed to whoever is typing.
        func didPasteText(in range: NSRange) {
            guard prefs.showAuthors, let storage = textView?.textStorage, NSMaxRange(range) <= storage.length else { return }
            storage.removeAttribute(.mdAuthor, range: range)
            applyOverlays()
        }

        // MARK: Styling

        private func restyle(edited: NSRange? = nil, delta: Int = 0) {
            guard let textView, let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            styler.style(storage, with: style, edited: edited, delta: delta)
            textView.typingAttributes = typingAttributes
        }

        /// What new typing gets: plain body text, attributed to the writer when authorship is on.
        private var typingAttributes: [NSAttributedString.Key: Any] {
            var typing = style.baseAttributes
            if prefs.showAuthors { typing[.mdAuthor] = Author.me.key }
            return typing
        }

        // MARK: NSTextStorageDelegate

        /// Records where characters changed and keeps the language-pass results lined up with the text.
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters), !isLoading else { return }
            pendingEdit = pendingEdit.map { previous in
                // Shift the earlier edit if this one happened before it, then merge.
                var earlier = previous
                if editedRange.location <= earlier.location { earlier.location = max(0, earlier.location + delta) }
                return NSUnionRange(earlier, editedRange)
            } ?? editedRange
            pendingDelta += delta
            let oldEnd = NSMaxRange(editedRange) - delta
            func shift(_ r: NSRange) -> NSRange? {
                if NSMaxRange(r) <= editedRange.location { return r }
                if r.location >= oldEnd { return NSRange(location: r.location + delta, length: r.length) }
                return nil
            }
            partsOfSpeech = partsOfSpeech.compactMap { range, part in shift(range).map { ($0, part) } }
            styleMatches = styleMatches.compactMap { match in
                shift(match.range).map { TextAnalysis.StyleMatch(range: $0, category: match.category) }
            }
        }

        /// The visible characters, extended by `screens` viewport heights above and below.
        private func visibleCharacters(extendedBy screens: CGFloat) -> NSRange {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
                  let scrollView, let storage = textView.textStorage, storage.length > 0 else { return NSRange(location: 0, length: 0) }
            var rect = scrollView.contentView.documentVisibleRect
            rect = rect.insetBy(dx: 0, dy: -rect.height * screens)
            rect.origin.y -= textView.textContainerOrigin.y
            let glyphs = layoutManager.glyphRange(forBoundingRectWithoutAdditionalLayout: rect, in: container)
            var chars = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            // Whole paragraphs, so sentences and phrases aren't cut in half.
            chars = storage.mutableString.paragraphRange(for: chars)
            return NSIntersectionRange(chars, NSRange(location: 0, length: storage.length))
        }

        /// Runs part-of-speech tagging and Style Check off the main thread, on the text around what's visible.
        private func analyze() {
            analysisWork?.cancel()
            analysisGeneration += 1
            let generation = analysisGeneration
            let wantsSyntax = prefs.syntaxHighlight, wantsStyle = prefs.styleCheck
            guard wantsSyntax || wantsStyle, let storage = textView?.textStorage else {
                partsOfSpeech = []
                styleMatches = []
                analyzedRange = NSRange(location: NSNotFound, length: 0)
                return
            }
            let window = visibleCharacters(extendedBy: 3)
            let text = storage.mutableString.substring(with: window)
            let parts = prefs.syntaxParts, categories = prefs.styleCategories, custom = prefs.customPatterns
            let work = DispatchWorkItem { [weak self] in
                let offset = window.location
                let pos = wantsSyntax ? TextAnalysis.partsOfSpeech(in: text, include: parts)
                    .map { (NSRange(location: $0.0.location + offset, length: $0.0.length), $0.1) } : []
                let style = wantsStyle ? TextAnalysis.styleCheck(text, categories: categories, customPatterns: custom)
                    .map { TextAnalysis.StyleMatch(range: NSRange(location: $0.range.location + offset, length: $0.range.length), category: $0.category) } : []
                DispatchQueue.main.async {
                    guard let self, generation == self.analysisGeneration else { return }
                    self.partsOfSpeech = pos
                    self.styleMatches = style
                    self.analyzedRange = window
                    self.applyOverlays()
                }
            }
            analysisWork = work
            analysisQueue.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        /// Drawing-only layers on top of the markdown styling: authors, parts of speech, style check, focus.
        /// Only the visible part of the document (with a screen of margin) is touched, so the cost per
        /// keystroke doesn't grow with the length of the document.
        private func applyOverlays() {
            guard let textView, let layoutManager = textView.layoutManager, let storage = textView.textStorage else { return }
            let anyLayer = prefs.syntaxHighlight || prefs.styleCheck || prefs.showAuthors
                || (prefs.focusMode && prefs.focusScope != .typewriter)
            // Nothing to draw and nothing left over from before: skip the pass entirely.
            guard anyLayer || overlayRange.length > 0 else { return }
            let length = storage.length
            let previous = NSIntersectionRange(overlayRange, NSRange(location: 0, length: length))
            let range = visibleCharacters(extendedBy: 1)
            overlayRange = range
            let clear = previous.length > 0 ? NSUnionRange(previous, range) : range
            for key: NSAttributedString.Key in [.foregroundColor, .strikethroughStyle, .strikethroughColor] {
                layoutManager.removeTemporaryAttribute(key, forCharacterRange: clear)
            }
            if !anyLayer { overlayRange = NSRange(location: 0, length: 0) }
            guard anyLayer, range.length > 0 else { return }
            func clipped(_ r: NSRange) -> NSRange? {
                let i = NSIntersectionRange(r, range)
                return i.length > 0 ? i : nil
            }

            if prefs.showAuthors {
                storage.enumerateAttribute(.mdAuthor, in: range) { value, run, _ in
                    let author = (value as? String).flatMap(Author.init(key:))
                    switch author?.kind {
                    case .ai?:
                        // A soft gradient across the run.
                        var whole = NSRange()
                        _ = storage.attribute(.mdAuthor, at: run.location, longestEffectiveRange: &whole,
                                              in: NSRange(location: 0, length: length))
                        var i = run.location
                        let step = max(1, whole.length / 24)
                        while i < NSMaxRange(run) {
                            let r = NSRange(location: i, length: min(step, NSMaxRange(run) - i))
                            let fraction = CGFloat(i - whole.location) / CGFloat(max(1, whole.length))
                            layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.aiGradient(at: fraction), forCharacterRange: r)
                            i += step
                        }
                    case .reference?:
                        layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.dimmed, forCharacterRange: run)
                    case .human?:
                        if author?.name != Author.me.name {
                            layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.secondary, forCharacterRange: run)
                        }
                    case nil:
                        layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.secondary, forCharacterRange: run)
                    }
                }
            }

            if prefs.syntaxHighlight {
                for (word, part) in partsOfSpeech {
                    if let r = clipped(word) {
                        layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.partOfSpeech(part), forCharacterRange: r)
                    }
                }
            }

            if prefs.styleCheck {
                for match in styleMatches {
                    guard let r = clipped(match.range) else { continue }
                    layoutManager.addTemporaryAttributes([
                        .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                        .strikethroughColor: Theme.styleCheckStrike,
                        .foregroundColor: Theme.secondary,
                    ], forCharacterRange: r)
                }
            }

            if prefs.focusMode, prefs.focusScope != .typewriter {
                let text = storage.mutableString
                let caret = textView.selectedRange()
                var focus = prefs.focusScope == .sentence
                    ? TextAnalysis.sentence(in: text, at: caret.location)
                    : TextAnalysis.paragraph(in: text, at: caret.location)
                if caret.length > 0 { focus = NSUnionRange(focus, caret) }
                let before = NSRange(location: 0, length: focus.location)
                let after = NSRange(location: NSMaxRange(focus), length: length - NSMaxRange(focus))
                for r in [before, after] {
                    if let r = clipped(r) {
                        layoutManager.addTemporaryAttribute(.foregroundColor, value: Theme.dimmed, forCharacterRange: r)
                    }
                }
            }
        }

        /// After scrolling somewhere new, extend the layers (and the language passes) to the new text.
        private func refreshOverlaysAfterScroll() {
            let visible = visibleCharacters(extendedBy: 0)
            guard visible.length > 0 else { return }
            if NSIntersectionRange(visible, overlayRange) != visible { applyOverlays() }
            if prefs.syntaxHighlight || prefs.styleCheck,
               analyzedRange.location == NSNotFound || NSIntersectionRange(visible, analyzedRange) != visible {
                analyze()
            }
        }

        // MARK: Typewriter

        /// Keeps the caret line in the vertical middle of the window.
        private func centerCaret(animated: Bool) {
            guard let textView, let scrollView, let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            let length = textView.textStorage?.length ?? 0
            let caret = min(textView.selectedRange().location, length)
            var lineRect: NSRect
            if length == 0 || (caret == length && textView.textStorage?.mutableString.hasSuffix("\n") == true) {
                lineRect = layoutManager.extraLineFragmentRect
                if lineRect.isEmpty && length > 0 {
                    let glyph = layoutManager.glyphIndexForCharacter(at: max(0, length - 1))
                    lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                }
            } else {
                let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, length - 1))
                layoutManager.ensureLayout(forGlyphRange: NSRange(location: glyph, length: 1))
                lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            }
            _ = container
            // Center within the part of the view not covered by the toolbar.
            let insets = scrollView.contentInsets
            let midY = lineRect.midY + textView.textContainerOrigin.y
            // The bottom inset is extra scroll room, not hidden space; only the header covers the view.
            let visible = scrollView.contentView.bounds.height - insets.top
            let minY = -insets.top
            let maxY = max(minY, textView.frame.height - scrollView.contentView.bounds.height + insets.bottom)
            let target = NSPoint(x: 0, y: min(maxY, max(minY, (midY - insets.top - visible / 2).rounded())))
            guard abs(scrollView.contentView.bounds.origin.y - target.y) > 0.5 else { return }
            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    context.allowsImplicitAnimation = true
                    scrollView.contentView.animator().setBoundsOrigin(target)
                } completionHandler: {
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            } else {
                scrollView.contentView.setBoundsOrigin(target)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        private func scrolled() {
            guard let textView, let scrollView else { return }
            let visible = scrollView.contentView.bounds
            let insets = scrollView.contentInsets
            let range = max(1, textView.frame.height - visible.height + insets.top + insets.bottom)
            let fraction = min(1, max(0, (visible.minY + insets.top) / range))
            // Every change goes out: the Preview follows pixel for pixel, not in steps.
            if fraction != model.status.scroll.value { model.status.scroll.send(fraction) }
            if prefs.syntaxHighlight || prefs.styleCheck || prefs.showAuthors || prefs.focusMode {
                refreshOverlaysAfterScroll()
            }
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let textView, !isLoading else { return }
            let edited = pendingEdit, delta = pendingDelta
            pendingEdit = nil
            pendingDelta = 0
            restyle(edited: edited.flatMap { NSMaxRange($0) <= (textView.textStorage?.length ?? 0) ? $0 : nil }, delta: delta)
            applyOverlays()
            analyze()
            model.textChanged()
            if prefs.focusMode {
                DispatchQueue.main.async { self.centerCaret(animated: false) }
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isLoading else { return }
            if prefs.focusMode {
                applyOverlays()
                let event = NSApp.currentEvent?.type
                // Clicking or dragging to select shouldn't make the page jump under the pointer.
                if event != .leftMouseDown && event != .leftMouseDragged && event != .leftMouseUp {
                    centerCaret(animated: true)
                }
            }
            model.selectionChanged()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)),
               NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                (textView as? MarkdownTextView)?.openLinkAtCaret(nil)
                return true
            }
            return false
        }

        /// Keeps typing in plain body style. Without this, clicking into bold, a heading, or text by
        /// another author would carry that formatting (and authorship) into what is typed next.
        func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldTypingAttributes: [String: Any] = [:],
                      toAttributes newTypingAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
            typingAttributes
        }
    }
}
