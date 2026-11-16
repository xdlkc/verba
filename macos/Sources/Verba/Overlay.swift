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

// MARK: - Directly Interactive Floating Subtitle Window

private final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class SubtitleOverlayController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let panel: OverlayPanel
    private let view: OverlayView
    private var monitorTimer: Timer?

    private var shown = false
    private var manuallyHidden = false
    private var collapsed = false
    private var isLocked = false {
        didSet {
            panel.ignoresMouseEvents = isLocked
            view.isLocked = isLocked
            if !isLocked { panel.alphaValue = 1.0 }
            view.needsDisplay = true
        }
    }

    private var lastContentAt = Date()
    private var width: CGFloat = 780
    private var fontSize: CGFloat = 24
    private var origin = NSPoint.zero
    private var screenKey = ""

    static let margin: CGFloat = 8

    init(model: AppModel) {
        self.model = model
        self.view = OverlayView(frame: NSRect(x: 0, y: 0, width: 780, height: 140))
        self.panel = OverlayPanel(
            contentRect: view.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false // Always interactive by default so drag/click works immediately
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.sharingType = .none // Invisible during screen sharing
        panel.delegate = self
        panel.contentView = view
        view.controller = self
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard !view.isResizing else { return }
        let m = Self.margin
        origin = NSPoint(x: panel.frame.origin.x + m, y: panel.frame.origin.y + m)
        saveGeometry()
    }

    // MARK: - Model Sync

    func syncFromModel() {
        let mode = model.settings.overlayMode
        if mode == "off" {
            hideWindow()
            return
        }

        let shouldShowWindow = (model.listening || model.overlayVisible || mode == "always") && !manuallyHidden
        if !shouldShowWindow {
            if shown { hideWindow() }
            return
        }

        view.listening = model.listening
        view.micOn = model.roomMicEnabled
        view.alert = (model.systemAudioDenied || (model.lastError != nil && !model.lastError!.isEmpty)) ? model.lastError : nil

        let (src, dst, isStatus) = buildSubtitleStrings()
        let contentChanged = src != view.source || dst != view.translation || isStatus != view.isStatus
        view.source = src
        view.translation = dst
        view.isStatus = isStatus

        if !isStatus && contentChanged && (!src.isEmpty || !dst.isEmpty) {
            lastContentAt = Date()
            if collapsed {
                setCollapsed(false)
            }
        }

        if !shown {
            restoreGeometry()
            collapsed = false
            view.collapsed = false
            showWindow()
        } else {
            layout()
        }
    }

    private func buildSubtitleStrings() -> (String, String, Bool) {
        let lines = model.liveSession?.lines ?? []
        let lastLine = lines.last
        let draft = model.draft

        let src: String
        if let d = draft, !d.src.isEmpty {
            src = d.src
        } else if let l = lastLine {
            src = l.shown
        } else {
            src = ""
        }

        let dst: String
        if let d = draft, let dd = d.dst, !dd.isEmpty {
            if let l = lastLine, let ld = l.dst, !ld.isEmpty, d.src.count < 14 {
                dst = "\(ld) \(dd)"
            } else {
                dst = dd
            }
        } else {
            let recentDst = lines.suffix(2).compactMap { $0.dst }.filter { !$0.isEmpty }
            if !recentDst.isEmpty {
                dst = recentDst.joined(separator: " ")
            } else if !src.isEmpty {
                dst = "正在翻译…"
            } else {
                dst = ""
            }
        }

        if src.isEmpty && dst.isEmpty {
            let hint = model.listening
                ? "正在聆听系统声音…（直接按住拖动位置 · 右下角调大小）"
                : "字幕浮层已就绪（直接拖动调整位置 · 双击恢复居中）"
            return ("", hint, true)
        }
        return (src, dst, false)
    }

    func toggleManual() {
        if !shown || manuallyHidden {
            manuallyHidden = false
            isLocked = false
            collapsed = false
            view.collapsed = false
            lastContentAt = Date()
            model.overlayVisible = true
            syncFromModel()
        } else {
            manuallyHidden = true
            model.overlayVisible = false
            hideWindow()
        }
    }

    func enterEditMode() {
        manuallyHidden = false
        isLocked = false
        collapsed = false
        view.collapsed = false
        lastContentAt = Date()
        model.overlayVisible = true
        syncFromModel()
        view.hover = true
        view.needsDisplay = true
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()
    }

    // MARK: - Window Show / Hide / Collapse

    private func showWindow() {
        shown = true
        layout()
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()
        startMonitorTimer()
    }

    private func hideWindow() {
        shown = false
        monitorTimer?.invalidate()
        monitorTimer = nil
        panel.orderOut(nil)
    }

    private func setCollapsed(_ on: Bool) {
        guard collapsed != on else { return }
        collapsed = on
        view.collapsed = on
        if on { view.hover = false }
        layout()
        panel.alphaValue = 1.0
    }

    private func startMonitorTimer() {
        monitorTimer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        monitorTimer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func tick() {
        guard shown else { return }

        // If user enabled click-through lock, dim smoothly when cursor passes over
        if isLocked {
            let mouse = NSEvent.mouseLocation
            let over = panel.frame.contains(mouse)
            let targetAlpha: CGFloat = over ? 0.18 : 1.0
            if abs(panel.alphaValue - targetAlpha) > 0.05 {
                panel.alphaValue = targetAlpha
            }
        } else if panel.alphaValue < 0.99 {
            panel.alphaValue = 1.0
        }

        // Expand pill immediately if collapsed and pointer touches it
        if collapsed {
            let mouse = NSEvent.mouseLocation
            if panel.frame.insetBy(dx: -8, dy: -8).contains(mouse) {
                lastContentAt = Date()
                setCollapsed(false)
            }
            return
        }

        // Only tuck away when auto-hide elapsed AND cursor isn't hovering/dragging AND real subtitles have ended
        if model.settings.overlayMode == "auto",
           !view.hover,
           !view.isResizing,
           !view.isStatus,
           Date().timeIntervalSince(lastContentAt) > max(3.0, model.settings.overlayHideAfter) {
            setCollapsed(true)
        }
    }

    // MARK: - Actions Triggered by OverlayView

    fileprivate func adjustFont(delta: CGFloat) {
        fontSize = max(16, min(44, fontSize + delta))
        layout()
        saveGeometry()
    }

    fileprivate func toggleMic() {
        model.roomMicEnabled.toggle()
        syncFromModel()
    }

    fileprivate func openNotes() {
        model.onOpenNotesWindow?()
    }

    fileprivate func enableLockClickThrough() {
        isLocked = true
    }

    fileprivate func closeFromBar() {
        manuallyHidden = true
        model.overlayVisible = false
        hideWindow()
    }

    fileprivate func pointerEnteredBar() {
        lastContentAt = Date()
        if collapsed {
            setCollapsed(false)
        }
    }

    // MARK: - Geometry & Per-Screen Persistence

    private func layout() {
        view.fontSize = fontSize
        let m = Self.margin

        if collapsed {
            let pillW: CGFloat = 144
            let pillH: CGFloat = 28
            let x = origin.x + width / 2 - pillW / 2
            let y = origin.y
            panel.setFrame(NSRect(x: x - m, y: y - m, width: pillW + 2 * m, height: pillH + 2 * m), display: true)
            view.needsDisplay = true
            return
        }

        view.transLines = view.neededLines(barWidth: width)
        let h = view.barHeight(fontSize: fontSize)
        panel.setFrame(NSRect(x: origin.x - m, y: origin.y - m, width: width + 2 * m, height: h + 2 * m), display: true)
        view.needsDisplay = true
    }

    private func currentScreen() -> NSScreen {
        let mid = NSPoint(x: origin.x + width / 2, y: origin.y + 20)
        return NSScreen.screens.first { $0.frame.contains(mid) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func key(for screen: NSScreen) -> String {
        let n = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
        return "verba.overlay2.\(n)"
    }

    private func defaults(on screen: NSScreen) {
        let v = screen.visibleFrame
        width = min(840, max(520, v.width - 200))
        fontSize = 24
        origin = NSPoint(x: v.midX - width / 2, y: v.minY + 52)
    }

    private func restoreGeometry() {
        let d = UserDefaults.standard
        let last = d.string(forKey: "verba.overlay2.lastScreen")
        let screen = NSScreen.screens.first { Self.key(for: $0) == last }
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        screenKey = Self.key(for: screen)
        if let a = d.array(forKey: screenKey) as? [Double], a.count == 4 {
            let rect = NSRect(x: a[0], y: a[1], width: a[2], height: 60)
            if screen.frame.intersects(rect) {
                origin = NSPoint(x: a[0], y: a[1])
                width = max(420, min(1600, a[2]))
                fontSize = max(16, min(44, a[3]))
                return
            }
        }
        defaults(on: screen)
    }

    fileprivate func saveGeometry() {
        let screen = currentScreen()
        screenKey = Self.key(for: screen)
        UserDefaults.standard.set([Double(origin.x), Double(origin.y), Double(width), Double(fontSize)], forKey: screenKey)
        UserDefaults.standard.set(screenKey, forKey: "verba.overlay2.lastScreen")
    }

    fileprivate func resetPosition() {
        defaults(on: currentScreen())
        layout()
        saveGeometry()
    }

    // MARK: - Bottom-Right Corner Resize (Keeps Top Edge & Left Edge Pinned)

    private var resizeStartMouse = NSPoint.zero
    private var resizeStartWidth: CGFloat = 0
    private var resizeStartFont: CGFloat = 0
    private var resizeStartTop: CGFloat = 0

    fileprivate func beginResize() {
        resizeStartMouse = NSEvent.mouseLocation
        resizeStartWidth = width
        resizeStartFont = fontSize
        resizeStartTop = origin.y + view.barHeight(fontSize: fontSize)
    }

    fileprivate func updateResize() {
        let p = NSEvent.mouseLocation
        let dx = p.x - resizeStartMouse.x
        let screen = currentScreen()
        let maxW = min(1600, screen.visibleFrame.width - 32)
        let newW = max(420, min(maxW, resizeStartWidth + dx))
        width = newW
        fontSize = max(16, min(44, (resizeStartFont * newW / resizeStartWidth).rounded()))
        view.transLines = view.neededLines(barWidth: width)
        let newH = view.barHeight(fontSize: fontSize)
        origin.y = max(screen.visibleFrame.minY + 8, resizeStartTop - newH)
        layout()
    }

    fileprivate func endResize() {
        saveGeometry()
    }
}

// MARK: - Custom-Drawn View with Instant Hover Toolbar & Native Drag

private final class OverlayView: NSView {
    weak var controller: SubtitleOverlayController?

    var source = ""
    var translation = ""
    var isStatus = false
    var alert: String?
    var fontSize: CGFloat = 24
    var hover = false
    var collapsed = false
    var isLocked = false
    var isResizing = false
    var transLines = 1
    var micOn = false
    var listening = false

    private var trackingArea: NSTrackingArea?
    private let accent = NSColor(srgbRed: 0.91, green: 0.33, blue: 0.17, alpha: 1)

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hover = true
        controller?.pointerEnteredBar()
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        if !isResizing {
            hover = false
            needsDisplay = true
        }
    }

    // Metrics
    private var topToolbarHeight: CGFloat { 26 }
    private func k(_ fs: CGFloat) -> CGFloat { fs / 24 }
    private func srcFont(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: max(12, fs * 0.56), weight: .medium) }
    private func transFont(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: fs, weight: .semibold) }
    private func alertFont(_ fs: CGFloat) -> NSFont { .systemFont(ofSize: max(11, fs * 0.48), weight: .semibold) }
    private func lineHeight(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) * 1.18 }
    private func alertHeight(_ fs: CGFloat) -> CGFloat { ceil(lineHeight(alertFont(fs)) + 6 * k(fs)) }

    func barHeight(fontSize fs: CGFloat) -> CGFloat {
        let bottomPad = 12 * k(fs)
        let topPad = topToolbarHeight + 6
        var h = topPad + bottomPad + lineHeight(srcFont(fs)) + 5 * k(fs) + lineHeight(transFont(fs)) * CGFloat(transLines)
        if alert != nil { h += alertHeight(fs) + 6 * k(fs) }
        return ceil(max(96, h))
    }

    private var barRect: NSRect { bounds.insetBy(dx: SubtitleOverlayController.margin, dy: SubtitleOverlayController.margin) }

    // Hit Rects for Toolbar Buttons (inside top bar strip, right-aligned)
    private var closeBtnRect: NSRect {
        NSRect(x: barRect.maxX - 30, y: barRect.maxY - 26, width: 22, height: 20)
    }
    private var lockBtnRect: NSRect {
        NSRect(x: closeBtnRect.minX - 52, y: barRect.maxY - 26, width: 48, height: 20)
    }
    private var notesBtnRect: NSRect {
        NSRect(x: lockBtnRect.minX - 46, y: barRect.maxY - 26, width: 42, height: 20)
    }
    private var micBtnRect: NSRect {
        NSRect(x: notesBtnRect.minX - 28, y: barRect.maxY - 26, width: 24, height: 20)
    }
    private var fontPlusRect: NSRect {
        NSRect(x: micBtnRect.minX - 30, y: barRect.maxY - 26, width: 26, height: 20)
    }
    private var fontMinusRect: NSRect {
        NSRect(x: fontPlusRect.minX - 28, y: barRect.maxY - 26, width: 26, height: 20)
    }

    private var gripRect: NSRect {
        NSRect(x: barRect.maxX - 24, y: barRect.minY + 2, width: 22, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        if collapsed {
            let pill = barRect
            NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 0.88).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            NSColor.white.withAlphaComponent(0.18).setStroke()
            let border = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
            border.lineWidth = 0.8
            border.stroke()

            (listening ? accent : NSColor.systemGray).setFill()
            NSBezierPath(ovalIn: NSRect(x: pill.minX + 12, y: pill.midY - 3.5, width: 7, height: 7)).fill()

            let label = listening ? "正在聆听 · 悬停展开" : "字幕已收起"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.88),
            ]
            let sz = (label as NSString).size(withAttributes: attrs)
            (label as NSString).draw(at: NSPoint(x: pill.minX + 25, y: pill.midY - sz.height / 2), withAttributes: attrs)
            return
        }

        let bar = barRect
        let radius: CGFloat = 14
        NSColor(srgbRed: 0.06, green: 0.07, blue: 0.095, alpha: 0.90).setFill()
        NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()

        let border = NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius)
        border.lineWidth = hover ? 1.4 : 0.8
        (hover ? accent.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.16)).setStroke()
        border.stroke()

        // Top toolbar controls (always crisp and immediately clickable on hover)
        if hover && !isLocked {
            let hintAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.60),
            ]
            let dotColor = listening ? accent : NSColor.white.withAlphaComponent(0.45)
            dotColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: bar.minX + 12, y: bar.maxY - 19, width: 6, height: 6)).fill()
            ("按住任意空白处拖动 · 双击复位" as NSString).draw(at: NSPoint(x: bar.minX + 23, y: bar.maxY - 22), withAttributes: hintAttrs)

            drawToolText(fontMinusRect, title: "A-", active: false)
            drawToolText(fontPlusRect, title: "A+", active: false)
            drawToolSymbol(micBtnRect, symbol: micOn ? "mic.fill" : "mic", active: micOn)
            drawToolText(notesBtnRect, title: "笔记", active: false)
            drawToolText(lockBtnRect, title: "穿透", active: false)
            drawToolSymbol(closeBtnRect, symbol: "xmark", active: false)

            // Bottom-right corner resize grip lines
            let g = gripRect
            let p = NSBezierPath()
            p.lineWidth = 1.6
            p.lineCapStyle = .round
            p.move(to: NSPoint(x: g.minX + 6, y: g.minY + 4))
            p.line(to: NSPoint(x: g.maxX - 4, y: g.maxY - 6))
            p.move(to: NSPoint(x: g.midX + 1, y: g.minY + 4))
            p.line(to: NSPoint(x: g.maxX - 4, y: g.midY - 1))
            NSColor.white.withAlphaComponent(0.65).setStroke()
            p.stroke()
        }

        // Subtitle Text
        let fs = fontSize
        let padX = 24 * k(fs)
        let inner = NSRect(
            x: bar.minX + padX,
            y: bar.minY + 10 * k(fs),
            width: max(60, bar.width - 2 * padX),
            height: max(20, bar.height - topToolbarHeight - 14 * k(fs))
        )
        var y = inner.maxY

        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.lineBreakMode = .byWordWrapping

        func drawSub(_ text: String, font: NSFont, color: NSColor, maxLines: Int) {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: center]
            let maxH = lineHeight(font) * CGFloat(maxLines)
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
            let w = min(inner.width, ceil(sz.width) + 22 * k(fs))
            let pill = NSRect(x: inner.midX - w / 2, y: y - h, width: w, height: h)
            accent.setFill()
            NSBezierPath(roundedRect: pill, xRadius: h / 2, yRadius: h / 2).fill()
            (alert as NSString).draw(at: NSPoint(x: pill.midX - min(sz.width, w - 10) / 2, y: pill.midY - sz.height / 2), withAttributes: attrs)
            y -= h + 6 * k(fs)
        }

        let srcText = isStatus ? "" : source
        drawSub(srcText, font: srcFont(fs), color: NSColor.white.withAlphaComponent(0.65), maxLines: 1)
        y -= 4 * k(fs)
        drawSub(
            translation,
            font: transFont(fs),
            color: isStatus ? NSColor.white.withAlphaComponent(0.78) : .white,
            maxLines: transLines
        )
    }

    private func drawToolText(_ rect: NSRect, title: String, active: Bool) {
        (active ? accent : NSColor.white.withAlphaComponent(0.14)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        let sz = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2), withAttributes: attrs)
    }

    private func drawToolSymbol(_ rect: NSRect, symbol: String, active: Bool) {
        (active ? accent : NSColor.white.withAlphaComponent(0.14)).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        let cfg = NSImage.SymbolConfiguration(pointSize: 10.5, weight: .semibold)
            .applying(.init(paletteColors: [NSColor.white]))
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
        let w = max(60, barWidth - 48 * k(fs))
        return height(of: translation, attrs: attrs, width: w) > lineHeight(transFont(fs)) * 1.3 ? 2 : 1
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

    // MARK: - Direct Mouse Down / Native OS Window Drag / Resize

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)

        if collapsed {
            controller?.pointerEnteredBar()
            window?.performDrag(with: event)
            return
        }

        if hover && fontMinusRect.contains(p) {
            controller?.adjustFont(delta: -2)
            return
        }
        if hover && fontPlusRect.contains(p) {
            controller?.adjustFont(delta: 2)
            return
        }
        if hover && micBtnRect.contains(p) {
            controller?.toggleMic()
            return
        }
        if hover && notesBtnRect.contains(p) {
            controller?.openNotes()
            return
        }
        if hover && lockBtnRect.contains(p) {
            controller?.enableLockClickThrough()
            return
        }
        if hover && closeBtnRect.contains(p) {
            controller?.closeFromBar()
            return
        }

        if gripRect.insetBy(dx: -8, dy: -8).contains(p) {
            isResizing = true
            controller?.beginResize()
            NSCursor.crosshair.push()
            return
        }

        if event.clickCount == 2 {
            controller?.resetPosition()
            return
        }

        // Let macOS WindowServer drag the borderless window smoothly with 0 jitter
        window?.performDrag(with: event)
        controller?.saveGeometry()
    }

    override func mouseDragged(with event: NSEvent) {
        if isResizing {
            controller?.updateResize()
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing {
            isResizing = false
            NSCursor.pop()
            controller?.endResize()
        }
    }

    override func resetCursorRects() {
        addCursorRect(barRect, cursor: .openHand)
        if hover && !isLocked {
            addCursorRect(gripRect.insetBy(dx: -4, dy: -4), cursor: .crosshair)
            addCursorRect(fontMinusRect, cursor: .pointingHand)
            addCursorRect(fontPlusRect, cursor: .pointingHand)
            addCursorRect(micBtnRect, cursor: .pointingHand)
            addCursorRect(notesBtnRect, cursor: .pointingHand)
            addCursorRect(lockBtnRect, cursor: .pointingHand)
            addCursorRect(closeBtnRect, cursor: .pointingHand)
        }
    }
}
