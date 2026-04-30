//
//  AppDelegate.swift
//  MsgDots — top-level wire-up.
//
//  This is intentionally small.  Its only jobs are:
//    1. Install the menu-bar status item (the red Q icon + menu).
//    2. Install a global keyboard monitor so the hotkey is heard even
//       when WeChat / WeCom is frontmost.
//
//  Port status:
//    ✅ Status item with red circle + white Q
//    ✅ NSEvent-based global hotkey monitor (main-thread, no TSM trap)
//    ✅ Permission self-check panel (auto-opens on launch if missing)
//    ⬜ Overlay with letter labels next to each visible message
//    ⬜ Bubble detection (CGWindowListCreateImage + pixel analysis)
//    ⬜ Quote-action driver (AXUIElement → right-click menu → "引用")
//    ⬜ "Change hotkey…" menu item
//

import Cocoa
import os

/// Diagnostic log that writes to BOTH unified logging and a file under
/// /tmp/msgdots.log.  Apple's unified logging silently filters NSLog
/// output from Swift apps in many cases, so having a guaranteed-to-work
/// side channel makes debugging packaged builds tractable.
enum QMLog {
    private static let logger = Logger(subsystem: "com.msgdots.app", category: "main")
    private static let filePath = "/tmp/msgdots.log"

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        appendToFile(message)
    }

    private static func appendToFile(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: filePath)) {
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // First write — create the file.
            try? data.write(to: URL(fileURLWithPath: filePath))
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    // The status bar spot is retained for the life of the app.  Dropping
    // this reference would silently remove the icon.
    private var statusItem: NSStatusItem!

    // `addGlobal/LocalMonitorForEvents` return opaque `Any?` handles that
    // must be passed back to `removeMonitor` to tear the monitor down.
    // We never tear them down in practice (the monitor lives as long as
    // the process), but keep the references for tidiness.
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    /// Held at instance scope so the window isn't released after close.
    private var permissionsController: PermissionsWindowController?
    private var hotkeyController: HotkeyRecorderWindowController?

    /// Cached menu items whose titles depend on the current hotkey.
    /// Refreshed by `updateHotkeyLabels()` when the user saves a new binding.
    private var hotkeyHintMenuItem: NSMenuItem?
    private var hotkeyChangeMenuItem: NSMenuItem?

    /// Live overlay instance, kept alive while the user picks a letter.
    /// Nil outside an overlay session — also used as a re-entrancy
    /// guard so a second hotkey press while the overlay is up is ignored.
    private var activeOverlay: LabelOverlay?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStatusItem()
        installKeyMonitor()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyDidChange),
            name: HotkeyConfig.didChangeNotification,
            object: nil
        )
        QMLog.info("launched — hotkey: \(HotkeyConfig.current.display)")

        // Dump the runtime permission view so we can correlate "hotkey
        // silent" failures with what the TCC probes actually report.
        for (perm, status) in Permissions.checkAll() {
            QMLog.info("perm: \(perm.id) = \(status)")
        }
        QMLog.info("monitors installed: global=\(globalKeyMonitor != nil) local=\(localKeyMonitor != nil)")

        // If any TCC permission is missing, pop the checker automatically
        // so the user isn't left with a hotkey that silently does nothing.
        if !Permissions.allGranted() {
            showPermissionsWindow()
        }
    }

    // MARK: - Status bar

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        if let button = statusItem.button {
            button.image = Self.makeStatusIcon()
            button.toolTip = "消息点点 — 消息快捷操作"
        }

        let menu = NSMenu()
        let hintItem = NSMenuItem(
            title: hotkeyHintText(),
            action: nil,
            keyEquivalent: ""
        )
        hintItem.isEnabled = false
        menu.addItem(hintItem)
        hotkeyHintMenuItem = hintItem
        menu.addItem(.separator())

        let changeItem = NSMenuItem(
            title: changeHotkeyMenuTitle(),
            action: #selector(showHotkeyRecorderMenu(_:)),
            keyEquivalent: ""
        )
        changeItem.target = self
        menu.addItem(changeItem)
        hotkeyChangeMenuItem = changeItem

        let permsItem = NSMenuItem(
            title: "权限检查…",
            action: #selector(showPermissionsWindowMenu(_:)),
            keyEquivalent: ""
        )
        permsItem.target = self
        menu.addItem(permsItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "关于 消息点点",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Render a red circle + white "M" glyph at 2× for Retina menu bars.
    private static func makeStatusIcon() -> NSImage {
        // macOS status-bar icons are expected to be 22 pt tall at 1×.
        // We draw at the point size and let the system handle backing
        // scale — NSImage + lockFocus honours the screen's DPR.
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocusFlipped(false)

        let rect = NSRect(origin: .zero, size: size)
        let inset = CGFloat(1)
        let circle = NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset))
        NSColor(srgbRed: 0xE5/255.0, green: 0x39/255.0, blue: 0x35/255.0, alpha: 1).setFill()
        circle.fill()

        let glyph = NSAttributedString(
            string: "M",
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: NSColor.white,
            ]
        )
        let glyphSize = glyph.size()
        glyph.draw(at: NSPoint(
            x: (size.width - glyphSize.width) / 2,
            y: (size.height - glyphSize.height) / 2
        ))

        image.unlockFocus()
        // Not a template image — we want the colour to stay red regardless
        // of the menu-bar appearance (light/dark).
        image.isTemplate = false
        return image
    }

    // MARK: - Global hotkey

    private func installKeyMonitor() {
        let mask: NSEvent.EventTypeMask = [.keyDown]

        // Global monitor fires for key events headed to *other* apps.
        // Requires "Input Monitoring" permission (System Settings →
        // Privacy & Security → Input Monitoring).
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) {
            [weak self] event in
            self?.handleKey(event)
        }

        // Local monitor fires for events headed to *us* (e.g. the user
        // pressed the hotkey while our About dialog had focus).  The
        // handler must return the event unmodified — we observe, never
        // swallow.
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) {
            [weak self] event in
            self?.handleKey(event)
            return event
        }
    }

    private func handleKey(_ event: NSEvent) {
        // The match uses HotkeyConfig.current so a user-customised
        // binding takes effect without restarting.  We match on
        // virtual keyCode (not character) so the binding is stable
        // across keyboard layouts.
        guard HotkeyConfig.current.matches(event) else { return }
        QMLog.info("hotkey fired (\(HotkeyConfig.current.display))")
        startQuoteFlow()
    }

    // MARK: - Quote pipeline

    /// Hotkey → detect bubbles → show overlay → act on the chosen bubble.
    ///
    /// All three phases run on the main thread.  Detection is fast
    /// enough (~60ms on a dense chat) that doing it synchronously
    /// before the overlay appears is acceptable and avoids a stale-
    /// bubble race (user typing while the detector runs).
    private func startQuoteFlow() {
        if activeOverlay != nil {
            QMLog.info("ignoring hotkey: overlay already visible")
            return
        }

        guard let (app, pid) = IMAppRegistry.activeIMApp() else {
            QMLog.info("hotkey ignored: frontmost app is not a supported IM; frontmost=\(IMAppRegistry.frontmostDescription())")
            return
        }
        QMLog.info("targeting \(app.displayName) pid=\(pid)")

        let messages: [Message]
        do {
            messages = try BubbleDetector.detectRecentMessages(
                app: app,
                pid: pid,
                limit: Config.maxMessages
            )
        } catch {
            QMLog.info("bubble detect failed: \(error)")
            return
        }
        QMLog.info("detected \(messages.count) messages")

        // Retain the overlay while it's on-screen; release in completion.
        let overlay = LabelOverlay(messages: messages) { [weak self] outcome in
            guard let self else { return }
            self.activeOverlay = nil
            switch outcome {
            case .cancelled:
                QMLog.info("quote flow: cancelled")
            case .picked(let letter, let msg):
                QMLog.info("quote flow: picked \(letter) at \(msg.center)")
                do {
                    try QuoteAction.quoteAt(msg, in: app, pid: pid)
                    QMLog.info("quote flow: 引用 triggered")
                } catch {
                    QMLog.info("quote flow: action failed: \(error)")
                }
            }
        }
        activeOverlay = overlay
        overlay.present()
    }

    // MARK: - Permissions window

    /// Lazily create + focus the permissions checker window.
    func showPermissionsWindow() {
        if permissionsController == nil {
            permissionsController = PermissionsWindowController()
        }
        permissionsController?.showAndFocus()
    }

    @objc private func showPermissionsWindowMenu(_ sender: Any?) {
        showPermissionsWindow()
    }

    // MARK: - Hotkey recorder

    @objc private func showHotkeyRecorderMenu(_ sender: Any?) {
        if hotkeyController == nil {
            hotkeyController = HotkeyRecorderWindowController()
        }
        hotkeyController?.showAndFocus()
    }

    @objc private func hotkeyDidChange() {
        // Live-refresh the visible labels so the user sees the new
        // binding immediately without reopening the menu.
        hotkeyHintMenuItem?.title = hotkeyHintText()
        hotkeyChangeMenuItem?.title = changeHotkeyMenuTitle()
    }

    private func hotkeyHintText() -> String {
        "按 \(HotkeyConfig.current.display) 触发消息操作"
    }

    private func changeHotkeyMenuTitle() -> String {
        "更改快捷键…（当前 \(HotkeyConfig.current.display)）"
    }

    // MARK: - Menu actions

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "消息点点"
        alert.informativeText =
            "消息快捷操作辅助（Swift 原生版）\n\n" +
            "按 \(HotkeyConfig.current.display) 在聊天输入框中触发。"
        alert.alertStyle = .informational
        alert.runModal()
    }
}
