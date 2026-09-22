import Foundation
import AppKit

/// One signed-in subscription the chat panel can drive. Each account is an
/// isolated CLI config directory — Claude Code reads `CLAUDE_CONFIG_DIR`, Codex
/// reads `CODEX_HOME` — so switching accounts is just spawning the CLI with a
/// different environment. No API keys: the CLIs sign in with the subscription.
struct AIAccount: Codable, Identifiable, Hashable {
    enum Provider: String, Codable { case claude, codex }

    var id = UUID()
    var provider: Provider
    var label: String
    /// nil = the CLI's own default location (the account you already use in
    /// the terminal). Extra accounts get their own folder.
    var configDir: String?
    var email: String?
    var plan: String?
    var loggedIn = false

    var providerName: String { provider == .claude ? "Claude" : "ChatGPT" }
    /// "個人 · you@x.com · max"
    var subtitle: String {
        [email, plan].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }
}

@MainActor
final class AIAccountStore: ObservableObject {
    static let shared = AIAccountStore()

    @Published private(set) var accounts: [AIAccount] = []
    @Published var activeID: UUID? { didSet { save() } }

    var active: AIAccount? { accounts.first { $0.id == activeID } ?? accounts.first }

    private let key = "aiAccounts.v1"
    private let activeKey = "aiAccounts.active"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([AIAccount].self, from: data), !list.isEmpty {
            accounts = list
        } else {
            // Seed with the CLI's default Claude login — usually already signed in.
            accounts = [AIAccount(provider: .claude, label: "Claude")]
        }
        if let s = UserDefaults.standard.string(forKey: activeKey), let id = UUID(uuidString: s),
           accounts.contains(where: { $0.id == id }) {
            activeID = id
        } else {
            activeID = accounts.first?.id
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(data, forKey: key)
        }
        UserDefaults.standard.set(activeID?.uuidString, forKey: activeKey)
    }

    // MARK: - CLI locations / environment

    nonisolated static var claudePath: String? { ClaudeCodeLauncher.claudePath }
    nonisolated static var codexPath: String? {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
         "\(NSHomeDirectory())/.npm-global/bin/codex", "\(NSHomeDirectory())/.local/bin/codex"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    nonisolated static func cliPath(_ p: AIAccount.Provider) -> String? { p == .claude ? claudePath : codexPath }

    /// Process environment for an account: the app's env, a PATH that finds
    /// Homebrew tools (Claude's Bash/Grep tools need them), and the account's
    /// config-dir override.
    nonisolated static func environment(for acct: AIAccount) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let cur = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (extra + cur.filter { !extra.contains($0) }).joined(separator: ":")
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        if let dir = acct.configDir {
            env[acct.provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"] = dir
        }
        return env
    }

    // MARK: - Status

    /// Ask the CLI who is signed in for this account (`claude auth status`
    /// prints JSON: loggedIn / email / subscriptionType).
    func refresh(_ id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let acct = accounts[i]
        guard acct.provider == .claude, let exe = Self.claudePath else {
            // Codex status is read from its auth file once Codex is installed.
            if acct.provider == .codex { refreshCodex(id) }
            return
        }
        let env = Self.environment(for: acct)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let out = Self.run(exe, ["auth", "status"], env: env)
            var loggedIn = false, email: String?, plan: String?
            if let data = out.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                loggedIn = obj["loggedIn"] as? Bool ?? false
                email = obj["email"] as? String
                plan = obj["subscriptionType"] as? String
            }
            DispatchQueue.main.async {
                guard let self, let j = self.accounts.firstIndex(where: { $0.id == id }) else { return }
                self.accounts[j].loggedIn = loggedIn
                self.accounts[j].email = email ?? self.accounts[j].email
                self.accounts[j].plan = plan ?? self.accounts[j].plan
                self.save()
            }
        }
    }

    private func refreshCodex(_ id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let home = accounts[i].configDir ?? "\(NSHomeDirectory())/.codex"
        let signedIn = FileManager.default.fileExists(atPath: "\(home)/auth.json")
        accounts[i].loggedIn = signedIn && Self.codexPath != nil
        save()
    }

    func refreshAll() { accounts.map(\.id).forEach(refresh) }

    /// If a CLI is installed and already signed in at its default location,
    /// offer that login as an account — no need to sign in again inside Nebula.
    func seedInstalledLogins() {
        if Self.codexPath != nil,
           FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/.codex/auth.json"),
           !accounts.contains(where: { $0.provider == .codex && $0.configDir == nil }) {
            accounts.append(AIAccount(provider: .codex, label: "ChatGPT", loggedIn: true))
            save()
        }
        if Self.claudePath != nil,
           !accounts.contains(where: { $0.provider == .claude && $0.configDir == nil }) {
            accounts.insert(AIAccount(provider: .claude, label: "Claude"), at: 0)
            save()
        }
    }

    // MARK: - Add / login / remove

    /// Create a new isolated account and start its sign-in.
    @discardableResult
    func add(provider: AIAccount.Provider, label: String) -> AIAccount {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nebula/accounts", isDirectory: true)
        let acct0 = AIAccount(provider: provider,
                              label: label.isEmpty ? (provider == .claude ? "Claude" : "ChatGPT") : label)
        let dir = base.appendingPathComponent(acct0.id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var acct = acct0
        acct.configDir = dir.path
        accounts.append(acct)
        save()
        login(acct.id)
        return acct
    }

    /// Sign in via the CLI's own browser flow, in a Terminal window (OAuth
    /// needs a real TTY). Hit refresh in the panel afterwards.
    func login(_ id: UUID) {
        guard let acct = accounts.first(where: { $0.id == id }),
              let exe = Self.cliPath(acct.provider) else { return }
        var lines = ["#!/bin/zsh"]
        if let dir = acct.configDir {
            let v = acct.provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
            lines.append("export \(v)=\(Self.q(dir))")
        }
        let cmd = acct.provider == .claude ? "\(Self.q(exe)) auth login" : "\(Self.q(exe)) login"
        // The label is user-typed — quote it, never splice it into the script raw.
        lines.append("echo " + Self.q("▸ 登入 \(acct.providerName)：\(acct.label)"))
        lines.append(cmd)
        lines.append("echo; echo '完成後回到 Nebula 按「重新整理」。這個視窗可以關掉。'")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("np-login", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("login-\(acct.id.uuidString.prefix(8)).command")
        try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        NSWorkspace.shared.open(file)
    }

    /// Forget an account. Its private config folder (holding that login) is
    /// deleted too; the default account's folder is never touched.
    func remove(_ id: UUID) {
        guard let acct = accounts.first(where: { $0.id == id }) else { return }
        if let dir = acct.configDir,
           dir.contains("/Nebula/accounts/") {       // only folders we created
            try? FileManager.default.removeItem(atPath: dir)
        }
        accounts.removeAll { $0.id == id }
        if accounts.isEmpty { accounts = [AIAccount(provider: .claude, label: "Claude")] }
        if activeID == id { activeID = accounts.first?.id }
        save()
    }

    func rename(_ id: UUID, to label: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].label = label; save()
    }

    // MARK: - helpers

    nonisolated static func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Run a short CLI command and return its stdout.
    nonisolated static func run(_ exe: String, _ args: [String], env: [String: String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
