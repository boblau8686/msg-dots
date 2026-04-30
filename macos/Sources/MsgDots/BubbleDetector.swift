//
//  BubbleDetector.swift
//  Screenshot-based bubble detection for supported IM apps on macOS.
//
//  Port of `message_reader/macos_screenshot_reader.py`.
//
//  Algorithm (unchanged from Python):
//    1. Find the IM app's main window via CGWindowList (PID-based).
//    2. Capture it with CGWindowListCreateImage.
//    3. Crop to chat area (subtract sidebar / header / input / scrollbar).
//    4. Estimate background colour via per-channel mode of a pixel sample.
//    5. Build a bool mask of non-background pixels.
//    6. Collect vertical bands, tolerant of small row gaps.
//    7. For each band, the widest contiguous column run is the bubble's
//       horizontal extent (avatars form narrower secondary runs that
//       lose to the bubble).
//    8. Classify sent/received by position + green-dominant centre.
//    9. Reject centred-narrow blocks (timestamps).
//
//  Coordinates: detection runs in pixels, results come back as logical
//  screen points (what AppKit / CGEvent consume).
//

import AppKit
import CoreGraphics

enum BubbleDetectorError: Error, CustomStringConvertible {
    case windowNotFound
    case captureFailed
    case windowTooSmall
    case noBubblesDetected

    var description: String {
        switch self {
        case .windowNotFound:    return "IM window not found on screen"
        case .captureFailed:
            return "Failed to capture IM window — screen recording permission "
                 + "or the target app's privacy setting may be blocking it"
        case .windowTooSmall:    return "IM window is too small for the chat area"
        case .noBubblesDetected: return "No message bubbles detected"
        }
    }
}

enum BubbleDetector {

    // MARK: - Public entry point

    static func detectRecentMessages(
        app: IMApp,
        pid: pid_t,
        limit: Int = Config.maxMessages
    ) throws -> [Message] {
        guard let info = mainWindowInfo(app: app, pid: pid) else {
            throw BubbleDetectorError.windowNotFound
        }

        let bounds = info.bounds
        let winID = info.windowID

        guard let cg = captureWindow(windowID: winID) else {
            throw BubbleDetectorError.captureFailed
        }

        let pxW = cg.width
        let pxH = cg.height
        guard pxW > 0, pxH > 0 else {
            throw BubbleDetectorError.captureFailed
        }

        // scale = pixels per point (2.0 on Retina, 1.0 on plain DPI).
        let scale: CGFloat = bounds.width > 0
            ? CGFloat(pxW) / bounds.width
            : 1.0

        // Extract RGB pixel bytes for the full captured window.  The crop
        // itself can be dynamic for apps with resizable sidebars.
        guard let pixels = extractRGB(cgImage: cg) else {
            throw BubbleDetectorError.captureFailed
        }

        let crop = chatCrop(
            app: app,
            pixels: pixels,
            fullW: pxW,
            fullH: pxH,
            scale: scale
        )
        let cropLeft = crop.left
        let cropRight = crop.right
        let cropTop = crop.top
        let cropBottom = crop.bottom

        guard cropRight > cropLeft, cropBottom > cropTop else {
            throw BubbleDetectorError.windowTooSmall
        }

        let cropW = cropRight - cropLeft
        let cropH = cropBottom - cropTop
        QMLog.info(
            "\(app.id): capture px=\(pxW)x\(pxH) scale=\(String(format: "%.2f", Double(scale))) "
          + "crop=(x:\(cropLeft), y:\(cropTop), w:\(cropW), h:\(cropH))"
        )
        writeDebugCropIfNeeded(app: app, cgImage: cg, cropRect: CGRect(
            x: cropLeft,
            y: cropTop,
            width: cropW,
            height: cropH
        ))

        let bubbles = detectBubbles(
            app: app,
            pixels: pixels,
            fullW: pxW,
            cropOriginX: cropLeft,
            cropOriginY: cropTop,
            cropW: cropW,
            cropH: cropH
        )

        guard !bubbles.isEmpty else {
            throw BubbleDetectorError.noBubblesDetected
        }

        // Newest = bottom-most.  Take up to `limit`.
        let sorted = bubbles.sorted { $0.bottom > $1.bottom }
        let top = Array(sorted.prefix(limit))

        // Map crop-local pixels back to logical screen points.
        let messages = top.map { b in
            let pxLeft   = b.left   + cropLeft
            let pxRight  = b.right  + cropLeft
            let pxTop    = b.top    + cropTop
            let pxBottom = b.bottom + cropTop

            let ptX = bounds.origin.x + CGFloat(pxLeft)   / scale
            let ptY = bounds.origin.y + CGFloat(pxTop)    / scale
            let ptW = CGFloat(pxRight  - pxLeft)   / scale
            let ptH = CGFloat(pxBottom - pxTop)    / scale

            return Message(x: ptX, y: ptY, width: ptW, height: ptH, fromSelf: b.fromSelf)
        }
        logMessagesIfNeeded(app: app, messages: messages)
        return messages
    }

    // MARK: - Window lookup

    struct WindowInfo {
        let windowID: CGWindowID
        let bounds: CGRect
    }

    /// Frontmost normal-sized window owned by the IM process.
    static func mainWindowInfo(app: IMApp, pid: pid_t) -> WindowInfo? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        var largest: (area: CGFloat, info: WindowInfo)?
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = boundsDict["Width"], let h = boundsDict["Height"],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  w >= app.minWinWidthPt, h >= app.minWinHeightPt,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }

            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            let candidate = WindowInfo(
                windowID: wid,
                bounds: CGRect(x: x, y: y, width: w, height: h)
            )

            if layer == 0 {
                QMLog.info("\(app.id): selected front window id=\(wid) bounds=\(candidate.bounds)")
                return candidate
            }

            let area = w * h
            if largest == nil || area > largest!.area {
                largest = (area, candidate)
            }
        }
        if let fallback = largest?.info {
            QMLog.info("\(app.id): selected largest non-normal window id=\(fallback.windowID) bounds=\(fallback.bounds)")
            return fallback
        }
        return nil
    }

    // MARK: - Capture + pixel extraction

    static func captureWindow(windowID: CGWindowID) -> CGImage? {
        // CGWindowListCreateImage is deprecated on macOS 14 but still
        // functions on 14/15 and ScreenCaptureKit is heavier to wire up
        // for a synchronous one-shot capture.  Migrate later.
        return CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            .boundsIgnoreFraming
        )
    }

    private struct CropRect {
        let left: Int
        let right: Int
        let top: Int
        let bottom: Int
    }

    private static func chatCrop(
        app: IMApp,
        pixels: [UInt8],
        fullW: Int,
        fullH: Int,
        scale: CGFloat
    ) -> CropRect {
        if app.id == "wecom" {
            return dynamicWeComCrop(pixels: pixels, fullW: fullW, fullH: fullH, scale: scale, app: app)
        }

        let left = Int(app.sidebarWidthPt * scale)
        let right = Int(CGFloat(fullW) - app.rightMarginPt * scale)
        let top = Int(app.headerHeightPt * scale + Config.edgeMargin * scale)
        let bottom = Int(CGFloat(fullH) - app.inputHeightPt * scale - Config.edgeMargin * scale)
        return CropRect(left: left, right: right, top: top, bottom: bottom)
    }

    /// Enterprise WeChat lets users resize the conversation list and can
    /// show/hide a right-side group info panel.  Detect the message stream
    /// region from window separators instead of assuming fixed chrome sizes.
    private static func dynamicWeComCrop(
        pixels: [UInt8],
        fullW: Int,
        fullH: Int,
        scale: CGFloat,
        app: IMApp
    ) -> CropRect {
        let fallbackLeft = Int(app.sidebarWidthPt * scale)
        let fallbackRight = Int(CGFloat(fullW) - app.rightMarginPt * scale)
        let fallbackTop = Int(app.headerHeightPt * scale + Config.edgeMargin * scale)
        let fallbackBottom = Int(CGFloat(fullH) - app.inputHeightPt * scale - Config.edgeMargin * scale)

        let vLines = verticalSeparatorCandidates(pixels: pixels, fullW: fullW, fullH: fullH)
        let minChatWidth = Int(420 * scale)

        let leftSearchMin = max(
            Int(CGFloat(fullW) * 0.24),
            fallbackLeft - Int(180 * scale)
        )
        let leftSearchMax = Int(CGFloat(fullW) * 0.62)
        let leftLine = vLines.first { x in
            x >= leftSearchMin && x <= leftSearchMax
        }
        let left = clamp((leftLine ?? fallbackLeft) + Int(10 * scale), 0, max(0, fullW - minChatWidth))

        let rightSearchMin = left + minChatWidth
        let rightSearchMax = Int(CGFloat(fullW) * 0.96)
        let rightLine = vLines.first { x in
            x >= rightSearchMin && x <= rightSearchMax
        }
        let right = clamp((rightLine ?? fallbackRight) - Int(10 * scale), left + minChatWidth, fullW)

        let top = detectHeaderBottom(
            pixels: pixels,
            fullW: fullW,
            fullH: fullH,
            left: left,
            right: right,
            fallback: fallbackTop,
            scale: scale
        )
        let bottom = detectInputTop(
            pixels: pixels,
            fullW: fullW,
            fullH: fullH,
            left: left,
            right: right,
            fallback: fallbackBottom,
            scale: scale
        )

        let lineSummary = vLines.prefix(8).map(String.init).joined(separator: ",")
        QMLog.info(
            "wecom: dynamic crop lines vertical=\(lineSummary) "
          + "left=\(left) right=\(right) top=\(top) bottom=\(bottom)"
        )

        return CropRect(left: left, right: right, top: top, bottom: bottom)
    }

    private static func verticalSeparatorCandidates(
        pixels: [UInt8],
        fullW: Int,
        fullH: Int
    ) -> [Int] {
        let y0 = max(0, fullH / 20)
        let y1 = min(fullH - 1, fullH - fullH / 12)
        let step = 4
        let samples = max(1, (y1 - y0) / step)
        var candidates: [(x: Int, score: Int)] = []

        for x in 1..<(fullW - 1) {
            var score = 0
            var y = y0
            while y < y1 {
                if isSeparatorPixel(pixels, fullW: fullW, x: x, y: y) {
                    score += 2
                } else {
                    let left = colorAt(pixels, fullW: fullW, x: x - 1, y: y)
                    let right = colorAt(pixels, fullW: fullW, x: x + 1, y: y)
                    if colorDistance(left, right) > 42 {
                        score += 1
                    }
                }
                y += step
            }
            if score > samples / 2 {
                candidates.append((x, score))
            }
        }

        return groupedLineCenters(candidates)
    }

    private static func detectHeaderBottom(
        pixels: [UInt8],
        fullW: Int,
        fullH: Int,
        left: Int,
        right: Int,
        fallback: Int,
        scale: CGFloat
    ) -> Int {
        let y0 = Int(24 * scale)
        let y1 = min(Int(120 * scale), fullH - 1)
        if let line = strongestHorizontalSeparator(
            pixels: pixels,
            fullW: fullW,
            fullH: fullH,
            left: left,
            right: right,
            y0: y0,
            y1: y1,
            minRatio: 0.28
        ) {
            return clamp(line + Int(8 * scale), 0, fullH - 1)
        }
        return fallback
    }

    private static func detectInputTop(
        pixels: [UInt8],
        fullW: Int,
        fullH: Int,
        left: Int,
        right: Int,
        fallback: Int,
        scale: CGFloat
    ) -> Int {
        let y0 = Int(CGFloat(fullH) * 0.66)
        let y1 = min(Int(CGFloat(fullH) * 0.95), fullH - 1)
        if let line = strongestHorizontalSeparator(
            pixels: pixels,
            fullW: fullW,
            fullH: fullH,
            left: left,
            right: right,
            y0: y0,
            y1: y1,
            minRatio: 0.34
        ) {
            return clamp(line - Int(8 * scale), 0, fullH - 1)
        }
        return fallback
    }

    private static func strongestHorizontalSeparator(
        pixels: [UInt8],
        fullW: Int,
        fullH: Int,
        left: Int,
        right: Int,
        y0: Int,
        y1: Int,
        minRatio: Double
    ) -> Int? {
        let x0 = clamp(left + 8, 0, fullW - 1)
        let x1 = clamp(right - 8, x0 + 1, fullW)
        let step = 4
        let samples = max(1, (x1 - x0) / step)
        var best: (y: Int, score: Int)?

        for y in max(1, y0)..<min(fullH - 1, y1) {
            var score = 0
            var x = x0
            while x < x1 {
                if isSeparatorPixel(pixels, fullW: fullW, x: x, y: y) {
                    score += 2
                } else {
                    let up = colorAt(pixels, fullW: fullW, x: x, y: y - 1)
                    let down = colorAt(pixels, fullW: fullW, x: x, y: y + 1)
                    if colorDistance(up, down) > 36 {
                        score += 1
                    }
                }
                x += step
            }
            if Double(score) / Double(samples) >= minRatio,
               best == nil || score > best!.score {
                best = (y, score)
            }
        }
        return best?.y
    }

    private static func groupedLineCenters(_ candidates: [(x: Int, score: Int)]) -> [Int] {
        guard !candidates.isEmpty else { return [] }
        var out: [Int] = []
        var group: [(x: Int, score: Int)] = []
        var prev = candidates[0].x

        for candidate in candidates {
            if candidate.x - prev > 3, !group.isEmpty {
                out.append(weightedCenter(group))
                group.removeAll()
            }
            group.append(candidate)
            prev = candidate.x
        }
        if !group.isEmpty {
            out.append(weightedCenter(group))
        }
        return out
    }

    private static func weightedCenter(_ group: [(x: Int, score: Int)]) -> Int {
        let total = group.reduce(0) { $0 + max(1, $1.score) }
        let weighted = group.reduce(0) { $0 + $1.x * max(1, $1.score) }
        return total > 0 ? weighted / total : group[group.count / 2].x
    }

    private static func isSeparatorPixel(_ pixels: [UInt8], fullW: Int, x: Int, y: Int) -> Bool {
        let c = colorAt(pixels, fullW: fullW, x: x, y: y)
        let maxC = max(c.r, max(c.g, c.b))
        let minC = min(c.r, min(c.g, c.b))
        guard maxC - minC <= 8 else { return false }
        return (c.r >= 208 && c.r <= 244) || (c.r >= 42 && c.r <= 82)
    }

    private static func colorAt(
        _ pixels: [UInt8],
        fullW: Int,
        x: Int,
        y: Int
    ) -> (r: Int, g: Int, b: Int) {
        let off = (y * fullW + x) * 3
        return (Int(pixels[off]), Int(pixels[off + 1]), Int(pixels[off + 2]))
    }

    private static func colorDistance(
        _ a: (r: Int, g: Int, b: Int),
        _ b: (r: Int, g: Int, b: Int)
    ) -> Int {
        abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
    }

    private static func clamp(_ value: Int, _ minValue: Int, _ maxValue: Int) -> Int {
        min(max(value, minValue), maxValue)
    }

    private static func writeDebugCropIfNeeded(app: IMApp, cgImage: CGImage, cropRect: CGRect) {
        guard app.id == "wecom",
              let crop = cgImage.cropping(to: cropRect) else {
            return
        }
        let rep = NSBitmapImageRep(cgImage: crop)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return
        }
        let path = "/tmp/msgdots-wecom-crop.png"
        do {
            try data.write(to: URL(fileURLWithPath: path))
            QMLog.info("wecom: wrote debug crop \(path)")
        } catch {
            QMLog.info("wecom: failed to write debug crop: \(error)")
        }
    }

    private static func logMessagesIfNeeded(app: IMApp, messages: [Message]) {
        guard app.id == "wecom" else { return }
        for (idx, msg) in messages.enumerated() {
            let letter = idx < Config.labelLetters.count ? Config.labelLetters[idx] : "?"
            QMLog.info(
                "wecom: message \(letter) rect=(x:\(String(format: "%.1f", Double(msg.x))), "
              + "y:\(String(format: "%.1f", Double(msg.y))), "
              + "w:\(String(format: "%.1f", Double(msg.width))), "
              + "h:\(String(format: "%.1f", Double(msg.height))), "
              + "fromSelf:\(msg.fromSelf))"
            )
        }
    }

    /// Flatten a CGImage to row-packed RGB (3 bytes/pixel).
    static func extractRGB(cgImage: CGImage) -> [UInt8]? {
        let w = cgImage.width
        let h = cgImage.height
        let bytesPerRow = w * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * h)

        // Force a known layout: RGBA8 premultiplied last.
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buf,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Drop alpha.
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        for i in 0..<(w * h) {
            rgb[i * 3 + 0] = buf[i * 4 + 0]
            rgb[i * 3 + 1] = buf[i * 4 + 1]
            rgb[i * 3 + 2] = buf[i * 4 + 2]
        }
        return rgb
    }

    // MARK: - Pixel analysis

    /// Crop-local bubble rect.
    private struct Bubble {
        var left:   Int
        var right:  Int
        var top:    Int
        var bottom: Int
        var fromSelf: Bool
    }

    /// `pixels` is row-packed RGB for the full captured image (fullW × ?).
    /// We read the sub-rectangle (cropOriginX, cropOriginY, cropW × cropH).
    private static func detectBubbles(
        app: IMApp,
        pixels: [UInt8],
        fullW: Int,
        cropOriginX: Int,
        cropOriginY: Int,
        cropW: Int,
        cropH: Int
    ) -> [Bubble] {
        guard cropW >= 10, cropH >= 10 else { return [] }

        // ---- 1. Estimate background colour via per-channel histogram mode.
        var histR = [Int](repeating: 0, count: 256)
        var histG = [Int](repeating: 0, count: 256)
        var histB = [Int](repeating: 0, count: 256)

        // Sample every Nth pixel; keep total < 50 000 as in Python.
        let total = cropW * cropH
        let stride = max(1, total / 50_000)

        var sampled = 0
        var idx = 0
        pixels.withUnsafeBufferPointer { buf in
            // Linear walk over crop in row-major order, every `stride`-th pixel.
            // Compute each sampled pixel's address in the full image.
            while idx < total {
                let cy = idx / cropW
                let cx = idx % cropW
                let srcX = cropOriginX + cx
                let srcY = cropOriginY + cy
                let off = (srcY * fullW + srcX) * 3
                histR[Int(buf[off + 0])] += 1
                histG[Int(buf[off + 1])] += 1
                histB[Int(buf[off + 2])] += 1
                sampled += 1
                idx += stride
            }
        }

        let bgR = argmax(histR)
        let bgG = argmax(histG)
        let bgB = argmax(histB)
        QMLog.info("bg estimate rgb=(\(bgR),\(bgG),\(bgB)) sampled=\(sampled)")

        // ---- 2. Build mask: true where the pixel differs meaningfully.
        var mask = [Bool](repeating: false, count: cropW * cropH)
        pixels.withUnsafeBufferPointer { buf in
            for cy in 0..<cropH {
                let srcRow = (cropOriginY + cy) * fullW + cropOriginX
                for cx in 0..<cropW {
                    let off = (srcRow + cx) * 3
                    let dr = abs(Int(buf[off + 0]) - bgR)
                    let dg = abs(Int(buf[off + 1]) - bgG)
                    let db = abs(Int(buf[off + 2]) - bgB)
                    mask[cy * cropW + cx] = (dr + dg + db) > app.bubbleBGThreshold
                }
            }
        }

        // ---- 3. Scrub vertical dividers / scrollbars.
        //
        // WeCom can leave a chat-list separator inside the crop if the
        // sidebar width is slightly off.  A single full-height divider makes
        // every row look "non-background" and collapses the whole chat into
        // one huge false band, so remove any column that is active for most
        // of the crop height before row grouping.
        var tallColumns = 0
        for x in 0..<cropW {
            var hits = 0
            for y in 0..<cropH where mask[y * cropW + x] { hits += 1 }
            if Double(hits) / Double(max(1, cropH)) > Config.bubbleTallColumnHitRatio {
                for y in 0..<cropH { mask[y * cropW + x] = false }
                tallColumns += 1
            }
        }
        if tallColumns > 0 {
            QMLog.info("\(app.id): scrubbed \(tallColumns) tall columns")
        }

        // ---- 4. Scrub edge-column dividers / scrollbars.
        let edgeMarginPx = min(20, cropW / 40)
        let rowFracThresh = 0.08
        // Count mask hits per column within edge bands.
        func scrubColumn(_ x: Int) {
            var hits = 0
            for y in 0..<cropH where mask[y * cropW + x] { hits += 1 }
            if Double(hits) / Double(max(1, cropH)) > rowFracThresh {
                for y in 0..<cropH { mask[y * cropW + x] = false }
            }
        }
        for x in 0..<edgeMarginPx                 { scrubColumn(x) }
        for x in max(0, cropW - edgeMarginPx)..<cropW { scrubColumn(x) }

        // ---- 5. row_has (any True pixel in the row) & collect vertical bands.
        var rowHas = [Bool](repeating: false, count: cropH)
        for y in 0..<cropH {
            let base = y * cropW
            for x in 0..<cropW where mask[base + x] {
                rowHas[y] = true
                break
            }
        }

        var bands: [(top: Int, bottom: Int)] = []
        let gapClose = Config.bubbleGapClosePx
        var i = 0
        while i < cropH {
            if !rowHas[i] { i += 1; continue }
            var start = i
            var end   = i
            var gap   = 0
            while i < cropH {
                if rowHas[i] {
                    end = i
                    gap = 0
                } else {
                    gap += 1
                    if gap > gapClose { break }
                }
                i += 1
            }
            _ = start
            bands.append((start, end))
        }

        QMLog.info("found \(bands.count) vertical bands")

        // ---- 6. Resolve bands → bubbles.
        let minH = Config.bubbleMinHpx
        let minW = Config.bubbleMinWpx
        let crThresh = Config.centerRatioThreshold
        let maxCW = Config.maxCenterWidthRatio
        let greenDelta = app.sentGreenDelta
        let chatCX = cropW / 2

        var out: [Bubble] = []

        for (top, bottom) in bands {
            let bandH = bottom - top + 1
            if bandH < minH { continue }

            // Project band → columns (any row in the band True).
            var colsAny = [Bool](repeating: false, count: cropW)
            for y in top...bottom {
                let base = y * cropW
                for x in 0..<cropW where mask[base + x] {
                    colsAny[x] = true
                }
            }

            let (width, left, right) = widestRun(colsAny)
            if width < minW { continue }

            let midX = (left + right) / 2
            if abs(midX - chatCX) < Int(CGFloat(cropW) * crThresh),
               CGFloat(width) < CGFloat(cropW) * maxCW {
                continue  // timestamp row
            }

            // Classify from_self: sample a 5×5 patch at the bubble centre.
            let cx = (left + right) / 2
            let cy = (top + bottom) / 2
            let x0 = max(0, cx - 2), x1 = min(cropW, cx + 3)
            let y0 = max(0, cy - 2), y1 = min(cropH, cy + 3)

            var rs: [Int] = []
            var gs: [Int] = []
            var bs: [Int] = []
            pixels.withUnsafeBufferPointer { buf in
                for yy in y0..<y1 {
                    let srcRow = (cropOriginY + yy) * fullW + cropOriginX
                    for xx in x0..<x1 {
                        let off = (srcRow + xx) * 3
                        rs.append(Int(buf[off + 0]))
                        gs.append(Int(buf[off + 1]))
                        bs.append(Int(buf[off + 2]))
                    }
                }
            }
            let r = median(rs)
            let g = median(gs)
            let b = median(bs)
            let isGreen = (g > r + greenDelta) && (g > b + greenDelta)
            let isBlue = looksLikeSentBlue(
                pixels: pixels,
                fullW: fullW,
                cropOriginX: cropOriginX,
                cropOriginY: cropOriginY,
                cropW: cropW,
                cropH: cropH,
                left: left,
                right: right,
                top: top,
                bottom: bottom
            )
            let rightGap = cropW - 1 - right
            let posRight = rightGap <= left + 24
            let fromSelf = isGreen || isBlue || posRight

            out.append(Bubble(
                left: left, right: right,
                top: top, bottom: bottom,
                fromSelf: fromSelf
            ))
        }

        QMLog.info("after filtering: \(out.count) bubbles")
        return out
    }

    // MARK: - Small helpers

    private static func argmax(_ hist: [Int]) -> Int {
        var best = 0
        var bestIdx = 0
        for (i, v) in hist.enumerated() where v > best {
            best = v; bestIdx = i
        }
        return bestIdx
    }

    private static func looksLikeSentBlue(
        pixels: [UInt8],
        fullW: Int,
        cropOriginX: Int,
        cropOriginY: Int,
        cropW: Int,
        cropH: Int,
        left: Int,
        right: Int,
        top: Int,
        bottom: Int
    ) -> Bool {
        let inset = 8
        let xs = [
            clamp(left + inset, 0, max(0, cropW - 1)),
            clamp(right - inset, 0, max(0, cropW - 1)),
            clamp((left + right) / 2, 0, max(0, cropW - 1)),
        ]
        let ys = [
            clamp(top + inset, 0, max(0, cropH - 1)),
            clamp((top + bottom) / 2, 0, max(0, cropH - 1)),
            clamp(bottom - inset, 0, max(0, cropH - 1)),
        ]

        var blueish = 0
        var sampled = 0
        pixels.withUnsafeBufferPointer { buf in
            for y in ys {
                for x in xs {
                    let off = ((cropOriginY + y) * fullW + cropOriginX + x) * 3
                    let r = Int(buf[off + 0])
                    let g = Int(buf[off + 1])
                    let b = Int(buf[off + 2])
                    sampled += 1
                    if b > r + 24 && b > g + 8 && b >= 72 {
                        blueish += 1
                    }
                }
            }
        }
        return sampled > 0 && blueish >= max(2, sampled / 3)
    }

    /// (widestRunWidth, leftIdx, rightIdx) of the widest True run in `row`.
    private static func widestRun(_ row: [Bool]) -> (Int, Int, Int) {
        var best = (0, 0, 0)
        var curStart = -1
        var curEnd = -1
        for (x, v) in row.enumerated() {
            if v {
                if curStart < 0 { curStart = x }
                curEnd = x
            } else if curStart >= 0 {
                let w = curEnd - curStart + 1
                if w > best.0 { best = (w, curStart, curEnd) }
                curStart = -1
            }
        }
        if curStart >= 0 {
            let w = curEnd - curStart + 1
            if w > best.0 { best = (w, curStart, curEnd) }
        }
        return best
    }

    private static func median(_ xs: [Int]) -> Int {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        return s[s.count / 2]
    }
}
