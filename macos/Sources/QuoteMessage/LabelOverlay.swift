//
//  LabelOverlay.swift
//  Transparent, click-through overlay that stamps A–H circles next to bubbles.
//
//  Port of `overlay/label_overlay.py`.
//
//  Key points:
//    * The overlay window itself is transparent and click-through — it
//      does not steal focus from WeChat.  Key capture is done by the
//      process-wide NSEvent monitor that also listens for Ctrl+Q.
//    * Coordinates: Message rects come from BubbleDetector in CGWindow
//      space (top-left origin, y grows DOWN).  AppKit window frames
//      use bottom-left origin.  We convert when placing the overlay
//      and when drawing each label.
//

import AppKit

/// Result of an overlay interaction.
enum OverlayOutcome {
    case picked(letter: String, message: Message)
    case cancelled
}

final class LabelOverlay: KeyCaptureDelegate {

    private let messages: [Message]
    private let completion: (OverlayOutcome) -> Void

    private var window: NSWindow?
    private var view: OverlayView?

    /// CGEventTap that intercepts + SWALLOWS keyDown events while the
    /// overlay is up.  Without this, WeChat's input field receives the
    /// letter (prints "a") at the same moment we trigger the quote.
    private var keyTap: KeyCaptureTap?

    /// Fallback NSEvent monitor — used if CGEventTap can't start (e.g.
    /// Accessibility not granted).  It observes but can't swallow,
    /// so behaviour matches the previous build.
    private var fallbackMonitor: Any?

    private var finished = false

    init(messages: [Message], completion: @escaping (OverlayOutcome) -> Void) {
        self.messages = Array(messages.prefix(Config.maxMessages))
        self.completion = completion
    }

    // MARK: - Lifecycle

    func present() {
        // Virtual-desktop bounding frame in AppKit coords (bottom-left origin).
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            finish(.cancelled); return
        }
        var virt = screens[0].frame
        for s in screens.dropFirst() { virt = virt.union(s.frame) }

        // Borderless, transparent, non-activating panel so the frontmost
        // app (WeChat) keeps keyboard focus.
        let panel = NSPanel(
            contentRect: virt,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar       // above normal windows and dock
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        // Virtual-screen origin in AppKit coords — needed for CG→AppKit
        // Y flip when laying out labels.
        let screenTopY = virt.origin.y + virt.size.height

        let view = OverlayView(
            frame: NSRect(origin: .zero, size: virt.size),
            messages: messages,
            virtOriginX: virt.origin.x,
            screenTopY: screenTopY
        )
        panel.contentView = view

        panel.orderFrontRegardless()  // .orderFront bypasses activation

        self.window = panel
        self.view = view

        installKeyMonitor()
        QMLog.info("overlay presented with \(messages.count) labels")
    }

    private func installKeyMonitor() {
        // Primary path: CGEventTap — can SWALLOW the keystroke so it
        // doesn't also type into WeChat.  Requires Accessibility
        // permission (which the quote pipeline already needs anyway).
        let tap = KeyCaptureTap(delegate: self)
        if tap.start() {
            self.keyTap = tap
            return
        }

        // Fallback: NSEvent global+local monitor (observe-only).  The
        // letter WILL leak into WeChat here, but the quote still fires.
        QMLog.info("falling back to NSEvent monitor (letter will leak to WeChat)")
        let mask: NSEvent.EventTypeMask = [.keyDown]
        let handler: (NSEvent) -> Void = { [weak self] event in
            self?.dispatchKey(event)
        }
        fallbackMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler)
        _ = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handler(event); return event
        }
    }

    // MARK: - KeyCaptureDelegate

    func keyCapture(shouldSwallow event: NSEvent) -> KeyCaptureDecision {
        // Only swallow bare Esc or bare letters we actually map.
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.isEmpty else { return .passthrough }

        if event.keyCode == 53 { return .swallow }  // Escape

        guard let chars = event.charactersIgnoringModifiers?.uppercased(),
              chars.count == 1,
              let first = chars.first, first.isLetter else {
            return .passthrough
        }

        let letter = String(first)
        guard let idx = Config.labelLetters.firstIndex(of: letter),
              idx < messages.count else {
            // Letter outside A..(A+count-1): let it through so the user
            // can keep typing normally if they didn't mean to pick one.
            return .passthrough
        }
        return .swallow
    }

    func keyCaptureSwallowed(event: NSEvent) {
        dispatchKey(event)
    }

    private func dispatchKey(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.isEmpty else { return }

        if event.keyCode == 53 {
            finish(.cancelled); return
        }

        guard let chars = event.charactersIgnoringModifiers?.uppercased(),
              chars.count == 1,
              let first = chars.first, first.isLetter else { return }

        let letter = String(first)
        guard let idx = Config.labelLetters.firstIndex(of: letter),
              idx < messages.count else { return }
        finish(.picked(letter: letter, message: messages[idx]))
    }

    private func finish(_ outcome: OverlayOutcome) {
        guard !finished else { return }
        finished = true

        if let tap = keyTap {
            tap.stop()
            keyTap = nil
        }
        if let monitor = fallbackMonitor {
            NSEvent.removeMonitor(monitor)
            fallbackMonitor = nil
        }
        window?.orderOut(nil)
        window = nil
        view = nil

        QMLog.info("overlay dismissed: \(describe(outcome))")
        completion(outcome)
    }

    private func describe(_ outcome: OverlayOutcome) -> String {
        switch outcome {
        case .picked(let letter, _): return "picked=\(letter)"
        case .cancelled:             return "cancelled"
        }
    }
}

// MARK: - Overlay drawing

/// Full-screen NSView that paints the red circles + white letters.
private final class OverlayView: NSView {

    struct Label {
        let letter: String
        let centerInView: NSPoint   // AppKit view coords (bottom-left origin)
    }

    private let labels: [Label]

    init(frame: NSRect,
         messages: [Message],
         virtOriginX: CGFloat,
         screenTopY: CGFloat)
    {
        // Map each Message rect → label centre.
        // `msg.x / msg.y` are in CGWindow space (top-left origin, y down).
        // View coords are AppKit (bottom-left origin, y up).
        //
        //   viewX = msgX + offsetX - virtOriginX
        //   viewY = screenTopY - (msgY + offsetY)
        //
        let off = Config.labelOffset
        let d   = Config.labelDiameter

        var built: [Label] = []
        for (i, msg) in messages.enumerated() where i < Config.labelLetters.count {
            let letter = Config.labelLetters[i]

            let cxCG: CGFloat
            if msg.fromSelf {
                cxCG = msg.x - off - d / 2   // label on LEFT of sent bubble
            } else {
                cxCG = msg.x + msg.width + off + d / 2
            }
            let cyCG = msg.y + msg.height / 2

            let viewX = cxCG - virtOriginX
            let viewY = screenTopY - cyCG

            built.append(Label(letter: letter, centerInView: NSPoint(x: viewX, y: viewY)))
        }
        self.labels = built
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setShouldAntialias(true)

        let d = Config.labelDiameter
        let bg = NSColor(srgbRed: Config.labelBGRed,
                         green: Config.labelBGGreen,
                         blue:  Config.labelBGBlue,
                         alpha: 1.0)
        let ring = NSColor(white: 0, alpha: 0.31)
        let fg = NSColor.white

        let font = NSFont.boldSystemFont(ofSize: Config.labelFontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg,
        ]

        for lbl in labels {
            let origin = NSPoint(x: lbl.centerInView.x - d / 2,
                                 y: lbl.centerInView.y - d / 2)
            let rect = NSRect(origin: origin, size: NSSize(width: d, height: d))

            // Ring shadow.
            ring.setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = 2
            path.stroke()

            // Fill.
            bg.setFill()
            path.fill()

            // Letter, centred.
            let s = NSAttributedString(string: lbl.letter, attributes: attrs)
            let sz = s.size()
            let tp = NSPoint(
                x: lbl.centerInView.x - sz.width / 2,
                y: lbl.centerInView.y - sz.height / 2
            )
            s.draw(at: tp)
        }
    }
}
