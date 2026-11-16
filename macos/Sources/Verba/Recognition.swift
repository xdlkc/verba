import AVFoundation
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
    static func ensureAuthorized() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { return true }
        if current == .denied || current == .restricted { return false }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }
}

// MARK: - Rolling On-Device Speech Recognizer Stream

final class OnDeviceSpeechStream {
    private let queue = DispatchQueue(label: "com.verba.speechstream")
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

    init(langCode: String) {
        self.langCode = langCode == "auto" ? "en" : langCode
    }

    func start(onResult: @escaping (RecognizedSegment) -> Void) {
        queue.sync {
            self.onResult = onResult
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
                // Proactively rotate before Apple's ~60s on-device recognition cap
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
                    if let base = ptr.baseAddress {
                        ch.initialize(from: base, count: samples.count)
                    }
                }
                req.append(buf)
            }
        }

        let createdTask = rec.recognitionTask(with: req) { [weak self] result, error in
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
                } else if error != nil {
                    self.flushFinalLocked(cut: true)
                    self.openSessionLocked(replaySamples: nil)
                }
            }
        }
        task = createdTask
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
