import Foundation
import CryptoKit

/// A semantic-search hit: a chunk of a note ranked by meaning similarity.
struct SemHit: Identifiable, Hashable {
    let url: URL
    let heading: String
    let snippet: String
    let line: Int
    let score: Float
    var id: String { "\(url.path):\(line)" }
    var name: String { url.lastPathComponent }
}

/// Local semantic index over the vault: chunks every note, embeds each chunk
/// with nomic-embed-text (via Ollama), and answers "search by meaning" + RAG
/// "ask your notes" queries. Vectors are cached on disk per file+mtime, so only
/// changed notes are re-embedded. Everything stays on the machine.
@MainActor
final class SemanticIndex: ObservableObject {
    @Published private(set) var isIndexing = false
    @Published private(set) var ready = false
    @Published private(set) var progress = 0.0
    @Published private(set) var chunkCount = 0
    @Published var status = ""

    private struct Chunk { let url: URL; let heading: String; let text: String; let line: Int; let vector: [Float] }
    private var chunks: [Chunk] = []
    private var indexedRoot: URL?

    // MARK: persistence
    private struct StoredChunk: Codable { let heading: String; let text: String; let line: Int; let vector: [Float] }
    private struct StoredFile: Codable { let path: String; let mtime: Double; let chunks: [StoredChunk] }
    private struct Store: Codable { var model: String; var files: [StoredFile] }

    private func storeURL(for root: URL) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notepro", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let digest = Insecure.MD5.hash(data: Data(root.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent("sem-\(digest).json")
    }

    private func loadStore(_ root: URL) -> Store {
        guard let data = try? Data(contentsOf: storeURL(for: root)),
              let s = try? JSONDecoder().decode(Store.self, from: data) else {
            return Store(model: EmbeddingService.model, files: [])
        }
        return s
    }

    private func save(_ store: Store, root: URL) {
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: storeURL(for: root))
        }
    }

    // MARK: build

    /// (Re)build the index from the file index. Reuses cached vectors for files
    /// whose mtime is unchanged; embeds only new/changed notes.
    func build(_ index: IndexService, vault: VaultModel, force: Bool = false) async {
        guard let root = vault.rootURL else { return }
        if isIndexing { return }
        index.buildIfNeeded(vault)
        isIndexing = true; ready = false; progress = 0
        defer { isIndexing = false }

        // Cache tag includes a schema version: bump it when the embedding
        // recipe changes (e.g. nomic prefixes) so old vectors are rebuilt.
        let model = EmbeddingService.model + "|v2"
        var store = force ? Store(model: model, files: []) : loadStore(root)
        if store.model != model { store = Store(model: model, files: []) }
        let cached = Dictionary(store.files.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })

        // Plan: reuse unchanged files, queue changed ones for embedding.
        var built: [Chunk] = []
        var newStoredFiles: [StoredFile] = []
        struct Pending { let url: URL; let mtime: Double; let pieces: [(heading: String, text: String, line: Int)] }
        var pending: [Pending] = []

        let entries = index.entries
        for e in entries {
            let m = e.mtime.timeIntervalSince1970
            if !force, let sf = cached[e.url.path], abs(sf.mtime - m) < 1 {
                newStoredFiles.append(sf)
                for c in sf.chunks {
                    built.append(Chunk(url: e.url, heading: c.heading, text: c.text, line: c.line, vector: c.vector))
                }
            } else {
                let pieces = Self.chunk(e.content)
                if !pieces.isEmpty { pending.append(Pending(url: e.url, mtime: m, pieces: pieces)) }
                else { newStoredFiles.append(StoredFile(path: e.url.path, mtime: m, chunks: [])) }
            }
        }

        // Embed pending chunks in batches.
        let toEmbed = pending.flatMap { p in p.pieces.map { ($0.heading.isEmpty ? $0.text : "\($0.heading)\n\($0.text)") } }
        var vectors: [[Float]] = []
        let batchSize = 48
        if !toEmbed.isEmpty {
            status = "建立語意索引… 0/\(toEmbed.count)"
            var i = 0
            while i < toEmbed.count {
                // nomic-embed-text requires a task prefix on documents.
                let batch = toEmbed[i ..< min(i + batchSize, toEmbed.count)].map { "search_document: " + $0 }
                do {
                    let vecs = try await EmbeddingService.embed(batch)
                    guard vecs.count == batch.count else { status = "嵌入回應數量不符"; return }
                    vectors.append(contentsOf: vecs)
                } catch {
                    status = "索引失敗：\(error.localizedDescription)"
                    return
                }
                i += batch.count
                progress = Double(i) / Double(toEmbed.count)
                status = "建立語意索引… \(i)/\(toEmbed.count)"
            }
        }

        // Stitch embedded vectors back onto their files.
        var vi = 0
        for p in pending {
            var storedChunks: [StoredChunk] = []
            for piece in p.pieces {
                let vec = vi < vectors.count ? vectors[vi] : []
                vi += 1
                guard !vec.isEmpty else { continue }
                built.append(Chunk(url: p.url, heading: piece.heading, text: piece.text, line: piece.line, vector: vec))
                storedChunks.append(StoredChunk(heading: piece.heading, text: piece.text, line: piece.line, vector: vec))
            }
            newStoredFiles.append(StoredFile(path: p.url.path, mtime: p.mtime, chunks: storedChunks))
        }

        chunks = built
        chunkCount = built.count
        indexedRoot = root
        ready = !built.isEmpty
        save(Store(model: model, files: newStoredFiles), root: root)
        status = ready ? "索引就緒：\(built.count) 段、\(entries.count) 檔" : "沒有可索引的內容"
    }

    // MARK: query

    /// Top-k chunks most similar in meaning to `query`.
    func search(_ query: String, k: Int = 12) async -> [SemHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !chunks.isEmpty else { return [] }
        // nomic-embed-text requires the query task prefix (must match documents).
        guard let qvec = try? await EmbeddingService.embed(["search_query: " + q]).first,
              !qvec.isEmpty else { return [] }
        let qn = norm(qvec)
        let scored = chunks.map { c -> (Chunk, Float) in
            (c, cosine(qvec, c.vector, qn))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(k).map { (c, s) in
            SemHit(url: c.url, heading: c.heading,
                   snippet: String(c.text.prefix(180)).replacingOccurrences(of: "\n", with: " "),
                   line: c.line, score: s)
        }
    }

    /// Notes most similar in meaning to the given file (uses cached vectors —
    /// no network). Compares the file's centroid against every other file's
    /// best chunk. Synchronous and cheap.
    func related(to url: URL?, k: Int = 6) -> [SemHit] {
        guard let url, !chunks.isEmpty else { return [] }
        let mine = chunks.filter { $0.url == url }
        guard let dim = mine.first?.vector.count, dim > 0, !mine.isEmpty else { return [] }
        var centroid = [Float](repeating: 0, count: dim)
        for ch in mine where ch.vector.count == dim {
            for i in 0 ..< dim { centroid[i] += ch.vector[i] }
        }
        for i in 0 ..< dim { centroid[i] /= Float(mine.count) }
        let cn = norm(centroid)
        var bestByFile: [URL: (Float, Chunk)] = [:]
        for ch in chunks where ch.url != url {
            let s = cosine(centroid, ch.vector, cn)
            if let cur = bestByFile[ch.url], cur.0 >= s { continue }
            bestByFile[ch.url] = (s, ch)
        }
        return bestByFile.values.sorted { $0.0 > $1.0 }.prefix(k).map { (s, ch) in
            SemHit(url: ch.url, heading: ch.heading,
                   snippet: String(ch.text.prefix(120)).replacingOccurrences(of: "\n", with: " "),
                   line: ch.line, score: s)
        }
    }

    /// RAG: retrieve the most relevant chunks and ask the local LLM to answer
    /// grounded in them, citing sources as 【n】.
    func ask(_ question: String) async -> (answer: String, sources: [SemHit]) {
        let hits = await search(question, k: 8)
        guard !hits.isEmpty else { return ("索引裡找不到相關內容。", []) }
        let context = hits.enumerated().map { (i, h) in
            "【\(i + 1)】\(h.name)\(h.heading.isEmpty ? "" : " — \(h.heading)")\n\(h.snippet)"
        }.joined(separator: "\n\n")
        let prompt = """
        你是使用者私人筆記庫的研究助理。只根據下面提供的「筆記片段」回答問題，用繁體中文，並在引用某段時標註來源編號【n】。若片段不足以回答，就說明資訊不足，不要編造。

        筆記片段：
        \(context)

        問題：\(question)
        """
        let answer: String = await withCheckedContinuation { cont in
            AIProvider.shared.complete(prompt: prompt) { result in
                switch result {
                case .success(let t): cont.resume(returning: t)
                case .failure(let e): cont.resume(returning: "回答失敗：\(e.localizedDescription)")
                }
            }
        }
        return (answer, hits)
    }

    // MARK: math

    private func norm(_ v: [Float]) -> Float {
        var s: Float = 0; for x in v { s += x * x }; return s.squareRoot()
    }

    private func cosine(_ a: [Float], _ b: [Float], _ aNorm: Float) -> Float {
        guard a.count == b.count else { return -1 }
        var dot: Float = 0; var bn: Float = 0
        for i in 0 ..< a.count { dot += a[i] * b[i]; bn += b[i] * b[i] }
        let denom = aNorm * bn.squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    // MARK: chunking

    /// Split note content into heading-aware chunks (~700 chars), keeping the
    /// nearest heading as context and the starting line for "open".
    static func chunk(_ content: String) -> [(heading: String, text: String, line: Int)] {
        var out: [(heading: String, text: String, line: Int)] = []
        var heading = ""
        var buf = ""
        var bufStart = 0
        var lines = content.components(separatedBy: "\n")
        // Drop leading YAML frontmatter (title/author/… is not content to index).
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
        }

        func flush() {
            let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 20 { out.append((heading, t, bufStart + 1)) }
            buf = ""
        }

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#"), trimmed.contains(" ") || trimmed.allSatisfy({ $0 == "#" }) == false {
                flush()
                heading = String(trimmed.drop(while: { $0 == "#" || $0 == " " }))
                continue
            }
            if trimmed.isEmpty {
                if buf.count > 400 { flush() }
                continue
            }
            if buf.isEmpty { bufStart = i }
            buf += (buf.isEmpty ? "" : "\n") + line
            if buf.count > 700 { flush() }
        }
        flush()
        return out
    }
}
