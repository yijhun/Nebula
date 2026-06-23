import Foundation

/// Batch text embeddings via the local Ollama server (`/api/embed`).
/// Uses `nomic-embed-text` by default (configurable in Settings). No data
/// leaves the machine — same local server as the AI rewrite/generate features.
enum EmbeddingService {
    static var baseURL = URL(string: "http://localhost:11434")!
    static var model: String { UserDefaults.standard.string(forKey: "embedModel") ?? "nomic-embed-text" }

    enum EmbError: LocalizedError {
        case notRunning
        case badResponse
        var errorDescription: String? {
            switch self {
            case .notRunning: return "無法連線 Ollama（嵌入模型，請 `ollama pull nomic-embed-text`）"
            case .badResponse: return "Ollama 嵌入回應無效"
            }
        }
    }

    /// Embed a batch of texts. Completes on a background queue.
    static func embed(_ texts: [String], completion: @escaping (Result<[[Float]], Error>) -> Void) {
        guard !texts.isEmpty else { completion(.success([])); return }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "input": texts])
        URLSession.shared.dataTask(with: request) { data, _, error in
            if error != nil { completion(.failure(EmbError.notRunning)); return }
            guard
                let data,
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let arr = obj["embeddings"] as? [[Any]]
            else { completion(.failure(EmbError.badResponse)); return }
            let vecs = arr.map { row in row.compactMap { ($0 as? NSNumber)?.floatValue } }
            completion(.success(vecs))
        }.resume()
    }

    /// async wrapper around `embed`.
    static func embed(_ texts: [String]) async throws -> [[Float]] {
        try await withCheckedThrowingContinuation { cont in
            embed(texts) { cont.resume(with: $0) }
        }
    }
}
