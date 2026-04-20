//
//  PermissionsWindow.swift
//  SwiftUI-based status panel for the three TCC permissions.
//
//  Hosted inside an NSWindow so it behaves correctly for an accessory
//  app (no Dock icon) — a plain SwiftUI `WindowGroup` can't be added
//  after `setActivationPolicy(.accessory)` has been set.
//

import AppKit
import SwiftUI

// MARK: - The SwiftUI body

/// One row: icon + name + description + button.
private struct PermissionRowView: View {
    let permission: Permission
    let status: PermissionStatus
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            statusIcon
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.nameCN)
                    .font(.body.weight(.semibold))
                Text(permission.descCN)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 12)

            Button(action: onOpen) {
                Text(status == .granted ? "已授权" : "打开设置")
                    .frame(minWidth: 80)
            }
            .disabled(status == .granted)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch status {
        case .granted:
            Text("✓")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.green)
        case .denied:
            Text("✗")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.red)
        case .unknown:
            Text("?")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.gray)
        }
    }
}

/// The whole panel.
private struct PermissionsView: View {
    // The refreshTrigger hack: SwiftUI only re-runs the view body when
    // observed state changes, and `Permissions.checkAll()` lives
    // outside the model.  Incrementing this integer (from "重新检查")
    // forces the body to re-evaluate so the icons update.
    @State private var refreshTrigger: Int = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("本工具需要以下系统权限才能正常工作。"
                 + "未授权的项请点击右侧按钮跳转到设置页面开启，"
                 + "勾选后回到此处点「重新检查」。")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(.secondary)

            // `refreshTrigger` read here forces re-evaluation of
            // `Permissions.checkAll()` on every tick.
            let _ = refreshTrigger
            let statuses = Permissions.checkAll()

            VStack(spacing: 0) {
                ForEach(Array(statuses.enumerated()), id: \.element.0.id) {
                    index, pair in
                    PermissionRowView(
                        permission: pair.0,
                        status: pair.1,
                        onOpen: {
                            Permissions.openSettings(
                                anchor: pair.0.settingsAnchor
                            )
                        }
                    )
                    if index < statuses.count - 1 {
                        Divider()
                    }
                }
            }

            HStack {
                Text("授权后需要重启 QuoteMessage 才能生效")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("重新检查") {
                    refreshTrigger += 1
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("关闭") {
                    NSApp.keyWindow?.performClose(nil)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

// MARK: - NSWindowController wrapper

/// Owns the window so it survives being closed & reopened.  Menu-bar
/// apps without a Dock icon need an explicit `NSApp.activate` to get
/// the window to the foreground; otherwise it appears behind whatever
/// was frontmost.
final class PermissionsWindowController: NSWindowController, NSWindowDelegate {

    convenience init() {
        let hosting = NSHostingController(rootView: PermissionsView())
        // Let SwiftUI size itself; we just set a reasonable starting box.
        hosting.view.frame = NSRect(x: 0, y: 0, width: 560, height: 300)

        let window = NSWindow(contentViewController: hosting)
        window.title = "权限检查 — QuoteMessage"
        window.styleMask = [.titled, .closable]
        window.level = .floating            // stay above System Settings
        window.isReleasedWhenClosed = false // reopening must still work
        window.center()

        self.init(window: window)
        window.delegate = self
    }

    /// Bring the window to the front.  An accessory app has no menu
    /// bar, so `NSApp.activate` is the only thing that can foreground
    /// our window on macOS 14+.
    func showAndFocus() {
        guard let window else { return }
        // Nudge SwiftUI to re-check: any existing view will refresh on
        // next render, but the simplest way is to throw the panel
        // back up.  Replacing the root content-view with a fresh copy
        // also works and guarantees `onAppear` runs.
        if let host = window.contentViewController as? NSHostingController<PermissionsView> {
            host.rootView = PermissionsView()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // Keep the app alive when the last window closes (accessory apps
    // would otherwise stay fine, but spell it out for clarity).
    func windowShouldClose(_ sender: NSWindow) -> Bool { true }
}
