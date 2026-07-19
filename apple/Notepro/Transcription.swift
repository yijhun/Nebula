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
                           language: String = "en", initialPrompt: String = "",
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
            //    `initialPrompt` biases recognition toward the talk's domain terms
            //    (whisper caps it at ~224 tokens, so keep the glossary short).
            var args = ["-m", model, "-f", wav.path, "-l", language, "-pp", "-of", outStem.path]
            if !initialPrompt.isEmpty { args += ["--prompt", initialPrompt] }
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
    enum Phase: Equatable { case idle, recording, transcribing, summarizing, review, error(String) }
    @Published var phase: Phase = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var summarize = true
    @Published var timestamps = false
    /// Optional topic/terms for this talk. Blank is fine (English + generic astro
    /// glossary). If filled it biases ASR, prefills the note title, and gives the
    /// summariser the talk's real subject.
    @Published var topic = ""
    /// Talks are usually English; auto-detect only when this is on.
    @Published var autoLanguage = false
    /// Per-talk glossary generated from `topic` by the local LLM (empty →
    /// `defaultAstroTerms`). Generated in the background while recording runs.
    @Published var glossary: [String] = []
    private var glossaryTopic = ""                   // topic the glossary was made for
    private var glossaryBusy = false
    private var glossaryWaiters: [() -> Void] = []
    @Published var transcribeProgress: Double = 0   // 0…1 (whisper)
    @Published var summaryStep = 0                   // chunk n …
    @Published var summaryTotal = 0                  // … of N
    // Filled when transcription finishes; the review form turns them into a
    // meeting note (speaker/kind/event/title added there).
    @Published var pendingTranscript = ""
    @Published var pendingSummary: String?

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
                // Prewarm the per-talk glossary while the talk records — it's
                // ready long before the transcription needs it.
                self.ensureGlossary()
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
    func stopAndProcess() {
        timer?.invalidate(); timer = nil
        recorder?.stop(); recorder = nil
        guard let url = recURL else { phase = .idle; return }
        process(url)
    }

    /// Transcribe an imported audio file.
    func processFile(_ url: URL) {
        process(url)
    }

    private func process(_ audio: URL) {
        phase = .transcribing; transcribeProgress = 0
        // Make sure the per-talk glossary is in (usually prewarmed during the
        // recording; imported files wait here — bounded by the LLM timeout).
        ensureGlossary { [weak self] in self?.transcribe(audio) }
    }

    private func transcribe(_ audio: URL) {
        TranscriptionService.transcribe(audio, timestamps: timestamps,
                                        language: autoLanguage ? "auto" : "en",
                                        initialPrompt: asrPrompt(),
                                        progress: { [weak self] p in self?.transcribeProgress = p }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e): self.phase = .error(e.localizedDescription)
            case .success(let transcript):
                if self.summarize {
                    self.phase = .summarizing
                    self.makeSummary(transcript) { summary in
                        self.finish(transcript: transcript, summary: summary)
                    }
                } else {
                    self.finish(transcript: transcript, summary: nil)
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
                    .map { "(Partial summary \($0.offset + 1))\n\($0.element)" }.joined(separator: "\n\n")
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
    /// The transcript comes from ASR of a spoken talk, so it contains recognition
    /// errors (esp. technical terms, names, numbers). The prompt forces the model
    /// to flag out-of-domain garbage as `[?word]` instead of confabulating a
    /// fluent-but-wrong narrative, and to quarantine names/citations/numbers into
    /// a "To verify" section. Output is English, in three confidence tiers.
    private func summarize(_ text: String, combine: Bool, done: @escaping (String?) -> Void) {
        let task = combine
            ? """
            You are given several partial summaries of one spoken academic talk \
            (each already in the three-section format below). Merge them into ONE \
            summary in the SAME three-section format. Deduplicate. Keep every \
            [?word] flag and every "To verify" item from the inputs.
            """
            : """
            You are summarizing ONE segment of an automatic-speech-recognition \
            transcript of a spoken academic talk. Condense it into the three-section \
            format below.
            """
        let prompt = "\(Self.summarySystem(topic: topic, terms: effectiveTerms))\n\n\(task)\n\nTRANSCRIPT:\n\(text)"
        AIProvider.shared.complete(prompt: prompt, timeout: 300) { result in
            switch result {
            case .success(let s): done(s.trimmingCharacters(in: .whitespacesAndNewlines))
            case .failure: done(nil)   // best-effort; transcript is always kept
            }
        }
    }

    /// Terms actually in force: the LLM-generated per-talk glossary, else the
    /// generic astro defaults.
    private var effectiveTerms: [String] { glossary.isEmpty ? Self.defaultAstroTerms : glossary }

    /// The whisper `initial_prompt` for this talk: a domain sentence plus the
    /// biasing glossary. Blank topic → generic astro; a filled topic sharpens it.
    private func asrPrompt() -> String {
        let base = topic.isEmpty ? "Astronomy and astrophysics research talk. "
                                 : "Astronomy research talk on \(topic). "
        return base + "Terms: " + effectiveTerms.joined(separator: ", ") + "."
    }

    /// Generate (or reuse) the per-talk glossary for the current topic via the
    /// local LLM. No topic → defaults, done immediately. Concurrent callers are
    /// queued, not doubled. Failure is silent — defaults still apply.
    private func ensureGlossary(_ done: (() -> Void)? = nil) {
        let t = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { glossary = []; glossaryTopic = ""; done?(); return }
        if glossaryTopic == t, !glossary.isEmpty { done?(); return }   // cached
        if let done { glossaryWaiters.append(done) }
        guard !glossaryBusy else { return }
        glossaryBusy = true
        let prompt = """
        List 25 technical terms, jargon, instrument/survey/code names, and unit \
        symbols likely to be SPOKEN in an astronomy research talk about: \(t). \
        Include correct capitalization (e.g. AGN, ICM, kpc, Myr). Output ONLY the \
        terms, comma-separated, one line, no explanations.
        """
        AIProvider.shared.complete(prompt: prompt, timeout: 60) { [weak self] result in
            guard let self else { return }
            if case .success(let s) = result {
                let terms = Self.parseTerms(s)
                if terms.count >= 5 { self.glossary = terms; self.glossaryTopic = t }
            }
            self.glossaryBusy = false
            let waiters = self.glossaryWaiters; self.glossaryWaiters = []
            waiters.forEach { $0() }
        }
    }

    /// Parse an LLM term list (comma-separated, or bullets) into clean terms.
    /// Caps at 30 so the whisper prompt stays under its ~224-token limit.
    static func parseTerms(_ s: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for piece in s.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }) {
            var term = piece.trimmingCharacters(in: .whitespaces)
            while let f = term.first, "-•*0123456789. ".contains(f) { term.removeFirst() }
            term = term.trimmingCharacters(in: CharacterSet(charactersIn: " \"'`.。"))
            guard (1...40).contains(term.count), !term.contains(":") else { continue }
            let key = term.lowercased()
            if seen.insert(key).inserted { out.append(term) }
            if out.count >= 30 { break }
        }
        return out
    }

    /// Astronomy/astrophysics biasing glossary + the anti-hallucination rules and
    /// the required three-tier output shape. Shared by the map and reduce passes.
    /// `topic` (when the user gave one) is injected as the talk's real subject;
    /// `terms` is the per-talk glossary (or the generic defaults).
    private static func summarySystem(topic: String, terms: [String]) -> String {
        let subject = topic.isEmpty ? ""
            : "\nTHIS TALK IS ABOUT: \(topic). Prefer this subject when disambiguating garbled words.\n"
        return """
    You summarize ASR transcripts of spoken ASTRONOMY / ASTROPHYSICS research \
    talks. The transcript has recognition errors, especially in technical terms, \
    person names, citations, and numbers.
    \(subject)
    DOMAIN GLOSSARY (correct spellings — use as strong priors):
    \(terms.joined(separator: ", ")).

    RULES — follow strictly:
    1. Use the astrophysics field and the glossary above as strong priors. \
    Interpret ambiguous or garbled words as the nearest correct term in this field \
    (e.g. a talk about cluster turbulence saying "thermal" where "turbulent" fits, \
    or "agent feedback" → "AGN feedback").
    2. If a word or phrase does not fit an astrophysics talk (biology, finance, \
    anatomy, or other out-of-domain concepts suddenly appearing), ASSUME IT IS A \
    TRANSCRIPTION ERROR. Write it as [?original_word] with your best guess of the \
    intended term. NEVER invent a fluent narrative to accommodate a word you don't \
    trust. Do not make it make sense — mark it uncertain instead.
    3. Treat ALL person names, paper citations (author + year), and numeric values \
    as LOW CONFIDENCE. Do not state them as fact in the main summary; put them in \
    the "To verify" section with the raw transcript form noted.

    OUTPUT FORMAT — English, exactly these three sections (omit a section only if \
    truly empty):

    ## Key points
    - high-confidence, in-domain content only

    ## To verify
    - person names, citations (author + year), key numbers, and every [?...] flag, \
    each with the raw transcript wording

    ## Suspected transcription errors
    - corrected_term  ← heard as "garbled form"  (only when you changed something)

    Output only these sections, nothing else.
    """
    }

    /// Generic astronomy biasing terms, used until per-talk glossaries exist.
    static let defaultAstroTerms = [
        "AGN", "AGN feedback", "ICM", "intracluster medium", "cool-core",
        "cooling flow", "Hubble time", "Perseus cluster", "Hitomi",
        "turbulence", "turbulent heating", "turbulent dissipation",
        "velocity dispersion", "line-of-sight", "Kolmogorov", "inertial range",
        "power spectrum", "structure function", "solenoidal", "FLASH", "AMR",
        "kpc", "Myr", "cavity power", "galaxy cluster", "galaxy clusters",
    ]

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

    /// Transcription is done — stash the results and let the review form collect
    /// speaker/kind/event/title before writing the meeting note.
    private func finish(transcript: String, summary: String?) {
        pendingTranscript = transcript
        pendingSummary = summary
        elapsed = 0; transcribeProgress = 0; summaryStep = 0; summaryTotal = 0
        phase = .review
    }

    /// Discard the pending transcript and return to the start screen.
    func discardReview() {
        pendingTranscript = ""; pendingSummary = nil; topic = ""
        glossary = []; glossaryTopic = ""
        phase = .idle
    }
}
