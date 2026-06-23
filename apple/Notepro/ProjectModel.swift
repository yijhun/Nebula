import SwiftUI
import AppKit

/// On-disk settings for a project, stored as `project.json` in the project folder.
struct ProjectMeta: Codable, Hashable {
    var title: String
    var type: String = "paper"
    var template: String = "academic"
    /// Ordered list of chapter filenames that compile into the paper.
    var paper: [String] = []
    /// "zotero" (auto-export cited keys) or "manual" (use the folder's references.bib).
    var bib: String = "zotero"
    var created: String?
}

/// A Notepro project: a folder of Markdown notes, some of which (in `meta.paper`,
/// in order) compile into one LaTeX paper under `build/`. The plain `.md` files
/// stay the source of truth; `build/` holds regenerated artifacts.
struct Project: Identifiable, Hashable {
    let folder: URL
    var meta: ProjectMeta
    var id: URL { folder }
    var name: String { folder.lastPathComponent }

    var buildDir: URL { folder.appendingPathComponent("build", isDirectory: true) }
    var assetsDir: URL { folder.appendingPathComponent("assets", isDirectory: true) }
    var paperTex: URL { buildDir.appendingPathComponent("paper.tex") }
    var paperPDF: URL { buildDir.appendingPathComponent("paper.pdf") }
    var flatTex: URL { buildDir.appendingPathComponent("paper-flat.tex") }
}

/// Reads/writes projects on disk and tracks them for the current vault.
/// App-level (shared across windows), like `VaultModel` / `IndexService`.
final class ProjectsModel: ObservableObject {
    @Published var projects: [Project] = []

    static let metaName = "project.json"

    // MARK: - Detection / loading

    static func metaURL(_ folder: URL) -> URL { folder.appendingPathComponent(metaName) }
    static func isProject(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: metaURL(folder).path)
    }

    static func load(_ folder: URL) -> Project? {
        guard let data = try? Data(contentsOf: metaURL(folder)),
              let meta = try? JSONDecoder().decode(ProjectMeta.self, from: data) else { return nil }
        return Project(folder: folder, meta: meta)
    }

    @discardableResult
    static func save(_ project: Project) -> Bool {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(project.meta) else { return false }
        try? FileManager.default.createDirectory(at: project.folder, withIntermediateDirectories: true)
        return (try? data.write(to: metaURL(project.folder))) != nil
    }

    /// Rescan the vault for folders containing a `project.json`.
    func reload(vault root: URL?) {
        guard let root else { projects = []; return }
        var found: [Project] = []
        let fm = FileManager.default
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                  options: [.skipsHiddenFiles]) {
            for case let url as URL in en {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                   Self.isProject(url), let p = Self.load(url) {
                    found.append(p)
                    en.skipDescendants()   // don't recurse into a project's subfolders
                }
            }
        }
        projects = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Chapters

    /// All `.md` files directly in a folder.
    static func markdownFiles(in folder: URL) -> [URL] {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items.filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
    }

    /// Chapters that compile into the paper, in `meta.paper` order (existing only).
    static func paperChapters(_ project: Project) -> [URL] {
        project.meta.paper
            .map { project.folder.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Project `.md` files NOT in the paper (free notes), sorted by name.
    static func otherNotes(_ project: Project) -> [URL] {
        let inPaper = Set(project.meta.paper)
        return markdownFiles(in: project.folder)
            .filter { !inPaper.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    // MARK: - Mutators (persist project.json)

    func addToPaper(_ project: Project, file: String) { update(project) { if !$0.paper.contains(file) { $0.paper.append(file) } } }
    func removeFromPaper(_ project: Project, file: String) { update(project) { $0.paper.removeAll { $0 == file } } }
    func reorderPaper(_ project: Project, from src: IndexSet, to dst: Int) { update(project) { $0.paper.move(fromOffsets: src, toOffset: dst) } }
    func setTemplate(_ project: Project, _ template: String) { update(project) { $0.template = template } }

    private func update(_ project: Project, _ mutate: (inout ProjectMeta) -> Void) {
        var p = project
        mutate(&p.meta)
        Self.save(p)
        if let i = projects.firstIndex(where: { $0.folder == p.folder }) { projects[i] = p }
        else { projects.append(p) }
    }

    // MARK: - Create / mark / import

    private static func today() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date())
    }

    /// Turn an existing folder into a project: write `project.json` with all its
    /// `.md` (by name) as the initial paper chapters. Returns the project.
    @discardableResult
    func markAsProject(_ folder: URL, template: String) -> Project {
        let md = Self.markdownFiles(in: folder)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { $0.lastPathComponent }
        let meta = ProjectMeta(title: folder.lastPathComponent, type: "paper", template: template,
                               paper: md, bib: "zotero", created: Self.today())
        let p = Project(folder: folder, meta: meta)
        Self.save(p)
        if let i = projects.firstIndex(where: { $0.folder == folder }) { projects[i] = p } else { projects.append(p) }
        return p
    }

    /// Remove the project marking (delete project.json); keep all the .md.
    func unmark(_ folder: URL) {
        try? FileManager.default.removeItem(at: Self.metaURL(folder))
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("build"))
        projects.removeAll { $0.folder == folder }
    }

    /// Create a brand-new project folder under `parent` with starter chapters.
    @discardableResult
    func create(in parent: URL, name: String, template: String) -> Project? {
        let fm = FileManager.default
        var folder = parent.appendingPathComponent(name, isDirectory: true)
        var n = 1
        while fm.fileExists(atPath: folder.path) { n += 1; folder = parent.appendingPathComponent("\(name) \(n)", isDirectory: true) }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let starters = [
            ("01-intro.md", "# Introduction\n\n"),
            ("02-method.md", "# Method\n\n"),
            ("03-results.md", "# Results\n\n"),
        ]
        for (fn, body) in starters {
            try? body.write(to: folder.appendingPathComponent(fn), atomically: true, encoding: .utf8)
        }
        return markAsProject(folder, template: template)
    }

    /// Copy an existing `.md` into the project folder (unique name). Returns its URL.
    @discardableResult
    func importNote(_ src: URL, into project: Project, addToPaper: Bool) -> URL? {
        let fm = FileManager.default
        let base = src.deletingPathExtension().lastPathComponent
        var dest = project.folder.appendingPathComponent(src.lastPathComponent)
        var n = 1
        while fm.fileExists(atPath: dest.path) { n += 1; dest = project.folder.appendingPathComponent("\(base) \(n).md") }
        guard (try? fm.copyItem(at: src, to: dest)) != nil else { return nil }
        if addToPaper { self.addToPaper(project, file: dest.lastPathComponent) }
        return dest
    }
}
