//
//  Permissions.swift
//  Silent TCC probes + deep-link into System Settings.
//
//  All three check functions are non-prompting — they just read the
//  current decision.  `open(anchor:)` fires the `x-apple.systempreferences:`
//  URL scheme which System Settings handles by jumping straight to the
//  matching privacy pane.
//

import AppKit
import ApplicationServices
import CoreGraphics
import IOKit.hid

// MARK: - Data model

enum PermissionStatus: Equatable {
    case granted
    case denied
    /// TCC has no decision on record yet (typical on a fresh install).
    case unknown
}

struct Permission: Identifiable, Hashable {
    let id: String
    let nameCN: String
    let descCN: String
    /// Appended to `x-apple.systempreferences:com.apple.preference.security?`.
    let settingsAnchor: String

    static func == (lhs: Permission, rhs: Permission) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Catalogue + probes

enum Permissions {

    /// Order is deliberate: most-critical first.
    ///
    /// Automation (AppleScript → WeChat / System Events) is intentionally
    /// absent: the only way to query it is `AEDeterminePermissionToAutomateTarget`,
    /// which itself triggers a prompt the first time it runs — exactly
    /// what we want to avoid in a "silent status panel".  macOS will
    /// prompt for it organically the first time we osascript-activate
    /// WeChat, which is fine.
    static let all: [Permission] = [
        Permission(
            id: "input_monitoring",
            nameCN: "输入监控",
            descCN: "监听全局快捷键（Ctrl+Q 等）",
            settingsAnchor: "Privacy_ListenEvent"
        ),
        Permission(
            id: "accessibility",
            nameCN: "辅助功能",
            descCN: "读取微信窗口位置 / 触发\"引用\"菜单",
            settingsAnchor: "Privacy_Accessibility"
        ),
        Permission(
            id: "screen_recording",
            nameCN: "屏幕录制",
            descCN: "截图识别消息气泡的位置",
            settingsAnchor: "Privacy_ScreenCapture"
        ),
    ]

    /// Probe every permission in `all` and return matched statuses.
    static func checkAll() -> [(Permission, PermissionStatus)] {
        all.map { ($0, check($0)) }
    }

    static func allGranted() -> Bool {
        checkAll().allSatisfy { $0.1 == .granted }
    }

    /// Dispatch to the correct probe by permission id.
    static func check(_ permission: Permission) -> PermissionStatus {
        switch permission.id {
        case "input_monitoring":  return checkInputMonitoring()
        case "accessibility":     return checkAccessibility()
        case "screen_recording":  return checkScreenRecording()
        default:                  return .unknown
        }
    }

    // ------------------------------------------------------------------
    // Individual probes
    // ------------------------------------------------------------------

    /// Input Monitoring — required by NSEvent global monitors and
    /// CGEventTap.  Non-prompting.
    static func checkInputMonitoring() -> PermissionStatus {
        let v = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        switch v {
        case kIOHIDAccessTypeGranted:
            return .granted
        case kIOHIDAccessTypeDenied:
            return .denied
        default:
            // kIOHIDAccessTypeUnknown ⇒ TCC has no entry for us yet.
            return .unknown
        }
    }

    /// Accessibility — required by AXUIElement APIs (reading another
    /// app's window tree).  Non-prompting when `opts` is nil.
    static func checkAccessibility() -> PermissionStatus {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Screen Recording — required by CGWindowListCreateImage against
    /// other apps' windows.  Non-prompting.
    static func checkScreenRecording() -> PermissionStatus {
        CGPreflightScreenCaptureAccess() ? .granted : .denied
    }

    // MARK: - Deep-link into System Settings

    static func openSettings(anchor: String) {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        guard let url = URL(string: base + anchor) else { return }
        NSWorkspace.shared.open(url)
    }
}
