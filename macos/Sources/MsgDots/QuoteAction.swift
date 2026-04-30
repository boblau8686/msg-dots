//
//  QuoteAction.swift
//  Right-click on a bubble → pick "引用" from an IM context menu.
//
//  Port of `action/quote_action.py`, generalized for supported IM apps:
//
//    1. Activate the target IM app.
//    2. Snapshot its current on-screen windows.
//    3. Synthesise a right-click at the bubble centre via CGEventPost
//       at the SESSION tap (not HID — session keeps IMS happy).
//    4. Prefer AX menu-item lookup by visible title.
//    5. Fall back to OCR on the popup menu image.
//    6. Fall back to per-IM popup geometry only if OCR fails.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Vision

enum QuoteActionError: Error, CustomStringConvertible {
    case rightClickFailed
    case popupNotFound
    case clickFailed

    var description: String {
        switch self {
        case .rightClickFailed:   return "Failed to post synthetic right-click"
        case .popupNotFound:      return "Context menu did not appear — bubble may be off-screen"
        case .clickFailed:        return "Failed to post click on quote menu item"
        }
    }
}

enum QuoteAction {

    /// Synthesise right-click → click 引用 at the given screen point
    /// (CGWindow coords: top-left origin, y grows DOWN).
    static func quoteAt(_ message: Message, in app: IMApp, pid: pid_t) throws {
        let point = message.center
        // 1. Activate the target app so it holds keyboard focus when the menu opens.
        activate(pid: pid)
        usleep(120_000)   // 120 ms for the activation to settle

        // 2. Snapshot target-owned windows.
        let baseline = snapshotWindowIDs(pid: pid)

        // 3. Right-click.
        postRightClick(at: point)
        usleep(UInt32(Config.actionStepDelayMs) * 1000)

        // 4. Preferred path: click the menu item by visible title.
        if let clickPt = MenuItemFinder.findMenuItemCenter(
            pid: pid,
            titles: app.quoteMenuTitles,
            timeoutMs: 400
        ) {
            QMLog.info("\(app.id): AX hit quote menu at \(clickPt)")
            postLeftClick(at: clickPt)
            return
        }

        QMLog.info("\(app.id): AX miss, looking for popup menu")

        // 5. Wait for the popup window.
        guard let popup = findPopupWindow(pid: pid, app: app, baseline: baseline, timeoutMs: 250) else {
            throw QuoteActionError.popupNotFound
        }

        // 6. OCR path: WeCom does not expose menu item titles via AX.
        if let clickPt = ocrMenuItemCenter(in: popup, titles: ocrQuoteTitles(for: app)) {
            QMLog.info("\(app.id): OCR hit quote menu at \(clickPt)")
            postLeftClick(at: clickPt)
            return
        }

        QMLog.info("\(app.id): OCR miss, falling back to geometric popup click")

        // 7. Last resort: click by menu geometry.
        guard let clickPt = geometricItemCenter(
            in: popup.bounds,
            fallback: geometricFallback(for: message, in: app)
        ) else {
            throw QuoteActionError.clickFailed
        }
        QMLog.info("\(app.id): popup bounds=\(popup.bounds) click=\(clickPt)")
        postLeftClick(at: clickPt)

        // NOTE: the Python version followed this with a hide/show cycle
        // of the chat app via osascript to nudge the input-method server into
        // rebinding the reply field.  That kick was only necessary
        // because pynput's keyboard CGEventTap was running in parallel
        // and desynced IMS state with the synthetic mouse path.
        //
        // The Swift port has no pynput: both the right-click and the
        // left-click on 引用 are posted via CGEvent at .cgSessionEventTap
        // (above IMS), and the only CGEventTap we own is the key
        // capture, which has already been torn down with the overlay
        // by the time this function runs.  IMS therefore sees a clean
        // pointer-event sequence and leaves the reply field in
        // the correct input mode — no visible hide/show flash needed.
    }

    private static func ocrQuoteTitles(for app: IMApp) -> [String] {
        if app.id == "wecom" {
            return ["引用", "Quote"]
        }
        return app.quoteMenuTitles
    }

    private static func geometricFallback(
        for message: Message,
        in app: IMApp
    ) -> IMApp.GeometricMenuFallback {
        guard app.id == "wecom" else {
            return app.geometricFallback
        }

        // WeCom changes the context menu by message type.  Rich cards /
        // documents add "打开" above "复制", moving "引用" from the 3rd
        // row to the 4th row. AX exposes no menu titles for this popup, so
        // infer the richer menu from the selected bubble shape.
        let richCard = message.height >= 90 || (message.width >= 260 && message.height >= 70)
        if richCard {
            QMLog.info("wecom: using rich-card quote fallback for message w=\(message.width) h=\(message.height)")
            return .init(totalItems: 8, quoteItemFromBottom: 5.35, bottomPadPt: 24)
        }

        QMLog.info("wecom: using text quote fallback for message w=\(message.width) h=\(message.height)")
        return app.geometricFallback
    }

    // MARK: - App activation

    private static func activate(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateIgnoringOtherApps])
    }

    // MARK: - Window snapshots + popup detection

    private static func snapshotWindowIDs(pid: pid_t) -> Set<CGWindowID> {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var ids: Set<CGWindowID> = []
        for info in list {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            ids.insert(wid)
        }
        return ids
    }

    private struct PopupWindow {
        let windowID: CGWindowID
        let bounds: CGRect
    }

    /// Poll up to `timeoutMs` for a new target-owned window in the
    /// popup size range.
    private static func findPopupWindow(
        pid: pid_t,
        app: IMApp,
        baseline: Set<CGWindowID>,
        timeoutMs: Int
    ) -> PopupWindow? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var loggedOnce = false

        while Date() < deadline {
            guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                    as? [[String: Any]] else { usleep(40_000); continue }

            var candidates: [(layer: Int, popup: PopupWindow)] = []
            var newInfos: [[String: Any]] = []

            for info in list {
                guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                      ownerPID == pid,
                      let wid = info[kCGWindowNumber as String] as? CGWindowID,
                      !baseline.contains(wid)
                else { continue }
                newInfos.append(info)

                guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                      let x = boundsDict["X"], let y = boundsDict["Y"],
                      let w = boundsDict["Width"], let h = boundsDict["Height"]
                else { continue }

                if w > 40, w < 600, h > 60, h < 900 {
                    let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
                    candidates.append((layer, PopupWindow(
                        windowID: wid,
                        bounds: CGRect(x: x, y: y, width: w, height: h)
                    )))
                }
            }

            if !loggedOnce, !newInfos.isEmpty {
                QMLog.info("\(app.id): new windows after right-click: \(newInfos.count)")
                loggedOnce = true
            }

            if !candidates.isEmpty {
                // Highest layer = frontmost.
                candidates.sort { $0.layer > $1.layer }
                return candidates[0].popup
            }

            usleep(40_000)
        }
        return nil
    }

    private static func ocrMenuItemCenter(
        in popup: PopupWindow,
        titles: [String]
    ) -> CGPoint? {
        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            popup.windowID,
            .boundsIgnoreFraming
        ) else {
            QMLog.info("popup OCR capture failed for window=\(popup.windowID)")
            return nil
        }

        writeDebugPopup(image)

        let wanted = titles.map(normalizeOCRText).filter { !$0.isEmpty }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = false

        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            QMLog.info("popup OCR failed: \(error)")
            return nil
        }

        guard let observations = request.results else {
            QMLog.info("popup OCR returned no observations")
            return nil
        }

        var seen: [String] = []
        for observation in observations {
            let candidates = observation.topCandidates(3)
            for candidate in candidates {
                let text = candidate.string
                seen.append(text)
                let normalized = normalizeOCRText(text)
                guard wanted.contains(where: { normalized.contains($0) || $0.contains(normalized) }) else {
                    continue
                }

                let box = observation.boundingBox
                let clickX = popup.bounds.origin.x + box.midX * popup.bounds.width
                let clickY = popup.bounds.origin.y + (1 - box.midY) * popup.bounds.height
                QMLog.info("popup OCR matched '\(text)' box=\(box) seen=\(seen)")
                return CGPoint(x: clickX, y: clickY)
            }
        }

        QMLog.info("popup OCR miss for titles=\(titles); seen=\(seen)")
        return nil
    }

    private static func normalizeOCRText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{3000}", with: "")
            .lowercased()
    }

    private static func writeDebugPopup(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: "/tmp/msgdots-menu-popup.png"))
    }

    /// Click target for "引用" using per-IM popup geometry.
    private static func geometricItemCenter(
        in popup: CGRect,
        fallback: IMApp.GeometricMenuFallback
    ) -> CGPoint? {
        let nItems = fallback.totalItems
        let pad: CGFloat = 3
        let bottomPad = fallback.bottomPadPt
        let menuH = max(40, popup.height - bottomPad)
        let itemH = max(16, (menuH - 2 * pad) / nItems)

        let clickX = popup.origin.x + popup.width * 0.5
        var clickY = popup.origin.y + popup.height - bottomPad - pad - itemH * fallback.quoteItemFromBottom
        clickY = max(popup.origin.y + pad,
                     min(clickY, popup.origin.y + popup.height - pad))

        return CGPoint(x: clickX, y: clickY)
    }

    // MARK: - Synthetic clicks

    private static func postRightClick(at pt: CGPoint) {
        let move = CGEvent(mouseEventSource: nil,
                           mouseType: .mouseMoved,
                           mouseCursorPosition: pt,
                           mouseButton: .right)
        let down = CGEvent(mouseEventSource: nil,
                           mouseType: .rightMouseDown,
                           mouseCursorPosition: pt,
                           mouseButton: .right)
        let up   = CGEvent(mouseEventSource: nil,
                           mouseType: .rightMouseUp,
                           mouseCursorPosition: pt,
                           mouseButton: .right)
        // Session tap (above the input-method server) — using HID tap
        // here desyncs IMS and leaves the reply field unable to accept
        // Chinese input afterwards.
        move?.post(tap: .cgSessionEventTap)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    private static func postLeftClick(at pt: CGPoint) {
        let move = CGEvent(mouseEventSource: nil,
                           mouseType: .mouseMoved,
                           mouseCursorPosition: pt,
                           mouseButton: .left)
        let down = CGEvent(mouseEventSource: nil,
                           mouseType: .leftMouseDown,
                           mouseCursorPosition: pt,
                           mouseButton: .left)
        let up   = CGEvent(mouseEventSource: nil,
                           mouseType: .leftMouseUp,
                           mouseCursorPosition: pt,
                           mouseButton: .left)
        move?.post(tap: .cgSessionEventTap)
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

}
