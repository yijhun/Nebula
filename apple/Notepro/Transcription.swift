import Foundation
import AVFoundation
import AppKit

/// Local speech-to-text via whisper.cpp (`whisper-cli`) + ffmpeg. Fully offline,
/// no cloud / API. Model defaults to the user's downloaded large-v3-turbo.
enum TranscriptionService {
    enum TError: LocalizedError {
        case noWhisper, noModel, noFFmpeg, failed(String)
        var errorDescription: String? {
            switch self {
            case .noWhisper: return "找不到 whisper-cli（brew install whisper-cpp）"
            case .noModel:   return "找不到 Whisper 模型（設定可指定路徑）"
            case .noFFmpeg:  return "找不到 ffmpeg（brew install ffmpeg）"
            case .failed(let s): return "轉錄失敗：\(s)"
            }
        }
    }

    static func findExec(_ names: [String]) -> String? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.cargo/bin"]
        for d in dirs { for n in names {
            let p = "\(d)/\(n)"; if FileManager.default.isExecutableFile(atPath: p) { return p }
        } }
        return nil
    }

    /// Whisper model path: user setting, else the common downloaded location.
    static var modelPath: String {
        if let m = UserDefaults.standard.string(forKey: "whisperModel"), !m.isEmpty,
           FileManager.default.fileExists(atPath: m) { return m }
        let home = NSHomeDirectory()
        for p in ["\(home)/model_whisper/ggml-large-v3-turbo.bin",
                  "\(home)/model_whisper/ggml-large-v3.bin",
                  "\(home)/model_whisper/ggml-medium.bin"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return ""
    }

    static var isAvailable: Bool {
        findExec(["whisper-cli", "whisper-cpp", "main"]) != nil && !modelPath.isEmpty
    }

    /// Transcribe an audio file → plain text (with `[mm:ss]` paragraph stamps when
    /// `timestamps`). Runs ffmpeg → 16 kHz wav → whisper-cli. Off the main queue.
    static func transcribe(_ audio: URL, timestamps: Bool,
                           progress: @escaping (Double) -> Void = { _ in },
                           completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let done: (Result<String, Error>) -> Void = { r in DispatchQueue.main.async { completion(r) } }
            let prog: (Double) -> Void = { v in DispatchQueue.main.async { progress(v) } }
            guard let whisper = findExec(["whisper-cli", "whisper-cpp", "main"]) else { return done(.failure(TError.noWhisper)) }
            let model = modelPath
            guard !model.isEmpty else { return done(.failure(TError.noModel)) }
            guard let ffmpeg = findExec(["ffmpeg"]) else { return done(.failure(TError.noFFmpeg)) }

            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("np-asr-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let wav = dir.appendingPathComponent("in.wav")
            let outStem = dir.appendingPathComponent("out")

            // 1. Convert to 16 kHz mono PCM wav (what whisper wants).
            if let e = run(ffmpeg, ["-y", "-i", audio.path, "-ar", "16000", "-ac", "1",
                                    "-c:a", "pcm_s16le", wav.path]) {
                return done(.failure(TError.failed("ffmpeg: \(e)")))
            }
            // 2. Whisper → SRT (timestamps) or TXT, with live progress (-pp).
            var args = ["-m", model, "-f", wav.path, "-l", "auto", "-pp", "-of", outStem.path]
            args.append(timestamps ? "-osrt" : "-otxt")
            if let e = runWhisper(whisper, args, progress: prog) {
                return done(.failure(TError.failed("whisper: \(e)")))
            }

            let outURL = outStem.appendingPathExtension(timestamps ? "srt" : "txt")
            guard let raw = try? String(contentsOf: outURL, encoding: .utf8) else {
                return done(.failure(TError.failed("無輸出")))
            }
            done(.success(timestamps ? srtToStamped(raw) : raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    /// Run a process; return nil on success, else the tail of output. Drains the
    /// pipe concurrently so a chatty process (ffmpeg progress) can't fill the
    /// 64 KB buffer and deadlock waitUntilExit().
    private static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
        let tail = PipeTail()
        pipe.fileHandleForReading.readabilityHandler = { tail.append($0.availableData) }
        do { try p.run(); p.waitUntilExit() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil; return error.localizedDescription
        }
        // Clearing the handler unwinds async — a still-in-flight invocation
        // could race with readDataToEndOfFile() and append the same bytes
        // twice. The handler is the sole reader; trust it to have drained.
        pipe.fileHandleForReading.readabilityHandler = nil
        return p.terminationStatus == 0 ? nil : String(tail.string().suffix(300))
    }

    /// Run whisper, parsing `progress = NN%` lines live to drive `progress`.
    private static func runWhisper(_ exe: String, _ args: [String],
                                   progress: @escaping (Double) -> Void) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let pipe = Pipe()
        p.standardError = pipe; p.standardOutput = pipe
        let tail = PipeTail()
        let re = try? NSRegularExpression(pattern: #"progress\s*=\s*(\d+)"#)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = h.availableData
            tail.append(chunk)
            guard !chunk.isEmpty, let s = String(data: chunk, encoding: .utf8) else { return }
            if let re, let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               let r = Range(m.range(at: 1), in: s), let pct = Double(s[r]) {
                progress(min(max(pct / 100, 0), 1))
            }
        }
        do { try p.run(); p.waitUntilExit() } catch {
            pipe.fileHandleForReading.readabilityHandler = nil; return error.localizedDescription
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        return p.terminationStatus == 0 ? nil : String(tail.string().suffix(300))
    }

    /// Collapse an SRT into `[mm:ss] text` paragraphs.
    private static func srtToStamped(_ srt: String) -> String {
        var out: [String] = []
        let blocks = srt.components(separatedBy: "\n\n")
        for b in blocks {
            let lines = b.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard lines.count >= 2 else { continue }
            let timeLine = lines.first { $0.contains("-->") } ?? ""
            let start = timeLine.components(separatedBy: " --> ").first ?? ""
            // "00:01:23,456" → mm:ss
            let parts = start.replacingOccurrences(of: ",", with: ":").components(separatedBy: ":")
            var stamp = ""
            if parts.count >= 3, let h = Int(parts[0]), let m = Int(parts[1]), let s = Int(parts[2]) {
                let mm = h * 60 + m
                stamp = String(format: "[%02d:%02d] ", mm, s)
            }
            let text = lines.filter { !$0.contains("-->") && Int($0) == nil }.joined(separator: " ")
            if !text.isEmpty { out.append(stamp + text) }
        }
        return out.joined(separator: "\n\n")
    }
}

/// Records a talk (or takes an imported file), transcribes it, optionally has the
/// local LLM summarize, and writes the result as a note.
@MainActor
final class MeetingRecorder: NSObject, ObservableObject {
    enum Phase: Equatable { case idle, recording, transcribing, summarizing, error(String) }
    @Published var phase: Phase = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var summarize = true
    @Published var timestamps = false
    @Published var transcribeProgress: Double = 0   // 0…1 (whisper)
    @Published var summaryStep = 0                   // chunk n …
    @Published var summaryTotal = 0                  // … of N

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recURL: URL?

    var isRecording: Bool { phase == .recording }
    var isBusy: Bool { phase == .transcribing || phase == .summarizing }

    func startRecording() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else { self.phase = .error("未取得麥克風權限（系統設定 ▸ 隱私 ▸ 麥克風）"); return }
                self.beginRecording()
            }
        }
    }

    private func beginRecording() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("np-rec-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.record()
            recorder = r; recURL = url; elapsed = 0; phase = .recording
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.elapsed += 1 }
            }
        } catch {
            phase = .error("無法開始錄音：\(error.localizedDescription)")
        }
    }

    /// Stop recording and process the captured audio.
    func stopAndProcess(write: @escaping (_ title: String, _ content: String) -> URL?,
                        open: @escaping (URL) -> Void) {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        guard let url = recURL else { phase = .idle; return }
        process(url, write: write, open: open)
    }

    /// Transcribe an imported audio file.
    func processFile(_ url: URL, write: @escaping (_ title: String, _ content: String) -> URL?,
                     open: @escaping (URL) -> Void) {
        process(url, write: write, open: open)
    }

    private func process(_ audio: URL, write: @escaping (_ title: String, _ content: String) -> URL?,
                         open: @escaping (URL) -> Void) {
        phase = .transcribing; transcribeProgress = 0
        TranscriptionService.transcribe(audio, timestamps: timestamps,
                                        progress: { [weak self] p in self?.transcribeProgress = p }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e): self.phase = .error(e.localizedDescription)
            case .success(let transcript):
                if self.summarize {
                    self.phase = .summarizing
                    self.makeSummary(transcript) { summary in
                        self.finish(transcript: transcript, summary: summary, write: write, open: open)
                    }
                } else {
                    self.finish(transcript: transcript, summary: nil, write: write, open: open)
                }
            }
        }
    }

    /// Map-reduce summary: long transcripts are split into chunks, each
    /// summarized, then the section summaries are merged into one — so nothing is
    /// dropped (no 8000-char truncation).
    private func makeSummary(_ transcript: String, done: @escaping (String?) -> Void) {
        let chunks = Self.chunk(transcript)
        if chunks.count <= 1 {
            summaryTotal = 1; summaryStep = 1
            summarize(chunks.first ?? transcript, combine: false, done: done)
            return
        }
        summaryTotal = chunks.count + 1
        var partials: [String] = []
        func next(_ i: Int) {
            if i >= chunks.count {
                summaryStep = chunks.count + 1
                let merged = partials.enumerated()
                    .map { "（第 \($0.offset + 1) 段摘要）\n\($0.element)" }.joined(separator: "\n\n")
                summarize(merged, combine: true, done: done)
                return
            }
            summaryStep = i + 1
            summarize(chunks[i], combine: false) { s in
                partials.append(s ?? ""); next(i + 1)
            }
        }
        next(0)
    }

    /// One LLM call: summarize a transcript chunk, or merge section summaries.
    private func summarize(_ text: String, combine: Bool, done: @escaping (String?) -> Void) {
        let prompt = combine
            ? "你是會議記錄助手。下面是一場演講各段的摘要。請用繁體中文合併成：先一段整體摘要，再條列整場重點（- ），去除重複。只輸出整理結果。\n\n\(text)"
            : "你是會議記錄助手。下面是一場演講逐字稿的一段。請用繁體中文濃縮成幾個重點（- ），保留關鍵數據/名詞。只輸出重點。\n\n\(text)"
        AIProvider.shared.complete(prompt: prompt, timeout: 300) { result in
            switch result {
            case .success(let s): done(s.trimmingCharacters(in: .whitespacesAndNewlines))
            case .failure: done(nil)   // best-effort; transcript is always kept
            }
        }
    }

    /// Split into ~chunks at paragraph boundaries, sized so there are at most ~12
    /// chunks (chunk size grows with the transcript so very long talks don't fan
    /// out into dozens of LLM calls).
    private static func chunk(_ text: String) -> [String] {
        let maxChunks = 12
        let size = max(5000, text.count / maxChunks)
        var chunks: [String] = []
        var cur = ""
        for para in text.components(separatedBy: "\n\n") {
            if cur.count + para.count > size, !cur.isEmpty { chunks.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : "\n\n") + para
        }
        if !cur.isEmpty { chunks.append(cur) }
        return chunks
    }

    private func finish(transcript: String, summary: String?,
                        write: (_ title: String, _ content: String) -> URL?,
                        open: (URL) -> Void) {
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = fmt.string(from: Date())
        var body = "---\ntype: 演講記錄\ndate: \(stamp)\n---\n\n# 演講記錄 \(stamp)\n\n"
        if let summary, !summary.isEmpty {
            body += "## 摘要\n\n\(summary)\n\n"
        }
        body += "## 逐字稿\n\n\(transcript)\n"
        phase = .idle; elapsed = 0; transcribeProgress = 0; summaryStep = 0; summaryTotal = 0
        if let url = write("演講記錄 \(stamp)", body) { open(url) }
    }
}
