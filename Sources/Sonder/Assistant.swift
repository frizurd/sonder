import AppKit
import SwiftUI

/// A conversation with an AI tool about the open document. Answers are never written into the text
/// on their own: the writer inserts them or applies them as edits, and they are marked as AI-authored.
final class AssistantModel: ObservableObject {
    struct Message: Identifiable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        var provider: String = ""
        var isStreaming = false
        var failed = false
        /// For revisions: the text that was selected when asked, and where.
        var target: NSRange?
        var original: String?
        var expectsRevision = false
    }

    enum Action: String, CaseIterable, Identifiable {
        case critique, improve, shorten, grammar, continueWriting, summarize, titles
        var id: String { rawValue }

        var title: String {
            switch self {
            case .critique: "Critique"
            case .improve: "Improve"
            case .shorten: "Shorten"
            case .grammar: "Fix Grammar"
            case .continueWriting: "Continue"
            case .summarize: "Summarize"
            case .titles: "Titles"
            }
        }

        var symbol: String {
            switch self {
            case .critique: "text.bubble"
            case .improve: "wand.and.stars"
            case .shorten: "arrow.down.right.and.arrow.up.left"
            case .grammar: "checkmark.seal"
            case .continueWriting: "text.append"
            case .summarize: "list.bullet.rectangle"
            case .titles: "textformat"
            }
        }

        /// Actions whose answer replaces the text they were given.
        var isRevision: Bool { [.improve, .shorten, .grammar].contains(self) }

        var instruction: String {
            switch self {
            case .critique:
                "Critique the text as a demanding editor. Point out unclear arguments, weak wording, clichés and structural problems, quoting the passages. Don't rewrite it."
            case .improve:
                "Revise the text to be clearer and stronger while keeping the author's voice, meaning and Markdown formatting."
            case .shorten:
                "Shorten the text by about a third without losing its meaning. Keep the author's voice and Markdown formatting."
            case .grammar:
                "Fix spelling, grammar and punctuation only. Change nothing else, and keep the Markdown formatting."
            case .continueWriting:
                "Continue the text with one or two paragraphs in the author's voice. Return only the new paragraphs."
            case .summarize:
                "Summarize the text in a few bullet points."
            case .titles:
                "Suggest five titles for the text, as a Markdown list."
            }
        }
    }

    @Published var messages: [Message] = []
    @Published var draft = ""
    @Published private(set) var isRunning = false
    @Published var providerID: String {
        didSet { Preferences.store.set(providerID, forKey: "ai.provider") }
    }

    private weak var window: WindowModel?
    private var run: AIRun?
    private let toolbox = AIToolbox.shared

    init(window: WindowModel) {
        self.window = window
        providerID = Preferences.store.string(forKey: "ai.provider") ?? ""
    }

    var provider: AIToolbox.Installed? {
        toolbox.installed(providerID) ?? toolbox.installed.first
    }

    func model(for id: String) -> String {
        Preferences.store.string(forKey: "ai.model.\(id)") ?? ""
    }

    func setModel(_ model: String, for id: String) {
        Preferences.store.set(model, forKey: "ai.model.\(id)")
        objectWillChange.send()
    }

    // MARK: Asking

    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }
        draft = ""
        ask(question, action: nil)
    }

    func perform(_ action: Action) {
        ask(action.title, action: action)
    }

    private func ask(_ question: String, action: Action?) {
        guard !isRunning, let provider, let editor = window?.editor, let textView = editor.textView else {
            if provider == nil { NSSound.beep() }
            return
        }
        let model = model(for: provider.id)
        if provider.provider.requiresModel && model.isEmpty {
            messages.append(Message(role: .assistant, text: "Choose a model for \(provider.provider.name) first.", failed: true))
            return
        }

        let selection = textView.selectedRange()
        let text = editor.currentText()
        let selected = selection.length > 0 ? (text as NSString).substring(with: selection) : nil
        let expectsRevision = action?.isRevision == true
        // A revision without a selection revises the whole document.
        let target = expectsRevision ? (selected != nil ? selection : NSRange(location: 0, length: (text as NSString).length)) : nil

        messages.append(Message(role: .user, text: question))
        var answer = Message(role: .assistant, text: "", provider: provider.provider.name, isStreaming: true)
        answer.target = target
        answer.original = target.map { (text as NSString).substring(with: $0) }
        answer.expectsRevision = expectsRevision
        messages.append(answer)
        let answerID = answer.id

        let prompt = buildPrompt(question: question, action: action, document: text, selection: selected)
        isRunning = true
        run = AIRun(provider, prompt: prompt, model: model.isEmpty ? nil : model) { [weak self] event in
            guard let self, let index = self.messages.firstIndex(where: { $0.id == answerID }) else { return }
            switch event {
            case .output(let partial):
                self.messages[index].text = partial
            case .finished(let final):
                self.messages[index].text = expectsRevision ? Self.unwrapFence(final) : final
                self.messages[index].isStreaming = false
                self.finish()
            case .failed(let error):
                self.messages[index].text = error
                self.messages[index].failed = true
                self.messages[index].isStreaming = false
                self.finish()
            }
        }
    }

    private func finish() {
        isRunning = false
        run = nil
    }

    func stop() {
        run?.cancel()
    }

    func clear() {
        stop()
        messages = []
    }

    private func buildPrompt(question: String, action: Action?, document: String, selection: String?) -> String {
        let title = window?.title ?? "Untitled"
        // Very long documents are trimmed around the selection so the prompt stays within tool limits.
        let limit = 60_000
        var context = document
        if context.count > limit { context = String(context.prefix(limit)) + "\n[…document truncated…]" }

        var prompt = """
        You are a writing partner inside a plain-text Markdown editor. The writer stays the author: \
        be direct and specific. Answer in Markdown, without preamble or closing remarks. \
        Don't use tools or read files; everything you need is below.

        """
        let history = messages.dropLast(2).suffix(8).filter { !$0.failed }
        if !history.isEmpty {
            prompt += "\nConversation so far:\n"
            for message in history {
                prompt += (message.role == .user ? "Writer: " : "You: ") + message.text + "\n"
            }
        }
        prompt += "\n<document title=\"\(title)\">\n\(context)\n</document>\n"
        if let selection {
            prompt += "\n<selection>\n\(selection)\n</selection>\n"
        }
        if let action {
            let subject = selection != nil ? "the selected text" : "the document"
            prompt += "\nTask: \(action.instruction.replacingOccurrences(of: "the text", with: subject))"
            if action.isRevision {
                prompt += " Return only the revised version of \(subject), with nothing before or after it."
            }
        } else {
            prompt += "\nThe writer asks: \(question)"
        }
        return prompt
    }

    /// Some tools wrap a revision in a code fence; the revision is the inside.
    static func unwrapFence(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard lines.count >= 2, lines.first!.hasPrefix("```"), lines.last!.trimmingCharacters(in: .whitespaces) == "```" else { return text }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    // MARK: Using answers

    private func author(for message: Message) -> Author {
        Author(kind: .ai, name: message.provider.isEmpty ? "AI" : message.provider)
    }

    /// Inserts the answer at the caret, marked as written by the AI.
    func insert(_ message: Message) {
        guard let textView = window?.editor?.textView else { return }
        var text = message.text
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        // Insert as its own paragraph unless the caret is at an empty line.
        let line = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
        let lineIsEmpty = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !lineIsEmpty {
            textView.setSelectedRange(NSRange(location: NSMaxRange(TextAnalysis.paragraph(in: ns, at: caret)), length: 0))
            text = "\n\n" + text
        }
        textView.insert(text, by: author(for: message))
        textView.window?.makeFirstResponder(textView)
    }

    /// Applies a revision over the text it was made from: only the changed words become AI-authored.
    func apply(_ message: Message) {
        guard let textView = window?.editor?.textView, let target = message.target, let original = message.original else { return }
        let ns = textView.string as NSString
        var range = target
        // The text may have moved since; find the original again, or fall back to the current selection.
        if NSMaxRange(range) > ns.length || ns.substring(with: range) != original {
            let found = ns.range(of: original)
            if found.location != NSNotFound {
                range = found
            } else if textView.selectedRange().length > 0 {
                range = textView.selectedRange()
            } else {
                NSSound.beep()
                return
            }
        }
        textView.replaceWithEdits(range, newText: message.text, author: author(for: message))
        textView.window?.makeFirstResponder(textView)
    }

    func copy(_ message: Message) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
    }
}

// MARK: - Pane

struct AssistantPane: View {
    @ObservedObject var model: WindowModel
    @ObservedObject var assistant: AssistantModel
    @ObservedObject private var toolbox = AIToolbox.shared
    @FocusState private var inputFocused: Bool

    init(model: WindowModel) {
        self.model = model
        assistant = model.assistant
    }

    var body: some View {
        VStack(spacing: 0) {
            if toolbox.installed.isEmpty { Color.clear.frame(height: Chrome.barHeight) } else { header }
            if toolbox.installed.isEmpty {
                emptyState
            } else {
                conversation
                actions
                input
            }
        }
    }

    /// The model to use, just below the title-bar header (AssistantHeader) that picks the tool.
    private var header: some View {
        HStack(spacing: 6) {
            Text("Model").font(.system(size: 11)).foregroundStyle(.secondary)
            modelField
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.top, Chrome.barHeight + 2)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var modelField: some View {
        if let provider = assistant.provider {
            if provider.id == "ollama", !toolbox.ollamaModels.isEmpty {
                Picker("Model", selection: Binding(
                    get: { assistant.model(for: provider.id) },
                    set: { assistant.setModel($0, for: provider.id) })) {
                    Text("Choose Model").tag("")
                    ForEach(toolbox.ollamaModels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            } else {
                TextField(provider.provider.placeholderModel.isEmpty ? "default model" : "model, e.g. \(provider.provider.placeholderModel)",
                          text: Binding(get: { assistant.model(for: provider.id) },
                                        set: { assistant.setModel($0, for: provider.id) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("Model to use; leave empty for the tool's default")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(toolbox.isScanning ? "Looking for AI tools…" : "No AI tools found")
                .font(.system(size: 13, weight: .medium))
            Text("The Assistant uses AI command-line tools installed on this Mac: Claude Code, Codex, Cursor, Gemini, Grok, Copilot, OpenCode, Qwen, Ollama or llm.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
            Button("Look Again") { toolbox.rescan() }
                .disabled(toolbox.isScanning)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if assistant.messages.isEmpty {
                        intro
                    }
                    ForEach(assistant.messages) { message in
                        MessageView(message: message, assistant: assistant)
                            .id(message.id)
                    }
                }
                .padding(14)
            }
            .onChange(of: assistant.messages.last?.text) { _, _ in
                if let last = assistant.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about your text")
                .font(.system(size: 13, weight: .semibold))
            Text("Select a passage, or nothing for the whole document. Answers stay here until you insert them; anything you insert or apply is marked as AI-written in Authorship.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var actions: some View {
        FlowLayout(spacing: 6) {
            ForEach(AssistantModel.Action.allCases) { action in
                Button {
                    assistant.perform(action)
                } label: {
                    Label(action.title, systemImage: action.symbol)
                        .font(.system(size: 11.5))
                }
                .glassButton()
                .controlSize(.small)
                .disabled(assistant.isRunning)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask \(assistant.provider?.provider.name ?? "AI")…", text: $assistant.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($inputFocused)
                .onSubmit { assistant.send() }
            if assistant.isRunning {
                Button { assistant.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 18)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentBlue)
                    .help("Stop")
            } else {
                Button { assistant.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 18)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(assistant.draft.isEmpty ? Color.chrome : Color.accentBlue)
                    .disabled(assistant.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send (Return)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: 18)
        .padding([.horizontal, .bottom], 12)
        .onAppear { inputFocused = true }
    }
}

private struct MessageView: View {
    let message: AssistantModel.Message
    @ObservedObject var assistant: AssistantModel

    var body: some View {
        switch message.role {
        case .user:
            Text(message.text)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if message.text.isEmpty && message.isStreaming {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(message.provider) is thinking…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                } else {
                    Text(message.text)
                        .font(.custom(Theme.font(Preferences.shared.typeface, size: 13).fontName, size: 13))
                        .lineSpacing(3)
                        .foregroundStyle(message.failed ? Color.red.opacity(0.8) : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !message.isStreaming && !message.failed && !message.text.isEmpty {
                    HStack(spacing: 12) {
                        if message.expectsRevision {
                            Button("Apply Edits") { assistant.apply(message) }
                                .help("Replace the original with this revision; only changed words are marked as AI")
                        }
                        Button("Insert") { assistant.insert(message) }
                            .help("Insert at the caret, marked as written by \(message.provider)")
                        Button("Copy") { assistant.copy(message) }
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}

/// The Assistant's title-bar header: which AI tool answers, and clearing the conversation.
struct AssistantHeader: View {
    @ObservedObject var assistant: AssistantModel
    @ObservedObject private var toolbox = AIToolbox.shared

    var body: some View {
        HStack(spacing: 10) {
            if !toolbox.installed.isEmpty {
                GlassButtonGroup {
                    Menu {
                        Picker("Assistant", selection: Binding(
                            get: { assistant.provider?.id ?? "" },
                            set: { assistant.providerID = $0 })) {
                            ForEach(toolbox.installed) { Text($0.provider.name).tag($0.id) }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Button("Look for AI Tools Again") { toolbox.rescan() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                            Text(assistant.provider?.provider.name ?? "Assistant")
                                .font(.system(size: 13, weight: .semibold))
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                        }
                        .padding(.horizontal, 10)
                        .frame(height: Chrome.buttonSize - 4)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(HeaderButtonStyle(shape: .capsule))
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Choose the AI tool")
                }
            } else {
                Text("Assistant").font(.system(size: 13, weight: .semibold))
            }
            Spacer(minLength: 0)
            GlassIconButton(symbol: "trash", help: "Clear conversation") { assistant.clear() }
                .disabled(assistant.messages.isEmpty)
                .opacity(assistant.messages.isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 14)
    }
}
