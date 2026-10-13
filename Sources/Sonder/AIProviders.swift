import Foundation

/// An AI command-line tool installed on this Mac, run headless with a prompt.
/// The app never talks to an AI service itself: it uses the tools (and accounts) the user already has.
struct AIProvider: Identifiable {
    enum Input {
        /// The prompt is written to the tool's standard input.
        case stdin
        /// The prompt is the last command-line argument.
        case argument
    }

    let id: String
    let name: String
    /// Executable names, in order of preference.
    let executables: [String]
    let input: Input
    /// Whether a model name is required (Ollama has no default).
    var requiresModel = false
    let placeholderModel: String
    /// Arguments before the prompt; `output` is a file the tool may write its final answer to.
    let arguments: (_ model: String?, _ output: URL) -> [String]
    /// Read the answer from `output` instead of standard output.
    var answerInFile = false

    static let all: [AIProvider] = [
        AIProvider(id: "claude", name: "Claude", executables: ["claude"], input: .stdin, placeholderModel: "sonnet",
                   arguments: { model, _ in
                       // Print mode, no tools: it answers from the prompt alone and cannot touch files.
                       ["-p", "--output-format", "text", "--tools", "", "--no-session-persistence"]
                           + (model.map { ["--model", $0] } ?? [])
                   }),
        AIProvider(id: "codex", name: "Codex", executables: ["codex"], input: .stdin, placeholderModel: "gpt-5",
                   arguments: { model, output in
                       ["exec", "--skip-git-repo-check", "--ephemeral", "--sandbox", "read-only", "--color", "never",
                        "--output-last-message", output.path]
                           + (model.map { ["--model", $0] } ?? [])
                   }, answerInFile: true),
        AIProvider(id: "cursor", name: "Cursor", executables: ["cursor-agent"], input: .argument, placeholderModel: "auto",
                   arguments: { model, _ in
                       // "auto" works on every Cursor plan; named models need a paid one.
                       ["-p", "--output-format", "text", "--mode", "ask", "--trust", "--model", model ?? "auto"]
                   }),
        AIProvider(id: "gemini", name: "Gemini", executables: ["gemini"], input: .argument, placeholderModel: "gemini-2.5-pro",
                   arguments: { model, _ in (model.map { ["--model", $0] } ?? []) + ["--prompt"] }),
        AIProvider(id: "grok", name: "Grok", executables: ["grok"], input: .argument, placeholderModel: "grok-4",
                   arguments: { model, _ in (model.map { ["--model", $0] } ?? []) + ["--prompt"] }),
        AIProvider(id: "copilot", name: "GitHub Copilot", executables: ["copilot"], input: .argument, placeholderModel: "",
                   arguments: { model, _ in (model.map { ["--model", $0] } ?? []) + ["-p"] }),
        AIProvider(id: "opencode", name: "OpenCode", executables: ["opencode"], input: .argument, placeholderModel: "provider/model",
                   arguments: { model, _ in ["run"] + (model.map { ["--model", $0] } ?? []) }),
        AIProvider(id: "qwen", name: "Qwen Code", executables: ["qwen"], input: .argument, placeholderModel: "",
                   arguments: { model, _ in (model.map { ["--model", $0] } ?? []) + ["-p"] }),
        AIProvider(id: "ollama", name: "Ollama", executables: ["ollama"], input: .stdin, requiresModel: true,
                   placeholderModel: "llama3.2",
                   arguments: { model, _ in ["run", model ?? "", "--nowordwrap"] }),
        AIProvider(id: "llm", name: "llm", executables: ["llm"], input: .stdin, placeholderModel: "",
                   arguments: { model, _ in model.map { ["--model", $0] } ?? [] }),
    ]
}

/// Finds which AI tools are installed. GUI apps don't inherit the shell's PATH,
/// so the login shell is asked for it once, with common install folders as a fallback.
final class AIToolbox: ObservableObject {
    static let shared = AIToolbox()

    struct Installed: Identifiable {
        let provider: AIProvider
        let executable: URL
        var id: String { provider.id }
    }

    @Published private(set) var installed: [Installed] = []
    @Published private(set) var isScanning = false
    /// Ollama's downloaded models, for the model menu.
    @Published private(set) var ollamaModels: [String] = []
    private(set) var searchPath: [String] = []

    private init() {
        rescan()
    }

    func rescan() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let path = Self.loginShellPath()
            let found = AIProvider.all.compactMap { provider -> Installed? in
                for name in provider.executables {
                    if let url = Self.find(name, in: path) { return Installed(provider: provider, executable: url) }
                }
                return nil
            }
            let ollama = found.first { $0.id == "ollama" }.map { Self.ollamaModels($0.executable, path: path) } ?? []
            DispatchQueue.main.async {
                self.searchPath = path
                self.installed = found
                self.ollamaModels = ollama
                self.isScanning = false
            }
        }
    }

    func installed(_ id: String) -> Installed? {
        installed.first { $0.id == id }
    }

    /// Any command-line tool on the user's PATH (fzf, for Open Quickly).
    func executable(named name: String) -> URL? {
        Self.find(name, in: searchPath.isEmpty ? Self.fallbackPath : searchPath)
    }

    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Before the login-shell lookup finishes, fall back to the usual install folders.
        let path = searchPath.isEmpty ? Self.fallbackPath + (env["PATH"] ?? "").split(separator: ":").map(String.init) : searchPath
        env["PATH"] = path.joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["CI"] = "1"
        return env
    }

    private static func find(_ name: String, in path: [String]) -> URL? {
        for directory in path {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url.resolvingSymlinksInPath() }
        }
        return nil
    }

    private static let fallbackPath: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "\(home)/.claude/local", "\(home)/.npm-global/bin", "\(home)/.bun/bin",
                "\(home)/.cargo/bin", "\(home)/.volta/bin", "\(home)/go/bin", "\(home)/.opencode/bin",
                "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    }()

    /// The PATH an interactive login shell would have, so tools installed via nvm, Homebrew or bun are found.
    static func loginShellPath() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '__PATH__%s__END__' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        var path: [String] = []
        if (try? process.run()) != nil {
            // A slow or interactive shell profile must not hang the app.
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { process.terminate() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
            if let start = text.range(of: "__PATH__"), let end = text.range(of: "__END__", range: start.upperBound..<text.endIndex) {
                path = text[start.upperBound..<end.lowerBound].split(separator: ":").map(String.init)
            }
        }
        var seen = Set<String>()
        return (path + fallbackPath).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func ollamaModels(_ executable: URL, path: [String]) -> [String] {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["list"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst()
            .compactMap { $0.split(separator: " ").first.map(String.init) }
    }
}

/// One headless run of an AI tool: streams its answer, can be cancelled, never hangs the app.
final class AIRun {
    enum Event {
        case output(String)
        case finished(String)
        case failed(String)
    }

    private let process = Process()
    private let workDirectory: URL
    private let outputFile: URL
    private let installed: AIToolbox.Installed
    private var stdout = Data()
    private var stderr = Data()
    private var cancelled = false
    private let lock = NSLock()
    private var timeout: DispatchWorkItem?
    private let onEvent: (Event) -> Void

    /// - Parameter onEvent: called on the main queue.
    init(_ installed: AIToolbox.Installed, prompt: String, model: String?, onEvent: @escaping (Event) -> Void) {
        self.installed = installed
        self.onEvent = onEvent
        // An empty folder of its own: the tool sees no files but the prompt.
        workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ai-\(UUID().uuidString)", isDirectory: true)
        outputFile = workDirectory.appendingPathComponent("answer.md")
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)

        let provider = installed.provider
        let model = model?.trimmingCharacters(in: .whitespaces).isEmpty == false ? model : nil
        var arguments = provider.arguments(model, outputFile)
        if provider.input == .argument { arguments.append(prompt) }
        process.executableURL = installed.executable
        process.arguments = arguments
        process.currentDirectoryURL = workDirectory
        process.environment = AIToolbox.shared.environment

        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = provider.input == .stdin ? input : FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            self.stdout.append(data)
            let text = String(decoding: self.stdout, as: UTF8.self)
            self.lock.unlock()
            guard !provider.answerInFile else { return }
            DispatchQueue.main.async { self.onEvent(.output(Self.clean(text))) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.lock()
            // Keep only the tail; some tools log a lot.
            self.stderr.append(data)
            if self.stderr.count > 64_000 { self.stderr = self.stderr.suffix(32_000) }
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            // Drain whatever arrived after the last callback, but don't wait on a pipe that a
            // leftover child process still holds open.
            var rest = Data()
            let drained = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                rest = output.fileHandleForReading.readDataToEndOfFile()
                drained.signal()
            }
            let didDrain = drained.wait(timeout: .now() + 1) == .success
            guard let self else { return }
            self.lock.lock()
            if didDrain { self.stdout.append(rest) }
            let out = Self.clean(String(decoding: self.stdout, as: UTF8.self))
            let err = Self.clean(String(decoding: self.stderr, as: UTF8.self))
            let cancelled = self.cancelled
            self.lock.unlock()
            let fileAnswer = provider.answerInFile ? (try? String(contentsOf: self.outputFile, encoding: .utf8)) : nil
            let answer = (fileAnswer ?? out).trimmingCharacters(in: .whitespacesAndNewlines)
            try? FileManager.default.removeItem(at: self.workDirectory)
            DispatchQueue.main.async {
                self.timeout?.cancel()
                if cancelled {
                    self.onEvent(.failed("Stopped."))
                } else if process.terminationStatus == 0, !answer.isEmpty {
                    self.onEvent(.finished(answer))
                } else {
                    let detail = err.split(separator: "\n").suffix(6).joined(separator: "\n")
                    let message = detail.isEmpty ? (answer.isEmpty ? "\(provider.name) returned nothing." : answer) : detail
                    if process.terminationReason == .uncaughtSignal {
                        self.onEvent(.failed("\(provider.name) was stopped by the system (signal \(process.terminationStatus)). "
                            + "Try running `\(self.installed.executable.lastPathComponent)` in Terminal; it may need reinstalling or signing in."))
                    } else {
                        self.onEvent(.failed("\(provider.name) exited with code \(process.terminationStatus).\n\(message)"))
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async { onEvent(.failed("Couldn't start \(installed.executable.path): \(error.localizedDescription)")) }
            return
        }
        if provider.input == .stdin {
            // Write on a background queue: a large prompt would otherwise block on a full pipe.
            DispatchQueue.global(qos: .userInitiated).async {
                input.fileHandleForWriting.write(Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
            }
        }
        let timeout = DispatchWorkItem { [weak self] in self?.cancel() }
        self.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: timeout)
    }

    var isRunning: Bool { process.isRunning }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]|\u{1B}\\][^\u{07}]*\u{07}")

    static func clean(_ text: String) -> String {
        let ns = text as NSString
        return ansi.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
    }
}
