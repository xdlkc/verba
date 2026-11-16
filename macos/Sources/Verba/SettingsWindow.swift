import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab = "loom"

    @State private var testReply: LoomTestResponse?
    @State private var testingLoom = false

    @State private var newWord = ""
    @State private var newHeard = ""
    @State private var batchVocabText = ""
    @State private var showBatchImport = false
    @State private var syncStatusText = ""

    var body: some View {
        TabView(selection: $selectedTab) {
            loomTab
                .tabItem { Label("本地 Loom AI", systemImage: "cpu") }
                .tag("loom")

            translationAndDisplayTab
                .tabItem { Label("字幕与语言", systemImage: "captions.bubble") }
                .tag("display")

            vocabularyTab
                .tabItem { Label("专有词表", systemImage: "text.book.closed") }
                .tag("vocab")

            exportTab
                .tabItem { Label("导出与 Obsidian", systemImage: "folder") }
                .tag("export")
        }
        .padding(18)
        .frame(width: 620, height: 500)
        .background(Color(hex: 0xF3F4F6))
    }

    // MARK: - Loom AI Gateway Tab

    private var loomTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                settingsCard(title: "本地 Loom 模型网关") {
                    HStack(spacing: 10) {
                        let connected = model.loomStatus?.connected == true
                        Circle()
                            .fill(connected ? Color(hex: 0x16A34A) : Color(hex: 0xDC2626))
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(connected ? "已连接本地 Loom（\(model.loomStatus?.models.count ?? 0) 个可用模型）" : "未连接到 Loom")
                                .font(.system(size: 13.5, weight: .semibold))
                            Text(model.loomStatus?.lastError ?? "语音采集与 Apple 识别严格留在设备端；仅文本经本机回环地址发给 Loom（读取 hub.key 鉴权）。")
                                .font(.caption)
                                .foregroundStyle(Color(hex: 0x5A5F6B))
                        }
                        Spacer()
                        Button("检查连接") {
                            Task { _ = await model.checkLoom() }
                        }
                        .controlSize(.small)

                        Button {
                            testingLoom = true
                            testReply = nil
                            Task {
                                testReply = await model.testLoom()
                                testingLoom = false
                            }
                        } label: {
                            if testingLoom { ProgressView().controlSize(.small) }
                            else { Text("试译一句") }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: 0xE8552B))
                        .controlSize(.small)
                        .disabled(testingLoom)
                    }

                    if let reply = testReply {
                        HStack(spacing: 8) {
                            Image(systemName: reply.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(reply.ok ? Color(hex: 0x16A34A) : Color.red)
                            if reply.ok {
                                Text("\(reply.translation ?? "") （\(reply.model ?? "") · \(reply.latencyMs ?? 0)ms）")
                                    .font(.caption)
                            } else {
                                Text(reply.error ?? "失败")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: 0xF9FAFB))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }

                    Divider().opacity(0.4)

                    HStack {
                        Text("Loom 地址")
                            .frame(width: 96, alignment: .leading)
                            .font(.caption)
                        TextField("http://127.0.0.1:4319/v1", text: Binding(
                            get: { model.settings.loomUrl },
                            set: { v in model.settings.loomUrl = v }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            Task { await model.updateSettings(["loomUrl": model.settings.loomUrl]) }
                        }
                    }

                    let models = model.loomStatus?.models ?? []
                    HStack {
                        Text("翻译模型")
                            .frame(width: 96, alignment: .leading)
                            .font(.caption)
                        Picker("", selection: Binding(
                            get: { model.settings.translateModel },
                            set: { v in Task { await model.updateSettings(["translateModel": v]) } }
                        )) {
                            Text("自动选择最佳快模型（推荐 \(model.loomStatus?.activeTranslateModel ?? "")）").tag("")
                            ForEach(models) { m in
                                Text("\(m.provider) · \(m.id)").tag(m.id)
                            }
                        }
                        .labelsHidden()
                    }

                    HStack {
                        Text("纪要模型")
                            .frame(width: 96, alignment: .leading)
                            .font(.caption)
                        Picker("", selection: Binding(
                            get: { model.settings.notesModel },
                            set: { v in Task { await model.updateSettings(["notesModel": v]) } }
                        )) {
                            Text("自动选择高质量模型（推荐 \(model.loomStatus?.activeNotesModel ?? "")）").tag("")
                            ForEach(models) { m in
                                Text("\(m.provider) · \(m.id)").tag(m.id)
                            }
                        }
                        .labelsHidden()
                    }
                }

                if !model.recentCalls.isEmpty {
                    settingsCard(title: "最近 Loom 调用记录") {
                        ForEach(model.recentCalls.prefix(6)) { call in
                            HStack {
                                Text(call.role)
                                    .font(.caption2.weight(.semibold))
                                    .frame(width: 78, alignment: .leading)
                                Text(call.model)
                                    .font(.caption2)
                                    .foregroundStyle(Color(hex: 0x5A5F6B))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(call.latencyMs)ms")
                                    .font(.caption2.monospacedDigit())
                                Text(call.outcome)
                                    .font(.caption2)
                                    .foregroundStyle(call.outcome == "ok" ? Color(hex: 0x16A34A) : Color.red)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Translation & Display Tab

    private var translationAndDisplayTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                settingsCard(title: "语言方向") {
                    HStack {
                        Text("会议源语言")
                            .frame(width: 96, alignment: .leading)
                            .font(.caption)
                        Picker("", selection: Binding(
                            get: { model.settings.sourceLang },
                            set: { v in Task { await model.updateSettings(["sourceLang": v]) } }
                        )) {
                            ForEach(Languages.all) { lang in
                                Text(lang.name).tag(lang.code)
                            }
                        }
                        .labelsHidden()
                    }
                    HStack {
                        Text("翻译目标语")
                            .frame(width: 96, alignment: .leading)
                            .font(.caption)
                        Picker("", selection: Binding(
                            get: { model.settings.targetLang },
                            set: { v in Task { await model.updateSettings(["targetLang": v]) } }
                        )) {
                            ForEach(Languages.targets) { lang in
                                Text(lang.name).tag(lang.code)
                            }
                        }
                        .labelsHidden()
                    }
                    HStack {
                        Text("纪要生成语言")
                            .frame(width: 96, alignment: .leading)
                            .font(.caption)
                        Picker("", selection: Binding(
                            get: { model.settings.notesLang },
                            set: { v in Task { await model.updateSettings(["notesLang": v]) } }
                        )) {
                            ForEach(Languages.notesLanguages, id: \.value) { opt in
                                Text(opt.label).tag(opt.value)
                            }
                        }
                        .labelsHidden()
                    }
                }

                settingsCard(title: "字幕浮层与笔记保护") {
                    HStack {
                        Text("字幕浮层显示")
                            .frame(width: 96, alignment: .leading)
                            .font(.caption)
                        Picker("", selection: Binding(
                            get: { model.settings.overlayMode },
                            set: { v in Task { await model.updateSettings(["overlayMode": v]) } }
                        )) {
                            Text("说话时自动显示").tag("auto")
                            Text("聆听时始终显示").tag("always")
                            Text("关闭字幕浮层").tag("off")
                        }
                        .labelsHidden()
                    }
                    HStack {
                        Text("停顿自动隐藏")
                            .frame(width: 96, alignment: .leading)
                            .font(.caption)
                        Slider(
                            value: Binding(
                                get: { model.settings.overlayHideAfter },
                                set: { v in model.settings.overlayHideAfter = v }
                            ),
                            in: 2...12,
                            step: 0.5
                        ) { _ in }
                        .onChange(of: model.settings.overlayHideAfter) { _, val in
                            Task { await model.updateSettings(["overlayHideAfter": val]) }
                        }
                        Text("\(String(format: "%.1fs", model.settings.overlayHideAfter))")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40)
                    }
                    Toggle("边说话边出临时译文（未说完即先出大意，说完修正）", isOn: Binding(
                        get: { model.settings.draftTranslate },
                        set: { v in Task { await model.updateSettings(["draftTranslate": v]) } }
                    ))
                    .font(.caption)

                    Toggle("同音误字与人名术语自动纠错", isOn: Binding(
                        get: { model.settings.liveFixEnabled },
                        set: { v in Task { await model.updateSettings(["liveFixEnabled": v]) } }
                    ))
                    .font(.caption)

                    Toggle("允许在屏幕共享和截图中显示实时笔记窗口", isOn: Binding(
                        get: { model.settings.notesCapturable },
                        set: { v in Task { await model.updateSettings(["notesCapturable": v]) } }
                    ))
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Vocabulary Tab

    private var vocabularyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCard(title: "专有词表（优先纠偏人名与术语）") {
                HStack(spacing: 8) {
                    TextField("常见听错写法（可选，如 莫拉）", text: $newHeard)
                        .textFieldStyle(.roundedBorder)
                    TextField("正确拼写（如 Morpho）", text: $newWord)
                        .textFieldStyle(.roundedBorder)
                    Button("添加") {
                        let w = newWord.trimmingCharacters(in: .whitespaces)
                        guard !w.isEmpty else { return }
                        let h = newHeard.trimmingCharacters(in: .whitespaces)
                        newWord = ""
                        newHeard = ""
                        Task {
                            _ = try? await model.backend.confirmVocab(heard: h, word: w)
                            await model.refreshState()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: 0xE8552B))
                    .controlSize(.small)

                    Button("批量粘贴…") { showBatchImport = true }
                        .controlSize(.small)
                }
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    if model.settings.vocabulary.isEmpty {
                        Text("词表为空。当你把错字改对、确认「对」或手动添加术语后，Verba 会记住并在后续会议自动套用。")
                            .font(.caption)
                            .foregroundStyle(Color(hex: 0x6B7080))
                            .padding(16)
                    } else {
                        ForEach(model.settings.vocabulary) { entry in
                            HStack {
                                Text(entry.word)
                                    .font(.system(size: 13, weight: .semibold))
                                if !entry.heard.isEmpty {
                                    Text("← \(entry.heard.joined(separator: "、"))")
                                        .font(.caption)
                                        .foregroundStyle(Color(hex: 0x5A5F6B))
                                }
                                Spacer()
                                if entry.fixes > 0 {
                                    Text("已纠正 \(entry.fixes) 次")
                                        .font(.caption2)
                                        .foregroundStyle(Color(hex: 0xE8552B))
                                }
                                Button {
                                    let updated = model.settings.vocabulary.filter { $0.word != entry.word }
                                    let dicts: [[String: Any]] = updated.map { e in
                                        var d: [String: Any] = ["word": e.word, "heard": e.heard, "source": e.source, "fixes": e.fixes]
                                        if let u = e.used {
                                            d["used"] = ISO8601DateFormatter().string(from: u)
                                        }
                                        return d
                                    }
                                    Task { await model.updateSettings(["vocabulary": dicts]) }
                                } label: {
                                    Image(systemName: "trash").font(.caption)
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color(hex: 0x6B7080))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showBatchImport) {
            VStack(alignment: .leading, spacing: 10) {
                Text("批量导入词表")
                    .font(.headline)
                Text("每行一条，支持 `错词 -> 正确词` 或直接写正确拼写：")
                    .font(.caption)
                    .foregroundStyle(Color(hex: 0x5A5F6B))
                TextEditor(text: $batchVocabText)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(height: 160)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.1)))
                HStack {
                    Spacer()
                    Button("取消") { showBatchImport = false }
                    Button("导入") {
                        let txt = batchVocabText
                        batchVocabText = ""
                        showBatchImport = false
                        Task { _ = await model.importVocab(text: txt) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: 0xE8552B))
                }
            }
            .padding(16)
            .frame(width: 420)
        }
    }

    // MARK: - Obsidian & Folder Export Tab

    private var exportTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                settingsCard(title: "自动导出到文件夹 / Obsidian Vault") {
                    Toggle("每场会议结束或更新纪要后自动写入 Markdown 文件", isOn: Binding(
                        get: { model.settings.exportEnabled },
                        set: { v in Task { await model.updateSettings(["exportEnabled": v]) } }
                    ))
                    .font(.system(size: 13, weight: .medium))

                    HStack {
                        Text("目标文件夹")
                            .frame(width: 84, alignment: .leading)
                            .font(.caption)
                        TextField("未选择文件夹", text: Binding(
                            get: { model.settings.exportFolder },
                            set: { v in model.settings.exportFolder = v }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("选择…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url {
                                Task {
                                    await model.updateSettings([
                                        "exportFolder": url.path,
                                        "exportEnabled": true,
                                    ])
                                }
                            }
                        }
                        .controlSize(.small)
                    }

                    if !model.obsidianVaults.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("已发现的 Obsidian Vault（一键设为自动同步目录）：")
                                .font(.caption)
                                .foregroundStyle(Color(hex: 0x5A5F6B))
                            FlowVaultButtons(vaults: model.obsidianVaults) { vault in
                                let target = URL(fileURLWithPath: vault.path).appendingPathComponent("Verba Meetings").path
                                Task {
                                    await model.updateSettings([
                                        "exportFolder": target,
                                        "exportEnabled": true,
                                    ])
                                }
                            }
                        }
                    }

                    HStack {
                        Button("立即同步已结束会议") {
                            Task {
                                if let idx = await model.syncExportFolder() {
                                    syncStatusText = "已同步 \(idx.files.count) 份笔记"
                                } else {
                                    syncStatusText = "请先选择目标文件夹"
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(hex: 0xE8552B))
                        .controlSize(.small)

                        if !model.settings.exportFolder.isEmpty {
                            Button("在访达中打开") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: model.settings.exportFolder)
                            }
                            .controlSize(.small)
                        }
                        if !syncStatusText.isEmpty {
                            Text(syncStatusText)
                                .font(.caption)
                                .foregroundStyle(Color(hex: 0x16A34A))
                        }
                    }
                }
            }
        }
    }

    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color(hex: 0x15171C))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct FlowVaultButtons: View {
    let vaults: [ObsidianVault]
    let onSelect: (ObsidianVault) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(vaults.prefix(4)) { vault in
                Button {
                    onSelect(vault)
                } label: {
                    Label(vault.name, systemImage: "book.closed")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
