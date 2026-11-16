import AppKit
import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

// MARK: - Menu Bar Popover UI

struct MenuBarPopoverView: View {
    @ObservedObject var model: AppModel
    @State private var mics: [InputDevice] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verba · 言辞")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(hex: 0x15171C))
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.loomStatus?.connected == true ? Color(hex: 0x16A34A) : Color(hex: 0xDC2626))
                            .frame(width: 6, height: 6)
                        Text(model.loomStatus?.connected == true
                             ? "Loom: \(model.loomStatus?.activeTranslateModel ?? "已连接")"
                             : "Loom 未连接")
                            .font(.caption2)
                            .foregroundStyle(Color(hex: 0x5A5F6B))
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button {
                    model.onOpenSettingsWindow?()
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
            }

            if let err = model.lastError, !err.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                    if model.systemAudioDenied {
                        Button("打开系统音频授权设置") {
                            SystemAudioPermission.openPrivacySettings()
                        }
                        .controlSize(.mini)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0xFEF2F2))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Button {
                model.toggleListening()
            } label: {
                HStack {
                    Image(systemName: model.listening ? "stop.fill" : "waveform")
                    Text(model.listening ? "停止聆听并生成最终纪要" : "开始实时字幕与纪要")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(model.listening ? Color(hex: 0x15171C) : Color(hex: 0xE8552B))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("同时听现场麦克风（把自己的声音并入记录）", isOn: $model.roomMicEnabled)
                    .font(.caption)
                    .disabled(model.listening)
                    .onAppear { mics = AudioDevices.roomMicChoices() }
                if model.roomMicEnabled, !mics.isEmpty {
                    Picker("现场麦克风", selection: Binding(
                        get: { model.selectedRoomMicID ?? mics.first?.id ?? 0 },
                        set: { model.selectedRoomMicID = $0 }
                    )) {
                        ForEach(mics) { mic in
                            Text(mic.name).tag(mic.id)
                        }
                    }
                    .font(.caption)
                    .disabled(model.listening)
                }
            }
            .padding(10)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(spacing: 4) {
                menuActionRow(title: "切换字幕浮层", shortcut: "⌃⌥S", icon: "captions.bubble") {
                    model.toggleOverlayManually()
                }
                menuActionRow(title: "调整字幕位置和大小", shortcut: nil, icon: "arrow.up.and.down.and.arrow.left.and.right") {
                    model.onEditOverlay?()
                }
                menuActionRow(title: "打开实时防截屏笔记窗口", shortcut: nil, icon: "note.text") {
                    model.onOpenNotesWindow?()
                }
                menuActionRow(title: "打开会议记录与文件导入", shortcut: nil, icon: "tray.full") {
                    model.onOpenMainWindow?()
                }
                menuActionRow(title: "导入本地音视频转写…", shortcut: nil, icon: "square.and.arrow.down") {
                    model.onOpenMainWindow?()
                    model.pickAndImportFile()
                }
            }

            Divider().opacity(0.4)

            HStack {
                Text("共 \(model.sessions.count) 场本地记录")
                    .font(.caption2)
                    .foregroundStyle(Color(hex: 0x6B7080))
                Spacer()
                Button("退出 Verba") {
                    model.shutdown()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundStyle(Color(hex: 0x6B7080))
            }
        }
        .padding(14)
        .frame(width: 310)
        .background(Color(hex: 0xF3F4F6))
    }

    private func menuActionRow(title: String, shortcut: String?, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundStyle(Color(hex: 0x5A5F6B))
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: 0x15171C))
                Spacer()
                if let shortcut {
                    Text(shortcut)
                        .font(.caption2)
                        .foregroundStyle(Color(hex: 0x6B7080))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - App Delegate & Window Coordinator

@MainActor
final class VerbaAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var overlayController: SubtitleOverlayController!
    private var notesController: NotesWindowController!
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var hotKey: GlobalHotkey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        overlayController = SubtitleOverlayController(model: model)
        notesController = NotesWindowController(model: model)

        model.onOpenNotesWindow = { [weak self] in
            self?.popover.performClose(nil)
            self?.notesController.show()
        }
        model.onOpenMainWindow = { [weak self] in
            self?.popover.performClose(nil)
            self?.openMainWindow()
        }
        model.onOpenSettingsWindow = { [weak self] in
            self?.popover.performClose(nil)
            self?.openSettingsWindow()
        }
        model.onOverlayUpdated = { [weak self] in
            self?.overlayController.syncFromModel()
            self?.notesController.syncCaptureSetting()
            self?.updateMenuBarIcon()
        }
        model.onToggleOverlayManual = { [weak self] in
            self?.overlayController.toggleManual()
            self?.updateMenuBarIcon()
        }
        model.onEditOverlay = { [weak self] in
            self?.popover.performClose(nil)
            self?.overlayController.enterEditMode()
        }

        setupMenuBar()
        hotKey = GlobalHotkey { [weak self] in
            self?.model.toggleOverlayManually()
        }

        model.bootstrap()
        if !CommandLine.arguments.contains("--background") {
            openMainWindow()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openMainWindow()
        return true
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateMenuBarIcon()
        if let btn = statusItem.button {
            btn.action = #selector(togglePopover)
            btn.target = self
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 310, height: 390)
        pop.contentViewController = NSHostingController(rootView: MenuBarPopoverView(model: model))
        popover = pop
    }

    private func updateMenuBarIcon() {
        guard let btn = statusItem?.button else { return }
        let symbolName = model.listening ? "waveform.circle.fill" : "waveform"
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Verba")
        img?.isTemplate = !model.listening
        btn.image = img
        btn.contentTintColor = model.listening ? NSColor(srgbRed: 0.91, green: 0.33, blue: 0.17, alpha: 1) : nil
    }

    @objc private func togglePopover() {
        guard let btn = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func openMainWindow() {
        if mainWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1020, height: 680),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Verba · 会议记录"
            win.center()
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.contentView = NSHostingView(rootView: MainRecordsView(model: model))
            mainWindow = win
        }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openSettingsWindow() {
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 500),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Verba · 设置"
            win.center()
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.contentView = NSHostingView(rootView: SettingsView(model: model))
            settingsWindow = win
        }
        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let mainOpen = (mainWindow?.isVisible == true) && (closing != mainWindow)
        let settingsOpen = (settingsWindow?.isVisible == true) && (closing != settingsWindow)
        if !mainOpen && !settingsOpen {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

@main
struct VerbaMain {
    private static var sharedDelegate: VerbaAppDelegate?

    static func main() {
        let app = NSApplication.shared
        let delegate = VerbaAppDelegate()
        sharedDelegate = delegate
        app.delegate = delegate
        app.run()
    }
}
