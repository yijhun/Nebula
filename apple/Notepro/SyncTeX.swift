import Foundation

/// SyncTeX forward (source line → PDF page + coordinates) and reverse (PDF
/// click → source line). Wraps the MacTeX/TeX Live `synctex` CLI; if it's not
/// installed, lookups return nil and the editor falls back to manual scrolling.
enum SyncTeX {
    /// (page is 1-indexed, x/y in PDF points from page top-left, width/height
    /// of the box enclosing the located source line.)
    struct ForwardResult {
        let page: Int
        let x: CGFloat
        let y: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    /// (1-indexed source line + the absolute source file path.)
    struct ReverseResult {
        let line: Int
        let sourceFile: String
    }

    /// Path to the `synctex` CLI binary, or nil if MacTeX/TeX Live isn't
    /// installed. Tested in priority order — TeX Live versioned dir first,
    /// then unversioned symlinks.
    static var binary: String? {
        let fm = FileManager.default
        // /usr/local/texlive/<year>/bin/<arch>/synctex
        let texlive = "/usr/local/texlive"
        if let years = try? fm.contentsOfDirectory(atPath: texlive)
            .filter({ Int($0) != nil })
            .sorted(by: >),
           let year = years.first {
            let dir = "\(texlive)/\(year)/bin"
            if let arches = try? fm.contentsOfDirectory(atPath: dir) {
                for arch in arches {
                    let candidate = "\(dir)/\(arch)/synctex"
                    if fm.isExecutableFile(atPath: candidate) { return candidate }
                }
            }
        }
        for candidate in ["/usr/local/bin/synctex", "/opt/homebrew/bin/synctex", "/usr/bin/synctex"] {
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Source line → PDF position. Used to scroll the PDF preview when the
    /// editor's cursor moves to a new line. PDF + source must share the same
    /// directory so the .synctex.gz can be located by the CLI.
    static func forward(line: Int, source: URL, pdf: URL) -> ForwardResult? {
        guard let synctex = binary else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: synctex)
        p.arguments = ["view", "-i", "\(line):1:\(source.path)", "-o", pdf.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        guard let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else { return nil }
        // Parse the first SyncTeX result block (multiple results are sorted by
        // proximity; the first is closest).
        var page = 0; var x: Double = 0; var y: Double = 0; var w: Double = 0; var h: Double = 0
        var found = false
        for raw in out.split(separator: "\n") {
            let l = String(raw)
            if l.hasPrefix("Page:"),  let v = Int(l.dropFirst(5).trimmingCharacters(in: .whitespaces)) { page = v; found = true }
            else if l.hasPrefix("x:"), let v = Double(l.dropFirst(2).trimmingCharacters(in: .whitespaces)) { x = v }
            else if l.hasPrefix("y:"), let v = Double(l.dropFirst(2).trimmingCharacters(in: .whitespaces)) { y = v }
            else if l.hasPrefix("W:"), let v = Double(l.dropFirst(2).trimmingCharacters(in: .whitespaces)) { w = v }
            else if l.hasPrefix("H:"), let v = Double(l.dropFirst(2).trimmingCharacters(in: .whitespaces)) { h = v }
            else if l.hasPrefix("SyncTeX result end") && found { break }
        }
        guard found, page > 0 else { return nil }
        return ForwardResult(page: page, x: CGFloat(x), y: CGFloat(y),
                             width: CGFloat(w), height: CGFloat(h))
    }

    /// PDF click → source line + file. Coordinates are in PDF points from the
    /// page's top-left corner (PDFKit's pageBounds coordinate system flipped).
    static func reverse(pdf: URL, page: Int, x: CGFloat, y: CGFloat) -> ReverseResult? {
        guard let synctex = binary else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: synctex)
        p.arguments = ["edit", "-o", "\(page):\(x):\(y):\(pdf.path)"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        guard let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        else { return nil }
        var line = 0; var src = ""
        for raw in out.split(separator: "\n") {
            let l = String(raw)
            if l.hasPrefix("Input:") { src = String(l.dropFirst(6)) }
            else if l.hasPrefix("Line:"), let v = Int(l.dropFirst(5).trimmingCharacters(in: .whitespaces)) { line = v }
        }
        guard line > 0, !src.isEmpty else { return nil }
        return ReverseResult(line: line, sourceFile: src)
    }
}
