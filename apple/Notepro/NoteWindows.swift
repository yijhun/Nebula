import SwiftUI
import AppKit
import UniformTypeIdentifiers



/// A pop-out LIVE preview window (right-side HTML preview detached). Read-only:
/// it opens the note in preview mode and live-updates as the source editor
/// broadcasts content (debounced) — drag it to another screen to watch the
/// rendered note while you type in the main window.
struct PreviewWindowView: View {
    let url: URL
    @EnvironmentObject var vault: VaultModel
    @StateObject private var editor = EditorModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "eye").font(.caption).foregroundStyle(.secondary)
                Text(editor.displayName).font(.callout.weight(.medium)).lineLimit(1)
                Text("即時預覽").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
            Divider()
            WebView().environmentObject(editor)
        }
        .onAppear {
            editor.isMirror = true
            EditorModel.mirrorCount += 1
            editor.vaultRoot = vault.rootURL
            editor.open(url)
            editor.viewMode = .preview
        }
        .onDisappear { EditorModel.mirrorCount = max(0, EditorModel.mirrorCount - 1) }
        .onReceive(NotificationCenter.default.publisher(for: .noteproMirrorContent)) { note in
            guard let u = note.userInfo?["url"] as? URL, u == url,
                  let text = note.userInfo?["text"] as? String else { return }
            let src = note.userInfo?["sourceID"] as? String
            // Lock onto the first source that sends content for this file, so a
            // second editor showing the same file can't hijack the mirror.
            if editor.mirrorSourceID == nil { editor.mirrorSourceID = src }
            guard editor.mirrorSourceID == src else { return }
            editor.applyMirrorContent(text)
        }
        .navigationTitle("\(editor.displayName) — 預覽")
    }
}
