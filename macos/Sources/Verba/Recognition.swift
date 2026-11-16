import AVFoundation
import CoreMedia
import Foundation
import NaturalLanguage
import Speech

struct LanguageOption: Identifiable, Hashable {
    let code: String
    let name: String
    let localeIdentifier: String

    var id: String { code }
}

enum Languages {
    static let all: [LanguageOption] = [
        LanguageOption(code: "auto", name: "自动识别", localeIdentifier: "en-US"),
        LanguageOption(code: "en", name: "英语", localeIdentifier: "en-US"),
        LanguageOption(code: "zh-CN", name: "中文（简体）", localeIdentifier: "zh-CN"),
        LanguageOption(code: "zh-TW", name: "中文（繁體）", localeIdentifier: "zh-TW"),
        LanguageOption(code: "ja", name: "日语", localeIdentifier: "ja-JP"),
        LanguageOption(code: "ko", name: "韩语", localeIdentifier: "ko-KR"),
        LanguageOption(code: "es", name: "西班牙语", localeIdentifier: "es-ES"),
        LanguageOption(code: "fr", name: "法语", localeIdentifier: "fr-FR"),
        LanguageOption(code: "de", name: "德语", localeIdentifier: "de-DE"),
        LanguageOption(code: "pt", name: "葡萄牙语", localeIdentifier: "pt-PT"),
    ]

    static let targets: [LanguageOption] = all.filter { $0.code != "auto" }

    static let notesLanguages: [(value: String, label: String)] = [
        ("Simplified Chinese", "简体中文"),
        ("Traditional Chinese", "繁體中文"),
        ("English", "English"),
        ("Japanese", "日本語"),
        ("Korean", "한국어"),
    ]

    static func locale(for code: String) -> Locale {
        if let match = all.first(where: { $0.code == code }) {
            return Locale(identifier: match.localeIdentifier)
        }
        return Locale(identifier: code == "auto" ? "en-US" : code)
    }

    static func displayName(for code: String) -> String {
        all.first(where: { $0.code == code })?.name ?? code
    }
}

struct RecognizedSegment {
    let text: String
    let isFinal: Bool
    let lang: String
    let cut: Bool
}

enum SpeechPermission {
    static var usesSpeechAnalyzer: Bool {
        if #available(macOS 26, *) {
            return SpeechTranscriber.isAvailable
        }
        return false
    }

    static func ensureAuthorized() async -> Bool {
        // macOS 26 SpeechTranscriber / SpeechAnalyzer does not require legacy Siri/Dictation TCC or Settings
        if usesSpeechAnalyzer { return true }
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { return true }
        if current == .denied || current == .restricted { return false }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    static func isDictationBlockedError(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "kLSRErrorDomain" && ns.code == 201
    }
}

// MARK: - Unified On-Device Speech Stream (macOS 26 SpeechAnalyzer + Legacy Fallback)

final class OnDeviceSpeechStream {
    private var langCode: String
    private var onResult: ((RecognizedSegment) -> Void)?
    private var onError: ((String) -> Void)?

    private var analyzerBackend: AnyObject?
    private var legacyBackend: LegacySpeechStream?

    init(langCode: String) {
        self.langCode = langCode == "auto" ? "en" : langCode
    }

    func start(
        onResult: @escaping (RecognizedSegment) -> Void,
        onError: @escaping (String) -> Void = { _ in }
    ) {
        self.onResult = onResult
        self.onError = onError

        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            let backend = ModernAnalyzerStream(langCode: langCode, onResult: onResult, onError: onError)
            analyzerBackend = backend
            backend.start(replaySamples: nil)
        } else {
            let legacy = LegacySpeechStream(langCode: langCode)
            legacyBackend = legacy
            legacy.start(onResult: onResult, onError: onError)
        }
    }

    func switchLanguage(to newCode: String, replaySamples: [Float]) {
        let resolved = newCode == "auto" ? "en" : newCode
        guard resolved != langCode else { return }
        langCode = resolved

        if #available(macOS 26, *), let backend = analyzerBackend as? ModernAnalyzerStream {
            backend.switchLanguage(to: resolved, replaySamples: replaySamples)
        } else {
            legacyBackend?.switchLanguage(to: resolved, replaySamples: replaySamples)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        if #available(macOS 26, *), let backend = analyzerBackend as? ModernAnalyzerStream {
            backend.append(buffer)
        } else {
            legacyBackend?.append(buffer)
        }
    }

    func stop() {
        if #available(macOS 26, *), let backend = analyzerBackend as? ModernAnalyzerStream {
            backend.stop()
            analyzerBackend = nil
        }
        legacyBackend?.stop()
        legacyBackend = nil
        onResult = nil
        onError = nil
    }

    /// Offline chunk transcription helper used by FileImporter (supports macOS 26 without Siri/Dictation)
    static func transcribeBuffers(_ buffers: [AVAudioPCMBuffer], langCode: String) async throws -> String {
        let resolved = langCode == "auto" ? "en" : langCode
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            return try await transcribeModern(buffers: buffers, langCode: resolved)
        }
        return try await transcribeLegacy(buffers: buffers, langCode: resolved)
    }

    @available(macOS 26, *)
    private static func transcribeModern(buffers: [AVAudioPCMBuffer], langCode: String) async throws -> String {
        let locale = Languages.locale(for: langCode)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            if let req = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await req.downloadAndInstall()
            }
        }
        let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: targetFormat)

        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
        let collector = Task { () -> String in
            var parts: [String] = []
            for try await result in transcriber.results where result.isFinal {
                let s = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { parts.append(s) }
            }
            return parts.joined(separator: " ")
        }
        try await analyzer.start(inputSequence: stream)

        var converter: AVAudioConverter?
        for buf in buffers {
            if let converted = convertBuffer(buf, to: targetFormat, converter: &converter) {
                input.yield(AnalyzerInput(buffer: converted))
            }
        }
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    private static func transcribeLegacy(buffers: [AVAudioPCMBuffer], langCode: String) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: Languages.locale(for: langCode)),
              recognizer.isAvailable else {
            return ""
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        for b in buffers { req.append(b) }
        req.endAudio()

        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            recognizer.recognitionTask(with: req) { result, error in
                if resumed { return }
                if let result, result.isFinal {
                    resumed = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if let error {
                    resumed = true
                    let nsErr = error as NSError
                    if nsErr.domain == "kAFAssistantErrorDomain" || nsErr.code == 1110 {
                        cont.resume(returning: "")
                    } else {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }
}

private func convertBuffer(
    _ input: AVAudioPCMBuffer,
    to format: AVAudioFormat,
    converter: inout AVAudioConverter?
) -> AVAudioPCMBuffer? {
    if input.format == format { return input }
    if converter == nil || converter!.inputFormat != input.format || converter!.outputFormat != format {
        converter = AVAudioConverter(from: input.format, to: format)
    }
    guard let conv = converter else { return nil }
    let ratio = format.sampleRate / max(input.format.sampleRate, 1)
    let cap = max(AVAudioFrameCount(Double(input.frameLength) * ratio) + 64, 64)
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: cap) else { return nil }
    var fed = false
    var err: NSError?
    let status = conv.convert(to: out, error: &err) { _, st in
        if fed { st.pointee = .noDataNow; return nil }
        fed = true
        st.pointee = .haveData
        return input
    }
    if status == .error || err != nil || out.frameLength == 0 { return nil }
    return out
}

// MARK: - macOS 26 SpeechAnalyzer Implementation

@available(macOS 26, *)
private final class ModernAnalyzerStream {
    private let lock = NSLock()
    private var langCode: String
    private var generation = 0
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var readerTask: Task<Void, Never>?
    private var cutTask: Task<Void, Never>?
    private var fedSeconds: Double = 0
    private var lastCutThrough: Double = 0
    private var lastVolatile = ""
    private var lastVolatileAt = Date.distantPast
    private var cutting = false
    private var stopped = false

    private let onResult: (RecognizedSegment) -> Void
    private let onError: (String) -> Void

    init(
        langCode: String,
        onResult: @escaping (RecognizedSegment) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.langCode = langCode
        self.onResult = onResult
        self.onError = onError
    }

    func start(replaySamples: [Float]?) {
        let gen = lock.withLock { () -> Int in
            stopped = false
            generation += 1
            return generation
        }
        let targetLang = lock.withLock { langCode }
        Task { [weak self] in
            await self?.openSession(generation: gen, langCode: targetLang, replaySamples: replaySamples)
        }
    }

    func switchLanguage(to newCode: String, replaySamples: [Float]) {
        let gen = lock.withLock { () -> Int in
            langCode = newCode
            generation += 1
            return generation
        }
        Task { [weak self] in
            await self?.teardownCurrent()
            await self?.openSession(generation: gen, langCode: newCode, replaySamples: replaySamples)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard !stopped, let fmt = targetFormat, let cont = input else { return }
            if let converted = convertBuffer(buffer, to: fmt, converter: &converter) {
                fedSeconds += Double(converted.frameLength) / fmt.sampleRate
                cont.yield(AnalyzerInput(buffer: converted))
            }
        }
    }

    func stop() {
        lock.withLock {
            stopped = true
            generation += 1
        }
        Task { [weak self] in
            await self?.teardownCurrent()
        }
    }

    private func teardownCurrent() async {
        let (curAnalyzer, curInput, curReader, curCut) = lock.withLock {
            () -> (SpeechAnalyzer?, AsyncStream<AnalyzerInput>.Continuation?, Task<Void, Never>?, Task<Void, Never>?) in
            let a = analyzer
            let i = input
            let r = readerTask
            let c = cutTask
            analyzer = nil
            input = nil
            readerTask = nil
            cutTask = nil
            targetFormat = nil
            converter = nil
            lastVolatile = ""
            return (a, i, r, c)
        }
        curCut?.cancel()
        curInput?.finish()
        if let curAnalyzer {
            try? await curAnalyzer.finalizeAndFinishThroughEndOfInput()
        }
        _ = await curReader?.value
    }

    private func openSession(generation gen: Int, langCode: String, replaySamples: [Float]?) async {
        do {
            let locale = Languages.locale(for: langCode)
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: []
            )
            if await AssetInventory.status(forModules: [transcriber]) != .installed {
                if let req = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await req.downloadAndInstall()
                }
            }
            let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
                ?? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false)!

            let stillValid = lock.withLock { !stopped && gen == generation }
            guard stillValid else { return }

            let newAnalyzer = SpeechAnalyzer(modules: [transcriber])
            try await newAnalyzer.prepareToAnalyze(in: fmt)

            let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self, bufferingPolicy: .unbounded)
            try await newAnalyzer.start(inputSequence: stream)

            let installed = lock.withLock { () -> Bool in
                guard !stopped && gen == generation else { return false }
                analyzer = newAnalyzer
                input = cont
                targetFormat = fmt
                converter = nil
                fedSeconds = 0
                lastCutThrough = 0
                lastVolatile = ""
                cutting = false
                return true
            }
            guard installed else {
                cont.finish()
                await newAnalyzer.cancelAndFinishNow()
                return
            }

            if let samples = replaySamples, !samples.isEmpty,
               let srcFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
               let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFmt, frameCapacity: AVAudioFrameCount(samples.count)) {
                srcBuf.frameLength = AVAudioFrameCount(samples.count)
                if let ch = srcBuf.floatChannelData?[0] {
                    samples.withUnsafeBufferPointer { ptr in
                        if let base = ptr.baseAddress { ch.initialize(from: base, count: samples.count) }
                    }
                    append(srcBuf)
                }
            }

            let reader = Task { [weak self] in
                do {
                    for try await r in transcriber.results {
                        guard let self else { break }
                        let valid = self.lock.withLock { !self.stopped && gen == self.generation }
                        if !valid { break }
                        let text = String(r.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        self.lock.withLock {
                            if r.isFinal {
                                self.lastVolatile = ""
                                self.lastCutThrough = max(self.lastCutThrough, CMTimeGetSeconds(r.range.end))
                            } else {
                                if text != self.lastVolatile {
                                    self.lastVolatileAt = Date()
                                }
                                self.lastVolatile = text
                            }
                        }
                        self.onResult(RecognizedSegment(
                            text: text,
                            isFinal: r.isFinal,
                            lang: langCode,
                            cut: false
                        ))
                    }
                } catch {
                    guard let self else { return }
                    let valid = self.lock.withLock { !self.stopped && gen == self.generation }
                    if valid {
                        self.onError("语音识别异常：\(error.localizedDescription)")
                    }
                }
            }

            // Periodically finalize completed sentences so subtitles and translations commit briskly
            let cutter = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard let self else { break }
                    let cutPoint: Double? = self.lock.withLock {
                        guard !self.stopped && gen == self.generation && !self.cutting else { return nil }
                        let draft = self.lastVolatile
                        guard !draft.isEmpty else { return nil }
                        let deltaAudio = self.fedSeconds - self.lastCutThrough
                        guard deltaAudio >= 0.4 else { return nil }
                        let age = Date().timeIntervalSince(self.lastVolatileAt)
                        let hasCJK = draft.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                        let size = hasCJK ? draft.count : draft.split(separator: " ").count
                        let endsSentence = draft.last.map { "。！？.!?".contains($0) } ?? false

                        if endsSentence && size >= (hasCJK ? 8 : 5) {
                            self.cutting = true
                            return self.fedSeconds
                        }
                        if size >= (hasCJK ? 18 : 11) && age >= 0.55 {
                            self.cutting = true
                            return self.fedSeconds
                        }
                        if size >= (hasCJK ? 34 : 22) && deltaAudio >= 2.0 {
                            self.cutting = true
                            return self.fedSeconds
                        }
                        return nil
                    }
                    if let through = cutPoint {
                        try? await newAnalyzer.finalize(through: CMTime(seconds: through, preferredTimescale: 1000))
                        self.lock.withLock {
                            self.lastCutThrough = max(self.lastCutThrough, through)
                            self.cutting = false
                        }
                    }
                }
            }

            lock.withLock {
                readerTask = reader
                cutTask = cutter
            }
        } catch {
            let valid = lock.withLock { !stopped && gen == generation }
            if valid {
                onError("无法启动设备端语音模型（\(langCode)）：\(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Legacy macOS 14.4–15 SFSpeechRecognizer Fallback

private final class LegacySpeechStream {
    private let queue = DispatchQueue(label: "com.verba.speechstream.legacy")
    private var langCode: String
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var sessionStartedAt = Date()
    private var lastTranscript = ""
    private var committedPrefix = ""
    private var running = false
    private var rotating = false
    private var onResult: ((RecognizedSegment) -> Void)?
    private var onError: ((String) -> Void)?

    init(langCode: String) {
        self.langCode = langCode == "auto" ? "en" : langCode
    }

    func start(onResult: @escaping (RecognizedSegment) -> Void, onError: @escaping (String) -> Void) {
        queue.sync {
            self.onResult = onResult
            self.onError = onError
            self.running = true
            self.openSessionLocked(replaySamples: nil)
        }
    }

    func switchLanguage(to newCode: String, replaySamples: [Float]) {
        let resolved = newCode == "auto" ? "en" : newCode
        queue.async { [weak self] in
            guard let self, self.running, resolved != self.langCode else { return }
            self.flushFinalLocked(cut: true)
            self.langCode = resolved
            self.openSessionLocked(replaySamples: replaySamples)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            if !self.rotating && Date().timeIntervalSince(self.sessionStartedAt) >= 50 {
                self.rotateSessionLocked()
            }
            self.request?.append(buffer)
        }
    }

    func stop() {
        queue.sync {
            self.running = false
            self.flushFinalLocked(cut: true)
            self.teardownLocked()
            self.onResult = nil
            self.onError = nil
        }
    }

    private func teardownLocked() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        recognizer = nil
        lastTranscript = ""
        committedPrefix = ""
    }

    private func flushFinalLocked(cut: Bool) {
        let trimmed = remainingTailLocked()
        if !trimmed.isEmpty {
            onResult?(RecognizedSegment(text: trimmed, isFinal: true, lang: langCode, cut: cut))
        }
        lastTranscript = ""
        committedPrefix = ""
    }

    private func remainingTailLocked() -> String {
        let raw = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        if !committedPrefix.isEmpty, raw.hasPrefix(committedPrefix) {
            return String(raw.dropFirst(committedPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    private func rotateSessionLocked() {
        rotating = true
        flushFinalLocked(cut: false)
        openSessionLocked(replaySamples: nil)
        rotating = false
    }

    private func openSessionLocked(replaySamples: [Float]?) {
        teardownLocked()
        let locale = Languages.locale(for: langCode)
        let rec = SFSpeechRecognizer(locale: locale)
        guard let rec, rec.isAvailable else { return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        if rec.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }

        recognizer = rec
        request = req
        sessionStartedAt = Date()
        let genLanguage = langCode

        if let samples = replaySamples, !samples.isEmpty,
           let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
           let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count)) {
            buf.frameLength = AVAudioFrameCount(samples.count)
            if let ch = buf.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { ptr in
                    if let base = ptr.baseAddress { ch.initialize(from: base, count: samples.count) }
                }
                req.append(buf)
            }
        }

        task = rec.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                guard self.running else { return }
                if let result {
                    let formatted = result.bestTranscription.formattedString
                    self.lastTranscript = formatted
                    let delta = self.remainingTailLocked()
                    if !delta.isEmpty {
                        self.onResult?(RecognizedSegment(
                            text: delta,
                            isFinal: result.isFinal,
                            lang: genLanguage,
                            cut: false
                        ))
                        if result.isFinal {
                            self.committedPrefix = formatted
                        }
                    }
                    if result.isFinal {
                        self.openSessionLocked(replaySamples: nil)
                    }
                } else if let error {
                    if SpeechPermission.isDictationBlockedError(error) {
                        self.running = false
                        self.onError?("旧版语音识别需要在「系统设置 → 键盘」中打开听写或 Siri。")
                        return
                    }
                    self.flushFinalLocked(cut: true)
                    self.openSessionLocked(replaySamples: nil)
                }
            }
        }
    }
}

// MARK: - Language Auto-Detector

final class LanguageDetector {
    private let recognizer = NLLanguageRecognizer()

    func detectLanguageCode(for text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return fallback }

        let hasKana = trimmed.unicodeScalars.contains { s in
            (0x3040...0x309F).contains(s.value) || (0x30A0...0x30FF).contains(s.value)
        }
        if hasKana { return "ja" }

        let hasHangul = trimmed.unicodeScalars.contains { s in
            (0xAC00...0xD7AF).contains(s.value) || (0x1100...0x11FF).contains(s.value)
        }
        if hasHangul { return "ko" }

        let hasCJK = trimmed.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        if hasCJK { return "zh-CN" }

        recognizer.reset()
        recognizer.processString(trimmed)
        if let dom = recognizer.dominantLanguage {
            switch dom {
            case .english: return "en"
            case .simplifiedChinese: return "zh-CN"
            case .traditionalChinese: return "zh-TW"
            case .japanese: return "ja"
            case .korean: return "ko"
            case .spanish: return "es"
            case .french: return "fr"
            case .german: return "de"
            case .portuguese: return "pt"
            default: break
            }
        }
        return fallback
    }
}
