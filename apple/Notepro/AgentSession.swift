import Foundation

/// A live conversation with a subscription CLI, driven through its structured
/// streaming interface (the same one editor extensions use). Both providers
/// emit one JSON object per line, which is forwarded untouched to the chat UI;
/// Swift only owns the processes.
///
///   Claude Code — one long-lived process for the whole conversation:
///     claude -p --input-format stream-json --output-format stream-json …
///   Codex — one process per turn, threaded with `resume`:
///     codex exec --json …            (first turn)
///     codex exec resume <thread> …   (later turns)
final class AgentSession {
    enum Mode: String { case readOnly, edit }

    let account: AIAccount
    let cwd: URL
    let mode: Mode
    let model: String?          // nil = the CLI's default
    /// Continue an earlier conversation (after Stop, or a mode/model change).
    let resumeID: String?
    /// Folders outside `cwd` the CLI may read — attachments from Zotero's
    /// storage, Downloads, and so on.
    let extraDirs: [String]

    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    /// Claude: the -p session id. Codex: the thread id. Both resume with it.
    private(set) var sessionID: String?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private let errTail = PipeTail()

    init(account: AIAccount, cwd: URL, mode: Mode, model: String?,
         resumeID: String? = nil, extraDirs: [String] = []) {
        self.account = account; self.cwd = cwd; self.mode = mode
        self.model = model; self.resumeID = resumeID; self.extraDirs = extraDirs
        self.sessionID = account.provider == .codex ? resumeID : nil
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Claude keeps one process for the conversation; Codex starts one per turn.
    private var persistent: Bool { account.provider == .claude }

    /// Prepare the session. Returns a user-facing error, or nil.
    func start() -> String? {
        guard AIAccountStore.cliPath(account.provider) != nil else {
            return account.provider == .claude
                ? "找不到 claude CLI（npm install -g @anthropic-ai/claude-code）"
                : "找不到 codex CLI（npm install -g @openai/codex）"
        }
        return persistent ? spawn(claudeArgs()) : nil   // Codex spawns on send
    }

    /// Send one user turn.
    func send(_ text: String) {
        if persistent {
            if !isRunning, let err = spawn(claudeArgs()) {
                emitError(err); return
            }
            let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
            guard let data = try? JSONSerialization.data(withJSONObject: msg), let stdin else { return }
            stdin.write(data); stdin.write(Data("\n".utf8))
        } else {
            if isRunning { process?.terminate() }
            if let err = spawn(codexArgs(prompt: text)) { emitError(err) }
        }
    }

    /// Stop generating. Claude can be resumed from `sessionID`; Codex's next
    /// turn resumes the thread anyway.
    func stop() {
        guard let p = process, p.isRunning else { return }
        p.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { if p.isRunning { p.terminate() } }
    }

    // MARK: - argv

    private func claudeArgs() -> [String] {
        var a = ["-p",
                 "--input-format", "stream-json",
                 "--output-format", "stream-json",
                 "--verbose",
                 "--include-partial-messages",
                 "--permission-mode", mode == .readOnly ? "default" : "acceptEdits"]
        // Read-only is "default" mode with the editing tools removed, not
        // "plan": plan mode also blocks every MCP tool, so the AI couldn't
        // look anything up in Zotero. (Verified: in default mode a -p session
        // has no one to grant permission, so a writing Bash command is
        // refused too.)
        if mode == .readOnly { a += ["--disallowedTools", "Edit", "Write", "MultiEdit", "NotebookEdit"] }
        a += ["--append-system-prompt", systemNote]
        if let m = model, !m.isEmpty { a += ["--model", m] }
        for d in extraDirs { a += ["--add-dir", d] }
        if let r = resumeID { a += ["--resume", r] }
        a += NebulaMCP.claudeArgs()          // Zotero / ADS tools
        return a
    }

    private func codexArgs(prompt: String) -> [String] {
        var a = ["exec"]
        if let t = sessionID, !t.isEmpty { a += ["resume", t] }
        a += ["--json",
              "--skip-git-repo-check",              // a vault usually isn't a git repo
              "-s", mode == .readOnly ? "read-only" : "workspace-write",
              "-C", cwd.path]
        if let m = model, !m.isEmpty { a += ["-m", m] }
        for d in extraDirs { a += ["--add-dir", d] }
        a += NebulaMCP.codexArgs()           // Zotero / ADS tools
        a += ["\(systemNote)\n\n\(prompt)"]
        return a
    }

    private static let baseNote =
        "You are running inside Nebula, a Markdown/LaTeX research-notes app; the working directory is the user's notes vault. Reply in the user's language. Write math as $…$ / $$…$$."

    /// Base instructions + the Zotero/ADS tool rules + the user's own style
    /// guide (learned from this vault), each when enabled in Settings.
    private var systemNote: String {
        [Self.baseNote, NebulaMCP.instruction, WritingStyle.instruction(vault: cwd)]
            .compactMap { $0 }.joined(separator: "\n\n")
    }

    // MARK: - process

    private func spawn(_ args: [String]) -> String? {
        guard let exe = AIAccountStore.cliPath(account.provider) else { return "找不到 CLI" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = cwd
        p.environment = AIAccountStore.environment(for: account)
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            self?.consume(chunk)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.errTail.append(h.availableData)
        }
        p.terminationHandler = { [weak self] proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            let tail = self?.errTail.string() ?? ""
            DispatchQueue.main.async { self?.onExit?(proc.terminationStatus, String(tail.suffix(400))) }
        }
        do { try p.run() } catch { return "無法啟動：\(error.localizedDescription)" }
        process = p
        stdin = inPipe.fileHandleForWriting
        // Codex reads extra prompt text from stdin when it isn't a TTY and
        // blocks forever waiting for EOF — close it right away.
        if !persistent { try? inPipe.fileHandleForWriting.close() }
        return nil
    }

    private func emitError(_ text: String) {
        let obj: [String: Any] = ["type": "nebula", "event": "notice", "text": text]
        if let d = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: d, encoding: .utf8) {
            DispatchQueue.main.async { [weak self] in self?.onLine?(s) }
        }
    }

    // MARK: - line splitting

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if sessionID == nil,
               let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                // Claude: session_id on every event. Codex: thread.started.
                if let sid = obj["session_id"] as? String { sessionID = sid }
                else if obj["type"] as? String == "thread.started",
                        let tid = obj["thread_id"] as? String { sessionID = tid }
            }
            DispatchQueue.main.async { [weak self] in self?.onLine?(line) }
        }
    }
}
