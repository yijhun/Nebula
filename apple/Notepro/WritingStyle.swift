import Foundation

/// The user's own writing style, learned from their vault and handed to every
/// AI that writes for them (the chat panel's CLIs and ⌘K inline assist).
///
/// The guide lives in the vault, at `.notepro/ai/style.md`, so it travels with
/// the notes. It's plain Markdown the user can edit; a small frontmatter
/// records when and from how many notes it was generated.
enum WritingStyle {
    /// Settings toggle (default on).
    static var enabled: Bool { UserDefaults.standard.object(forKey: "aiUseMyStyle") as? Bool ?? true }

    static var activeVault: URL? {
        UserDefaults.standard.string(forKey: "lastVaultPath").map { URL(fileURLWithPath: $0) }
    }

    static func guideURL(vault: URL) -> URL {
        vault.appendingPathComponent(".notepro/ai/style.md")
    }

    /// The guide text for prompts (frontmatter stripped), or nil when there's
    /// none yet or the toggle is off.
    static func promptText(vault: URL? = activeVault) -> String? {
        guard enabled, let vault,
              let raw = try? String(contentsOf: guideURL(vault: vault), encoding: .utf8) else { return nil }
        let body = stripFrontmatter(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    /// The text to append to an AI's instructions so it writes like the user.
    static func instruction(vault: URL? = activeVault) -> String? {
        guard let guide = promptText(vault: vault) else { return nil }
        return """
        When you write or rewrite prose for the user, write it the way they write — follow their style guide below (it was learned from their own notes). It governs voice and phrasing only; correctness and the user's explicit instructions come first.

        <user_style_guide>
        \(guide)
        </user_style_guide>
        """
    }

    struct Info { var date: String; var notes: Int }

    static func info(vault: URL) -> Info? {
        guard let raw = try? String(contentsOf: guideURL(vault: vault), encoding: .utf8),
              raw.hasPrefix("---") else { return nil }
        func field(_ k: String) -> String? {
            raw.components(separatedBy: "\n").first { $0.hasPrefix("\(k):") }
                .map { String($0.dropFirst(k.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        return Info(date: field("generated") ?? "", notes: Int(field("notes") ?? "") ?? 0)
    }

    static func save(_ body: String, vault: URL, notes: Int?) throws {
        let url = guideURL(vault: vault)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var head = ""
        if let notes {
            let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                  formatOptions: [.withFullDate])
            head = "---\ngenerated: \(day)\nnotes: \(notes)\n---\n\n"
        } else if let old = info(vault: vault) {
            head = "---\ngenerated: \(old.date)\nnotes: \(old.notes)\n---\n\n"
        }
        try (head + body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }

    static func stripFrontmatter(_ s: String) -> String {
        guard s.hasPrefix("---"), let end = s.range(of: "\n---", range: s.index(s.startIndex, offsetBy: 3)..<s.endIndex)
        else { return s }
        return String(s[end.upperBound...])
    }

    // MARK: - Learning the style

    /// Prose sampled from across the vault: frontmatter, code, math, tables
    /// and embeds removed, so what remains is how the user actually writes.
    /// Spread over as many notes as possible rather than a few long ones.
    static func corpus(vault: URL, maxChars: Int = 24_000) -> (text: String, notes: Int) {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: vault, includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ("", 0) }
        var perNote: [[String]] = []
        for case let url as URL in en where url.pathExtension.lowercased() == "md" {
            if url.lastPathComponent == "CLAUDE.md" || url.lastPathComponent == "AGENTS.md" { continue }
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let paras = proseParagraphs(raw)
            if !paras.isEmpty { perNote.append(paras) }
        }
        // Round-robin: one paragraph from each note per pass.
        var out: [String] = []
        var used = 0, pass = 0, notesUsed = Set<Int>()
        while used < maxChars {
            var took = false
            for (i, paras) in perNote.enumerated() where pass < paras.count {
                let p = paras[pass]
                guard used + p.count <= maxChars else { continue }
                out.append(p); used += p.count; notesUsed.insert(i); took = true
            }
            if !took { break }
            pass += 1
        }
        return (out.joined(separator: "\n\n---\n\n"), notesUsed.count)
    }

    static func proseParagraphs(_ raw: String) -> [String] {
        var s = stripFrontmatter(raw)
        func strip(_ pattern: String, _ with: String = "") {
            s = s.replacingOccurrences(of: pattern, with: with, options: .regularExpression)
        }
        strip(#"(?s)```.*?```"#)                    // code / chart / tikz blocks
        strip(#"(?s)\$\$.*?\$\$"#, "[equation]")    // display math
        strip(#"\$[^$\n]+\$"#, "[math]")            // inline math
        strip(#"!\[\[[^\]]*\]\]"#)                  // embeds
        strip(#"\[\[([^\]|]*\|)?([^\]]*)\]\]"#, "$2") // wikilinks → their text
        strip(#"<[^>\n]+>"#)                        // html
        return s.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n").map(String.init)
                .filter { !$0.hasPrefix("|") && !$0.hasPrefix("#") && !$0.hasPrefix("![") }
            let p = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // Enough actual words: a CJK character counts as a word. The
            // [math] / [equation] stand-ins and citekeys aren't prose — a
            // derivation that's mostly symbols says little about style.
            let words = p.replacingOccurrences(of: #"\[(math|equation)\]|\[@[^\]]*\]"#, with: "",
                                               options: .regularExpression)
            let letters = words.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            return letters >= 60 ? p : nil
        }
    }

    /// Ask the user's AI account (the chat panel's CLI) to distill a style
    /// guide from the samples. Runs off the main thread; completes on main.
    static func generate(vault: URL, account: AIAccount,
                         completion: @escaping (Result<Int, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let (samples, notes) = corpus(vault: vault)
            guard !samples.isEmpty else {
                return DispatchQueue.main.async { completion(.failure(StyleError.noProse)) }
            }
            guard let exe = AIAccountStore.cliPath(account.provider) else {
                return DispatchQueue.main.async { completion(.failure(StyleError.noCLI)) }
            }
            let prompt = analysisPrompt(samples)
            let args = account.provider == .claude
                ? ["-p", "--output-format", "text", "--permission-mode", "plan", prompt]
                : ["exec", "--skip-git-repo-check", "-s", "read-only", prompt]
            let out = runCLI(exe, args, env: AIAccountStore.environment(for: account), timeout: 300)
            let guide = cleanGuide(out)
            DispatchQueue.main.async {
                guard guide.count > 80 else { return completion(.failure(StyleError.badOutput(String(out.suffix(300))))) }
                do { try save(guide, vault: vault, notes: notes); completion(.success(notes)) }
                catch { completion(.failure(error)) }
            }
        }
    }

    /// Run a CLI to completion and return its stdout. stdin is closed (Codex
    /// otherwise waits for more prompt on it forever) and stderr discarded
    /// (an undrained pipe deadlocks once it fills). Killed after `timeout`.
    static func runCLI(_ exe: String, _ args: [String], env: [String: String],
                       timeout: TimeInterval) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        let out = Pipe(); p.standardOutput = out
        let tail = PipeTail()
        out.fileHandleForReading.readabilityHandler = { tail.append($0.availableData) }
        do { try p.run() } catch { return "" }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        out.fileHandleForReading.readabilityHandler = nil
        if let rest = try? out.fileHandleForReading.readToEnd() { tail.append(rest) }
        return tail.string()
    }

    static func analysisPrompt(_ samples: String) -> String {
        """
        以下是一位天文研究者在自己的筆記與論文草稿中寫的段落樣本（公式、程式碼、表格已移除，以 [math] / [equation] 代替）。請歸納這位作者的寫作風格，寫成一份「文風指南」，讓 AI 之後替作者寫或改寫文字時能模仿。

        要求：
        - 只根據樣本歸納，不要加入一般性的寫作建議。
        - 樣本裡的錯字與拼字錯誤（例如 wavelenght、cental）是打字失誤，不是風格：不要寫進指南，AI 寫作時要拼對。
        - 分成「英文學術寫作」與「中文筆記」兩部分；樣本裡沒有的語言就略過那部分。
        - 涵蓋：語氣與人稱、句子長短與結構、常用連接詞與句型、段落組織、術語與符號習慣（單位、數學怎麼寫、引用方式）、格式偏好（條列、標題）、作者會避免的寫法。
        - 每一點附一個從樣本摘出的短例句（中文 20 字內、英文 20 words 內）。
        - 中文部分用中文寫，英文部分用英文寫；全文精簡，不超過約 450 字。
        - 只輸出指南本身（Markdown，從標題開始），不要前言或結語。

        樣本：
        ---
        \(samples)
        """
    }

    /// Drop anything a CLI printed around the guide (status lines, fences).
    static func cleanGuide(_ out: String) -> String {
        var s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: #"^```[a-z]*\n|\n```$"#, with: "", options: .regularExpression)
        }
        if let h = s.range(of: "#") { s = String(s[h.lowerBound...]) }   // start at the first heading
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum StyleError: LocalizedError {
        case noProse, noCLI, badOutput(String)
        var errorDescription: String? {
            switch self {
            case .noProse: return LZ("vault 裡找不到足夠的文字可以分析")
            case .noCLI: return LZ("找不到 AI 帳號的 CLI（請先在聊天面板登入 Claude 或 ChatGPT）")
            case .badOutput(let tail): return LZ("AI 沒有回傳文風指南") + "：\(tail)"
            }
        }
    }
}
