import Foundation

/// One-click download of the full `ggml-large-v3` Whisper model (~3 GB, more
/// accurate than the default turbo distill) into `~/model_whisper/`, with
/// progress. Settings offers "use it" once installed.
final class WhisperDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = WhisperDownloader()

    @Published var downloading = false
    @Published var progress: Double = 0     // 0…1
    @Published var error: String?

    static let sourceURL = URL(string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")!
    var destDir: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("model_whisper") }
    var destFile: URL { destDir.appendingPathComponent("ggml-large-v3.bin") }
    var installed: Bool { FileManager.default.fileExists(atPath: destFile.path) }

    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func start() {
        guard !downloading else { return }
        downloading = true; progress = 0; error = nil
        let t = session.downloadTask(with: Self.sourceURL)
        task = t
        t.resume()
    }

    func cancel() {
        task?.cancel(); task = nil
        DispatchQueue.main.async { self.downloading = false; self.progress = 0 }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.progress = p }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Move must happen synchronously in this callback (temp file is deleted
        // after it returns).
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: destFile.path) { try fm.removeItem(at: destFile) }
            try fm.moveItem(at: location, to: destFile)
            DispatchQueue.main.async {
                self.downloading = false; self.progress = 1
                // Point transcription at the freshly installed model.
                UserDefaults.standard.set(self.destFile.path, forKey: "whisperModel")
            }
        } catch {
            DispatchQueue.main.async {
                self.downloading = false
                self.error = "安裝失敗：\(error.localizedDescription)"
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        DispatchQueue.main.async {
            self.downloading = false
            self.error = "下載失敗：\(error.localizedDescription)"
        }
    }
}
