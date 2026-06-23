import Foundation

/// Abstraction over a local AI backend (DESIGN §: "AIService … 日後可換").
/// v1 implementation talks to a local Ollama server.
protocol AIService {
    func edit(text: String, instruction: String, completion: @escaping (Result<String, Error>) -> Void)
    /// Generate new content to insert at the cursor, given preceding context.
    func generate(context: String, instruction: String, completion: @escaping (Result<String, Error>) -> Void)
    /// Run an arbitrary prompt. Completes on main. `timeout` lets slow tasks
    /// (e.g. whole-document LaTeX fixes) wait longer.
    func complete(prompt: String, timeout: TimeInterval, completion: @escaping (Result<String, Error>) -> Void)
}

extension AIService {
    /// Convenience with the default timeout.
    func complete(prompt: String, completion: @escaping (Result<String, Error>) -> Void) {
        complete(prompt: prompt, timeout: 120, completion: completion)
    }
}

/// Shared provider. Swap the implementation here to change backends.
enum AIProvider {
    static let shared: AIService = OllamaService()
}

/// Calls a local Ollama server (http://localhost:11434). No data leaves the machine.
final class OllamaService: AIService {
    var baseURL = URL(string: "http://localhost:11434")!
    /// Model from Settings (qwen3 handles Chinese well by default).
    var model: String { UserDefaults.standard.string(forKey: "aiModel") ?? "qwen3:8b" }

    enum AIError: LocalizedError {
        case notRunning
        case badResponse
        case timedOut
        var errorDescription: String? {
            switch self {
            case .notRunning: return "無法連線 Ollama（請執行 `ollama serve` 並 pull 模型）"
            case .badResponse: return "Ollama 回應無效"
            case .timedOut: return "AI 逾時（文件較長或模型較慢，請再試或縮短內容）"
            }
        }
    }

    func edit(text: String, instruction: String, completion: @escaping (Result<String, Error>) -> Void) {
        let prompt = """
        你是專業的寫作助手。請依照指示處理「文字」，**只輸出處理後的結果**，不要加任何解釋、引號或前後綴，並保留原本的語言。

        指示：\(instruction)

        文字：
        \(text)
        """
        post(prompt: prompt, completion: completion)
    }

    func generate(context: String, instruction: String, completion: @escaping (Result<String, Error>) -> Void) {
        let prompt = """
        你是專業的寫作助手。以下是文件目前的內容（上文）。請依照指示，產生「要插入到游標處的新內容」，**只輸出新內容本身**，不要重複上文、不要任何解釋。保留原本的語言。

        上文：
        \(context.suffix(1500))

        指示：\(instruction)
        """
        post(prompt: prompt, completion: completion)
    }

    func complete(prompt: String, timeout: TimeInterval, completion: @escaping (Result<String, Error>) -> Void) {
        post(prompt: prompt, timeout: timeout, completion: completion)
    }

    /// Shared POST to Ollama /api/generate. Completes on the main queue.
    private func post(prompt: String, timeout: TimeInterval = 120,
                      completion rawCompletion: @escaping (Result<String, Error>) -> Void) {
        let completion: (Result<String, Error>) -> Void = { r in DispatchQueue.main.async { rawCompletion(r) } }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "prompt": prompt, "stream": false, "think": false,
        ])
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                let code = (error as NSError).code
                completion(.failure(code == NSURLErrorTimedOut ? AIError.timedOut : AIError.notRunning))
                return
            }
            guard
                let data,
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let response = obj["response"] as? String
            else { completion(.failure(AIError.badResponse)); return }
            completion(.success(Self.clean(response)))
        }.resume()
    }

    /// Strip thinking blocks / stray fences some models add.
    static func clean(_ s: String) -> String {
        var out = s
        // Remove <think>…</think> (qwen3 etc.)
        if let r = out.range(of: "<think>"), let e = out.range(of: "</think>") {
            out.removeSubrange(r.lowerBound..<e.upperBound)
        }
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop wrapping ``` fences if the whole thing is fenced.
        if out.hasPrefix("```") {
            var lines = out.components(separatedBy: "\n")
            if lines.first?.hasPrefix("```") == true { lines.removeFirst() }
            if lines.last?.hasPrefix("```") == true { lines.removeLast() }
            out = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }
}
