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

    // MARK: - Overlay labels
    static let labelLetters: [String] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ").map(String.init)
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
    // IM-specific sidebar / header / input values live in IMApp.swift.
    static let edgeMargin: CGFloat      = 4

    // Pixel classifier thresholds.
    static let bubbleGapClosePx: Int  = 8
    static let bubbleMinHpx: Int      = 24
    static let bubbleMinWpx: Int      = 36
    static let bubbleTallColumnHitRatio: Double = 0.70
    static let centerRatioThreshold: CGFloat = 0.08
    static let maxCenterWidthRatio: CGFloat  = 0.40
}
