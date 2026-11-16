import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainRecordsView: View {
    @ObservedObject var model: AppModel

    @State private var searchQuery = ""
    @State private var searchHits: [SearchHit] = []
    @State private var editingTitle = false
    @State private var draftTitle = ""
    @State private var highlightedLineId: String?

    @State private var fixingLine: TranscriptLine?
    @State private var fixEditedText = ""
    @State private var fixApplyAll = true

    @State private var namingVoice: Int?
    @State private var voiceDraftName = ""

    @State private var confirmDeleteId: String?
    @State private var toastMessage: String?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 350)
        } detail: {
            detailPane
        }
        .background(Color(hex: 0xF3F4F6))
        .onChange(of: model.selectedSessionId) { _, newId in
            if let newId {
                Task { await model.selectSession(newId) }
            }
        }
        .sheet(item: $fixingLine) { line in
            fixLineSheet(line: line)
        }
        .alert("删除这条会议记录？", isPresented: Binding(
            get: { confirmDeleteId != nil },
            set: { if !$0 { confirmDeleteId = nil } }
        )) {
            Button("取消", role: .cancel) { confirmDeleteId = nil }
            Button("删除", role: .destructive) {
                if let id = confirmDeleteId {
                    Task { await model.deleteSession(id: id) }
                }
                confirmDeleteId = nil
            }
        } message: {
            Text("将同时移除本地文字记录、纪要及录音文件。")
        }
    }

    // MARK: - Left Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        model.toggleListening()
                    } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(model.listening ? Color.white : Color(hex: 0xE8552B))
                                .frame(width: 7, height: 7)
                            Text(model.listening ? "停止" : "开始聆听")
                                .font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(model.listening ? Color(hex: 0xE8552B) : Color.white)
                        .foregroundStyle(model.listening ? Color.white : Color(hex: 0x15171C))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)

                    Button {
                        model.pickAndImportFile()
                    } label: {
                        Label("导入音视频", systemImage: "square.and.arrow.down")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.white)
                            .foregroundStyle(Color(hex: 0x15171C))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)

                    Spacer()
                    Button {
                        model.onOpenSettingsWindow?()
                    } label: {
                        Image(systemName: "gearshape")
                            .foregroundStyle(Color(hex: 0x5A5F6B))
                    }
                    .buttonStyle(.borderless)
                    .help("打开设置")
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0x6B7080))
                    TextField("搜索纪要、原句（支持中文音近词）", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .onChange(of: searchQuery) { _, val in
                            let q = val.trimmingCharacters(in: .whitespacesAndNewlines)
                            if q.isEmpty {
                                searchHits = []
                            } else {
                                Task {
                                    searchHits = (try? await model.backend.search(query: q)) ?? []
                                }
                            }
                        }
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            searchHits = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color(hex: 0x9CA3AF))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(10)

            if let prog = model.importProgress {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(prog.fileName).font(.caption.weight(.medium)).lineLimit(1)
                        Spacer()
                        Text("\(Int(prog.fraction * 100))%").font(.caption2.monospacedDigit())
                    }
                    ProgressView(value: prog.fraction)
                        .tint(Color(hex: 0xE8552B))
                    Text(prog.error ?? prog.status)
                        .font(.caption2)
                        .foregroundStyle(prog.error != nil ? .red : Color(hex: 0x5A5F6B))
                        .lineLimit(2)
                }
                .padding(10)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            Divider().opacity(0.4)

            if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                searchResultsList
            } else {
                groupedSessionsList
            }
        }
        .background(Color(hex: 0xECEEF2))
    }

    private var searchResultsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if searchHits.isEmpty {
                    Text("没有找到匹配记录")
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0x6B7080))
                        .padding(16)
                } else {
                    ForEach(searchHits) { hit in
                        Button {
                            Task {
                                await model.selectSession(hit.sessionId)
                                highlightedLineId = hit.lineId
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(hit.sessionTitle)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color(hex: 0x15171C))
                                        .lineLimit(1)
                                    if hit.homophoneMatch {
                                        Text("音近")
                                            .font(.system(size: 10, weight: .semibold))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Color(hex: 0xFFF0EB))
                                            .foregroundStyle(Color(hex: 0xE8552B))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    Spacer()
                                    if let t = hit.t {
                                        Text(AppModel.formatClock(t))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(Color(hex: 0x6B7080))
                                    }
                                }
                                Text(hit.text)
                                    .font(.caption)
                                    .foregroundStyle(Color(hex: 0x374151))
                                    .lineLimit(2)
                            }
                            .padding(9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(10)
        }
    }

    private var groupedSessionsList: some View {
        let groups = groupSessions(model.sessions)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if model.sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("还没有会议记录")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x15171C))
                        Text("点击左上角「开始聆听」，或导入本地音视频文件。")
                            .font(.caption)
                            .foregroundStyle(Color(hex: 0x6B7080))
                    }
                    .padding(16)
                } else {
                    ForEach(groups, id: \.title) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color(hex: 0x6B7080))
                                .padding(.horizontal, 6)
                            ForEach(group.items) { s in
                                sessionRow(s)
                            }
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private func sessionRow(_ s: SessionSummary) -> some View {
        let selected = model.selectedSessionId == s.id
        return Button {
            model.selectedSessionId = s.id
            highlightedLineId = nil
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if model.liveSession?.id == s.id {
                        Circle()
                            .fill(Color(hex: 0xE8552B))
                            .frame(width: 6, height: 6)
                    }
                    Text(s.displayTitle)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(Color(hex: 0x15171C))
                        .lineLimit(1)
                    Spacer()
                }
                HStack(spacing: 6) {
                    Text(shortDate(s.startedAt))
                    Text("·")
                    Text(formatDuration(s.durationSeconds))
                    if let pair = s.languagePair {
                        Text("·")
                        Text(pair)
                    }
                    if s.hasAudio {
                        Image(systemName: "waveform")
                    }
                    Spacer()
                    if s.hasNotes {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(Color(hex: 0xE8552B))
                    }
                }
                .font(.caption2)
                .foregroundStyle(Color(hex: 0x6B7080))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.white : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: selected ? .black.opacity(0.04) : .clear, radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if model.liveSession?.id != s.id {
                Button("重命名…") {
                    model.selectedSessionId = s.id
                    draftTitle = s.displayTitle
                    editingTitle = true
                }
                Button("删除记录", role: .destructive) {
                    confirmDeleteId = s.id
                }
            }
        }
    }

    // MARK: - Detail Workspace

    private var detailPane: some View {
        Group {
            if let s = model.selectedSession {
                VStack(spacing: 0) {
                    detailHeader(s)
                    if s.hasAudio || model.sessionAudioURL(id: s.id) != nil {
                        audioPlaybackBar(s)
                    }
                    Divider().opacity(0.4)

                    HSplitView {
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
                                if let notes = s.notes, !notes.isEmpty {
                                    StructuredNotesContent(
                                        notes: notes,
                                        compact: false,
                                        onJumpToTime: { sec in
                                            if s.hasAudio || model.sessionAudioURL(id: s.id) != nil {
                                                model.playOrSeek(sessionId: s.id, at: sec)
                                            }
                                            if let line = s.lines.min(by: { abs($0.t - sec) < abs($1.t - sec) }) {
                                                highlightedLineId = line.id
                                            }
                                        }
                                    )
                                } else {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text("暂无结构化纪要")
                                            .font(.system(size: 14, weight: .semibold))
                                        Text("点击右上角「生成纪要」即可使用本地 Loom 生成摘要、议题、鱼骨图、结论、待办与术语。")
                                            .font(.caption)
                                            .foregroundStyle(Color(hex: 0x5A5F6B))
                                    }
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                }
                            }
                            .padding(16)
                        }
                        .frame(minWidth: 320, idealWidth: 420)

                        transcriptScrollView(s)
                            .frame(minWidth: 320)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 36))
                        .foregroundStyle(Color(hex: 0x9CA3AF))
                    Text("选择或开始一场会议")
                        .font(.headline)
                        .foregroundStyle(Color(hex: 0x15171C))
                    Text("所有语音识别在 Apple 设备端完成，AI 翻译与纪要整理通过本地 Loom 运行。")
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0x5A5F6B))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func detailHeader(_ s: SessionDetail) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                if editingTitle {
                    HStack(spacing: 6) {
                        TextField("会议标题", text: $draftTitle)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                            .onSubmit {
                                Task {
                                    await model.renameSession(id: s.id, title: draftTitle)
                                    editingTitle = false
                                }
                            }
                        Button("保存") {
                            Task {
                                await model.renameSession(id: s.id, title: draftTitle)
                                editingTitle = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: 0xE8552B))
                        .controlSize(.small)
                    }
                } else {
                    HStack(spacing: 6) {
                        Text(s.displayTitle)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(Color(hex: 0x15171C))
                        Button {
                            draftTitle = s.displayTitle
                            editingTitle = true
                        } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(Color(hex: 0x6B7080))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack(spacing: 8) {
                    Text(fullDate(s.startedAt))
                    Text("·")
                    Text("\(s.lines.count) 句")
                    if let file = s.sourceFile {
                        Text("·")
                        Label(file, systemImage: "film")
                    }
                }
                .font(.caption)
                .foregroundStyle(Color(hex: 0x6B7080))
            }

            Spacer()

            if let toastMessage {
                Text(toastMessage)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(hex: 0xECFDF5))
                    .foregroundStyle(Color(hex: 0x15803D))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            Button {
                Task { await model.generateNotes(sessionId: s.id, fresh: true) }
            } label: {
                if model.notesLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label(s.notes == nil ? "生成纪要" : "刷新纪要", systemImage: "sparkles")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color(hex: 0xE8552B))
            .controlSize(.small)
            .disabled(s.lines.isEmpty || model.notesLoading)

            Menu {
                Button("复制 Markdown 纪要和记录") {
                    Task {
                        if let md = try? await model.backend.exportSession(id: s.id, format: "markdown") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(md, forType: .string)
                            showToast("已复制 Markdown")
                        }
                    }
                }
                Button("导出为 Markdown (.md)…") { exportFile(session: s, format: "markdown", ext: "md") }
                Button("导出为字幕文件 (.srt)…") { exportFile(session: s, format: "srt", ext: "srt") }
                Divider()
                Button("用当前模型重新翻译本场") {
                    Task { await model.retranslateSession(id: s.id) }
                }
                if model.settings.exportEnabled {
                    Button("立即同步到 Obsidian / 导出文件夹") {
                        Task {
                            _ = await model.syncExportFolder()
                            showToast("已同步文件夹")
                        }
                    }
                }
                if model.liveSession?.id != s.id {
                    Divider()
                    Button("删除记录", role: .destructive) {
                        confirmDeleteId = s.id
                    }
                }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
                    .font(.caption.weight(.medium))
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.white)
    }

    private func audioPlaybackBar(_ s: SessionDetail) -> some View {
        let active = model.playingSessionId == s.id
        let cur = active ? model.playbackTime : 0
        let total = active && model.playbackDuration > 0 ? model.playbackDuration : max(s.durationSeconds, 1)

        return HStack(spacing: 10) {
            Button {
                model.togglePlayPause(sessionId: s.id)
            } label: {
                Image(systemName: (active && model.isPlaying) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color(hex: 0xE8552B))
            }
            .buttonStyle(.plain)

            Text(AppModel.formatClock(cur))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color(hex: 0x5A5F6B))

            Slider(
                value: Binding(
                    get: { cur },
                    set: { newVal in
                        if !active { model.playOrSeek(sessionId: s.id, at: newVal) }
                        else { model.seekAudio(to: newVal) }
                    }
                ),
                in: 0...max(total, 1)
            )
            .tint(Color(hex: 0xE8552B))

            Text(AppModel.formatClock(total))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color(hex: 0x6B7080))

            Button {
                model.cyclePlaybackRate()
            } label: {
                Text(String(format: "%.2gx", model.playbackRate))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(hex: 0xECEEF2))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(hex: 0xFAFAFB))
    }

    private func transcriptScrollView(_ s: SessionDetail) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(s.lines) { line in
                        transcriptLineCard(s, line)
                            .id(line.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: highlightedLineId) { _, target in
                if let target {
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                }
            }
            .onChange(of: model.playbackTime) { _, pt in
                guard model.playingSessionId == s.id, model.isPlaying else { return }
                if let active = s.lines.last(where: { $0.t <= pt + 0.3 }) {
                    highlightedLineId = active.id
                }
            }
        }
        .background(Color(hex: 0xF3F4F6))
    }

    private func transcriptLineCard(_ s: SessionDetail, _ line: TranscriptLine) -> some View {
        let isHighlighted = highlightedLineId == line.id
        let canPlay = s.hasAudio || model.sessionAudioURL(id: s.id) != nil

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Button {
                    if canPlay { model.playOrSeek(sessionId: s.id, at: line.t) }
                    highlightedLineId = line.id
                } label: {
                    Text(AppModel.formatClock(line.t))
                        .font(.caption2.monospacedDigit())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(isHighlighted ? Color(hex: 0xE8552B) : Color(hex: 0xF3F4F6))
                        .foregroundStyle(isHighlighted ? Color.white : Color(hex: 0x6B7080))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)

                if let v = line.voice {
                    Button(s.speakerLabel(for: line)) {
                        namingVoice = v
                        voiceDraftName = s.voiceNames?[String(v)] ?? ""
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(hex: 0x5A5F6B))
                    .popover(isPresented: Binding(
                        get: { namingVoice == v },
                        set: { if !$0 { namingVoice = nil } }
                    )) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("设置说话人名称").font(.caption.weight(.semibold))
                            TextField("输入姓名…", text: $voiceDraftName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                                .onSubmit {
                                    Task {
                                        await model.setVoiceName(id: s.id, voice: v, name: voiceDraftName)
                                        namingVoice = nil
                                    }
                                }
                            HStack {
                                Spacer()
                                Button("确定") {
                                    Task {
                                        await model.setVoiceName(id: s.id, voice: v, name: voiceDraftName)
                                        namingVoice = nil
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Color(hex: 0xE8552B))
                                .controlSize(.small)
                            }
                        }
                        .padding(12)
                    }
                } else {
                    Text(s.speakerLabel(for: line))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(line.speaker == "me" ? Color(hex: 0xE8552B) : Color(hex: 0x5A5F6B))
                }

                Spacer()

                Button("改这句…") {
                    fixEditedText = line.shown
                    fixApplyAll = true
                    fixingLine = line
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundStyle(Color(hex: 0x6B7080))
            }

            Text(line.shown)
                .font(.system(size: 13.5))
                .foregroundStyle(Color(hex: 0x15171C))
                .textSelection(.enabled)

            if let dst = line.dst, !dst.isEmpty {
                Text(dst)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Color(hex: 0x4B5563))
                    .textSelection(.enabled)
            }

            ForEach(line.pendingAsks, id: \.self) { ask in
                HStack(spacing: 8) {
                    Text("「\(ask.from)」→「\(ask.to)」")
                        .font(.caption)
                        .foregroundStyle(Color(hex: 0x15171C))
                    Button("对") {
                        Task { await model.acceptAsk(sessionId: s.id, lineId: line.id, from: ask.from, to: ask.to) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: 0xE8552B))
                    .controlSize(.mini)
                    Button("不用") {
                        Task { await model.rejectAsk(sessionId: s.id, lineId: line.id, from: ask.from, to: ask.to) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? Color(hex: 0xFFF7F4) : Color.white)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHighlighted ? Color(hex: 0xE8552B).opacity(0.4) : Color.clear, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func fixLineSheet(line: TranscriptLine) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("修正识别文字")
                .font(.headline)
            Text("原文（原始识别）：\(line.src)")
                .font(.caption)
                .foregroundStyle(Color(hex: 0x6B7080))
            TextField("编辑正确的文字…", text: $fixEditedText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...5)
            Toggle("在本场后续及同错处一起修正，并加入词表记住", isOn: $fixApplyAll)
                .font(.caption)
            HStack {
                Spacer()
                Button("取消") { fixingLine = nil }
                Button("保存并重新翻译") {
                    guard let sid = model.selectedSession?.id else { return }
                    let edited = fixEditedText
                    let applyAll = fixApplyAll
                    fixingLine = nil
                    Task {
                        await model.editLineText(sessionId: sid, lineId: line.id, editedText: edited, applyAll: applyAll)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(hex: 0xE8552B))
            }
        }
        .padding(18)
        .frame(width: 440)
    }

    private func exportFile(session: SessionDetail, format: String, ext: String) {
        Task {
            guard let text = try? await model.backend.exportSession(id: session.id, format: format) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(session.displayTitle).\(ext)"
            if panel.runModal() == .OK, let url = panel.url {
                try? text.write(to: url, atomically: true, encoding: .utf8)
                showToast("已导出 .\(ext)")
            }
        }
    }

    private func showToast(_ msg: String) {
        toastMessage = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if toastMessage == msg { toastMessage = nil }
        }
    }

    // MARK: - Date Grouping Helpers

    private struct SessionGroup {
        let title: String
        let items: [SessionSummary]
    }

    private func groupSessions(_ items: [SessionSummary]) -> [SessionGroup] {
        let cal = Calendar.current
        let now = Date()
        var today: [SessionSummary] = []
        var yesterday: [SessionSummary] = []
        var week: [SessionSummary] = []
        var older: [SessionSummary] = []

        for s in items {
            if cal.isDateInToday(s.startedAt) {
                today.append(s)
            } else if cal.isDateInYesterday(s.startedAt) {
                yesterday.append(s)
            } else if let diff = cal.dateComponents([.day], from: s.startedAt, to: now).day, diff < 7 {
                week.append(s)
            } else {
                older.append(s)
            }
        }
        var out: [SessionGroup] = []
        if !today.isEmpty { out.append(SessionGroup(title: "今天", items: today)) }
        if !yesterday.isEmpty { out.append(SessionGroup(title: "昨天", items: yesterday)) }
        if !week.isEmpty { out.append(SessionGroup(title: "最近 7 天", items: week)) }
        if !older.isEmpty { out.append(SessionGroup(title: "更早", items: older)) }
        return out
    }

    private func shortDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "M/d HH:mm"
        return df.string(from: date)
    }

    private func fullDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy年M月d日 HH:mm"
        return df.string(from: date)
    }

    private func formatDuration(_ sec: Double) -> String {
        let m = Int(sec) / 60
        if m < 1 { return "<1 分钟" }
        return "\(m) 分钟"
    }
}
