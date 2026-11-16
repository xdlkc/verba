import AppKit
import SwiftUI

// MARK: - Anti-Capture Floating Notes Window (Non-Activating, First-Click Responsive)

private final class NotesPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotesWindowController: NSObject, NSWindowDelegate {
    enum LayoutMode { case card, sidebar, wide }

    private let model: AppModel
    private var panel: NotesPanel?
    private let autosaveName = "VerbaNotesWindowV2"
    private let onTopKey = "verba.notes.onTop"

    var onTop: Bool {
        get { UserDefaults.standard.object(forKey: onTopKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: onTopKey)
            panel?.level = newValue ? .floating : .normal
            panel?.isFloatingPanel = newValue
            model.notesOnTop = newValue
        }
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        model.notesOnTop = onTop
    }

    func show() {
        ensurePanel()
        syncCaptureSetting()
        panel?.orderFrontRegardless()
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

    func resize(layout: LayoutMode) {
        guard let p = panel, let screen = p.screen ?? NSScreen.main else { return }
        let targetW: CGFloat
        let targetH: CGFloat?
        switch layout {
        case .card:
            targetW = 320
            targetH = 260
        case .sidebar:
            targetW = 440
            targetH = min(720, screen.visibleFrame.height - 48)
        case .wide:
            targetW = 800
            targetH = min(760, screen.visibleFrame.height - 48)
        }
        var f = p.frame
        let top = f.maxY
        let right = f.maxX
        f.size.width = min(targetW, screen.visibleFrame.width - 24)
        if let th = targetH {
            f.size.height = th
        }
        f.origin.x = min(max(screen.visibleFrame.minX + 12, right - f.size.width), screen.visibleFrame.maxX - f.size.width - 12)
        f.origin.y = max(screen.visibleFrame.minY + 12, top - f.size.height)
        p.setFrame(f, display: true, animate: true)
    }

    private func ensurePanel() {
        if panel != nil {
            syncCaptureSetting()
            return
        }
        let v = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        let defaultRect = NSRect(x: v.maxX - 456, y: v.minY + 28, width: 440, height: min(740, v.height - 56))

        let p = NotesPanel(
            contentRect: defaultRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.isFloatingPanel = onTop
        p.level = onTop ? .floating : .normal
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.isReleasedWhenClosed = false
        p.minSize = NSSize(width: 280, height: 220)
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.sharingType = model.settings.notesCapturable ? .readOnly : .none
        p.delegate = self

        let root = NotesPanelView(
            model: model,
            onResizeLayout: { [weak self] mode in self?.resize(layout: mode) },
            onToggleOnTop: { [weak self] in
                guard let self else { return }
                self.onTop.toggle()
            }
        )
        p.contentView = FirstClickHostingView(rootView: root)
        p.setFrameAutosaveName(autosaveName)
        if !p.setFrameUsingName(autosaveName) {
            p.setFrame(defaultRect, display: false)
        }
        panel = p
    }
}

// MARK: - Responsive Notes Panel UI

struct NotesPanelView: View {
    @ObservedObject var model: AppModel
    let onResizeLayout: (NotesWindowController.LayoutMode) -> Void
    let onToggleOnTop: () -> Void

    @State private var tab = "notes"
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
            let wide = w >= 680
            let isCard = w < 350

            VStack(spacing: 0) {
                headerBar(wide: wide, isCard: isCard)

                if !wide && !isCard {
                    HStack(spacing: 4) {
                        tabPill("纪要", id: "notes")
                        tabPill(
                            (activeSession?.lines.isEmpty == false)
                                ? "文字记录 · \(activeSession?.lines.count ?? 0)"
                                : "文字记录",
                            id: "transcript"
                        )
                    }
                    .padding(3)
                    .background(Color(hex: 0xECEEF2))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                    .background(Color.white)
                }

                if showSearch {
                    searchStrip
                }
                if let ask = pendingAsk {
                    askBanner(ask)
                }
                Divider().opacity(0.35)

                if wide {
                    HStack(spacing: 0) {
                        notesPane(narrow: false)
                            .frame(maxWidth: .infinity)
                        Divider().opacity(0.35)
                        transcriptPane
                            .frame(width: min(max(w * 0.44, 260), 420))
                    }
                } else if isCard {
                    cardCompactView
                } else if tab == "notes" {
                    notesPane(narrow: false)
                    liveBottomCaptionBar
                } else {
                    transcriptPane
                }
            }
            .background(Color(hex: 0xF3F4F6))
        }
        .onExitCommand { showSearch = false }
    }

    private func tabPill(_ label: String, id: String) -> some View {
        let active = tab == id
        return Button {
            tab = id
        } label: {
            Text(label)
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? Color(hex: 0x15171C) : Color(hex: 0x5A5F6B))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(active ? Color.white : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func headerBar(wide: Bool, isCard: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(model.listening ? Color(hex: 0xE8552B) : Color(hex: 0x9CA3AF))
                    .frame(width: 8, height: 8)
                Text(activeSession?.displayTitle ?? "Verba 实时笔记")
                    .font(.system(size: isCard ? 13 : 14.5, weight: .bold))
                    .foregroundStyle(Color(hex: 0x15171C))
                    .lineLimit(1)
                Spacer(minLength: 6)

                Button {
                    model.toggleListening()
                } label: {
                    Text(model.listening ? "停止" : "开始")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(model.listening ? Color(hex: 0x15171C) : Color(hex: 0xE8552B))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(model.listening ? "停止聆听" : "开始实时字幕与纪要")

                if !isCard {
                    Button {
                        showSearch.toggle()
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: 0x5A5F6B))
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut("f", modifiers: .command)
                    .help("会内搜索 (⌘F)")
                }

                if !isCard {
                    Button {
                        onToggleOnTop()
                    } label: {
                        Image(systemName: model.notesOnTop ? "pin.fill" : "pin")
                            .font(.system(size: 12))
                            .foregroundStyle(model.notesOnTop ? Color(hex: 0xE8552B) : Color(hex: 0x6B7080))
                    }
                    .buttonStyle(.borderless)
                    .help(model.notesOnTop ? "取消置顶" : "窗口置顶")
                }

                Button {
                    let next = !model.settings.notesCapturable
                    Task { await model.updateSettings(["notesCapturable": next]) }
                } label: {
                    Image(systemName: model.settings.notesCapturable ? "eye" : "eye.slash")
                        .font(.system(size: 12))
                        .foregroundStyle(model.settings.notesCapturable ? Color(hex: 0xE8552B) : Color(hex: 0x6B7080))
                }
                .buttonStyle(.borderless)
                .help(model.settings.notesCapturable ? "屏幕共享对方可见（点击改为防截屏）" : "防截屏隐身中（对方看不到）")

                // Layout preset toggle buttons: Card <-> Sidebar <-> Wide
                if isCard {
                    Button {
                        onResizeLayout(.sidebar)
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help("展开单栏窗口")
                } else {
                    Button {
                        onResizeLayout(wide ? .sidebar : .wide)
                    } label: {
                        Image(systemName: wide ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: 0x5A5F6B))
                    }
                    .buttonStyle(.borderless)
                    .help(wide ? "切回单栏" : "展开纪要+原话双栏")

                    Button {
                        onResizeLayout(.card)
                    } label: {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(hex: 0x5A5F6B))
                    }
                    .buttonStyle(.borderless)
                    .help("收成小卡片")
                }

                if let s = activeSession, !s.lines.isEmpty && !isCard {
                    Button {
                        Task { await model.generateNotes(sessionId: s.id, fresh: false) }
                    } label: {
                        if model.notesLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("立即更新结构化纪要")
                }
            }
        }
        .padding(.leading, 68) // Leave clean space for macOS traffic-light buttons in transparent titlebar
        .padding(.trailing, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(Color.white)
    }

    private var cardCompactView: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let s = activeSession, let notes = s.notes, !notes.isEmpty {
                        Text(notes.summary)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color(hex: 0x15171C))
                    } else if let last = activeSession?.lines.last {
                        Text(last.shown)
                            .font(.caption)
                            .foregroundStyle(Color(hex: 0x5A5F6B))
                        if let dst = last.dst, !dst.isEmpty {
                            Text(dst)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x15171C))
                        }
                    } else {
                        Text(model.listening ? "正在聆听系统声音…" : "点击右上角「开始」即可开始实时转写与纪要")
                            .font(.caption)
                            .foregroundStyle(Color(hex: 0x6B7080))
                    }
                }
                .padding(12)
            }
            liveBottomCaptionBar
        }
    }

    private var liveBottomCaptionBar: some View {
        let lastLine = activeSession?.lines.last
        let draft = model.draft
        let src = draft?.src ?? lastLine?.shown ?? ""
        let dst = draft?.dst ?? lastLine?.dst ?? ""

        return Group {
            if model.listening || !src.isEmpty || !dst.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    if !src.isEmpty {
                        HStack(spacing: 5) {
                            if model.listening {
                                Circle().fill(Color(hex: 0xE8552B)).frame(width: 6, height: 6)
                            }
                            Text(src)
                                .font(.caption)
                                .foregroundStyle(Color(hex: 0x5A5F6B))
                                .lineLimit(2)
                        }
                    }
                    if !dst.isEmpty {
                        Text(dst)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x15171C))
                            .lineLimit(2)
                    } else if model.listening && src.isEmpty {
                        Text("正在聆听系统音频，说话后这里与字幕浮层会同步显示…")
                            .font(.caption)
                            .foregroundStyle(Color(hex: 0x6B7080))
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white)
                .overlay(Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1), alignment: .top)
            }
        }
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
                                tab = "transcript"
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
                                    tab = "transcript"
                                }
                            }
                        }
                    )
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.listening ? "会议纪要将在发言累积后自动生成" : "还没有纪要")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x15171C))
                        Text("Verba 会通过本地 Loom 自动提炼摘要、议题、鱼骨图、结论、待办与术语表。你也可切换上方「文字记录」查看逐句转写。")
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

                        if model.listening && model.liveSession?.id == s.id, let d = model.draft {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 5) {
                                    Circle().fill(Color(hex: 0xE8552B)).frame(width: 6, height: 6)
                                    Text(d.speaker == "me" ? "我 · 识别中" : "对方 · 识别中")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color(hex: 0xE8552B))
                                }
                                Text(d.src)
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Color(hex: 0x15171C))
                                if let dst = d.dst, !dst.isEmpty {
                                    Text(dst)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Color(hex: 0x4B5563))
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(hex: 0xFFF7F4))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .id("notes-live-draft")
                        }
                    }
                }
                .padding(10)
            }
            .onChange(of: activeSession?.lines.count) { _, _ in
                if model.listening, let last = activeSession?.lines.last?.id {
                    proxy.scrollTo(model.draft != nil ? "notes-live-draft" : last, anchor: .bottom)
                }
            }
            .onChange(of: model.draft?.src) { _, _ in
                if model.listening && model.draft != nil {
                    proxy.scrollTo("notes-live-draft", anchor: .bottom)
                }
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
