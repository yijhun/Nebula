import SwiftUI
import SwiftTerm

/// A live Claude Code session embedded as a resizable side pane. The terminal
/// view (and its PTY process) is owned HERE, not by SwiftUI — hiding the pane
/// detaches the view but keeps the session alive, so toggling the pane doesn't
/// kill your conversation.
@MainActor
final class ClaudeTermController: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    static let shared = ClaudeTermController()

    @Published var exited = false
    /// Bumped on every (re)start so SwiftUI swaps in the fresh NSView.
    @Published var generation = 0
    private(set) var termView: LocalProcessTerminalView?

    /// The view for the pane — reuses the running session, or starts one.
    func view(for vault: URL?) -> LocalProcessTerminalView {
        if let v = termView, !exited { return v }
        return start(vault: vault)
    }

    /// Start (or restart) `claude` in the vault via a login shell, so the
    /// user's PATH/rc are honoured.
    @discardableResult
    func start(vault: URL?) -> LocalProcessTerminalView {
        termView?.removeFromSuperview()
        let v = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 480, height: 480))
        v.processDelegate = self
        termView = v
        exited = false
        generation += 1
        if let vault { ClaudeCodeLauncher.ensureClaudeMD(vault: vault) }
        let root = vault?.path ?? NSHomeDirectory()
        let claude = ClaudeCodeLauncher.claudePath ?? "claude"
        let cmd = "cd \(Self.q(root)) && exec \(Self.q(claude))"
        var env = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        env.append("LANG=en_US.UTF-8")
        v.startProcess(executable: "/bin/zsh", args: ["-lc", cmd], environment: env, execName: nil)
        return v
    }

    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: LocalProcessTerminalViewDelegate
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in self.exited = true }
    }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}

/// Bridges the controller-owned terminal NSView into SwiftUI.
private struct ClaudeTermRepresentable: NSViewRepresentable {
    let vault: URL?
    @ObservedObject var ctrl: ClaudeTermController

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        ctrl.view(for: vault)
    }
    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

/// The side pane: header (restart / open-external / close) + the terminal.
struct ClaudeTermPane: View {
    let vault: URL?
    let onClose: () -> Void
    @StateObject private var ctrl = ClaudeTermController.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal").foregroundStyle(.secondary)
                Text("Claude Code").font(.caption.weight(.semibold))
                if ctrl.exited {
                    Text(LZ("已結束")).font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Button {
                    _ = ctrl.start(vault: vault)
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help(LZ("重新啟動 Claude Code"))
                Button {
                    ClaudeCodeLauncher.open(vault: vault)
                } label: { Image(systemName: "rectangle.portrait.and.arrow.right") }
                    .buttonStyle(.borderless).help(LZ("改在外部終端機開啟"))
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).help(LZ("關閉側欄（工作階段保留）"))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            ClaudeTermRepresentable(vault: vault, ctrl: ctrl)
                .id(ctrl.generation)   // restart swaps in the fresh view
        }
    }
}
