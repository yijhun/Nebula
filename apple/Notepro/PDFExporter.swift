import Foundation

/// Compiles a LaTeX document to PDF by shelling out to Tectonic.
/// (Self-contained offline compilation via the Rust `pdf_compiler` XCFramework
/// is a later increment; for the macOS desktop app, the installed `tectonic`
/// binary is the simplest reliable path.)
enum PDFExporter {
    enum ExportError: LocalizedError {
        case tectonicNotFound
        case compileFailed(String)

        var errorDescription: String? {
            switch self {
            case .tectonicNotFound:
                return "找不到 tectonic（請先 `brew install tectonic`）"
            case .compileFailed(let log):
                return "tectonic 編譯失敗:\n" + log
            }
        }
    }

    static func export(
        tex: String,
        bib: String,
        name: String,
        base: URL? = nil,
        vault: URL? = nil,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runCompile(tex: tex, bib: bib, name: name, base: base, vault: vault)
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Live-preview compile: write `content` to a hidden temp .tex IN `dir`
    /// (so sibling references.bib / images / \input resolve) and compile it.
    /// Returns the produced hidden .pdf. The temp .tex is removed afterward.
    static func compilePreview(
        content: String,
        in dir: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<URL, Error>
            let texURL = dir.appendingPathComponent(".notepro-preview.tex")
            do {
                try content.write(to: texURL, atomically: true, encoding: .utf8)
                // Live preview: single pass + keep intermediates (.aux/.fmt persist
                // in `dir`), so each keystroke recompiles far faster. Cross-refs and
                // the bibliography may lag one pass — full quality is the export path.
                result = runTectonic(in: dir, texName: ".notepro-preview.tex",
                                     stem: ".notepro-preview", quick: true)
            } catch {
                result = .failure(error)
            }
            try? FileManager.default.removeItem(at: texURL) // keep only the .pdf
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Compile an existing .tex file in its own directory (so `\input`,
    /// `\bibliography{references}`, images alongside it resolve). Writes the PDF
    /// next to the source.
    static func compileFile(
        _ texURL: URL,
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runTectonic(in: texURL.deletingLastPathComponent(),
                                     texName: texURL.lastPathComponent,
                                     stem: texURL.deletingPathExtension().lastPathComponent)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private static func runCompile(tex: String, bib: String, name: String,
                                   base: URL? = nil, vault: URL? = nil) -> Result<URL, Error> {
        let stem = name.isEmpty ? "note" : name
        do {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("notepro-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try tex.write(to: dir.appendingPathComponent("\(stem).tex"), atomically: true, encoding: .utf8)
            if !bib.isEmpty {
                try bib.write(to: dir.appendingPathComponent("references.bib"), atomically: true, encoding: .utf8)
            }
            stageImages(tex: tex, into: dir, base: base, vault: vault)
            return runTectonic(in: dir, texName: "\(stem).tex", stem: stem)
        } catch {
            return .failure(error)
        }
    }

    /// Run `tectonic <texName>` in `dir`; return the produced `<stem>.pdf`.
    /// When `quick` (live preview), force a single pass and keep intermediates so
    /// subsequent recompiles in the same dir are much faster.
    private static func runTectonic(in dir: URL, texName: String, stem: String,
                                    quick: Bool = false) -> Result<URL, Error> {
        guard let tectonic = findTectonic() else { return .failure(ExportError.tectonicNotFound) }
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tectonic)
            process.arguments = quick
                ? ["--reruns", "0", "--keep-intermediates", texName]
                : [texName]
            process.currentDirectoryURL = dir
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            // Drain the pipe CONCURRENTLY: tectonic can emit > 64 KB (downloads,
            // many warnings); reading only after exit would fill the pipe and
            // deadlock waitUntilExit(). Keep just the tail for the error log.
            let tail = PipeTail()
            pipe.fileHandleForReading.readabilityHandler = { tail.append($0.availableData) }
            try process.run()
            process.waitUntilExit()
            pipe.fileHandleForReading.readabilityHandler = nil
            tail.append(pipe.fileHandleForReading.readDataToEndOfFile())

            let pdfURL = dir.appendingPathComponent("\(stem).pdf")
            if process.terminationStatus == 0, FileManager.default.fileExists(atPath: pdfURL.path) {
                return .success(pdfURL)
            }
            return .failure(ExportError.compileFailed(String(tail.string().suffix(800))))
        } catch {
            return .failure(error)
        }
    }

    /// Find every image referenced by `\includegraphics{ref}` in `tex`, resolve it
    /// in the vault (note dir → vault root → basename search, same as the npimg
    /// handler), and copy it into `dir` (preserving the referenced relative path)
    /// so Tectonic finds it. Obsidian `![[fig.png]]` → `\includegraphics{fig.png}`,
    /// but the file lives elsewhere in the vault — this stages it next to the .tex.
    static func stageImages(tex: String, into dir: URL, base: URL?, vault: URL?) {
        let fm = FileManager.default
        guard let re = try? NSRegularExpression(
            pattern: #"\\includegraphics(?:\[[^\]]*\])?\{([^}]+)\}"#) else { return }
        let ns = tex as NSString
        var seen = Set<String>()
        for m in re.matches(in: tex, range: NSRange(location: 0, length: ns.length)) {
            let ref = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !ref.isEmpty, !seen.contains(ref) else { continue }
            seen.insert(ref)
            let dest = dir.appendingPathComponent(ref)
            if fm.fileExists(atPath: dest.path) { continue }
            guard let src = ImageSchemeHandler.resolve(
                ref: ref, base: base?.path ?? "", vault: vault?.path ?? "") else { continue }
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: src, to: dest)
        }
    }

    private static func findTectonic() -> String? {
        let candidates = [
            "/opt/homebrew/bin/tectonic",
            "/usr/local/bin/tectonic",
            "\(NSHomeDirectory())/.cargo/bin/tectonic",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Thread-safe accumulator keeping only the last ~64 KB of process output, so a
/// chatty subprocess can't blow up memory and concurrent appends are race-free.
final class PipeTail {
    private var data = Data()
    private let lock = NSLock()
    private let cap = 65_536
    func append(_ d: Data) {
        guard !d.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        if data.count > cap { data.removeFirst(data.count - cap) }
    }
    func string() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
