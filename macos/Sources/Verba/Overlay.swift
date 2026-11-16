import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Global Carbon Hotkey (Control + Option + S)

final class GlobalHotkey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onTrigger: () -> Void

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        register()
    }

    private func register() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let me = Unmanaged<GlobalHotkey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { me.onTrigger() }
                return noErr
            },
            1,
            &eventSpec,
            selfPtr,
            &handlerRef
        )
        let id = EventHotKeyID(signature: OSType(0x5652_4241), id: 1) // 'VRBA'
        let modifiers = UInt32(controlKey | optionKey)
        RegisterEventHotKey(UInt32(kVK_ANSI_S), modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}

// MARK: - Click-Through Floating Subtitle Panel

private final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SubtitleOverlayController {
    private let model: AppModel
    private var panel: SubtitlePanel?
    private var mouseMonitorGlobal: Any?
    private var mouseMonitorLocal: Any?
    private var hoverState = HoverState()
    private var editMode = false {
        didSet {
            if oldValue != editMode {
                panel?.ignoresMouseEvents = !editMode
                model.overlayEditMode = editMode
            }
        }
    }

    private struct HoverState {
        var inside = false
        var lastPoint: NSPoint = .zero
        var stillTimer: Timer?
    }

    private let frameKey = "VerbaOverlayFrame"

    init(model: AppModel) {
        self.model = model
    }

    func syncVisibility() {
        let shouldShow: Bool
        switch model.settings.overlayMode {
        case "off":
            shouldShow = false
        case "always":
            shouldShow = model.listening || model.overlayVisible || model.draft != nil
        default:
            shouldShow = model.overlayVisible
        }

        if shouldShow {
            ensurePanel()
            if !(panel?.isVisible ?? false) {
                panel?.alphaValue = 0
                panel?.orderFrontRegardless()
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    panel?.animator().alphaValue = hoverState.inside && !editMode ? 0.15 : 1.0
                }
            }
        } else if let panel, panel.isVisible {
            editMode = false
            panel.orderOut(nil)
        }
    }

    private func ensurePanel() {
        if panel != nil { return }
        let defaultRect = defaultOverlayFrame()
        let p = SubtitlePanel(
            contentRect: defaultRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.sharingType = .none // Anti-capture: invisible during screen sharing
        p.ignoresMouseEvents = true

        panel = p
        installMouseTracking()
        installRootView()
    }

    private func defaultOverlayFrame() -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: frameKey) {
            let r = NSRectFromString(saved)
            if r.width >= 320 && r.height >= 72 {
                return r
            }
        }
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let w = min(760, screen.width - 80)
        let h: CGFloat = 116
        return NSRect(x: screen.midX - w / 2, y: screen.minY + 46, width: w, height: h)
    }

    private func saveFrame() {
        guard let frame = panel?.frame else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: frameKey)
    }

    private func installMouseTracking() {
        mouseMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluateHover() }
        }
        mouseMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] ev in
            Task { @MainActor [weak self] in self?.evaluateHover() }
            return ev
        }
    }

    private func evaluateHover() {
        guard let panel, panel.isVisible else { return }
        let pt = NSEvent.mouseLocation
        let inFrame = panel.frame.insetBy(dx: -4, dy: -4).contains(pt)

        if inFrame {
            if !hoverState.inside {
                hoverState.inside = true
                hoverState.lastPoint = pt
                if !editMode {
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.14
                        panel.animator().alphaValue = 0.15
                    }
                }
                scheduleEditHold(at: pt)
            } else if hypot(pt.x - hoverState.lastPoint.x, pt.y - hoverState.lastPoint.y) > 4 {
                hoverState.lastPoint = pt
                if !editMode {
                    scheduleEditHold(at: pt)
                }
            }
        } else if hoverState.inside {
            hoverState.inside = false
            hoverState.stillTimer?.invalidate()
            hoverState.stillTimer = nil
            if editMode {
                editMode = false
                saveFrame()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 1.0
            }
        }
    }

    private func scheduleEditHold(at point: NSPoint) {
        hoverState.stillTimer?.invalidate()
        hoverState.stillTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel, panel.isVisible, self.hoverState.inside else { return }
                let nowPt = NSEvent.mouseLocation
                if hypot(nowPt.x - point.x, nowPt.y - point.y) <= 5 {
                    self.editMode = true
                    panel.alphaValue = 1.0
                }
            }
        }
    }

    private func installRootView() {
        guard let panel else { return }
        let view = SubtitleOverlayView(
            model: model,
            onDragDelta: { [weak self] dx, dy in
                guard let self, let p = self.panel else { return }
                var f = p.frame
                f.origin.x += dx
                f.origin.y += dy
                p.setFrame(f, display: true)
                self.saveFrame()
            },
            onResize: { [weak self] dw, dh, moveLeft in
                guard let self, let p = self.panel else { return }
                var f = p.frame
                let nextW = max(340, min(1100, f.width + dw))
                let nextH = max(84, min(260, f.height + dh))
                if moveLeft {
                    f.origin.x -= (nextW - f.width)
                }
                f.size.width = nextW
                f.size.height = nextH
                p.setFrame(f, display: true)
                self.saveFrame()
            },
            onOpenNotes: { [weak self] in self?.model.onOpenNotesWindow?() },
            onHide: { [weak self] in
                self?.model.overlayVisible = false
                self?.syncVisibility()
            }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
    }
}

private struct SubtitleOverlayView: View {
    @ObservedObject var model: AppModel
    let onDragDelta: (CGFloat, CGFloat) -> Void
    let onResize: (CGFloat, CGFloat, Bool) -> Void
    let onOpenNotes: () -> Void
    let onHide: () -> Void

    @State private var lastDrag: CGSize = .zero

    private var editMode: Bool { model.overlayEditMode }

    private var activeLines: [TranscriptLine] {
        let lines = model.liveSession?.lines ?? []
        return Array(lines.suffix(2))
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: NSColor(srgbRed: 0.08, green: 0.09, blue: 0.115, alpha: 0.88)))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(editMode ? Color(hex: 0xE8552B) : Color.white.opacity(0.14), lineWidth: editMode ? 1.5 : 1)
                )

            VStack(alignment: .leading, spacing: 6) {
                if editMode {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                        Text("拖动调整位置 · 从左右或角落调整宽度")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.72))
                        Spacer()
                        Button("笔记窗口") { onOpenNotes() }
                            .buttonStyle(.borderless)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color(hex: 0xF38B67))
                        Button("隐藏") { onHide() }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                if activeLines.isEmpty && model.draft == nil {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color(hex: 0xE8552B))
                            .frame(width: 7, height: 7)
                        Text(model.listening ? "正在聆听系统声音，等待对方说话…" : "字幕浮层已就绪（按 ⌃⌥S 切换显隐）")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.84))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(activeLines) { line in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.shown)
                                .font(.system(size: 13.5, weight: .regular))
                                .foregroundStyle(.white.opacity(0.74))
                                .lineLimit(2)
                            if let dst = line.dst, !dst.isEmpty {
                                Text(dst)
                                    .font(.system(size: 15.5, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(2)
                            }
                        }
                    }
                    if let d = model.draft {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(Color(hex: 0xE8552B))
                                    .frame(width: 6, height: 6)
                                Text(d.src)
                                    .font(.system(size: 13.5))
                                    .foregroundStyle(.white.opacity(0.62))
                                    .lineLimit(2)
                            }
                            if let dst = d.dst, !dst.isEmpty {
                                Text(dst)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            if editMode {
                HStack {
                    Color.clear.frame(width: 10)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture().onChanged { v in
                                onResize(-v.translation.width, 0, true)
                            }
                        )
                    Spacer()
                    Color.clear.frame(width: 10)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture().onChanged { v in
                                onResize(v.translation.width, 0, false)
                            }
                        )
                }
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    guard editMode else { return }
                    let dx = value.translation.width - lastDrag.width
                    let dy = -(value.translation.height - lastDrag.height)
                    lastDrag = value.translation
                    onDragDelta(dx, dy)
                }
                .onEnded { _ in lastDrag = .zero }
        )
    }
}
