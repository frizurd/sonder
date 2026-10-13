import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            EditorSettings().tabItem { Label("Editor", systemImage: "character.cursor.ibeam") }
            FocusSettings().tabItem { Label("Focus", systemImage: "scope") }
            LibrarySettings().tabItem { Label("Library", systemImage: "books.vertical") }
            PreviewSettings().tabItem { Label("Templates", systemImage: "doc.richtext") }
            AISettings().tabItem { Label("Assistant", systemImage: "sparkles") }
        }
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Picker("Appearance", selection: $prefs.appearance) {
                ForEach(AppearanceSetting.allCases) { Text($0.title).tag($0) }
            }
            Picker("Word count", selection: $prefs.toolbar) {
                ForEach(ChromeVisibility.allCases) { Text($0.title).tag($0) }
            }
            Picker("New file extension", selection: $prefs.defaultExtension) {
                ForEach(["md", "markdown", "txt", "text"], id: \.self) { Text("." + $0).tag($0) }
            }
            TextField("Your name (Authorship)", text: $prefs.authorName)
        }
        .formStyle(.grouped)
    }
}

private struct EditorSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Text") {
                Picker("Typeface", selection: $prefs.typeface) {
                    ForEach(Typeface.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Text("Text size")
                    Slider(value: $prefs.textSize, in: Preferences.textSizes, step: 1)
                    Text("\(Int(prefs.textSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 44)
                }
                Picker("Line length", selection: $prefs.lineLength) {
                    ForEach(Preferences.lineLengths, id: \.self) { Text("\($0) characters").tag($0) }
                }
                Picker("Highlight color", selection: $prefs.highlightColor) {
                    ForEach(HighlightColor.allCases) { Text($0.title).tag($0) }
                }
                Picker("Completed tasks", selection: $prefs.completedTasks) {
                    ForEach(CompletedTaskStyle.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Typing") {
                Toggle("Insert and type over matching brackets", isOn: $prefs.pairBrackets)
                Toggle("Smart quotes", isOn: $prefs.smartQuotes)
                Toggle("Smart dashes", isOn: $prefs.smartDashes)
                Toggle("Check spelling while typing", isOn: $prefs.spellCheck)
            }
            Text("Set in IBM Plex, unless matching Mono, Duo or Quattro fonts are installed.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct FocusSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Section("Focus") {
                Picker("Focus on", selection: $prefs.focusScope) {
                    ForEach(FocusScope.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Syntax Highlight") {
                ForEach(PartOfSpeech.allCases) { part in
                    Toggle(isOn: Binding(
                        get: { prefs.syntaxParts.contains(part) },
                        set: { if $0 { prefs.syntaxParts.insert(part) } else { prefs.syntaxParts.remove(part) } })) {
                        HStack {
                            Circle().fill(Color(nsColor: Theme.partOfSpeech(part))).frame(width: 8, height: 8)
                            Text(part.title)
                        }
                    }
                }
            }
            Section("Style Check") {
                ForEach(StyleCategory.allCases) { category in
                    Toggle(category.title, isOn: Binding(
                        get: { prefs.styleCategories.contains(category) },
                        set: { if $0 { prefs.styleCategories.insert(category) } else { prefs.styleCategories.remove(category) } }))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Custom patterns")
                    TextEditor(text: $prefs.customPatterns)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 90)
                    Text("One per line. `-phrase` adds an exception, `/regex/` a regular expression, `as ~~well~~ as` strikes only part.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LibrarySettings: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var library = Library.shared

    var body: some View {
        Form {
            Section("Locations") {
                ForEach(library.locations, id: \.self) { url in
                    HStack {
                        Image(systemName: "folder")
                        Text(url.path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if library.locations.count > 1 {
                            Button("Remove") { library.removeLocation(url) }
                        }
                    }
                }
                Button("Add Location…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    if panel.runModal() == .OK, let url = panel.url { library.addLocation(url) }
                }
            }
            Section("Files") {
                Picker("Sort by", selection: $prefs.librarySort) {
                    ForEach(LibrarySort.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Folders on top", isOn: $prefs.foldersOnTop)
                Toggle("Show text excerpts", isOn: $prefs.showExcerpts)
                Toggle("Show file extensions", isOn: $prefs.showExtensions)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PreviewSettings: View {
    @ObservedObject private var prefs = Preferences.shared

    var body: some View {
        Form {
            Picker("Template", selection: $prefs.template) {
                ForEach(PreviewTemplate.allCases) { Text($0.title).tag($0) }
            }
            Section("Default templates") {
                Toggle("Center headings", isOn: $prefs.centerHeadings)
                Toggle("Number headings", isOn: $prefs.numberHeadings)
                Toggle("Indent paragraphs", isOn: $prefs.indentParagraphs)
                Toggle("Invert colors in Dark Mode", isOn: $prefs.invertPreview)
            }
            Section("Markdown") {
                Toggle("Smart punctuation in Preview", isOn: $prefs.smartPunctuation)
                Toggle("Single return makes a line break", isOn: $prefs.singleReturn)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AISettings: View {
    @ObservedObject private var toolbox = AIToolbox.shared

    var body: some View {
        Form {
            Section("AI tools on this Mac") {
                if toolbox.installed.isEmpty {
                    Text(toolbox.isScanning ? "Looking…" : "None found.").foregroundStyle(.secondary)
                }
                ForEach(toolbox.installed) { tool in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(tool.provider.name).font(.headline)
                            Spacer()
                            Text(tool.executable.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        ModelField(id: tool.id, placeholder: tool.provider.placeholderModel)
                    }
                }
                Button("Look Again") { toolbox.rescan() }.disabled(toolbox.isScanning)
            }
            Text("The Assistant runs these tools with your existing accounts, in an empty folder and without file or tool access, and only when you ask. Your document is sent to the tool you pick. Supported: Claude Code, Codex, Cursor, Gemini, Grok, GitHub Copilot, OpenCode, Qwen Code, Ollama and llm.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}

private struct ModelField: View {
    let id: String
    let placeholder: String
    @State private var model = ""

    var body: some View {
        TextField("Model", text: $model, prompt: Text(placeholder.isEmpty ? "Default" : placeholder))
            .onAppear { model = Preferences.store.string(forKey: "ai.model.\(id)") ?? "" }
            .onChange(of: model) { _, value in Preferences.store.set(value, forKey: "ai.model.\(id)") }
    }
}
