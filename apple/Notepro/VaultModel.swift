import SwiftUI
import AppKit

/// A node in the vault file tree (folder or markdown file).
struct FileNode: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?
    var mtime: Date = .distantPast
    /// True when this folder is a project (has a project.json).
    var isProject: Bool = false
    /// 1-based order if this .md is a chapter of its parent project's paper.
    var paperIndex: Int?

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

/// The vault: a chosen root folder and its markdown file tree.
/// App-level (shared across all windows), like an Obsidian vault.
final class VaultModel: ObservableObject {
    @Published var rootURL: URL?
    @Published var tree: [FileNode] = []

    /// Pinned file paths (★ favorites), persisted.
    @Published var pinned: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "pinnedPaths") ?? [])
    /// Folder path → color name, persisted.
    @Published var folderColors: [String: String] = (UserDefaults.standard.dictionary(forKey: "folderColors") as? [String: String]) ?? [:]
    /// Sort mode for files: "name" | "date" | "type".
    @Published var sortMode: String = UserDefaults.standard.string(forKey: "sortMode") ?? "name" {
        didSet { UserDefaults.standard.set(sortMode, forKey: "sortMode"); refresh() }
    }

    /// Called after every refresh (e.g. to rebuild the search index).
    var onChanged: (() -> Void)?
    private lazy var watcher = FSWatcher { [weak self] in self?.refresh() }

    func isPinned(_ url: URL) -> Bool { pinned.contains(url.path) }
    func togglePin(_ url: URL) {
        if pinned.contains(url.path) { pinned.remove(url.path) } else { pinned.insert(url.path) }
        UserDefaults.standard.set(Array(pinned), forKey: "pinnedPaths")
    }
    func color(for url: URL) -> String? { folderColors[url.path] }
    func setColor(_ name: String?, for url: URL) {
        if let name { folderColors[url.path] = name } else { folderColors.removeValue(forKey: url.path) }
        UserDefaults.standard.set(folderColors, forKey: "folderColors")
    }

    /// Vaults registered in Obsidian's own config (so the user can open the very
    /// same folder Obsidian uses — edits then sync live via the file watcher).
    static func obsidianVaults() -> [URL] {
        let cfg = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: cfg),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = obj["vaults"] as? [String: Any] else { return [] }
        var out: [URL] = []
        for (_, v) in vaults {
            if let d = v as? [String: Any], let path = d["path"] as? String,
               FileManager.default.fileExists(atPath: path) {
                out.append(URL(fileURLWithPath: path))
            }
        }
        return out.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Hidden output folder (inside the vault, ignored by scan + Obsidian) where
    /// generated LaTeX / .bib / PDF go, so the note area stays clean.
    static let outputSubdir = ".notepro/latex"

    /// Output dir for a note's generated LaTeX (mirrors the note's relative path).
    static func latexOutputDir(root: URL?, for noteURL: URL) -> URL {
        guard let root else { return noteURL.deletingLastPathComponent() }
        let rootStd = root.standardizedFileURL
        var rel = noteURL.deletingLastPathComponent().standardizedFileURL.path
        if rel.hasPrefix(rootStd.path) { rel = String(rel.dropFirst(rootStd.path.count)) }
        rel = rel.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var out = rootStd.appendingPathComponent(outputSubdir)
        if !rel.isEmpty { out = out.appendingPathComponent(rel) }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return out
    }

    /// The .tex output URL for a Markdown note.
    static func texURL(root: URL?, for noteURL: URL) -> URL {
        latexOutputDir(root: root, for: noteURL)
            .appendingPathComponent(noteURL.deletingPathExtension().lastPathComponent + ".tex")
    }

    /// Map a generated .tex (in the output dir) back to its source .md in the vault.
    static func markdownURL(root: URL?, forTex texURL: URL) -> URL {
        let base = texURL.deletingPathExtension().lastPathComponent
        guard let root else { return texURL.deletingPathExtension().appendingPathExtension("md") }
        let outBase = root.standardizedFileURL.appendingPathComponent(outputSubdir).path
        let texPath = texURL.standardizedFileURL.path
        guard texPath.hasPrefix(outBase) else {
            return texURL.deletingPathExtension().appendingPathExtension("md")
        }
        var rel = String(texPath.dropFirst(outBase.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        rel = (rel as NSString).deletingLastPathComponent
        var dir = root.standardizedFileURL
        if !rel.isEmpty { dir = dir.appendingPathComponent(rel) }
        return dir.appendingPathComponent("\(base).md")
    }

    /// Copy a dropped file into the vault's `Assets/` folder (unique name) and
    /// return its filename (for inserting `![[name]]`). nil if no vault.
    func importAsset(_ src: URL) -> String? {
        guard let root = rootURL else { return nil }
        let fm = FileManager.default
        let dir = root.appendingPathComponent("Assets", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = src.deletingPathExtension().lastPathComponent
        let ext = src.pathExtension
        var dest = dir.appendingPathComponent(src.lastPathComponent)
        var n = 1
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base)-\(n).\(ext)"); n += 1
        }
        do { try fm.copyItem(at: src, to: dest); refresh(); return dest.lastPathComponent }
        catch { return nil }
    }

    func openVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選擇資料夾 Open"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setVault(url)
    }

    func setVault(_ url: URL) {
        rootURL = url
        UserDefaults.standard.set(url.path, forKey: "lastVaultPath")
        watcher.start(url)   // auto-refresh on external/internal file changes
        refresh()
    }

    /// Re-open the last vault (e.g. your Obsidian folder) on launch, if it still exists.
    func restoreLastVault() {
        guard rootURL == nil,
              let path = UserDefaults.standard.string(forKey: "lastVaultPath") else { return }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        setVault(URL(fileURLWithPath: path))
    }

    func refresh() {
        guard let root = rootURL else { tree = []; return }
        tree = Self.scan(root, sort: sortMode)
        onChanged?()
    }

    /// Move a file/folder into `folder`.
    @discardableResult
    func move(_ url: URL, toFolder folder: URL) -> URL? {
        guard url.deletingLastPathComponent() != folder else { return nil }
        let dest = folder.appendingPathComponent(url.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: dest.path) else { return nil }
        do {
            try FileManager.default.moveItem(at: url, to: dest)
            refresh()
            return dest
        } catch { return nil }
    }

    /// Recursively list markdown/tex files and the folders that contain them.
    private static func scan(_ dir: URL, sort: String) -> [FileNode] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Inside a project folder, hide the generated `build/` (paper.tex/pdf etc.)
        // and order/badge the chapter .md by the project's paper order.
        let paper: [String]? = paperOrder(dir)
        let dirIsProject = paper != nil

        var nodes: [FileNode] = []
        for url in items {
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            let isDir = vals?.isDirectory ?? false
            let mtime = vals?.contentModificationDate ?? .distantPast
            if isDir {
                if dirIsProject && url.lastPathComponent == "build" { continue }
                // Show all folders, including empty/new ones (so a freshly
                // created folder is visible and can receive files).
                let children = scan(url, sort: sort)
                nodes.append(FileNode(url: url, isDirectory: true, children: children,
                                      mtime: mtime, isProject: paperOrder(url) != nil))
            } else {
                let ext = url.pathExtension.lowercased()
                if ext == "md" || ext == "markdown" || ext == "tex" || ext == "pdf" {
                    let pIdx = paper?.firstIndex(of: url.lastPathComponent).map { $0 + 1 }
                    nodes.append(FileNode(url: url, isDirectory: false, children: nil,
                                          mtime: mtime, paperIndex: pIdx))
                }
            }
        }
        if dirIsProject { return sortProjectNodes(nodes) }
        return sortNodes(nodes, by: sort)
    }

    /// The `paper` order array from a folder's project.json (nil = not a project).
    static func paperOrder(_ folder: URL) -> [String]? {
        let url = folder.appendingPathComponent("project.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paper = obj["paper"] as? [String] else { return nil }
        return paper
    }

    /// In a project folder: folders first, then paper chapters in order, then the
    /// remaining files by name.
    private static func sortProjectNodes(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            switch (a.paperIndex, b.paperIndex) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Folders first, then files by the chosen key.
    private static func sortNodes(_ nodes: [FileNode], by sort: String) -> [FileNode] {
        nodes.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory && !b.isDirectory }
            switch sort {
            case "date": return a.mtime > b.mtime
            case "type":
                if a.url.pathExtension != b.url.pathExtension { return a.url.pathExtension < b.url.pathExtension }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            default: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }

    /// Open (creating if needed) today's daily note in a "Daily" subfolder.
    func todayNote() -> URL? {
        guard let root = rootURL else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let name = fmt.string(from: Date())
        let dir = root.appendingPathComponent("Daily", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).md")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "# \(name)\n\n".write(to: url, atomically: true, encoding: .utf8)
            refresh()
        }
        return url
    }

    /// Create a new file in the vault root (unique name) and return its URL.
    func newFile(baseName: String, ext: String, content: String) -> URL? {
        guard let root = rootURL else { return nil }
        let fm = FileManager.default
        var url = root.appendingPathComponent("\(baseName).\(ext)")
        var n = 1
        while fm.fileExists(atPath: url.path) {
            n += 1
            url = root.appendingPathComponent("\(baseName) \(n).\(ext)")
        }
        try? content.write(to: url, atomically: true, encoding: .utf8)
        refresh()
        return url
    }

    func newNote() -> URL? { newFile(baseName: "Untitled", ext: "md", content: "# 新文件\n\n") }

    // MARK: - File operations

    /// The directory a "new" item should go into, given the selected node.
    func targetDirectory(for node: FileNode?) -> URL? {
        guard let node else { return rootURL }
        return node.isDirectory ? node.url : node.url.deletingLastPathComponent()
    }

    /// Create a new markdown note inside `dir` (or a folder node / vault root).
    func newNote(in dir: URL?) -> URL? {
        guard let dir = dir ?? rootURL else { return nil }
        return write(baseName: "Untitled", ext: "md", content: "# 新文件\n\n", in: dir)
    }

    /// Create a new sub-folder; returns its URL.
    @discardableResult
    func createFolder(in parent: URL?, name: String = "新資料夾") -> URL? {
        guard let parent = parent ?? rootURL else { return nil }
        let fm = FileManager.default
        var url = parent.appendingPathComponent(name)
        var n = 1
        while fm.fileExists(atPath: url.path) { n += 1; url = parent.appendingPathComponent("\(name) \(n)") }
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        refresh()
        return url
    }

    /// Rename a file/folder in place; returns the new URL (nil on failure).
    @discardableResult
    func rename(_ node: FileNode, to newName: String) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let dest = node.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: node.url, to: dest)
            refresh()
            return dest
        } catch {
            return nil
        }
    }

    /// Move a file/folder to the Trash.
    func delete(_ node: FileNode) { delete(url: node.url) }
    func delete(url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        pinned.remove(url.path)
        refresh()
    }

    /// Duplicate a file; returns the copy's URL.
    @discardableResult
    func duplicate(_ node: FileNode) -> URL? {
        guard !node.isDirectory else { return nil }
        let dir = node.url.deletingLastPathComponent()
        let base = node.url.deletingPathExtension().lastPathComponent
        let ext = node.url.pathExtension
        let fm = FileManager.default
        var url = dir.appendingPathComponent("\(base) copy.\(ext)")
        var n = 1
        while fm.fileExists(atPath: url.path) { n += 1; url = dir.appendingPathComponent("\(base) copy \(n).\(ext)") }
        try? fm.copyItem(at: node.url, to: url)
        refresh()
        return url
    }

    func reveal(_ node: FileNode) {
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    /// Write a uniquely-named file in a specific directory.
    private func write(baseName: String, ext: String, content: String, in dir: URL) -> URL? {
        let fm = FileManager.default
        var url = dir.appendingPathComponent("\(baseName).\(ext)")
        var n = 1
        while fm.fileExists(atPath: url.path) { n += 1; url = dir.appendingPathComponent("\(baseName) \(n).\(ext)") }
        try? content.write(to: url, atomically: true, encoding: .utf8)
        refresh()
        return url
    }
}
