import AVFoundation
import Foundation
import Speech

struct ImportProgress: Equatable {
    let sessionId: String?
    let fileName: String
    let fraction: Double
    let status: String
    let error: String?
}

enum FileImportError: LocalizedError {
    case unreadableAsset
    case noAudioTrack
    case speechNotAuthorized
    case recognizerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unreadableAsset: return "无法读取音视频文件"
        case .noAudioTrack: return "文件中未找到音频轨道"
        case .speechNotAuthorized: return "未授予语音识别权限，请在系统设置中允许 Verba"
        case .recognizerUnavailable(let lang): return "当前系统暂不支持离线识别语言：\(lang)"
        }
    }
}

enum FileImporter {
    static func importMedia(
        url: URL,
        sourceLang: String,
        backend: BackendClient,
        onProgress: @escaping @MainActor (ImportProgress) -> Void
    ) async throws -> SessionDetail? {
        let granted = await SpeechPermission.ensureAuthorized()
        guard granted else { throw FileImportError.speechNotAuthorized }

        let asset = AVURLAsset(url: url)
        let durationCM = try await asset.load(.duration)
        let durationSecs = max(CMTimeGetSeconds(durationCM), 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw FileImportError.noAudioTrack }

        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let createdAt = attrs?[.creationDate] as? Date

        await onProgress(ImportProgress(
            sessionId: nil,
            fileName: url.lastPathComponent,
            fraction: 0.04,
            status: "正在准备会话…",
            error: nil
        ))

        let begin = try await backend.beginImport(
            fileName: url.lastPathComponent,
            sourcePath: url.path,
            recordedAt: createdAt,
            durationSeconds: durationSecs
        )
        let sessionID = begin.session.id

        // Copy lightweight playable audio copy for synced playback inside Verba session folder if possible
        await copyPlayableAudioIfPossible(asset: asset, toFolder: URL(fileURLWithPath: begin.audioFolder))

        let resolvedLang = sourceLang == "auto" ? "en" : sourceLang
        if !SpeechPermission.usesSpeechAnalyzer {
            guard let recognizer = SFSpeechRecognizer(locale: Languages.locale(for: resolvedLang)),
                  recognizer.isAvailable else {
                throw FileImportError.recognizerUnavailable(resolvedLang)
            }
        }

        // Read audio in 35-second chunks and run on-device recognition per chunk
        let chunkSecs = 35.0
        let totalChunks = max(Int(ceil(durationSecs / chunkSecs)), 1)

        for idx in 0..<totalChunks {
            if Task.isCancelled { break }
            let startSec = Double(idx) * chunkSecs
            let endSec = min(durationSecs, startSec + chunkSecs)
            let range = CMTimeRange(
                start: CMTime(seconds: startSec, preferredTimescale: 600),
                duration: CMTime(seconds: max(endSec - startSec, 0.1), preferredTimescale: 600)
            )

            await onProgress(ImportProgress(
                sessionId: sessionID,
                fileName: url.lastPathComponent,
                fraction: 0.08 + 0.68 * (Double(idx) / Double(totalChunks)),
                status: "正在本地转写（\(idx + 1)/\(totalChunks)）…",
                error: nil
            ))

            let pcmBuffers = try extract16kHzPCM(asset: asset, tracks: tracks, timeRange: range)
            if !pcmBuffers.isEmpty {
                let text = try await OnDeviceSpeechStream.transcribeBuffers(pcmBuffers, langCode: resolvedLang)
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    let detector = LanguageDetector()
                    let detLang = sourceLang == "auto"
                        ? detector.detectLanguageCode(for: cleaned, fallback: resolvedLang)
                        : resolvedLang
                    try await backend.postImportPiece(
                        sessionId: sessionID,
                        text: cleaned,
                        t: startSec,
                        lang: detLang
                    )
                }
            }
        }

        await onProgress(ImportProgress(
            sessionId: sessionID,
            fileName: url.lastPathComponent,
            fraction: 0.82,
            status: "正在调用本地 Loom 批量翻译并生成纪要…",
            error: nil
        ))

        let finished = try await backend.finishImport(
            sessionId: sessionID,
            generateNotes: true,
            translateAll: true
        )

        await onProgress(ImportProgress(
            sessionId: sessionID,
            fileName: url.lastPathComponent,
            fraction: 1.0,
            status: "导入完成",
            error: nil
        ))

        return finished.session
    }

    private static func copyPlayableAudioIfPossible(asset: AVURLAsset, toFolder folder: URL) async {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dst = folder.appendingPathComponent("system.m4a")
        guard !FileManager.default.fileExists(atPath: dst.path),
              let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return
        }
        exporter.outputURL = dst
        exporter.outputFileType = .m4a
        await exporter.export()
    }

    private static func extract16kHzPCM(
        asset: AVAsset,
        tracks: [AVAssetTrack],
        timeRange: CMTimeRange
    ) throws -> [AVAudioPCMBuffer] {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw FileImportError.unreadableAsset }
        reader.add(output)
        guard reader.startReading() else { throw FileImportError.unreadableAsset }

        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        var result: [AVAudioPCMBuffer] = []

        while reader.status == .reading, let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var totalLen = 0
            var dataPtr: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &totalLen, dataPointerOut: &dataPtr)
            let frameCount = totalLen / MemoryLayout<Float>.size
            guard frameCount > 0, let ptr = dataPtr,
                  let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frameCount)) else { continue }
            pcm.frameLength = AVAudioFrameCount(frameCount)
            if let ch = pcm.floatChannelData?[0] {
                ptr.withMemoryRebound(to: Float.self, capacity: frameCount) { fPtr in
                    ch.initialize(from: fPtr, count: frameCount)
                }
                result.append(pcm)
            }
        }
        return result
    }
}
