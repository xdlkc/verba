import AppKit
import SwiftUI

// MARK: - Anti-Capture Floating Notes Window (Non-Activating)

private final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var panel: NotesPanel?
    private let frameKey = "VerbaNotesWindowFrame"

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        ensurePanel()
        panel?.sharingType = model.settings.notesCapturable ? .readOnly : .none
        panel?.makeKeyAndOrderFront(nil)
    }

    func toggle() {
        if let p = panel, p.isVisible {
            p.orderOut(nil)
        } else {
            show()
        }
    }

    func syncCaptureSetting() {
        panel?.sharingType = model.settings.notesCapturable ? .readOnly : .none
    }

    private func ensurePanel() {
        if panel != nil {
            syncCaptureSetting()
            return
        }
        let rect: NSRect = {
            if let saved = UserDefaults.standard.string(forKey: frameKey) {
                let r = NSRectFromString(saved)
                if r.width >= 240 && r.height >= 260 { return r }
            }
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            return NSRect(x: screen.maxX - 420, y: screen.midY - 290, width: 390, height: 580)
        }()

        let p = NotesPanel(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.title = "Verba · 实时笔记"
        p.isFloatingPanel = true
        p.level = .floating
        p.minSize = NSSize(width: 240, height: 280)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = model.settings.notesCapturable ? .readOnly : .none
        p.delegate = self

        let hosting = NSHostingView(rootView: NotesPanelView(model: model))
        p.contentView = hosting
        panel = p
    }

    func windowDidResize(_ notification: Notification) { saveFrame() }
    func windowDidMove(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        guard let f = panel?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(f), forKey: frameKey)
    }
}

// MARK: - Responsive Notes Panel UI

struct NotesPanelView: View {
    @ObservedObject var model: AppModel
    @State private var searchQuery = ""
    @State private var showSearch = false
    @State private var searchHits: [SearchHit] = []
    @State private var highlightedLineId: String?

    private var activeSession: SessionDetail? {
        model.liveSession ?? model.selectedSession
    }

    private var pendingAsk: (sessionId: String, lineId: String, fix: LineFix)? {
        guard let s = activeSession else { return nil }
        for l in s.lines.reversed() {
            if let f = l.pendingAsks.first {
                return (s.id, l.id, f)
            }
        }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            VStack(spacing: 0) {
                headerBar(narrow: w < 310)
                if showSearch {
                    searchStrip
                }
                if let ask = pendingAsk {
                    askBanner(ask)
                }
                Divider().opacity(0.4)

                if w >= 520 {
                    HStack(spacing: 0) {
                        notesPane(narrow: false)
                            .frame(maxWidth: .infinity)
                        Divider().opacity(0.4)
                        transcriptPane
                            .frame(width: min(max(w * 0.44, 220), 400))
                    }
                } else {
                    notesPane(narrow: w < 310)
                }
            }
            .background(Color(hex: 0xF3F4F6))
        }
        .onExitCommand { showSearch = false }
    }

    private func headerBar(narrow: Bool) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.listening ? Color(hex: 0xE8552B) : Color(hex: 0x9CA3AF))
                .frame(width: 8, height: 8)
            Text(activeSession?.displayTitle ?? "尚无活动会议")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0x15171C))
                .lineLimit(1)
            Spacer()
            if !model.settings.notesCapturable {
                Label("防截屏", systemImage: "eye.slash")
                    .labelStyle(.iconOnly)
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0x5A5F6B))
                    .help("当前屏幕共享对对方不可见")
            }
            Button {
                showSearch.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("f", modifiers: .command)
            .help("在本次记录中搜索 (⌘F)")

            if let s = activeSession, !s.lines.isEmpty {
                Button {
                    Task { await model.generateNotes(sessionId: s.id, fresh: narrow ? false : false) }
                } label: {
                    if model.notesLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                    }
                }
                .buttonStyle(.borderless)
                .help("调用本地 Loom 更新纪要")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white)
    }

    private var searchStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("搜索原句、译文或中文音近词…", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onChange(of: searchQuery) { _, val in
                        guard let sid = activeSession?.id else { return }
                        Task {
                            searchHits = (try? await model.backend.search(query: val, sessionId: sid)) ?? []
                        }
                    }
                Button("关闭") {
                    showSearch = false
                    searchQuery = ""
                    searchHits = []
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            if !searchHits.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(searchHits.prefix(6)) { hit in
                            Button {
                                highlightedLineId = hit.lineId
                            } label: {
                                HStack(spacing: 4) {
                                    if let t = hit.t {
                                        Text(AppModel.formatClock(t)).monospacedDigit()
                                    }
                                    if hit.homophoneMatch {
                                        Text("音近").foregroundStyle(Color(hex: 0xE8552B))
                                    }
                                    Text(hit.text).lineLimit(1)
                                }
                                .font(.caption2)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(hex: 0xECEEF2))
    }

    private func askBanner(_ ask: (sessionId: String, lineId: String, fix: LineFix)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Color(hex: 0xE8552B))
            Text("把「\(ask.fix.from)」记成「\(ask.fix.to)」？")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color(hex: 0x15171C))
                .lineLimit(2)
            Spacer()
            Button("对") {
                Task { await model.acceptAsk(sessionId: ask.sessionId, lineId: ask.lineId, from: ask.fix.from, to: ask.fix.to) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: 0xE8552B))
            .controlSize(.small)

            Button("不用") {
                Task { await model.rejectAsk(sessionId: ask.sessionId, lineId: ask.lineId, from: ask.fix.from, to: ask.fix.to) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: 0xFFF5F1))
    }

    private func notesPane(narrow: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let err = model.notesError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                if let notes = activeSession?.notes, !notes.isEmpty {
                    StructuredNotesContent(
                        notes: notes,
                        compact: narrow,
                        onJumpToTime: { sec in
                            if let s = activeSession {
                                if s.hasAudio {
                                    model.playOrSeek(sessionId: s.id, at: sec)
                                }
                                if let nearest = s.lines.min(by: { abs($0.t - sec) < abs($1.t - sec) }) {
                                    highlightedLineId = nearest.id
                                }
                            }
                        }
                    )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.listening ? "会议纪要将在发言累积后自动生成" : "还没有纪要")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x15171C))
                        Text("Verba 会通过本地 Loom 模型自动整理摘要、议题、鱼骨图、结论、待办与术语表。")
                            .font(.caption)
                            .foregroundStyle(Color(hex: 0x5A5F6B))
                        if let s = activeSession, !s.lines.isEmpty {
                            Button("立即生成纪要") {
                                Task { await model.generateNotes(sessionId: s.id, fresh: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(hex: 0xE8552B))
                            .controlSize(.small)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(12)
        }
    }

    private var transcriptPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let s = activeSession {
                        ForEach(s.lines) { line in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(AppModel.formatClock(line.t))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Color(hex: 0x6B7080))
                                    Text(s.speakerLabel(for: line))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(line.speaker == "me" ? Color(hex: 0xE8552B) : Color(hex: 0x5A5F6B))
                                }
                                Text(line.shown)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Color(hex: 0x15171C))
                                if let dst = line.dst, !dst.isEmpty {
                                    Text(dst)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Color(hex: 0x4B5563))
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(highlightedLineId == line.id ? Color(hex: 0xFFF3EE) : Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .id(line.id)
                        }
                    }
                }
                .padding(10)
            }
            .onChange(of: highlightedLineId) { _, target in
                if let target {
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                }
            }
        }
    }
}

// MARK: - Shared Structured Notes + Fishbone View

struct StructuredNotesContent: View {
    let notes: MeetingNotes
    let compact: Bool
    let onJumpToTime: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !notes.summary.isEmpty {
                card(title: "摘要") {
                    Text(notes.summary)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color(hex: 0x15171C))
                        .lineSpacing(3)
                }
            }

            if !notes.topics.isEmpty {
                card(title: "讨论议题") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(notes.topics) { topic in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Button {
                                        onJumpToTime(topic.start)
                                    } label: {
                                        Text(AppModel.formatClock(topic.start))
                                            .font(.caption2.monospacedDigit().weight(.medium))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(hex: 0xF3F4F6))
                                            .foregroundStyle(Color(hex: 0x5A5F6B))
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                    }
                                    .buttonStyle(.plain)

                                    Text(topic.title)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(Color(hex: 0x15171C))
                                }
                                if !topic.summary.isEmpty {
                                    Text(topic.summary)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Color(hex: 0x5A5F6B))
                                }
                                ForEach(Array(topic.points.enumerated()), id: \.offset) { idx, pt in
                                    HStack(alignment: .top, spacing: 6) {
                                        Text("•").foregroundStyle(Color(hex: 0xE8552B))
                                        Text(pt)
                                            .font(.system(size: 12.5))
                                            .foregroundStyle(Color(hex: 0x15171C))
                                        if let t = topic.pointTime(at: idx) {
                                            Spacer(minLength: 4)
                                            Button(AppModel.formatClock(t)) {
                                                onJumpToTime(t)
                                            }
                                            .buttonStyle(.plain)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(Color(hex: 0x6B7080))
                                        }
                                    }
                                }
                                if let fishbone = topic.fishbone, !fishbone.branches.isEmpty {
                                    FishboneDiagramView(fishbone: fishbone, onJumpToTime: onJumpToTime)
                                        .padding(.top, 4)
                                }
                            }
                            if topic.id != notes.topics.last?.id {
                                Divider().opacity(0.35)
                            }
                        }
                    }
                }
            }

            if !notes.conclusions.isEmpty {
                card(title: "结论与决定") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(notes.conclusions) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.caption)
                                    .foregroundStyle(Color(hex: 0x16A34A))
                                    .padding(.top, 2)
                                Text(item.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(hex: 0x15171C))
                                Spacer(minLength: 4)
                                if let t = item.t {
                                    Button(AppModel.formatClock(t)) { onJumpToTime(t) }
                                        .buttonStyle(.plain)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Color(hex: 0x6B7080))
                                }
                            }
                        }
                    }
                }
            }

            if !notes.todos.isEmpty {
                card(title: "待办事项") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(notes.todos) { td in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "circle")
                                    .font(.caption)
                                    .foregroundStyle(Color(hex: 0xE8552B))
                                    .padding(.top, 2)
                                Text(td.withOwner)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color(hex: 0x15171C))
                                Spacer(minLength: 4)
                                if let t = td.t {
                                    Button(AppModel.formatClock(t)) { onJumpToTime(t) }
                                        .buttonStyle(.plain)
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Color(hex: 0xE8552B))
                                }
                            }
                        }
                    }
                }
            }

            if !compact && !notes.terms.isEmpty {
                card(title: "人名与专业术语") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(notes.terms) { term in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(term.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0x15171C))
                                Text(term.note)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(hex: 0x5A5F6B))
                            }
                        }
                    }
                }
            }
        }
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x6B7080))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.03), radius: 3, y: 1)
    }
}

struct FishboneDiagramView: View {
    let fishbone: Fishbone
    let onJumpToTime: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0xE8552B))
                Text(fishbone.question)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x15171C))
            }

            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color(hex: 0xE5E7EB))
                    .frame(width: 2)
                    .padding(.leading, 8)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(fishbone.branches.enumerated()), id: \.offset) { _, branch in
                        HStack(alignment: .top, spacing: 8) {
                            Rectangle()
                                .fill(Color(hex: 0xE8552B))
                                .frame(width: 14, height: 2)
                                .padding(.top, 8)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(branch.label)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color(hex: 0x15171C))
                                    if let t = branch.t {
                                        Button(AppModel.formatClock(t)) { onJumpToTime(t) }
                                            .buttonStyle(.plain)
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(Color(hex: 0x6B7080))
                                    }
                                }
                                Text(branch.detail)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Color(hex: 0x5A5F6B))
                            }
                        }
                        .padding(.leading, 8)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(hex: 0xF9FAFB))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
