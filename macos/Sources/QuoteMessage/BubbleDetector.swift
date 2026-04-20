//
//  BubbleDetector.swift
//  Screenshot-based bubble detection for WeChat on macOS.
//
//  Port of `message_reader/macos_screenshot_reader.py`.
//
//  Algorithm (unchanged from Python):
//    1. Find WeChat's main window via CGWindowList (PID-based).
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
    case wechatNotRunning
    case windowNotFound
    case captureFailed
    case windowTooSmall
    case noBubblesDetected

    var description: String {
        switch self {
        case .wechatNotRunning:  return "WeChat is not running"
        case .windowNotFound:    return "WeChat window not found on screen"
        case .captureFailed:
            return "Failed to capture WeChat window — screen recording permission, "
                 + "or WeChat's built-in privacy toggle, is blocking it"
        case .windowTooSmall:    return "WeChat window is too small for the chat area"
        case .noBubblesDetected: return "No message bubbles detected"
        }
    }
}

enum BubbleDetector {

    // MARK: - Public entry point

    static func detectRecentMessages(limit: Int = Config.maxMessages) throws -> [Message] {
        guard let pid = wechatPID() else {
            throw BubbleDetectorError.wechatNotRunning
        }
        guard let info = wechatWindowInfo(pid: pid) else {
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

        let cropLeft   = Int(Config.sidebarWidth * scale)
        let cropRight  = Int(CGFloat(pxW) - Config.rightMargin * scale)
        let cropTop    = Int(Config.headerHeight * scale + Config.edgeMargin * scale)
        let cropBottom = Int(CGFloat(pxH) - Config.inputHeight * scale - Config.edgeMargin * scale)

        guard cropRight > cropLeft, cropBottom > cropTop else {
            throw BubbleDetectorError.windowTooSmall
        }

        // Extract RGB pixel bytes for just the crop region.
        guard let pixels = extractRGB(cgImage: cg) else {
            throw BubbleDetectorError.captureFailed
        }

        let cropW = cropRight - cropLeft
        let cropH = cropBottom - cropTop

        let bubbles = detectBubbles(
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
        return top.map { b in
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
    }

    // MARK: - Window lookup

    static func wechatPID() -> pid_t? {
        for app in NSWorkspace.shared.runningApplications {
            if let bid = app.bundleIdentifier, Config.wechatBundleIDs.contains(bid) {
                return app.processIdentifier
            }
            if let name = app.localizedName, Config.wechatProcessNames.contains(name) {
                return app.processIdentifier
            }
        }
        return nil
    }

    struct WindowInfo {
        let windowID: CGWindowID
        let bounds: CGRect
    }

    /// Largest on-screen window owned by WeChat (assumed = main chat).
    static func wechatWindowInfo(pid: pid_t) -> WindowInfo? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        var best: (area: CGFloat, info: WindowInfo)?
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = boundsDict["Width"], let h = boundsDict["Height"],
                  let x = boundsDict["X"], let y = boundsDict["Y"],
                  w >= Config.minWinWidth, h >= Config.minWinHeight,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }

            let area = w * h
            if best == nil || area > best!.area {
                best = (area, WindowInfo(
                    windowID: wid,
                    bounds: CGRect(x: x, y: y, width: w, height: h)
                ))
            }
        }
        return best?.info
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
                    mask[cy * cropW + cx] = (dr + dg + db) > Config.bubbleBGThreshold
                }
            }
        }

        // ---- 3. Scrub edge-column dividers / scrollbars.
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

        // ---- 4. row_has (any True pixel in the row) & collect vertical bands.
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

        // ---- 5. Resolve bands → bubbles.
        let minH = Config.bubbleMinHpx
        let minW = Config.bubbleMinWpx
        let crThresh = Config.centerRatioThreshold
        let maxCW = Config.maxCenterWidthRatio
        let greenDelta = Config.sentGreenDelta
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
            let posRight = (cropW - 1 - right) < left
            let fromSelf = isGreen || posRight

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
