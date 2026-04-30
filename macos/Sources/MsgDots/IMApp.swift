//
//  IMApp.swift
//  Supported IM application definitions and active-app selection.
//

import AppKit
import CoreGraphics

struct IMApp {
    let id: String
    let displayName: String
    let bundleIDs: Set<String>
    let processNames: Set<String>

    let sidebarWidthPt: CGFloat
    let headerHeightPt: CGFloat
    let inputHeightPt: CGFloat
    let rightMarginPt: CGFloat
    let minWinWidthPt: CGFloat
    let minWinHeightPt: CGFloat

    let bubbleBGThreshold: Int
    let sentGreenDelta: Int

    let quoteMenuTitles: [String]
    let geometricFallback: GeometricMenuFallback

    struct GeometricMenuFallback {
        let totalItems: CGFloat
        let quoteItemFromBottom: CGFloat
        let bottomPadPt: CGFloat
    }
}

enum IMAppRegistry {
    static let wechat = IMApp(
        id: "wechat",
        displayName: "微信",
        bundleIDs: ["com.tencent.xinWeChat", "com.tencent.WeChat"],
        processNames: ["WeChat", "微信", "WeChatUnified"],
        sidebarWidthPt: 360,
        headerHeightPt: 58,
        inputHeightPt: 130,
        rightMarginPt: 18,
        minWinWidthPt: 400,
        minWinHeightPt: 300,
        bubbleBGThreshold: 24,
        sentGreenDelta: 6,
        quoteMenuTitles: ["引用", "Quote", "Reply"],
        geometricFallback: .init(totalItems: 10, quoteItemFromBottom: 1.5, bottomPadPt: 36)
    )

    static let wecom = IMApp(
        id: "wecom",
        displayName: "企业微信",
        bundleIDs: ["com.tencent.WeWorkMac"],
        processNames: ["企业微信", "WeCom", "WeWork"],
        sidebarWidthPt: 430,
        headerHeightPt: 72,
        inputHeightPt: 320,
        rightMarginPt: 18,
        minWinWidthPt: 400,
        minWinHeightPt: 300,
        bubbleBGThreshold: 24,
        sentGreenDelta: 6,
        quoteMenuTitles: ["引用", "回复", "Quote", "Reply"],
        geometricFallback: .init(totalItems: 8, quoteItemFromBottom: 6.25, bottomPadPt: 24)
    )

    static let all: [IMApp] = [wechat, wecom]

    /// Returns a target only when the frontmost app is a supported IM.
    /// This avoids quoting a background chat window when the user presses
    /// the hotkey in another app.
    static func activeIMApp() -> (app: IMApp, pid: pid_t)? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let match = match(running: front) else {
            return nil
        }
        return (match, front.processIdentifier)
    }

    static func frontmostDescription() -> String {
        guard let front = NSWorkspace.shared.frontmostApplication else {
            return "unknown"
        }
        let name = front.localizedName ?? "unnamed"
        let bid = front.bundleIdentifier ?? "no-bundle-id"
        return "\(name) (\(bid), pid=\(front.processIdentifier))"
    }

    private static func match(running app: NSRunningApplication) -> IMApp? {
        for im in all {
            if let bid = app.bundleIdentifier, im.bundleIDs.contains(bid) {
                return im
            }
            if let name = app.localizedName, im.processNames.contains(name) {
                return im
            }
        }
        return nil
    }
}
