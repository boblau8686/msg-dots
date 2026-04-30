//
//  HotkeyRecorderWindow.swift
//  Tiny dialog for picking a new global hotkey.
//
//  Flow:
//    * Shows the current hotkey with a "录制新快捷键" button.
//    * Clicking the button switches the view into capture mode — the
//      next modifier-carrying keyDown is recorded and shown.
//    * "保存" persists via HotkeyConfig; "恢复默认" resets to Ctrl+D.
//
//  Why require a modifier: a bare letter / digit as a global hotkey
//  would fire on every keystroke typed anywhere, which is not what
//  the user wants.  We enforce ≥ 1 modifier at record time.
//

import AppKit
import SwiftUI

final class HotkeyRecorderWindowController: NSWindowController, NSWindowDelegate {

    convenience init() {
        let hosting = NSHostingController(rootView: HotkeyRecorderView())
        hosting.view.frame = NSRect(x: 0, y: 0, width: 380, height: 220)

        let window = NSWindow(contentViewController: hosting)
        window.title = "更改快捷键 — 消息点点"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()

        self.init(window: window)
        window.delegate = self
    }

    func showAndFocus() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - SwiftUI

private struct HotkeyRecorderView: View {
    @State private var displayed: Hotkey = HotkeyConfig.current
    @State private var recording: Bool = false
    @State private var hint: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("当前快捷键")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Text(displayed.display)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .frame(minWidth: 120, minHeight: 42)
                    .padding(.horizontal, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(recording ? Color.red : Color.secondary.opacity(0.3),
                                    lineWidth: recording ? 2 : 1)
                    )

                Spacer()
            }

            if recording {
                // The recorder NSView takes first responder and captures
                // the next modifier-carrying keyDown.
                HotkeyCaptureRepresentable(
                    onCapture: { hk in
                        recording = false
                        displayed = hk
                        hint = "已录制 — 点「保存」生效，或继续按新组合"
                    },
                    onHintChange: { msg in hint = msg }
                )
                .frame(height: 1) // invisible — it just owns the first responder
            }

            if !hint.isEmpty {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("必须至少包含一个修饰键（⌃ ⌥ ⇧ ⌘）。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 0)

            HStack {
                Button(recording ? "按下新组合…" : "录制") {
                    recording = true
                    hint = "按下你想用的组合键"
                }
                .disabled(recording)

                Button("恢复默认") {
                    displayed = .default
                    hint = "已还原为 ⌃D — 点「保存」生效"
                }

                Spacer()

                Button("取消") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut(.cancelAction)

                Button("保存") {
                    HotkeyConfig.save(displayed)
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(recording)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - First-responder key catcher

/// Wraps an NSView that, while mounted, steals first responder and
/// records the next modifier-bearing keyDown.  SwiftUI doesn't expose
/// raw key events to non-TextField views, so we drop down to AppKit.
private struct HotkeyCaptureRepresentable: NSViewRepresentable {
    let onCapture: (Hotkey) -> Void
    let onHintChange: (String) -> Void

    func makeNSView(context: Context) -> CaptureView {
        let v = CaptureView()
        v.onCapture = onCapture
        v.onHintChange = onHintChange
        return v
    }

    func updateNSView(_ nsView: CaptureView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onHintChange = onHintChange
        DispatchQueue.main.async { nsView.window?.makeFirstResponder(nsView) }
    }

    final class CaptureView: NSView {
        var onCapture: ((Hotkey) -> Void)?
        var onHintChange: ((String) -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let meaningful = mods.intersection([.command, .option, .control, .shift])
            if meaningful.isEmpty {
                onHintChange?("需要至少一个修饰键（⌃ ⌥ ⇧ ⌘）")
                NSSound.beep()
                return
            }
            onCapture?(Hotkey(keyCode: event.keyCode, modifiers: meaningful))
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // Catch combos like ⌘Q that AppKit normally short-circuits
            // into menu lookups.
            keyDown(with: event)
            return true
        }
    }
}
