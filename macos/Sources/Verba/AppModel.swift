import AVFoundation
import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    let backend = BackendClient()

    // Backend-mirrored state
    @Published var engineReady = false
    @Published var dataDir = ""
    @Published var listening = false
    @Published var roomMicEnabled = false
    @Published var selectedRoomMicID: UInt32?
    @Published var liveSession: SessionDetail?
    @Published var draft: DraftSubtitle?
    @Published var loomStatus: LoomStatus?
    @Published var recentCalls: [LoomCallRecord] = []
    @Published var settings = AppSettings(
        loomUrl: "http://127.0.0.1:4319/v1",
        loomDataDir: "",
        translateModel: "",
        notesModel: "",
        sourceLang: "auto",
        targetLang: "zh-CN",
        notesLang: "Simplified Chinese",
        loomOnly: true,
        draftTranslate: true,
        liveFixEnabled: true,
        overlayMode: "auto",
        overlayHideAfter: 4.0,
        notesCapturable: false,
        exportEnabled: false,
        exportFolder: "",
        vocabulary: []
    )
    @Published var sessions: [SessionSummary] = []
    @Published var obsidianVaults: [ObsidianVault] = []

    // UI selection & status
    @Published var selectedSessionId: String?
    @Published var selectedSession: SessionDetail?
    @Published var notesLoading = false
    @Published var notesError: String?
    @Published var lastError: String?
    @Published var systemAudioDenied = false
    @Published var audioLevel: Float = 0
    @Published var importProgress: ImportProgress?

    // Overlay visibility & mode
    @Published var overlayVisible = false
    @Published var overlayLastSpeechAt = Date.distantPast
    @Published var notesOnTop = true

    // Synchronized audio playback
    @Published var playingSessionId: String?
    @Published var isPlaying = false
    @Published var playbackTime: Double = 0
    @Published var playbackDuration: Double = 0
    @Published var playbackRate: Float = 1.0

    // Audio & speech capture pipeline
    private let router = AudioRouter()
    private let systemTap = SystemAudioTap()
    private let roomMic = RoomMic()
    private var sysSpeech: OnDeviceSpeechStream?
    private var roomSpeech: OnDeviceSpeechStream?
    private let langDetector = LanguageDetector()
    private var lastAutoSwitchAt = Date.distantPast
    private var currentActiveLang = "en"
    private var lastDraftSentAt = Date.distantPast
    private var draftSendInFlight = false
    private var lastLocalDraftAt = Date.distantPast
    private var lastFinalPostTask: Task<Void, Never>?

    private var player: AVAudioPlayer?
    private var playbackTimer: Timer?
    private var notesTicker: Task<Void, Never>?
    private var bootStarted = false

    // Window callbacks wired by VerbaApp
    var onOpenNotesWindow: (() -> Void)?
    var onOpenMainWindow: (() -> Void)?
    var onOpenSettingsWindow: (() -> Void)?
    var onOverlayUpdated: (() -> Void)?
    var onToggleOverlayManual: (() -> Void)?
    var onEditOverlay: (() -> Void)?

    func bootstrap() {
        guard !bootStarted else { return }
        bootStarted = true
        systemAudioDenied = SystemAudioPermission.status() == .denied
        Task { [self] in
            let ok = await backend.ensureRunning()
            engineReady = ok
            guard ok else {
                lastError = "无法启动本地 Verba 引擎（verba-engine）"
                return
            }
            backend.startSSE { [weak self] ev in
                self?.handleServerEvent(ev)
            }
            await refreshState()
            if let vaults = try? await backend.obsidianVaults() {
                obsidianVaults = vaults
            }
            _ = await checkLoom()
        }
    }

    func shutdown() {
        stopPlayback()
        if listening {
            Task { await stopListening() }
        }
        backend.shutdownOwnedEngine()
    }

    func refreshState() async {
        do {
            let state = try await backend.getState()
            dataDir = state.dataDir
            listening = state.listening
            liveSession = state.liveSession
            draft = state.draft
            loomStatus = state.loom
            recentCalls = state.recentCalls
            settings = state.settings
            sessions = state.sessions
            if selectedSessionId == nil {
                selectedSessionId = state.liveSessionId ?? state.sessions.first?.id
            }
            if let sid = selectedSessionId {
                await selectSession(sid)
            }
            onOverlayUpdated?()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleServerEvent(_ ev: ServerEvent) {
        switch ev {
        case .stateChanged:
            Task { await refreshState() }
        case .loomStatus(let status):
            loomStatus = status
        case .settingsUpdated(let updated):
            settings = updated
            onOverlayUpdated?()
        case .draftUpdated(let d):
            if let d {
                if var cur = draft, cur.speaker == d.speaker, cur.src.count > d.src.count {
                    cur.dst = d.dst ?? cur.dst
                    draft = cur
                } else {
                    draft = d
                }
                markSpeechActivity()
            } else if !listening || Date().timeIntervalSince(lastLocalDraftAt) > 0.35 {
                draft = nil
            }
            onOverlayUpdated?()
        case .lineUpdated(let sid, let line):
            markSpeechActivity()
            if liveSession?.id == sid {
                if let idx = liveSession?.lines.firstIndex(where: { $0.id == line.id }) {
                    liveSession?.lines[idx] = line
                } else {
                    liveSession?.lines.append(line)
                }
            }
            if selectedSession?.id == sid {
                if let idx = selectedSession?.lines.firstIndex(where: { $0.id == line.id }) {
                    selectedSession?.lines[idx] = line
                } else {
                    selectedSession?.lines.append(line)
                }
            }
            onOverlayUpdated?()
        case .notesUpdated(let sid, let notes):
            if liveSession?.id == sid { liveSession?.notes = notes }
            if selectedSession?.id == sid { selectedSession?.notes = notes }
        case .sessionUpdated(let sid, let s):
            if liveSession?.id == sid { liveSession = s }
            if selectedSession?.id == sid { selectedSession = s }
            if let idx = sessions.firstIndex(where: { $0.id == sid }) {
                sessions[idx] = SessionSummary(
                    id: s.id,
                    title: s.title,
                    displayTitle: s.displayTitle,
                    startedAt: s.startedAt,
                    endedAt: s.endedAt,
                    durationSeconds: s.durationSeconds,
                    lineCount: s.lines.count,
                    hasAudio: s.hasAudio,
                    hasNotes: s.notes.map { !$0.isEmpty } ?? false,
                    importing: s.importing == true,
                    sourceFile: s.sourceFile,
                    room: s.room == true,
                    languagePair: sessions[idx].languagePair
                )
            }
            onOverlayUpdated?()
        case .sessionsChanged:
            Task {
                if let state = try? await backend.getState() {
                    sessions = state.sessions
                    liveSession = state.liveSession
                    listening = state.listening
                    if let sid = selectedSessionId, let refreshed = try? await backend.getSession(id: sid) {
                        selectedSession = refreshed
                    } else if selectedSessionId == nil, let first = sessions.first?.id {
                        await selectSession(first)
                    }
                }
            }
        }
    }

    // MARK: - Live Listening

    func toggleListening() {
        Task {
            if listening {
                await stopListening()
            } else {
                await startListening()
            }
        }
    }

    func startListening() async {
        lastError = nil
        if !engineReady {
            engineReady = await backend.ensureRunning()
        }
        guard engineReady else {
            lastError = "本地引擎未就绪"
            return
        }

        let speechOK = await SpeechPermission.ensureAuthorized()
        guard speechOK else {
            lastError = "未授予语音识别权限，请在「系统设置 → 隐私与安全性 → 语音识别」中允许 Verba。"
            return
        }

        systemAudioDenied = SystemAudioPermission.status() == .denied
        if systemAudioDenied {
            lastError = "「仅系统音频录制」权限未开启，请点击「打开系统设置」授权后重启 Verba。"
            return
        }

        do {
            let started = try await backend.startListening(room: roomMicEnabled)
            listening = true
            liveSession = started.session
            selectedSessionId = started.session.id
            selectedSession = started.session
            lastDraftSentAt = .distantPast
            draftSendInFlight = false
            lastFinalPostTask = nil

            let initialLang = settings.sourceLang == "auto" ? "en" : settings.sourceLang
            currentActiveLang = initialLang

            router.beginSession(folder: URL(fileURLWithPath: started.audioFolder))
            let stream = OnDeviceSpeechStream(langCode: initialLang)
            sysSpeech = stream

            router.onLevel = { [weak self] lvl in
                Task { @MainActor [weak self] in
                    self?.audioLevel = lvl
                }
            }
            router.onSystemPCM = { [weak stream] pcm in
                stream?.append(pcm)
            }

            stream.start(
                onResult: { [weak self] seg in
                    Task { @MainActor [weak self] in
                        await self?.handleRecognizedSegment(seg, speaker: "them", via: "system")
                    }
                },
                onError: { [weak self] errMsg in
                    Task { @MainActor [weak self] in
                        self?.lastError = errMsg
                    }
                }
            )

            try systemTap.start(
                onBuffer: { [weak self] pcm in
                    self?.router.pushSystem(pcm)
                },
                onRateChange: { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.restartTapOnRateChange()
                    }
                }
            )

            if roomMicEnabled {
                let rStream = OnDeviceSpeechStream(langCode: initialLang)
                roomSpeech = rStream
                router.onRoomPCM = { [weak rStream] pcm in
                    rStream?.append(pcm)
                }
                rStream.start(
                    onResult: { [weak self] seg in
                        Task { @MainActor [weak self] in
                            await self?.handleRecognizedSegment(seg, speaker: "me", via: "room")
                        }
                    },
                    onError: { [weak self] errMsg in
                        Task { @MainActor [weak self] in
                            self?.lastError = errMsg
                        }
                    }
                )
                let devID = selectedRoomMicID.map { AudioDeviceID($0) }
                try? roomMic.start(deviceID: devID) { [weak self] pcm in
                    self?.router.pushRoom(pcm)
                }
            }

            if settings.overlayMode != "off" {
                overlayVisible = true
                overlayLastSpeechAt = Date()
            }
            onOverlayUpdated?()
            startLiveNotesTicker()
        } catch {
            lastError = error.localizedDescription
            systemTap.stop()
            roomMic.stop()
            sysSpeech?.stop()
            roomSpeech?.stop()
            sysSpeech = nil
            roomSpeech = nil
            listening = false
            _ = try? await backend.stopListening(keepEmptyWithAudio: false, generateFinalNotes: false)
        }
    }

    private func restartTapOnRateChange() async {
        guard listening else { return }
        systemTap.stop()
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard listening else { return }
        try? systemTap.start(
            onBuffer: { [weak self] pcm in
                self?.router.pushSystem(pcm)
            },
            onRateChange: { [weak self] in
                Task { @MainActor [weak self] in
                    await self?.restartTapOnRateChange()
                }
            }
        )
    }

    func stopListening() async {
        guard listening else { return }
        listening = false
        notesTicker?.cancel()
        notesTicker = nil

        systemTap.stop()
        roomMic.stop()
        sysSpeech?.stop()
        roomSpeech?.stop()
        sysSpeech = nil
        roomSpeech = nil
        audioLevel = 0

        let activeId = liveSession?.id
        let hadAudio = await router.finishSession()
        if let activeId, hadAudio {
            _ = try? await backend.setHasAudio(id: activeId, hasAudio: true)
        }

        do {
            let res = try await backend.stopListening(keepEmptyWithAudio: true, generateFinalNotes: true)
            liveSession = nil
            draft = nil
            if let ended = res.session {
                selectedSessionId = ended.id
                selectedSession = ended
            }
            if settings.overlayMode != "always" {
                overlayVisible = false
            }
            onOverlayUpdated?()
            await refreshState()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func handleRecognizedSegment(_ seg: RecognizedSegment, speaker: String, via: String) async {
        var effectiveLang = seg.lang
        if seg.isFinal, seg.text.count >= 12, settings.sourceLang == "auto", via == "system" {
            let detected = langDetector.detectLanguageCode(for: seg.text, fallback: currentActiveLang)
            if detected != currentActiveLang, Date().timeIntervalSince(lastAutoSwitchAt) > 6.0 {
                lastAutoSwitchAt = Date()
                currentActiveLang = detected
                effectiveLang = detected
                let replay = router.recentSystemSamples()
                sysSpeech?.switchLanguage(to: detected, replaySamples: replay)
                roomSpeech?.switchLanguage(to: detected, replaySamples: [])
            }
        }
        markSpeechActivity()

        if !seg.isFinal {
            lastLocalDraftAt = Date()
            let prevDst = (draft?.speaker == speaker) ? draft?.dst : nil
            draft = DraftSubtitle(
                speaker: speaker,
                src: seg.text,
                dst: prevDst,
                srcLang: effectiveLang,
                dstLang: settings.targetLang,
                t: liveSession.map { max(0, Date().timeIntervalSince($0.startedAt)) } ?? 0,
                voice: nil,
                via: via
            )
            onOverlayUpdated?()

            guard !draftSendInFlight && Date().timeIntervalSince(lastDraftSentAt) >= 0.45 else {
                return
            }
            draftSendInFlight = true
            lastDraftSentAt = Date()
            let backend = self.backend
            let text = seg.text
            let lang = effectiveLang
            Task { [weak self] in
                defer { self?.draftSendInFlight = false }
                try? await backend.postPiece(
                    text: text,
                    speaker: speaker,
                    isFinal: false,
                    lang: lang,
                    via: via,
                    cut: false
                )
            }
            return
        }

        if draft?.speaker == speaker {
            draft = nil
        }
        onOverlayUpdated?()
        let prevTask = lastFinalPostTask
        let backend = self.backend
        let text = seg.text
        let lang = effectiveLang
        let cut = seg.cut
        let task = Task {
            _ = await prevTask?.value
            try? await backend.postPiece(
                text: text,
                speaker: speaker,
                isFinal: true,
                lang: lang,
                via: via,
                cut: cut
            )
        }
        lastFinalPostTask = task
        await task.value
    }

    private func markSpeechActivity() {
        overlayLastSpeechAt = Date()
        if settings.overlayMode != "off" {
            overlayVisible = true
        }
    }

    func toggleOverlayManually() {
        if let onToggleOverlayManual {
            onToggleOverlayManual()
        } else {
            overlayVisible.toggle()
            onOverlayUpdated?()
        }
    }

    private func startLiveNotesTicker() {
        notesTicker?.cancel()
        notesTicker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                guard let self, self.listening, let s = self.liveSession else { continue }
                let covered = s.notes?.covered ?? 0
                if s.lines.count >= 6 && s.lines.count - covered >= 4 && !self.notesLoading {
                    await self.generateNotes(sessionId: s.id, fresh: false, isFinal: false)
                }
            }
        }
    }

    // MARK: - Sessions, Notes, Fixes, Settings & Loom

    func selectSession(_ id: String) async {
        selectedSessionId = id
        do {
            let s = try await backend.getSession(id: id)
            selectedSession = s
        } catch {
            lastError = error.localizedDescription
        }
    }

    func renameSession(id: String, title: String) async {
        if let s = try? await backend.renameSession(id: id, title: title) {
            if selectedSession?.id == id { selectedSession = s }
            await refreshState()
        }
    }

    func setVoiceName(id: String, voice: Int, name: String) async {
        if let s = try? await backend.setVoiceName(id: id, voice: voice, name: name) {
            if selectedSession?.id == id { selectedSession = s }
            if liveSession?.id == id { liveSession = s }
        }
    }

    func deleteSession(id: String) async {
        if playingSessionId == id { stopPlayback() }
        try? await backend.deleteSession(id: id)
        if selectedSessionId == id {
            selectedSessionId = nil
            selectedSession = nil
        }
        await refreshState()
    }

    func generateNotes(sessionId: String, fresh: Bool, isFinal: Bool? = nil) async {
        guard !notesLoading else { return }
        notesLoading = true
        notesError = nil
        defer { notesLoading = false }
        do {
            let notes = try await backend.generateNotes(sessionId: sessionId, fresh: fresh, isFinal: isFinal)
            if liveSession?.id == sessionId { liveSession?.notes = notes }
            if selectedSession?.id == sessionId { selectedSession?.notes = notes }
        } catch {
            notesError = error.localizedDescription
        }
    }

    func acceptAsk(sessionId: String, lineId: String, from: String, to: String) async {
        try? await backend.fixLineAction(sessionId: sessionId, lineId: lineId, action: "accept", from: from, to: to)
    }

    func rejectAsk(sessionId: String, lineId: String, from: String, to: String) async {
        try? await backend.fixLineAction(sessionId: sessionId, lineId: lineId, action: "reject", from: from, to: to)
    }

    func editLineText(sessionId: String, lineId: String, editedText: String, applyAll: Bool) async {
        try? await backend.editLineText(sessionId: sessionId, lineId: lineId, editedText: editedText, applyAll: applyAll)
    }

    func retranslateSession(id: String) async {
        try? await backend.retranslateSession(id: id)
    }

    @discardableResult
    func checkLoom() async -> LoomStatus? {
        do {
            let res = try await backend.checkLoom(loomUrl: settings.loomUrl, loomDataDir: settings.loomDataDir)
            loomStatus = res.status
            recentCalls = res.recentCalls
            return res.status
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func testLoom() async -> LoomTestResponse {
        do {
            return try await backend.testLoom()
        } catch {
            return LoomTestResponse(ok: false, translation: nil, model: nil, latencyMs: nil, error: error.localizedDescription)
        }
    }

    func updateSettings(_ patch: [String: Any]) async {
        do {
            settings = try await backend.saveSettings(patch)
            onOverlayUpdated?()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func importVocab(text: String) async -> Int {
        do {
            let res = try await backend.importVocab(text: text)
            settings = res.settings
            return res.imported
        } catch {
            lastError = error.localizedDescription
            return 0
        }
    }

    func syncExportFolder() async -> ExportIndex? {
        try? await backend.syncExport(folder: settings.exportFolder)
    }

    // MARK: - File Import

    func pickAndImportFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie, .mpeg4Movie, .mp3, .wav, .aiff]
        panel.message = "选择本地音频或视频文件，Verba 将通过本地 Apple 语音识别与 Loom 生成双语文字记录和会议纪要"
        if panel.runModal() == .OK, let url = panel.url {
            importMediaURL(url)
        }
    }

    func importMediaURL(_ url: URL) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let imported = try await FileImporter.importMedia(
                    url: url,
                    sourceLang: settings.sourceLang,
                    backend: backend,
                    onProgress: { [weak self] prog in
                        self?.importProgress = prog
                    }
                )
                if let imported {
                    await refreshState()
                    await selectSession(imported.id)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if importProgress?.error == nil {
                    importProgress = nil
                }
            } catch {
                importProgress = ImportProgress(
                    sessionId: nil,
                    fileName: url.lastPathComponent,
                    fraction: 0,
                    status: "导入失败",
                    error: error.localizedDescription
                )
            }
        }
    }

    // MARK: - Synced Audio Playback

    func sessionAudioURL(id: String) -> URL? {
        guard !dataDir.isEmpty else { return nil }
        let base = URL(fileURLWithPath: dataDir).appendingPathComponent("Sessions/\(id)")
        let m4a = base.appendingPathComponent("system.m4a")
        if FileManager.default.fileExists(atPath: m4a.path) { return m4a }
        let caf = base.appendingPathComponent("system.caf")
        if FileManager.default.fileExists(atPath: caf.path) { return caf }
        return nil
    }

    func playOrSeek(sessionId: String, at seconds: Double? = nil) {
        guard let url = sessionAudioURL(id: sessionId) else { return }
        if playingSessionId != sessionId || player == nil {
            stopPlayback()
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.delegate = self
                p.enableRate = true
                p.rate = playbackRate
                p.prepareToPlay()
                player = p
                playingSessionId = sessionId
                playbackDuration = p.duration
            } catch {
                lastError = "无法播放音频：\(error.localizedDescription)"
                return
            }
        }
        guard let p = player else { return }
        if let s = seconds {
            p.currentTime = max(0, min(s, p.duration))
            playbackTime = p.currentTime
        }
        p.rate = playbackRate
        p.play()
        isPlaying = true
        startPlaybackTimer()
    }

    func togglePlayPause(sessionId: String) {
        if playingSessionId == sessionId, let p = player {
            if p.isPlaying {
                p.pause()
                isPlaying = false
                playbackTimer?.invalidate()
            } else {
                p.rate = playbackRate
                p.play()
                isPlaying = true
                startPlaybackTimer()
            }
        } else {
            playOrSeek(sessionId: sessionId, at: 0)
        }
    }

    func seekAudio(to seconds: Double) {
        guard let p = player else { return }
        p.currentTime = max(0, min(seconds, p.duration))
        playbackTime = p.currentTime
    }

    func cyclePlaybackRate() {
        let rates: [Float] = [1.0, 1.25, 1.5, 2.0]
        let idx = rates.firstIndex(of: playbackRate) ?? 0
        playbackRate = rates[(idx + 1) % rates.count]
        player?.rate = playbackRate
    }

    func stopPlayback() {
        playbackTimer?.invalidate()
        playbackTimer = nil
        player?.stop()
        player = nil
        isPlaying = false
        playingSessionId = nil
        playbackTime = 0
        playbackDuration = 0
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let p = self.player else { return }
                self.playbackTime = p.currentTime
                self.playbackDuration = p.duration
                if !p.isPlaying && self.isPlaying {
                    self.isPlaying = false
                }
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.isPlaying = false
            self?.playbackTimer?.invalidate()
            self?.playbackTime = 0
        }
    }

    // MARK: - Formatting Helpers

    static func formatClock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s >= 3600 {
            return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}
