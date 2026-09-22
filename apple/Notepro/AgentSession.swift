import Foundation

/// A live conversation with a subscription CLI, driven through its structured
/// streaming interface (the same one editor extensions use):
///
///   claude -p --input-format stream-json --output-format stream-json …
///
/// One long-lived process holds the whole conversation; each user turn is one
/// JSON line on stdin, and every event (text deltas, tool calls, results) comes
/// back as one JSON line on stdout — forwarded untouched to the chat UI, which
/// does the rendering. Swift only owns the process.
final class AgentSession {
    enum Mode: String { case readOnly = "plan", edit = "acceptEdits" }

    let account: AIAccount
    let cwd: URL
    let mode: Mode
    /// Continue an earlier conversation (e.g. after Stop or a mode change).
    let resumeID: String?

    var onLine: ((String) -> Void)?
    var onExit: ((Int32, String) -> Void)?
    private(set) var sessionID: String?

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private let errTail = PipeTail()

    init(account: AIAccount, cwd: URL, mode: Mode, resumeID: String? = nil) {
        self.account = account; self.cwd = cwd; self.mode = mode; self.resumeID = resumeID
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Start the CLI. Returns a user-facing error, or nil.
    func start() -> String? {
        guard account.provider == .claude else {
            return "ChatGPT（Codex）對話尚未接上 — 需先安裝 Codex CLI"
        }
        guard let exe = AIAccountStore.claudePath else {
            return "找不到 claude CLI（npm install -g @anthropic-ai/claude-code）"
        }
        var args = ["-p",
                    "--input-format", "stream-json",
                    "--output-format", "stream-json",
                    "--verbose",
                    "--include-partial-messages",
                    "--permission-mode", mode.rawValue,
                    "--append-system-prompt",
                    "You are running inside Nebula, a Markdown/LaTeX research-notes app; the working directory is the user's notes vault. Reply in the user's language. Write math as $…$ / $$…$$."]
        if let r = resumeID { args += ["--resume", r] }

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
        return nil
    }

    /// Send one user turn.
    func send(_ text: String) {
        let msg: [String: Any] = ["type": "user",
                                  "message": ["role": "user", "content": text]]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let stdin else { return }
        stdin.write(data)
        stdin.write(Data("\n".utf8))
    }

    /// Stop generating. The CLI exits; reopening with `--resume sessionID`
    /// keeps the conversation.
    func stop() {
        guard let p = process, p.isRunning else { return }
        p.interrupt()
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { if p.isRunning { p.terminate() } }
    }

    // MARK: - line splitting

    private func consume(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let line = String(data: lineData, encoding: .utf8),
                  !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if sessionID == nil, line.contains("\"session_id\""),
               let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
               let sid = obj["session_id"] as? String {
                sessionID = sid
            }
            DispatchQueue.main.async { [weak self] in self?.onLine?(line) }
        }
    }
}
