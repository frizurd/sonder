import AppKit

/// What the text view asks of its surroundings.
protocol MarkdownTextViewDelegate: AnyObject {
    var documentURL: URL? { get }
    func follow(link: String)
    func didPasteText(in range: NSRange)
    func editorDidBecomeFocused()
}

final class MarkdownTextView: NSTextView {
    weak var markdownDelegate: MarkdownTextViewDelegate?

    /// The text without copying it (`string` copies the whole document). Read it before changing the text.
    var liveText: NSString { textStorage?.mutableString ?? "" }

    /// Characters per line of the text column (64, 72 or 80).
    var lineLength = 72 { didSet { updateInsets() } }
    var editorStyle = EditorStyle() { didSet { if editorStyle != oldValue { updateInsets() } } }
    /// Focus Mode keeps the caret line vertically centered, so the text needs room above and below.
    var typewriter = false { didSet { if typewriter != oldValue { updateInsets() } } }

    static func make() -> MarkdownTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        // Contiguous layout gives exact line heights, so scrolling never has to correct itself mid-flight.
        layoutManager.allowsNonContiguousLayout = false
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        // The container is sized explicitly (see updateInsets): the text column only changes width when
        // the window is narrower than it, so resizing a wide window never re-wraps the text.
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticTextReplacementEnabled = true
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.background
        textView.insertionPointColor = Theme.caret
        textView.selectedTextAttributes = [.backgroundColor: Theme.selection]
        textView.registerForDraggedTypes([.fileURL])
        textView.updateInsets()
        return textView
    }

    /// Whenever its frame changes, NSTextView re-centers on the caret (so toggling the Library or Preview
    /// made the text jump). Instead the line at the top of the view stays put.
    /// Depth of nested frame changes (NSTextView resizes itself again while being resized).
    private var resizeDepth = 0

    override func setFrameSize(_ newSize: NSSize) {
        guard abs(newSize.width - frame.width) > 0.5, let scrollView = enclosingScrollView,
              let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else {
            // Height changes as text is laid out or typed; typing scrolls to the caret on its own,
            // so the frame change itself shouldn't move the view.
            resizeDepth += 1
            super.setFrameSize(newSize)
            resizeDepth -= 1
            updateInsets()
            return
        }
        let clip = scrollView.contentView
        let top = -scrollView.contentInsets.top
        let atTop = clip.bounds.origin.y <= top + 0.5
        // The character at the top of the visible area, and how far below that edge its line starts.
        let visibleTop = clip.bounds.origin.y + scrollView.contentInsets.top
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: max(0, visibleTop - textContainerOrigin.y)), in: textContainer)
        let anchor = layoutManager.characterIndexForGlyph(at: glyph)
        let offset = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerOrigin.y - clip.bounds.origin.y

        resizeDepth += 1
        super.setFrameSize(newSize)
        updateInsets()
        resizeDepth -= 1

        var target = top
        if !atTop, anchor < (textStorage?.length ?? 0) {
            let newGlyph = layoutManager.glyphIndexForCharacter(at: anchor)
            layoutManager.ensureLayout(forGlyphRange: NSRange(location: 0, length: newGlyph + 1))
            target = layoutManager.lineFragmentRect(forGlyphAt: newGlyph, effectiveRange: nil).minY + textContainerOrigin.y - offset
        }
        let maxY = max(top, frame.height - clip.bounds.height + scrollView.contentInsets.bottom)
        target = min(max(target, top), maxY)
        if abs(clip.bounds.origin.y - target) > 0.5 {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    override func scrollToVisible(_ rect: NSRect) -> Bool {
        resizeDepth > 0 ? false : super.scrollToVisible(rect)
    }

    /// Centers a column of `lineLength` characters, plus the gutter on each side where markers hang.
    func updateInsets() {
        let width = enclosingScrollView?.contentSize.width ?? bounds.width
        let column = editorStyle.characterWidth * CGFloat(lineLength)
        let x = max(12, ((width - column) / 2 - editorStyle.gutter).rounded())
        let inset = NSSize(width: x, height: 28)
        if textContainerInset != inset { textContainerInset = inset }
        if let textContainer {
            let containerWidth = max(100, width - 2 * x)
            if abs(textContainer.size.width - containerWidth) > 0.5 {
                textContainer.size = NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
            }
        }

        // The scroll view's insets keep the text clear of the header. In Focus Mode there is room for
        // half a screen below the text, so the last line can still scroll up to the middle; the text
        // starts at the top as usual and the caret line stays centered once it gets there.
        if let scrollView = enclosingScrollView {
            let visible = scrollView.frame.height - Chrome.barHeight
            let insets = NSEdgeInsets(top: Chrome.barHeight, left: 0,
                                      bottom: typewriter ? max(0, (visible / 2).rounded()) : 0, right: 0)
            let current = scrollView.contentInsets
            if current.top != insets.top || current.bottom != insets.bottom || scrollView.automaticallyAdjustsContentInsets {
                // Stay pinned to the top if the text was scrolled all the way up.
                let wasAtTop = scrollView.contentView.bounds.origin.y <= -current.top + 1
                scrollView.automaticallyAdjustsContentInsets = false
                scrollView.contentInsets = insets
                if wasAtTop {
                    scrollView.contentView.scroll(to: NSPoint(x: 0, y: -insets.top))
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                }
            }
        }
    }

    /// Only follows the caret or selection. The layout manager also calls this while it lays out text,
    /// with its own guess of the visible range, which fights scrolling and makes the view jump on resize.
    /// Near the top, it keeps the page's top margin instead of tucking the first line under the header.
    override func scrollRangeToVisible(_ range: NSRange) {
        guard range == selectedRange() || selectedRanges.contains(where: { $0.rangeValue == range }) else { return }
        super.scrollRangeToVisible(range)
        guard let scrollView = enclosingScrollView else { return }
        let top = -scrollView.contentInsets.top
        let origin = scrollView.contentView.bounds.origin
        if origin.y > top && origin.y < textContainerInset.height {
            scrollView.contentView.scroll(to: NSPoint(x: origin.x, y: top))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { markdownDelegate?.editorDidBecomeFocused() }
        return accepted
    }

    // MARK: Caret

    /// A thick blue caret, a little shorter than the line.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var caret = rect
        caret.size.width = 2
        let height = min(rect.height, (editorStyle.size * 1.3).rounded())
        caret.origin.y = rect.midY - height / 2
        caret.size.height = height
        if flag {
            Theme.caret.setFill()
            NSBezierPath(roundedRect: caret, xRadius: 1, yRadius: 1).fill()
        } else {
            setNeedsDisplay(caret.insetBy(dx: -1, dy: 0), avoidAdditionalLayout: true)
        }
    }

    override func setNeedsDisplay(_ rect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = rect
        rect.size.width += 2
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    // MARK: Clipboard

    var pasteboard = NSPasteboard.general

    /// Copy always puts raw markdown, and only plain text, on the clipboard.
    override func copy(_ sender: Any?) {
        guard selectedRanges.count == 1 else { return super.copy(sender) }
        let range = selectedRange()
        guard range.length > 0 else { return }
        pasteboard.clearContents()
        pasteboard.setString((string as NSString).substring(with: range), forType: .string)
    }

    override func cut(_ sender: Any?) {
        copy(sender)
        guard isEditable, selectedRange().length > 0 else { return }
        insertText("", replacementRange: selectedRange())
    }

    override func paste(_ sender: Any?) {
        let start = selectedRange().location
        let before = (string as NSString).length - selectedRange().length
        super.paste(sender)
        let inserted = (string as NSString).length - before
        if inserted > 0 { markdownDelegate?.didPasteText(in: NSRange(location: start, length: inserted)) }
    }

    /// Paste as {author}: pastes plain text and attributes it.
    func paste(as author: Author) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        insert(text, by: author)
    }

    /// Mark Selection as {author}; nil removes authorship from the selection.
    func mark(_ range: NSRange, as author: Author?) {
        guard range.length > 0, let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        let before = storage.attributedSubstring(from: range)
        undoManager?.registerUndo(withTarget: self) { view in
            view.textStorage?.replaceCharacters(in: range, with: before)
            view.didChangeText()
        }
        if let author {
            storage.addAttribute(.mdAuthor, value: author.key, range: range)
        } else {
            storage.removeAttribute(.mdAuthor, range: range)
        }
        didChangeText()
    }

    // MARK: Links

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let link = link(at: convert(event.locationInWindow, from: nil)) {
            markdownDelegate?.follow(link: link)
            return
        }
        super.mouseDown(with: event)
    }

    private func link(at point: NSPoint) -> String? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let p = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: p, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        return link(atCharacter: layoutManager.characterIndexForGlyph(at: glyph))
    }

    func link(atCharacter index: Int) -> String? {
        guard let storage = textStorage, index < storage.length else { return nil }
        if let target = storage.attribute(.mdWikilink, at: index, effectiveRange: nil) as? String {
            return "wikilink:" + (target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target)
        }
        if let path = storage.attribute(.mdContentBlock, at: index, effectiveRange: nil) as? String {
            return path.hasPrefix("/") ? String(path.dropFirst()) : path
        }
        if let url = storage.attribute(.mdLink, at: index, effectiveRange: nil) as? String {
            return url.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }
        return nil
    }

    /// ⌘⏎: opens the link under the caret.
    @objc func openLinkAtCaret(_ sender: Any?) {
        let location = selectedRange().location
        let candidates = [location, location - 1].filter { $0 >= 0 }
        guard let link = candidates.lazy.compactMap({ self.link(atCharacter: $0) }).first else {
            NSSound.beep()
            return
        }
        markdownDelegate?.follow(link: link)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // NSTextView hands out a shared menu; changing it in place would add items every time.
        guard let menu = super.menu(for: event)?.copy() as? NSMenu else { return nil }
        if let link = link(at: convert(event.locationInWindow, from: nil)) {
            let item = NSMenuItem(title: "Open Link", action: #selector(openContextLink(_:)), keyEquivalent: "")
            item.representedObject = link
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        let authors = NSMenuItem(title: "Authors", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for author in [Author.me, .ai, .reference] {
            let paste = NSMenuItem(title: "Paste as \(author.name)", action: #selector(pasteAsAuthor(_:)), keyEquivalent: "")
            paste.representedObject = author.key
            paste.target = self
            submenu.addItem(paste)
        }
        let edits = NSMenuItem(title: "Paste Edits from AI", action: #selector(pasteEditsFromAI(_:)), keyEquivalent: "")
        edits.target = self
        submenu.addItem(edits)
        if selectedRange().length > 0 {
            submenu.addItem(.separator())
            for author in [Author.me, .ai, .reference] {
                let mark = NSMenuItem(title: "Mark Selection as \(author.name)", action: #selector(markSelection(_:)), keyEquivalent: "")
                mark.representedObject = author.key
                mark.target = self
                submenu.addItem(mark)
            }
            let clear = NSMenuItem(title: "Clear Authorship", action: #selector(markSelection(_:)), keyEquivalent: "")
            clear.target = self
            submenu.addItem(clear)
        }
        authors.submenu = submenu
        menu.addItem(.separator())
        menu.addItem(authors)
        return menu
    }

    @objc private func pasteAsAuthor(_ sender: NSMenuItem) {
        guard let author = (sender.representedObject as? String).flatMap(Author.init(key:)) else { return }
        paste(as: author)
    }

    @objc func pasteEditsFromAI(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        replaceWithEdits(selectedRange(), newText: text, author: .ai)
    }

    @objc private func markSelection(_ sender: NSMenuItem) {
        mark(selectedRange(), as: (sender.representedObject as? String).flatMap(Author.init(key:)))
    }

    /// Replaces `range` with a revised version, attributing only the words that changed to `author`;
    /// unchanged words keep whoever wrote them. One undoable step. ("Paste Edits From")
    func replaceWithEdits(_ range: NSRange, newText: String, author: Author) {
        guard isEditable, let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        let old = storage.attributedSubstring(from: range)
        let revised = AuthorshipDiff.merge(old: old, new: newText, author: author, base: typingAttributes)
        guard shouldChangeText(in: range, replacementString: newText) else { return }
        storage.replaceCharacters(in: range, with: revised)
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: revised.length))
    }

    /// Inserts text written by `author` at the selection, as one undoable step.
    func insert(_ text: String, by author: Author) {
        guard isEditable, let storage = textStorage else { return }
        let range = selectedRange()
        var attributes = typingAttributes
        attributes[.mdAuthor] = author.key
        guard shouldChangeText(in: range, replacementString: text) else { return }
        storage.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: attributes))
        didChangeText()
        setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    @objc private func openContextLink(_ sender: NSMenuItem) {
        if let link = sender.representedObject as? String { markdownDelegate?.follow(link: link) }
    }

    // MARK: Lists & structure

    private static let listPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(?:([-*+])[ \t]+(\[[ xX]\][ \t]+)?|(\d{1,9})([.)])[ \t]+(\[[ xX]\][ \t]+)?|(>[ \t]?))"#)

    override func insertNewline(_ sender: Any?) {
        let ns = liveText
        let selection = selectedRange()
        let line = lineContentRange(at: selection.location)
        guard isEditable, selection.length == 0,
              let m = Self.listPrefix.firstMatch(in: string, range: line),
              selection.location >= NSMaxRange(m.range)
        else {
            super.insertNewline(sender)
            return
        }

        // Return on an empty item ends the list.
        if NSMaxRange(m.range) == NSMaxRange(line) {
            insertText("", replacementRange: m.range)
            return
        }

        var next = ns.substring(with: m.range(at: 1))
        if m.range(at: 2).location != NSNotFound {
            next += ns.substring(with: m.range(at: 2)) + " "
            if m.range(at: 3).location != NSNotFound { next += "[ ] " }
        } else if m.range(at: 4).location != NSNotFound {
            let number = Int(ns.substring(with: m.range(at: 4))) ?? 0
            next += "\(number + 1)" + ns.substring(with: m.range(at: 5)) + " "
            if m.range(at: 6).location != NSNotFound { next += "[ ] " }
        } else {
            next += "> "
        }
        insertText("\n" + next, replacementRange: selection)
    }

    /// Tab indents list items and multi-line selections; elsewhere it types a tab.
    override func insertTab(_ sender: Any?) {
        if selectionSpansLines || isOnListItem {
            shiftLines(indent: true)
        } else {
            super.insertTab(sender)
        }
    }

    override func insertBacktab(_ sender: Any?) {
        shiftLines(indent: false)
    }

    private var isOnListItem: Bool {
        let line = lineContentRange(at: selectedRange().location)
        return Self.listPrefix.firstMatch(in: string, range: line).map { $0.range(at: 7).location == NSNotFound } ?? false
    }

    private var selectionSpansLines: Bool {
        let selection = selectedRange()
        return selection.length > 0 && (string as NSString).substring(with: selection).contains("\n")
    }

    private func shiftLines(indent: Bool) {
        transformLines { line in
            if indent { return "\t" + line }
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = line.prefix(4).prefix { $0 == " " }.count
            return String(line.dropFirst(spaces))
        }
    }

    /// Replaces each line touched by the selection, keeping the selection on the same text.
    private func transformLines(_ transform: (String) -> String) {
        guard isEditable else { return }
        let ns = string as NSString
        let selection = selectedRange()
        var range = ns.lineRange(for: selection)
        // A selection ending right at a line start doesn't include that line.
        if selection.length > 0, NSMaxRange(selection) == range.location + range.length,
           NSMaxRange(selection) > 0, ns.character(at: NSMaxRange(selection) - 1) == 0x0A {
            range = ns.lineRange(for: NSRange(location: selection.location, length: selection.length - 1))
        }
        let original = ns.substring(with: range)
        let hasTerminator = original.hasSuffix("\n")
        let lines = (hasTerminator ? String(original.dropLast()) : original).components(separatedBy: "\n")
        let replaced = lines.map(transform).joined(separator: "\n") + (hasTerminator ? "\n" : "")
        guard replaced != original, shouldChangeText(in: range, replacementString: replaced) else { return }
        textStorage?.replaceCharacters(in: range, with: replaced)
        didChangeText()
        let delta = (replaced as NSString).length - (original as NSString).length
        if lines.count == 1 {
            let firstDelta = delta
            setSelectedRange(NSRange(location: max(range.location, selection.location + firstDelta), length: selection.length))
        } else {
            setSelectedRange(NSRange(location: range.location, length: (replaced as NSString).length - (hasTerminator ? 1 : 0)))
        }
    }

    private func lineContentRange(at location: Int) -> NSRange {
        TextAnalysis.paragraph(in: liveText, at: location)
    }

    private static let blockPrefix = try! NSRegularExpression(
        pattern: #"^([ \t]*)(#{1,6}[ \t]+|(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?)?"#)

    /// Sets (or, if already set, removes) a line prefix such as `## ` or `- [ ] `.
    private func toggleLinePrefix(_ prefix: (Int) -> String, matches: (String) -> Bool) {
        var index = 0
        let allMatch = linesInSelection.allSatisfy { line in
            let m = Self.blockPrefix.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length))
            guard let marker = m?.range(at: 2), marker.location != NSNotFound else { return matches("") }
            return matches((line as NSString).substring(with: marker))
        }
        transformLines { line in
            let ns = line as NSString
            let m = Self.blockPrefix.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))!
            let indent = ns.substring(with: m.range(at: 1))
            let existing = m.range(at: 2)
            let content = existing.location == NSNotFound ? ns.substring(from: NSMaxRange(m.range(at: 1)))
                                                          : ns.substring(from: NSMaxRange(existing))
            defer { index += 1 }
            if line.trimmingCharacters(in: .whitespaces).isEmpty && linesInSelection.count > 1 { return line }
            return allMatch ? indent + content : indent + prefix(index) + content
        }
    }

    private var linesInSelection: [String] {
        let ns = string as NSString
        let range = ns.lineRange(for: selectedRange())
        var text = ns.substring(with: range)
        if text.hasSuffix("\n") { text.removeLast() }
        return text.components(separatedBy: "\n")
    }

    @objc func heading1(_ sender: Any?) { setHeading(1) }
    @objc func heading2(_ sender: Any?) { setHeading(2) }
    @objc func heading3(_ sender: Any?) { setHeading(3) }
    @objc func heading4(_ sender: Any?) { setHeading(4) }
    @objc func heading5(_ sender: Any?) { setHeading(5) }
    @objc func heading6(_ sender: Any?) { setHeading(6) }

    func setHeading(_ level: Int) {
        let marker = String(repeating: "#", count: level) + " "
        toggleLinePrefix({ _ in marker }) { $0.trimmingCharacters(in: .whitespaces) == marker.trimmingCharacters(in: .whitespaces) }
    }

    @objc func toggleBulletList(_ sender: Any?) {
        toggleLinePrefix({ _ in "- " }) { $0.hasPrefix("-") && !$0.contains("[") }
    }

    @objc func toggleTaskList(_ sender: Any?) {
        toggleLinePrefix({ _ in "- [ ] " }) { $0.hasPrefix("-") && $0.contains("[") }
    }

    @objc func toggleOrderedList(_ sender: Any?) {
        toggleLinePrefix({ "\($0 + 1). " }) { $0.first?.isNumber == true && !$0.contains("[") }
    }

    @objc func toggleOrderedTaskList(_ sender: Any?) {
        toggleLinePrefix({ "\($0 + 1). [ ] " }) { $0.first?.isNumber == true && $0.contains("[") }
    }

    /// ⌥⌘X: ticks the task(s) on the selected lines off, or back on.
    @objc func toggleTaskDone(_ sender: Any?) {
        let task = try! NSRegularExpression(pattern: #"^([ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+\[)([ xX])(\])"#)
        transformLines { line in
            let ns = line as NSString
            guard let m = task.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return line }
            let mark = ns.substring(with: m.range(at: 2)) == " " ? "x" : " "
            return ns.replacingCharacters(in: m.range(at: 2), with: mark)
        }
    }

    /// ⌥⌘↑ / ⌥⌘↓: moves the selected lines past the line above or below.
    @objc func moveLinesUp(_ sender: Any?) { moveLines(up: true) }
    @objc func moveLinesDown(_ sender: Any?) { moveLines(up: false) }

    private func moveLines(up: Bool) {
        guard isEditable else { return }
        let ns = string as NSString
        let selection = selectedRange()
        var block = ns.lineRange(for: selection)
        if selection.length > 0, NSMaxRange(selection) == NSMaxRange(block), NSMaxRange(block) > block.location,
           ns.character(at: NSMaxRange(selection) - 1) == 0x0A, selection.length > 1 {
            block = ns.lineRange(for: NSRange(location: selection.location, length: selection.length - 1))
        }
        if up {
            guard block.location > 0 else { return }
            let above = ns.lineRange(for: NSRange(location: block.location - 1, length: 0))
            var moving = ns.substring(with: block)
            var other = ns.substring(with: above)
            if !moving.hasSuffix("\n") { moving += "\n"; other.removeLast() }
            let range = NSRange(location: above.location, length: NSMaxRange(block) - above.location)
            replace(range, with: moving + other,
                    select: NSRange(location: selection.location - above.length, length: selection.length))
        } else {
            guard NSMaxRange(block) < ns.length else { return }
            let below = ns.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            var moving = ns.substring(with: block)
            var other = ns.substring(with: below)
            if !other.hasSuffix("\n") { other += "\n"; moving.removeLast() }
            let range = NSRange(location: block.location, length: NSMaxRange(below) - block.location)
            replace(range, with: other + moving,
                    select: NSRange(location: selection.location + (other as NSString).length, length: selection.length))
        }
    }

    private func replace(_ range: NSRange, with text: String, select: NSRange) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(select)
        scrollRangeToVisible(select)
    }

    // MARK: Inline formatting

    @objc func toggleBold(_ sender: Any?) { toggleWrap("**") }
    @objc func toggleItalic(_ sender: Any?) { toggleWrap("*") }
    @objc func toggleStrikethrough(_ sender: Any?) { toggleWrap("~~") }
    @objc func toggleHighlight(_ sender: Any?) { toggleWrap("==") }
    @objc func toggleInlineCode(_ sender: Any?) { toggleWrap("`") }

    @objc func insertLink(_ sender: Any?) { insertLinkSyntax(image: false) }
    @objc func insertImageLink(_ sender: Any?) { insertLinkSyntax(image: true) }

    private func insertLinkSyntax(image: Bool) {
        guard isEditable else { return }
        let selection = selectedRange()
        let label = (string as NSString).substring(with: selection)
        let prefix = image ? "![" : "["
        let pasted = NSPasteboard.general.string(forType: .string).flatMap { URL(string: $0)?.scheme != nil ? $0 : nil }
        let url = pasted ?? "url"
        insertText("\(prefix)\(label)](\(url))", replacementRange: selection)
        let base = selection.location + (prefix as NSString).length
        if label.isEmpty {
            setSelectedRange(NSRange(location: base, length: 0))
        } else {
            setSelectedRange(NSRange(location: base + (label as NSString).length + 2, length: (url as NSString).length))
        }
    }

    @objc func insertWikilink(_ sender: Any?) {
        guard isEditable else { return }
        let selection = selectedRange()
        let label = (string as NSString).substring(with: selection)
        insertText("[[\(label)]]", replacementRange: selection)
        setSelectedRange(NSRange(location: selection.location + 2 + (label as NSString).length, length: 0))
        if label.isEmpty { complete(nil) }
    }

    /// ⌃⌘K: inserts the next footnote reference and its definition at the end of the document.
    @objc func insertFootnote(_ sender: Any?) {
        guard isEditable else { return }
        let existing = try! NSRegularExpression(pattern: #"\[\^(\d+)\]"#)
        let numbers = existing.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length))
            .compactMap { Int((string as NSString).substring(with: $0.range(at: 1))) }
        let n = (numbers.max() ?? 0) + 1
        let reference = "[^\(n)]"
        let selection = selectedRange()
        insertText(reference, replacementRange: NSRange(location: NSMaxRange(selection), length: 0))
        let ns = string as NSString
        let separator = ns.hasSuffix("\n\n") ? "" : ns.hasSuffix("\n") ? "\n" : "\n\n"
        let definition = "\(separator)\(reference): "
        insertText(definition, replacementRange: NSRange(location: ns.length, length: 0))
        let end = (string as NSString).length
        setSelectedRange(NSRange(location: end, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// ⇧⌘J: wraps the selected lines in a code fence, or removes the fence around them.
    @objc func toggleCodeBlock(_ sender: Any?) {
        guard isEditable else { return }
        let ns = string as NSString
        let selection = selectedRange()
        let range = ns.lineRange(for: selection)
        var block = ns.substring(with: range)
        let trailing = block.hasSuffix("\n")
        if trailing { block.removeLast() }
        let lines = block.components(separatedBy: "\n")
        if lines.count >= 2, lines.first!.hasPrefix("```"), lines.last!.hasPrefix("```") {
            let inner = lines.dropFirst().dropLast().joined(separator: "\n")
            replace(range, with: inner + (trailing ? "\n" : ""), select: NSRange(location: range.location, length: (inner as NSString).length))
        } else {
            let wrapped = "```\n" + block + "\n```" + (trailing ? "\n" : "")
            let caret = block.isEmpty ? range.location + 3 : range.location + 4
            replace(range, with: wrapped, select: NSRange(location: caret, length: block.isEmpty ? 0 : (block as NSString).length))
        }
    }

    private func toggleWrap(_ token: String) {
        guard isEditable else { return }
        let ns = string as NSString
        var selection = selectedRange()
        let n = (token as NSString).length
        // With nothing selected, format the word under the caret.
        if selection.length == 0, let word = wordRange(at: selection.location) { selection = word }
        let before = NSRange(location: selection.location - n, length: n)
        let after = NSRange(location: NSMaxRange(selection), length: n)
        if before.location >= 0, NSMaxRange(after) <= ns.length,
           ns.substring(with: before) == token, ns.substring(with: after) == token {
            insertText(ns.substring(with: selection),
                       replacementRange: NSRange(location: before.location, length: selection.length + 2 * n))
            setSelectedRange(NSRange(location: before.location, length: selection.length))
        } else {
            let selected = ns.substring(with: selection)
            if selected.hasPrefix(token), selected.hasSuffix(token), (selected as NSString).length >= 2 * n {
                let inner = String(selected.dropFirst(token.count).dropLast(token.count))
                insertText(inner, replacementRange: selection)
                setSelectedRange(NSRange(location: selection.location, length: (inner as NSString).length))
                return
            }
            insertText(token + selected + token, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + n, length: selection.length))
        }
    }

    private func wordRange(at location: Int) -> NSRange? {
        let ns = string as NSString
        guard ns.length > 0 else { return nil }
        let isWord: (Int) -> Bool = { i in
            guard i >= 0, i < ns.length, let scalar = Unicode.Scalar(ns.character(at: i)) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "'" || scalar == "’"
        }
        guard isWord(location) || isWord(location - 1) else { return nil }
        var start = location, end = location
        while isWord(start - 1) { start -= 1 }
        while isWord(end) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    // MARK: Typing: pairs and completion

    var pairBrackets = true
    private static let pairs: [String: String] = ["(": ")", "[": "]", "{": "}"]

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let typed = string as? String, (typed as NSString).length == 1, isEditable, !hasMarkedText(),
              NSApp.currentEvent?.type == .keyDown else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        let ns = liveText
        let selection = replacementRange.location == NSNotFound ? selectedRange() : replacementRange

        if pairBrackets, let close = Self.pairs[typed] {
            if selection.length > 0 {
                // Typing a bracket around a selection wraps it.
                let selected = ns.substring(with: selection)
                super.insertText(typed + selected + close, replacementRange: selection)
                setSelectedRange(NSRange(location: selection.location + 1, length: selection.length))
            } else {
                super.insertText(typed + close, replacementRange: selection)
                setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            }
            if typed == "[", selection.location > 0, ns.character(at: selection.location - 1) == 0x5B, selection.length == 0 {
                complete(nil)
            }
            return
        }

        if pairBrackets, Self.pairs.values.contains(typed), selection.length == 0, selection.location < ns.length,
           ns.substring(with: NSRange(location: selection.location, length: 1)) == typed {
            // Type over the closing bracket that was inserted automatically.
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }

        super.insertText(string, replacementRange: replacementRange)

        if typed == "/", selection.length == 0 {
            let line = (liveText).lineRange(for: NSRange(location: selection.location, length: 0))
            if line.location == selection.location { complete(nil) }
        }
    }

    override func deleteBackward(_ sender: Any?) {
        let ns = liveText
        let selection = selectedRange()
        if pairBrackets, selection.length == 0, selection.location > 0, selection.location < ns.length {
            let open = ns.substring(with: NSRange(location: selection.location - 1, length: 1))
            if let close = Self.pairs[open], ns.substring(with: NSRange(location: selection.location, length: 1)) == close {
                insertText("", replacementRange: NSRange(location: selection.location - 1, length: 2))
                return
            }
        }
        super.deleteBackward(sender)
    }

    private enum CompletionKind { case wikilink, contentBlock }
    private var completionKind: CompletionKind?

    override var rangeForUserCompletion: NSRange {
        let ns = string as NSString
        let caret = selectedRange().location
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        let before = ns.substring(with: NSRange(location: line.location, length: caret - line.location))
        if let open = before.range(of: "[[", options: .backwards), !before[open.upperBound...].contains("]") {
            completionKind = .wikilink
            let start = line.location + (String(before[..<open.upperBound]) as NSString).length
            return NSRange(location: start, length: caret - start)
        }
        if before.hasPrefix("/"), !before.contains(" ") || before.count < 60 {
            completionKind = .contentBlock
            return NSRange(location: line.location + 1, length: caret - line.location - 1)
        }
        completionKind = nil
        return super.rangeForUserCompletion
    }

    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        let partial = (string as NSString).substring(with: charRange).lowercased()
        let library = Library.shared
        switch completionKind {
        case .wikilink:
            index.pointee = 0
            let names = library.textFiles
                .filter { $0 != markdownDelegate?.documentURL }
                .map { library.wikilink(for: $0) }
            return rank(names, partial)
        case .contentBlock:
            index.pointee = 0
            let base = markdownDelegate?.documentURL?.deletingLastPathComponent()
            let files = library.otherFiles + library.textFiles.filter { $0 != markdownDelegate?.documentURL }
            let paths = files.map { url -> String in
                if let base, url.path.hasPrefix(base.path + "/") { return String(url.path.dropFirst(base.path.count + 1)) }
                if let root = library.location(containing: url) { return String(url.path.dropFirst(root.path.count + 1)) }
                return url.path
            }
            return rank(paths, partial)
        case nil:
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }
    }

    private func rank(_ candidates: [String], _ partial: String) -> [String] {
        let matches = partial.isEmpty ? candidates : candidates.filter { $0.lowercased().contains(partial) }
        return Array(Set(matches)).sorted { a, b in
            let ap = a.lowercased().hasPrefix(partial), bp = b.lowercased().hasPrefix(partial)
            return ap != bp ? ap : a.localizedStandardCompare(b) == .orderedAscending
        }.prefix(40).map { $0 }
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        guard flag, completionKind == .wikilink, movement == NSReturnTextMovement else { return }
        // Return jumps past the closing brackets.
        let ns = string as NSString
        let caret = selectedRange().location
        if caret + 2 <= ns.length, ns.substring(with: NSRange(location: caret, length: 2)) == "]]" {
            setSelectedRange(NSRange(location: caret + 2, length: 0))
        }
    }

    // MARK: Drag & drop

    /// Dropping files adds them as content blocks; files from outside the Library are copied next to the document.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty, isEditable else {
            return super.performDragOperation(sender)
        }
        let point = convert(sender.draggingLocation, from: nil)
        let index = characterIndexForInsertion(at: point)
        let base = markdownDelegate?.documentURL?.deletingLastPathComponent()
        var lines: [String] = []
        for url in urls {
            var file = url
            if let base, Library.shared.location(containing: url) == nil {
                let copy = Library.shared.uniqueURL(in: base, base: url.deletingPathExtension().lastPathComponent,
                                                    extension: url.pathExtension)
                if (try? FileManager.default.copyItem(at: url, to: copy)) != nil { file = copy }
            }
            let path: String
            if let base, file.path.hasPrefix(base.path + "/") {
                path = String(file.path.dropFirst(base.path.count + 1))
            } else {
                path = file.path
            }
            lines.append("/" + path)
        }
        let ns = string as NSString
        let lineStart = ns.lineRange(for: NSRange(location: index, length: 0))
        let atLineStart = lineStart.location == index
        let text = (atLineStart ? "" : "\n") + lines.joined(separator: "\n") + "\n"
        insertText(text, replacementRange: NSRange(location: index, length: 0))
        Library.shared.changed()
        return true
    }
}
