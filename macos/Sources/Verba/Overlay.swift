import AppKit
import Carbon.HIToolbox

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

// MARK: - Pure AppKit Floating Subtitle Overlay

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SubtitleOverlayController {
    enum Pointer: Equatable {
        case away
        case passing   // Mouse passing over: faded to 15% and click-through
        case editing   // Mouse rested 0.45s or requested: outline + corner grip + quick buttons
    }

    enum Visibility: Equatable {
        case hidden
        case open(Pointer)
        case tucked
        case peeking
        case manuallyHidden
    }

    private let model: AppModel
    private let panel: OverlayPanel
    private let view: OverlayView
    private var hoverTimer: Timer?

    private(set) var visibility: Visibility = .hidden
    private var lastContentAt = Date()
    private var lastMouse = NSPoint.zero
    private var stillFor: Double = 0
    private var forcedEditUntilLeave = false
    private static let pollInterval: Double = 0.05

    private var width: CGFloat = 860
    private var fontSize: CGFloat = 26
    private var origin = NSPoint.zero
    private var screenKey = ""
    static let margin: CGFloat = 12

    init(model: AppModel) {
        self.model = model
        self.view = OverlayView(frame: NSRect(x: 0, y: 0, width: 860, height: 140))
        self.panel = OverlayPanel(
            contentRect: view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.sharingType = .none // Anti-capture during screen sharing
        panel.contentView = view
        view.controller = self
    }

    // MARK: - Model Sync

    func syncFromModel() {
        let mode = model.settings.overlayMode
        if mode == "off" {
            if visibility != .hidden { hide() }
            return
        }

        let hasLiveLines = !(model.liveSession?.lines.isEmpty ?? true)
        let hasDraft = model.draft != nil
        let shouldExist = model.listening || model.overlayVisible || mode == "always"

        guard shouldExist else {
            if visibility != .hidden { hide() }
            return
        }

        if visibility == .hidden {
            show(startExpanded: model.overlayVisible || mode == "always" || hasLiveLines || hasDraft)
        } else if visibility == .manuallyHidden && model.overlayVisible {
            lastContentAt = Date()
            setExpanded(true, animated: true)
        }

        view.listening = model.listening
        view.micOn = model.roomMicEnabled
        view.alert = (model.systemAudioDenied || (model.lastError != nil && !model.lastError!.isEmpty)) ? model.lastError : nil

        let (src, dst, isStatus) = buildSubtitleStrings()
        updateSubtitle(source: src, translation: dst, isStatus: isStatus)

        if mode != "auto", visibility == .tucked {
            lastContentAt = Date()
            expand()
        }
    }

    private func buildSubtitleStrings() -> (String, String, Bool) {
        let lines = model.liveSession?.lines ?? []
        let lastLine = lines.last
        let draft = model.draft

        var srcParts: [String] = []
        if let l = lastLine {
            // Only keep previous line if no fresh draft is already showing, or show last finalized + draft concisely
            if let d = draft, !d.src.isEmpty {
                srcParts = [d.src]
            } else {
                srcParts = [l.shown]
            }
        } else if let d = draft, !d.src.isEmpty {
            srcParts = [d.src]
        }

        var dstParts: [String] = []
        if let d = draft, let dd = d.dst, !dd.isEmpty {
            if let l = lastLine, let ld = l.dst, !ld.isEmpty, d.src.count < 16 {
                dstParts = [ld, dd]
            } else {
                dstParts = [dd]
            }
        } else {
            let recentDst = lines.suffix(2).compactMap { $0.dst }.filter { !$0.isEmpty }
            if !recentDst.isEmpty {
                dstParts = [recentDst.joined(separator: " ")]
            } else if let d = draft, !d.src.isEmpty {
                dstParts = ["翻译中…"]
            }
        }

        let src = srcParts.joined(separator: " ")
        let dst = dstParts.joined(separator: " ")

        if src.isEmpty && dst.isEmpty {
            let hint = model.listening
                ? "正在聆听系统声音…（鼠标停留 0.5s 可拖动/缩放 · ⌃⌥S 隐藏）"
                : "字幕浮层已就绪（点击开始聆听 · 双击重置位置）"
            return ("", hint, true)
        }
        return (src, dst, false)
    }

    private func updateSubtitle(source: String, translation: String, isStatus: Bool) {
        let changed = source != view.source || translation != view.translation || isStatus != view.isStatus
        guard changed else { return }

        view.source = source
        view.translation = translation
        view.isStatus = isStatus

        let lines = view.neededLines(barWidth: width)
        if lines != view.transLines, view.dragMode == nil {
            view.transLines = lines
            layout()
        }
        view.needsDisplay = true

        if !isStatus && (!source.isEmpty || !translation.isEmpty) {
            lastContentAt = Date()
            if visibility == .tucked {
                expand()
            }
        }
    }

    func toggleManual() {
        if visibility == .hidden {
            model.overlayVisible = true
            show(startExpanded: true)
            syncFromModel()
            return
        }
        if visibility == .manuallyHidden || visibility == .tucked {
            lastContentAt = Date()
            model.overlayVisible = true
            setExpanded(true, animated: true)
        } else {
            setHover(false)
            visibility = .manuallyHidden
            model.overlayVisible = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 0
            }
        }
    }

    func enterEditMode() {
        if visibility == .hidden {
            model.overlayVisible = true
            show(startExpanded: true)
            syncFromModel()
        } else if visibility == .tucked || visibility == .manuallyHidden {
            model.overlayVisible = true
            setExpanded(true, animated: true)
        }
        forcedEditUntilLeave = true
        lastContentAt = Date()
        panel.alphaValue = 1
        setHover(true)
    }

    // MARK: - Actions called from OverlayView

    fileprivate func openNotes() {
        model.onOpenNotesWindow?()
    }

    fileprivate func toggleMic() {
        model.roomMicEnabled.toggle()
        syncFromModel()
    }

    fileprivate func dismissOrTuck() {
        setHover(false)
        if model.settings.overlayMode == "auto" && model.listening {
            setExpanded(false, animated: true)
        } else {
            visibility = .manuallyHidden
            model.overlayVisible = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 0
            }
        }
    }

    // MARK: - Show / Hide

    private func show(startExpanded: Bool) {
        restore()
        setExpanded(startExpanded, animated: false)
        layout()
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        startHoverPoll()
    }

    private func hide() {
        visibility = .hidden
        hoverTimer?.invalidate()
        hoverTimer = nil
        forcedEditUntilLeave = false
        setHover(false)
        panel.orderOut(nil)
    }

    private func startHoverPoll() {
        hoverTimer?.invalidate()
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollHover()
            }
        }
        hoverTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func expand() {
        guard visibility != .hidden, visibility != .manuallyHidden else { return }
        if visibility == .tucked {
            setExpanded(true, animated: true)
        }
    }

    private func setExpanded(_ on: Bool, animated: Bool) {
        if !on {
            stillFor = 0
            forcedEditUntilLeave = false
            setHover(false)
        }
        visibility = on ? .open(.away) : .tucked

        if !animated {
            view.collapsed = !on
            view.needsDisplay = true
            panel.alphaValue = 1
            return
        }

        if on {
            view.collapsed = false
            view.needsDisplay = true
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.28
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.visibility == .tucked else { return }
                    self.view.collapsed = true
                    self.view.needsDisplay = true
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.18
                        self.panel.animator().alphaValue = 1
                    }
                }
            })
        }
    }

    // MARK: - Geometry & Per-Display Persistence

    private var barHeight: CGFloat { view.barHeight(fontSize: fontSize) }
    var barFrame: NSRect { NSRect(x: origin.x, y: origin.y, width: width, height: barHeight) }
    private var pillFrame: NSRect { NSRect(x: origin.x + width / 2 - 36, y: origin.y - 6, width: 72, height: 32) }

    private func layout() {
        view.fontSize = fontSize
        let m = Self.margin
        let frame = NSRect(x: origin.x - m, y: origin.y - m, width: width + 2 * m, height: barHeight + 2 * m)
        panel.setFrame(frame, display: true)
        view.needsDisplay = true
    }

    private func currentScreen() -> NSScreen {
        let mid = NSPoint(x: origin.x + width / 2, y: origin.y + 10)
        return NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func key(for screen: NSScreen) -> String {
        let n = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
        return "verba.overlay.\(n)"
    }

    private func defaults(on screen: NSScreen) {
        let v = screen.visibleFrame
        width = min(940, max(540, v.width - 180))
        fontSize = 26
        origin = NSPoint(x: v.midX - width / 2, y: v.minY + 52)
    }

    private func restore() {
        let d = UserDefaults.standard
        let last = d.string(forKey: "verba.overlay.lastScreen")
        let screen = NSScreen.screens.first { Self.key(for: $0) == last }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        screenKey = Self.key(for: screen)
        if let a = d.array(forKey: screenKey) as? [Double], a.count == 4 {
            let rect = NSRect(x: a[0], y: a[1], width: a[2], height: 40)
            if screen.frame.intersects(rect) {
                origin = NSPoint(x: a[0], y: a[1])
                width = max(420, min(1800, a[2]))
                fontSize = max(18, min(48, a[3]))
                return
            }
        }
        defaults(on: screen)
    }

    private func save() {
        let screen = currentScreen()
        screenKey = Self.key(for: screen)
        UserDefaults.standard.set([Double(origin.x), Double(origin.y), Double(width), Double(fontSize)], forKey: screenKey)
        UserDefaults.standard.set(screenKey, forKey: "verba.overlay.lastScreen")
    }

    fileprivate func resetPosition() {
        defaults(on: currentScreen())
        layout()
        save()
    }

    // MARK: - Hover State Machine (50ms Common RunLoop Polling)

    private var dimmed: Bool { visibility == .open(.passing) }
    private var expanded: Bool {
        switch visibility {
        case .open, .peeking, .manuallyHidden: true
        case .hidden, .tucked: false
        }
    }

    private func setDimmed(_ on: Bool) {
        guard dimmed != on, case .open = visibility else { return }
        visibility = .open(on ? .passing : .away)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = on ? 0.12 : 0.22
            panel.animator().alphaValue = on ? 0.15 : 1.0
        }
    }

    private func pollHover() {
        guard visibility != .hidden, visibility != .manuallyHidden, view.dragMode == nil else { return }
        let mouse = NSEvent.mouseLocation
        let moved = hypot(mouse.x - lastMouse.x, mouse.y - lastMouse.y) > 2
        lastMouse = mouse

        // Tucked away: hover the pill to peek at the latest subtitle
        if !expanded {
            if pillFrame.contains(mouse) {
                setExpanded(true, animated: true)
                visibility = .peeking
            }
            return
        }

        let overBar = barFrame.insetBy(dx: -6, dy: -6).contains(mouse)
        if visibility == .open(.editing) {
            if forcedEditUntilLeave {
                if overBar { forcedEditUntilLeave = false }
                return
            }
            if !overBar {
                setHover(false)
                stillFor = 0
            }
            return
        }

        if visibility == .peeking {
            if !overBar && !pillFrame.contains(mouse) {
                if model.settings.overlayMode == "auto" {
                    setExpanded(false, animated: true)
                } else {
                    visibility = .open(.away)
                }
            }
            return
        }

        if overBar {
            setDimmed(true)
            stillFor = moved ? 0 : stillFor + Self.pollInterval
            if stillFor >= 0.45 {
                setDimmed(false)
                setHover(true)
            }
        } else {
            stillFor = 0
            setDimmed(false)
        }

        if model.settings.overlayMode == "auto",
           visibility == .open(.away),
           !view.isStatus,
           Date().timeIntervalSince(lastContentAt) > max(2.0, model.settings.overlayHideAfter) {
            setExpanded(false, animated: true)
        }
    }

    private func setHover(_ on: Bool) {
        if case .open = visibility {
            visibility = .open(on ? .editing : .away)
        }
        view.hover = on
        panel.ignoresMouseEvents = !on
        view.needsDisplay = true
    }

    // MARK: - Smooth Screen-Space Drag & Scale

    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero
    private var dragStartWidth: CGFloat = 0
    private var dragStartFont: CGFloat = 0
    private var snapped = false

    fileprivate func beginDrag() {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = origin
        dragStartWidth = width
        dragStartFont = fontSize
        snapped = false
    }

    fileprivate func drag(scale: Bool) {
        let p = NSEvent.mouseLocation
        let dx = p.x - dragStartMouse.x
        let dy = p.y - dragStartMouse.y
        let screen = currentScreen()
        let sf = screen.frame

        if scale {
            let maxW = min(1800, sf.width - 24)
            width = max(420, min(maxW, dragStartWidth + dx))
            fontSize = max(18, min(48, (dragStartFont * width / dragStartWidth).rounded()))
            let oldTop = dragStartOrigin.y + view.barHeight(fontSize: dragStartFont)
            origin = NSPoint(x: dragStartOrigin.x, y: oldTop - view.barHeight(fontSize: fontSize))
        } else {
            var x = dragStartOrigin.x + dx
            let y = dragStartOrigin.y + dy
            let center = screen.visibleFrame.midX
            if abs(x + width / 2 - center) < 18 {
                x = center - width / 2
                if !snapped {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                snapped = true
            } else {
                snapped = false
            }
            origin = NSPoint(x: x, y: y)
        }

        let all = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
        origin.x = max(all.minX + 4 - width + 120, min(all.maxX - 120, origin.x))
        origin.y = max(all.minY + 4, min(all.maxY - barHeight - 4, origin.y))
        view.snapped = snapped && !scale
        layout()
    }

    fileprivate func endDrag() {
        view.snapped = false
        save()
        view.needsDisplay = true
    }
}

// MARK: - AppKit Custom-Drawn View

private final class OverlayView: NSView {
    weak var controller: SubtitleOverlayController?

    var source = ""
    var translation = ""
    var isStatus = false
    var alert: String?
    var fontSize: CGFloat = 26
    var hover = false
    var snapped = false
    var collapsed = false
    var transLines = 1
    var dragMode: Bool?
    var micOn = false
    var listening = false

    private let accent = NSColor(srgbRed: 0.91, green: 0.33, blue: 0.17, alpha: 1)

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func k(_ fs: CGFloat) -> CGFloat { fs / 28 }
    private func srcFont(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: max(12, fs * 0.56), weight: .medium) }
    private func transFont(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: fs, weight: .semibold) }
    private func alertFont(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: max(11, fs * 0.45), weight: .semibold) }
    private func line(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) * 1.18 }
    private func alertHeight(_ fs: CGFloat) -> CGFloat { ceil(line(alertFont(fs)) + 6 * k(fs)) }

    func barHeight(fontSize fs: CGFloat) -> CGFloat {
        let pad = 14 * k(fs)
        var h = pad * 2 + line(srcFont(fs)) + 6 * k(fs) + line(transFont(fs)) * CGFloat(transLines)
        if alert != nil { h += alertHeight(fs) + 8 * k(fs) }
        return ceil(h)
    }

    private var barRect: NSRect { bounds.insetBy(dx: SubtitleOverlayController.margin, dy: SubtitleOverlayController.margin) }

    private var gripRect: NSRect {
        let s: CGFloat = 26
        return NSRect(x: barRect.maxX - s + 6, y: barRect.minY - 6, width: s, height: s)
    }

    private var micRect: NSRect {
        let s: CGFloat = 26
        return NSRect(x: barRect.minX - 6, y: barRect.minY - 6, width: s + 4, height: s)
    }

    private var notesRect: NSRect {
        let s: CGFloat = 26
        return NSRect(x: micRect.maxX + 6, y: barRect.minY - 6, width: s + 4, height: s)
    }

    private var closeRect: NSRect {
        let s: CGFloat = 26
        return NSRect(x: barRect.maxX - s + 6, y: barRect.maxY - s + 6, width: s, height: s)
    }

    override func draw(_ dirtyRect: NSRect) {
        if collapsed {
            let pill = NSRect(x: barRect.midX - 24, y: barRect.minY, width: 48, height: 18)
            NSColor(calibratedWhite: 0.06, alpha: 0.78).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 9, yRadius: 9).fill()
            (listening ? accent : NSColor.white.withAlphaComponent(0.6)).setFill()
            NSBezierPath(ovalIn: NSRect(x: pill.minX + 12, y: pill.midY - 2.5, width: 5, height: 5)).fill()
            NSColor.white.withAlphaComponent(0.45).setFill()
            NSBezierPath(ovalIn: NSRect(x: pill.minX + 21.5, y: pill.midY - 1.5, width: 3, height: 3)).fill()
            NSBezierPath(ovalIn: NSRect(x: pill.minX + 29, y: pill.midY - 1.5, width: 3, height: 3)).fill()
            return
        }

        let bar = barRect
        let radius = 16 * k(fontSize)
        NSColor(srgbRed: 0.06, green: 0.07, blue: 0.09, alpha: 0.90).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

        if hover {
            let outline = NSBezierPath(roundedRect: bar.insetBy(dx: -2.5, dy: -2.5), xRadius: radius + 2.5, yRadius: radius + 2.5)
            outline.lineWidth = 1.5
            (snapped ? accent : NSColor.white.withAlphaComponent(0.55)).setStroke()
            outline.stroke()
        } else {
            let hairline = NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius)
            hairline.lineWidth = 0.8
            NSColor.white.withAlphaComponent(0.12).setStroke()
            hairline.stroke()
        }

        let fs = fontSize
        let pad = 14 * k(fs)
        let inner = bar.insetBy(dx: 28 * k(fs), dy: pad)
        var y = inner.maxY

        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.lineBreakMode = .byWordWrapping

        func drawText(_ text: String, font: NSFont, color: NSColor, maxLines: Int) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: center]
            let maxH = line(font) * CGFloat(maxLines)
            let fitted = fitTail(text, attrs: attrs, width: inner.width, maxHeight: maxH + 1)
            let h = min(maxH, height(of: fitted, attrs: attrs, width: inner.width))
            let rect = NSRect(x: inner.minX, y: y - maxH, width: inner.width, height: h)
            (fitted as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attrs)
            y -= maxH
        }

        if let alert {
            let f = alertFont(fs)
            let attrs: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: NSColor.white]
            let sz = (alert as NSString).size(withAttributes: attrs)
            let h = alertHeight(fs)
            let w = min(inner.width, ceil(sz.width) + 24 * k(fs))
            let pill = NSRect(x: inner.midX - w / 2, y: y - h, width: w, height: h)
            accent.setFill()
            NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill()
            (alert as NSString).draw(at: NSPoint(x: pill.midX - min(sz.width, w - 12) / 2, y: pill.midY - sz.height / 2), withAttributes: attrs)
            y -= h + 8 * k(fs)
        }

        let srcText = isStatus ? "" : source
        drawText(srcText, font: srcFont(fs), color: NSColor.white.withAlphaComponent(0.64), maxLines: 1)
        y -= 6 * k(fs)
        drawText(
            translation,
            font: transFont(fs),
            color: isStatus ? NSColor.white.withAlphaComponent(0.75) : .white,
            maxLines: transLines
        )

        if hover {
            drawCornerButton(micRect, symbol: micOn ? "mic.fill" : "mic", active: micOn)
            drawCornerButton(notesRect, symbol: "note.text", active: false)
            drawCornerButton(closeRect, symbol: "xmark", active: false)

            // Bottom-right proportional resize grip
            let g = gripRect
            NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
            NSBezierPath(roundedRect: g, xRadius: 8, yRadius: 8).fill()
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.move(to: NSPoint(x: g.minX + 8, y: g.minY + 7))
            path.line(to: NSPoint(x: g.maxX - 7, y: g.maxY - 8))
            path.move(to: NSPoint(x: g.midX + 1, y: g.minY + 7))
            path.line(to: NSPoint(x: g.maxX - 7, y: g.midY - 1))
            NSColor(calibratedWhite: 0.1, alpha: 1).setStroke()
            path.stroke()
        }
    }

    private func drawCornerButton(_ rect: NSRect, symbol: String, active: Bool) {
        let bg = active ? NSColor(srgbRed: 0.99, green: 0.93, blue: 0.906, alpha: 1) : NSColor(calibratedWhite: 0.94, alpha: 1)
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        let fg = active ? accent : NSColor(calibratedWhite: 0.1, alpha: 1)
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold).applying(.init(paletteColors: [fg]))
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            img.draw(in: NSRect(
                x: rect.midX - img.size.width / 2,
                y: rect.midY - img.size.height / 2,
                width: img.size.width,
                height: img.size.height
            ))
        }
    }

    func neededLines(barWidth: CGFloat) -> Int {
        let fs = fontSize
        let attrs: [NSAttributedString.Key: Any] = [.font: transFont(fs)]
        let w = barWidth - 56 * k(fs)
        return height(of: translation, attrs: attrs, width: w) > line(transFont(fs)) * 1.3 ? 2 : 1
    }

    private func height(of s: String, attrs: [NSAttributedString.Key: Any], width: CGFloat) -> CGFloat {
        ceil((s as NSString).boundingRect(
            with: NSSize(width: max(width, 40), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        ).height)
    }

    private func fitTail(_ text: String, attrs: [NSAttributedString.Key: Any], width: CGFloat, maxHeight: CGFloat) -> String {
        if text.isEmpty || height(of: text, attrs: attrs, width: width) <= maxHeight { return text }
        let chars = Array(text)
        var lo = 0
        var hi = chars.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if height(of: "…" + String(chars[mid...]), attrs: attrs, width: width) <= maxHeight {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return "…" + String(chars[min(lo, chars.count)...])
    }

    // MARK: - Mouse Dragging & Resizing

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            controller?.resetPosition()
            return
        }
        let p = convert(event.locationInWindow, from: nil)
        if hover && micRect.insetBy(dx: -4, dy: -4).contains(p) {
            controller?.toggleMic()
            return
        }
        if hover && notesRect.insetBy(dx: -4, dy: -4).contains(p) {
            controller?.openNotes()
            return
        }
        if hover && closeRect.insetBy(dx: -4, dy: -4).contains(p) {
            controller?.dismissOrTuck()
            return
        }
        dragMode = gripRect.insetBy(dx: -6, dy: -6).contains(p)
        controller?.beginDrag()
        (dragMode == true ? NSCursor.crosshair : NSCursor.closedHand).push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let mode = dragMode else { return }
        controller?.drag(scale: mode)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragMode != nil else { return }
        dragMode = nil
        NSCursor.pop()
        controller?.endDrag()
    }

    override func resetCursorRects() {
        if hover {
            addCursorRect(barRect, cursor: .openHand)
            addCursorRect(gripRect, cursor: .crosshair)
            addCursorRect(micRect, cursor: .pointingHand)
            addCursorRect(notesRect, cursor: .pointingHand)
            addCursorRect(closeRect, cursor: .pointingHand)
        }
    }
}
