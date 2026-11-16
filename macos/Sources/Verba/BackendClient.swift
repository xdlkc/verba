import Foundation

// MARK: - Wire Models Matching verba-engine JSON

struct LineFix: Codable, Equatable, Hashable {
    let from: String
    let to: String
    let ask: Bool?
    let off: Bool?
    let user: Bool?

    var isApplied: Bool { ask != true && off != true }
    var isPendingAsk: Bool { ask == true && off != true }
}

struct TranscriptLine: Codable, Identifiable, Equatable {
    let id: String
    let t: Double
    let speaker: String
    let src: String
    var dst: String?
    let srcLang: String
    let dstLang: String
    let voice: Int?
    let via: String?
    var fixes: [LineFix]?

    var shown: String {
        guard let fixes, !fixes.isEmpty else { return src }
        var text = src
        let ordered = fixes.filter { $0.user != true } + fixes.filter { $0.user == true }
        for f in ordered where f.isApplied && !f.from.isEmpty {
            if let range = text.range(of: f.from) {
                text.replaceSubrange(range, with: f.to)
            }
        }
        return text
    }

    var pendingAsks: [LineFix] {
        (fixes ?? []).filter { $0.isPendingAsk }
    }
}

struct FishboneBranch: Codable, Equatable {
    let label: String
    let detail: String
    let t: Double?
    let support: Int
}

struct Fishbone: Codable, Equatable {
    let question: String
    let branches: [FishboneBranch]
}

struct NoteTopic: Codable, Equatable, Identifiable {
    var id: String { "\(start)-\(title)" }
    let start: Double
    let title: String
    let summary: String
    let points: [String]
    let fishbone: Fishbone?
    let pointTimes: [Double?]?

    func pointTime(at index: Int) -> Double? {
        guard let pt = pointTimes, index >= 0, index < pt.count else { return nil }
        return pt[index]
    }
}

struct NoteItem: Codable, Equatable, Identifiable {
    var id: String { "\(text)-\(owner ?? "")" }
    let text: String
    let owner: String?
    let support: Int
    let t: Double?

    var withOwner: String {
        if let owner, !owner.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\(text)（\(owner)）"
        }
        return text
    }
}

struct NoteTerm: Codable, Equatable, Identifiable {
    var id: String { name }
    let name: String
    let note: String
    let heard: [String]
}

struct MeetingNotes: Codable, Equatable {
    let title: String?
    let summary: String
    let topics: [NoteTopic]
    let conclusions: [NoteItem]
    let todos: [NoteItem]
    let terms: [NoteTerm]
    let covered: Int
    let updatedAt: Date?
    let `final`: Bool

    var isEmpty: Bool { summary.isEmpty && topics.isEmpty }
}

struct SessionDetail: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let startedAt: Date
    let endedAt: Date?
    var lines: [TranscriptLine]
    var hasAudio: Bool
    var notes: MeetingNotes?
    let renamed: Bool?
    let voiceNames: [String: String]?
    let sourceFile: String?
    let sourcePath: String?
    let importing: Bool?
    let room: Bool?

    var displayTitle: String {
        let explicitlyRenamed = renamed ?? !title.hasPrefix("会议 ")
        if explicitlyRenamed { return title }
        if let name = notes?.title, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            let cal = Calendar.current
            let df = DateFormatter()
            df.dateFormat = cal.component(.year, from: startedAt) == cal.component(.year, from: Date())
                ? "M月d日" : "yyyy年M月d日"
            return "\(df.string(from: startedAt)) \(name)"
        }
        if let file = sourceFile {
            return URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent
        }
        return title
    }

    var durationSeconds: Double {
        max(0, (endedAt ?? Date()).timeIntervalSince(startedAt))
    }

    func speakerLabel(for line: TranscriptLine) -> String {
        if line.speaker == "me" { return "我" }
        if let v = line.voice {
            if let named = voiceNames?[String(v)], !named.isEmpty { return named }
            return "说话人 \(v)"
        }
        if line.via == "room" { return "现场" }
        return "对方"
    }
}

struct SessionSummary: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let displayTitle: String
    let startedAt: Date
    let endedAt: Date?
    let durationSeconds: Double
    let lineCount: Int
    let hasAudio: Bool
    let hasNotes: Bool
    let importing: Bool
    let sourceFile: String?
    let room: Bool
    let languagePair: String?
}

struct DraftSubtitle: Codable, Equatable {
    let speaker: String
    let src: String
    var dst: String?
    let srcLang: String
    let dstLang: String
    let t: Double
    let voice: Int?
    let via: String?
}

struct LoomModelInfo: Codable, Identifiable, Equatable, Hashable {
    let id: String
    let provider: String
    let ownedBy: String?
}

struct LoomStatus: Codable, Equatable {
    let connected: Bool
    let runtime: String?
    let keyPresent: Bool
    let loomUrl: String
    let models: [LoomModelInfo]
    let activeTranslateModel: String?
    let activeNotesModel: String?
    let lastError: String?
    let checkedAt: Date?
}

struct LoomCallRecord: Codable, Identifiable, Equatable {
    var id: String { "\(at.timeIntervalSince1970)-\(model)-\(role)-\(latencyMs)" }
    let at: Date
    let model: String
    let role: String
    let latencyMs: UInt64
    let outcome: String
    let promptTokens: UInt64
    let completionTokens: UInt64
}

struct VocabEntry: Codable, Identifiable, Equatable {
    var id: String { word }
    var word: String
    var heard: [String]
    var source: String
    var fixes: UInt32
    var used: Date?
}

struct AppSettings: Codable, Equatable {
    var loomUrl: String
    var loomDataDir: String
    var translateModel: String
    var notesModel: String
    var sourceLang: String
    var targetLang: String
    var notesLang: String
    var loomOnly: Bool
    var draftTranslate: Bool
    var liveFixEnabled: Bool
    var overlayMode: String
    var overlayHideAfter: Double
    var notesCapturable: Bool
    var exportEnabled: Bool
    var exportFolder: String
    var vocabulary: [VocabEntry]
}

struct ObsidianVault: Codable, Identifiable, Equatable {
    var id: String { path }
    let name: String
    let path: String
}

struct SearchHit: Codable, Identifiable, Equatable {
    var id: String { "\(sessionId)-\(lineId ?? "notes")-\(t ?? -1)-\(text)" }
    let sessionId: String
    let sessionTitle: String
    let lineId: String?
    let t: Double?
    let kind: String
    let text: String
    let translation: String?
    let homophoneMatch: Bool
}

struct ExportIndex: Codable, Equatable {
    let folder: String
    let files: [String: String]
    let lastFile: String?
    let lastAt: Date?
}

struct StatePayload: Codable {
    let version: String
    let dataDir: String
    let listening: Bool
    let liveSessionId: String?
    let draft: DraftSubtitle?
    let loom: LoomStatus
    let recentCalls: [LoomCallRecord]
    let settings: AppSettings
    let sessions: [SessionSummary]
    let liveSession: SessionDetail?
}

struct LoomCheckResponse: Codable {
    let status: LoomStatus
    let recentCalls: [LoomCallRecord]
}

struct LoomTestResponse: Codable {
    let ok: Bool
    let translation: String?
    let model: String?
    let latencyMs: UInt64?
    let error: String?
}

struct ListenStartResponse: Codable {
    let session: SessionDetail
    let audioFolder: String
}

struct ListenStopResponse: Codable {
    let session: SessionDetail?
}

struct ImportBeginResponse: Codable {
    let session: SessionDetail
    let audioFolder: String
}

struct ImportFinishResponse: Codable {
    let session: SessionDetail?
}

struct VocabImportResponse: Codable {
    let imported: Int
    let settings: AppSettings
}

enum ServerEvent: Decodable {
    case stateChanged
    case loomStatus(LoomStatus)
    case settingsUpdated(AppSettings)
    case draftUpdated(DraftSubtitle?)
    case lineUpdated(sessionId: String, line: TranscriptLine)
    case notesUpdated(sessionId: String, notes: MeetingNotes)
    case sessionUpdated(sessionId: String, session: SessionDetail)
    case sessionsChanged

    enum CodingKeys: String, CodingKey {
        case type, status, settings, draft, sessionId, line, notes, session
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .type)
        switch kind {
        case "stateChanged":
            self = .stateChanged
        case "loomStatus":
            self = .loomStatus(try c.decode(LoomStatus.self, forKey: .status))
        case "settingsUpdated":
            self = .settingsUpdated(try c.decode(AppSettings.self, forKey: .settings))
        case "draftUpdated":
            self = .draftUpdated(try c.decodeIfPresent(DraftSubtitle.self, forKey: .draft))
        case "lineUpdated":
            self = .lineUpdated(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                line: try c.decode(TranscriptLine.self, forKey: .line)
            )
        case "notesUpdated":
            self = .notesUpdated(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                notes: try c.decode(MeetingNotes.self, forKey: .notes)
            )
        case "sessionUpdated":
            self = .sessionUpdated(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                session: try c.decode(SessionDetail.self, forKey: .session)
            )
        case "sessionsChanged":
            self = .sessionsChanged
        default:
            self = .stateChanged
        }
    }
}

// MARK: - HTTP + SSE Client & Bundled Engine Supervisor

final class BackendClient {
    let baseURL: URL
    let port: Int

    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var engineProcess: Process?
    private var ownsProcess = false
    private var sseTask: Task<Void, Never>?

    init(port: Int = 4391) {
        self.port = port
        self.baseURL = URL(string: "http://127.0.0.1:\(port)")!

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 3600
        cfg.connectionProxyDictionary = [:] // Strictly loopback, never touch proxy
        self.session = URLSession(configuration: cfg)

        let dec = JSONDecoder()
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        dec.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let str = try container.decode(String.self)
            if let d = f1.date(from: str) ?? f2.date(from: str) {
                return d
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(str)")
        }
        self.decoder = dec

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
    }

    func ensureRunning() async -> Bool {
        if await ping() {
            return true
        }
        guard let binURL = resolveEngineBinary() else {
            return false
        }
        let proc = Process()
        proc.executableURL = binURL
        proc.arguments = ["serve", "--port", "\(port)"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            engineProcess = proc
            ownsProcess = true
        } catch {
            return false
        }
        for _ in 0..<40 {
            if await ping() {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return await ping()
    }

    func shutdownOwnedEngine() {
        sseTask?.cancel()
        sseTask = nil
        if ownsProcess, let p = engineProcess, p.isRunning {
            p.terminate()
        }
        engineProcess = nil
    }

    private func resolveEngineBinary() -> URL? {
        if let env = ProcessInfo.processInfo.environment["VERBA_ENGINE_BIN"], !env.isEmpty,
           FileManager.default.isExecutableFile(atPath: env) {
            return URL(fileURLWithPath: env)
        }
        let exeDir = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates: [URL?] = [
            exeDir?.appendingPathComponent("verba-engine"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/verba-engine"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("target/release/verba-engine"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("target/debug/verba-engine"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent().appendingPathComponent("target/release/verba-engine"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent().appendingPathComponent("target/debug/verba-engine"),
        ]
        for case let url? in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        return nil
    }

    func ping() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/health"))
        req.timeoutInterval = 1.5
        do {
            let (_, resp) = try await session.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    func startSSE(onEvent: @escaping @MainActor (ServerEvent) -> Void) {
        sseTask?.cancel()
        sseTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let url = self.baseURL.appendingPathComponent("api/events")
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 3600
                    let (bytes, resp) = try await self.session.bytes(for: req)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        continue
                    }
                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        guard let data = payload.data(using: .utf8),
                              let ev = try? self.decoder.decode(ServerEvent.self, from: data) else { continue }
                        await onEvent(ev)
                    }
                } catch {
                    if Task.isCancelled { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    // MARK: - API Calls

    func getState() async throws -> StatePayload {
        try await request("GET", path: "api/state", body: Optional<Int>.none)
    }

    func checkLoom(loomUrl: String? = nil, loomDataDir: String? = nil) async throws -> LoomCheckResponse {
        struct Body: Encodable { let loomUrl: String?; let loomDataDir: String? }
        return try await request("POST", path: "api/loom/check", body: Body(loomUrl: loomUrl, loomDataDir: loomDataDir))
    }

    func testLoom(text: String? = nil) async throws -> LoomTestResponse {
        struct Body: Encodable { let text: String? }
        return try await request("POST", path: "api/loom/test", body: Body(text: text))
    }

    func saveSettings(_ patch: [String: Any]) async throws -> AppSettings {
        let data = try JSONSerialization.data(withJSONObject: patch)
        return try await rawJSON("POST", path: "api/settings", jsonData: data)
    }

    func confirmVocab(heard: String, word: String, source: String = "user") async throws -> AppSettings {
        struct Body: Encodable { let heard: String; let word: String; let source: String }
        return try await request("POST", path: "api/vocabulary/confirm", body: Body(heard: heard, word: word, source: source))
    }

    func importVocab(text: String) async throws -> VocabImportResponse {
        struct Body: Encodable { let text: String }
        return try await request("POST", path: "api/vocabulary/import", body: Body(text: text))
    }

    func obsidianVaults() async throws -> [ObsidianVault] {
        try await request("GET", path: "api/obsidian-vaults", body: Optional<Int>.none)
    }

    func startListening(room: Bool, sourceLang: String? = nil, targetLang: String? = nil) async throws -> ListenStartResponse {
        struct Body: Encodable { let room: Bool; let sourceLang: String?; let targetLang: String? }
        return try await request("POST", path: "api/listen/start", body: Body(room: room, sourceLang: sourceLang, targetLang: targetLang))
    }

    func stopListening(keepEmptyWithAudio: Bool = true, generateFinalNotes: Bool = true) async throws -> ListenStopResponse {
        struct Body: Encodable { let keepEmptyWithAudio: Bool; let generateFinalNotes: Bool }
        return try await request("POST", path: "api/listen/stop", body: Body(keepEmptyWithAudio: keepEmptyWithAudio, generateFinalNotes: generateFinalNotes))
    }

    func postPiece(text: String, speaker: String, isFinal: Bool, lang: String, via: String, cut: Bool, t: Double? = nil) async throws {
        struct Body: Encodable {
            let text: String; let speaker: String; let isFinal: Bool
            let lang: String; let via: String; let cut: Bool; let t: Double?
        }
        let body = Body(text: text, speaker: speaker, isFinal: isFinal, lang: lang, via: via, cut: cut, t: t)
        _ = try await rawData("POST", path: "api/listen/piece", jsonData: try encoder.encode(body))
    }

    func getSession(id: String) async throws -> SessionDetail {
        try await request("GET", path: "api/sessions/\(id)", body: Optional<Int>.none)
    }

    func renameSession(id: String, title: String) async throws -> SessionDetail {
        struct Body: Encodable { let title: String }
        return try await request("PATCH", path: "api/sessions/\(id)", body: Body(title: title))
    }

    func setVoiceName(id: String, voice: Int, name: String) async throws -> SessionDetail {
        struct Body: Encodable { let voice: Int; let voiceName: String }
        return try await request("PATCH", path: "api/sessions/\(id)", body: Body(voice: voice, voiceName: name))
    }

    func setHasAudio(id: String, hasAudio: Bool) async throws -> SessionDetail {
        struct Body: Encodable { let hasAudio: Bool }
        return try await request("PATCH", path: "api/sessions/\(id)", body: Body(hasAudio: hasAudio))
    }

    func deleteSession(id: String) async throws {
        _ = try await rawData("DELETE", path: "api/sessions/\(id)", jsonData: nil)
    }

    func generateNotes(sessionId: String, fresh: Bool = false, isFinal: Bool? = nil) async throws -> MeetingNotes {
        struct Body: Encodable { let isFinal: Bool?; let fresh: Bool }
        return try await request("POST", path: "api/sessions/\(sessionId)/notes", body: Body(isFinal: isFinal, fresh: fresh))
    }

    func retranslateSession(id: String) async throws {
        _ = try await rawData("POST", path: "api/sessions/\(id)/retranslate", jsonData: Data("{}".utf8))
    }

    func fixLineAction(sessionId: String, lineId: String, action: String, from: String, to: String) async throws {
        struct Body: Encodable { let action: String; let from: String; let to: String }
        _ = try await rawData(
            "POST",
            path: "api/sessions/\(sessionId)/lines/\(lineId)/fix",
            jsonData: try encoder.encode(Body(action: action, from: from, to: to))
        )
    }

    func editLineText(sessionId: String, lineId: String, editedText: String, applyAll: Bool) async throws {
        struct Body: Encodable { let action: String; let editedText: String; let applyAll: Bool }
        _ = try await rawData(
            "POST",
            path: "api/sessions/\(sessionId)/lines/\(lineId)/fix",
            jsonData: try encoder.encode(Body(action: "edit", editedText: editedText, applyAll: applyAll))
        )
    }

    func beginImport(fileName: String, sourcePath: String, recordedAt: Date?, durationSeconds: Double) async throws -> ImportBeginResponse {
        struct Body: Encodable { let fileName: String; let sourcePath: String; let recordedAt: Date?; let durationSeconds: Double }
        return try await request("POST", path: "api/import/begin", body: Body(fileName: fileName, sourcePath: sourcePath, recordedAt: recordedAt, durationSeconds: durationSeconds))
    }

    func postImportPiece(sessionId: String, text: String, t: Double, lang: String) async throws {
        struct Body: Encodable { let text: String; let t: Double; let lang: String }
        _ = try await rawData("POST", path: "api/import/\(sessionId)/piece", jsonData: try encoder.encode(Body(text: text, t: t, lang: lang)))
    }

    func finishImport(sessionId: String, generateNotes: Bool, translateAll: Bool) async throws -> ImportFinishResponse {
        struct Body: Encodable { let generateNotes: Bool; let translateAll: Bool }
        return try await request("POST", path: "api/import/\(sessionId)/finish", body: Body(generateNotes: generateNotes, translateAll: translateAll))
    }

    func search(query: String, sessionId: String? = nil) async throws -> [SearchHit] {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/search"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "q", value: query)]
        if let sessionId { items.append(URLQueryItem(name: "session_id", value: sessionId)) }
        comps.queryItems = items
        let (data, _) = try await session.data(from: comps.url!)
        return try decoder.decode([SearchHit].self, from: data)
    }

    func exportSession(id: String, format: String) async throws -> String {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/sessions/\(id)/export"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "format", value: format)]
        let (data, _) = try await session.data(from: comps.url!)
        return String(decoding: data, as: UTF8.self)
    }

    func syncExport(folder: String? = nil) async throws -> ExportIndex {
        struct Body: Encodable { let folder: String? }
        return try await request("POST", path: "api/export/sync", body: Body(folder: folder))
    }

    // MARK: - Helpers

    private func request<B: Encodable, R: Decodable>(_ method: String, path: String, body: B?) async throws -> R {
        let jsonData = try body.map { try encoder.encode($0) }
        return try await rawJSON(method, path: path, jsonData: jsonData)
    }

    private func rawJSON<R: Decodable>(_ method: String, path: String, jsonData: Data?) async throws -> R {
        let data = try await rawData(method, path: path, jsonData: jsonData)
        return try decoder.decode(R.self, from: data)
    }

    private func rawData(_ method: String, path: String, jsonData: Data?) async throws -> Data {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        if let jsonData {
            req.httpBody = jsonData
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? String(decoding: data, as: UTF8.self)
            throw NSError(domain: "VerbaBackend", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: msg])
        }
        return data
    }
}
