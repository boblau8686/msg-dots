//
//  Config.swift
//  Process-wide constants — mirrors config.py from the Python version.
//
//  Keep this file free of heavy imports (AppKit only) so it can be
//  referenced from every other module without pulling in SwiftUI /
//  ApplicationServices needlessly.
//

import Foundation

enum Config {

    // MARK: - WeChat identification
    static let wechatBundleIDs: Set<String> = [
        "com.tencent.xinWeChat",   // 微信 macOS 主包名
        "com.tencent.WeChat",      // 旧版 / 企业微信
    ]
    static let wechatProcessNames: Set<String> = [
        "WeChat", "微信", "WeChatUnified",
    ]

    // MARK: - Overlay labels
    static let labelLetters: [String] = ["A", "B", "C", "D", "E", "F", "G", "H"]
    static var maxMessages: Int { labelLetters.count }

    static let labelDiameter: CGFloat = 28
    static let labelOffset: CGFloat = 8
    static let labelFontSize: CGFloat = 16
    // sRGB (0xE5, 0x39, 0x35) red, matches Python.
    static let labelBGRed: CGFloat = 0xE5 / 255
    static let labelBGGreen: CGFloat = 0x39 / 255
    static let labelBGBlue: CGFloat = 0x35 / 255

    // MARK: - Action timing (milliseconds)
    static let actionStepDelayMs: Int = 60
    static let rightClickMenuWaitMs: Int = 300

    // MARK: - Bubble detection (screenshot analysis)

    // Chrome around the chat area, in logical points.
    // Matches the Python values — bump these if WeChat's sidebar
    // width / header / input changes.
    static let sidebarWidth: CGFloat    = 360
    static let headerHeight: CGFloat    = 58
    static let inputHeight: CGFloat     = 130
    static let rightMargin: CGFloat     = 18
    static let avatarBand: CGFloat      = 52
    static let edgeMargin: CGFloat      = 4
    static let minWinWidth: CGFloat     = 400
    static let minWinHeight: CGFloat    = 300

    // Pixel classifier thresholds.
    static let bubbleBGThreshold: Int = 24   // Σ|ΔR|+|ΔG|+|ΔB|
    static let bubbleGapClosePx: Int  = 8
    static let bubbleMinHpx: Int      = 24
    static let bubbleMinWpx: Int      = 36
    static let centerRatioThreshold: CGFloat = 0.08
    static let maxCenterWidthRatio: CGFloat  = 0.40
    static let sentGreenDelta: Int = 6

    // Popup geometry — WeChat's right-click popup's CGWindow bounds
    // extend ~36pt below the actual menu content (shadow).  Increase
    // if clicks land on 删除 instead of 引用; decrease if they land
    // two items above.
    static let popupBottomPadPt: CGFloat = 36
}
