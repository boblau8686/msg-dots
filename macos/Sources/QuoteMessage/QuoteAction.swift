//
//  QuoteAction.swift
//  Right-click on a bubble → pick "引用" from WeChat's context menu.
//
//  Port of `action/quote_action.py`, keeping the main fast path that
//  works for current WeChat builds:
//
//    1. Activate WeChat (so keyboard focus transfers when the menu opens).
//    2. Snapshot its current on-screen windows.
//    3. Synthesise a right-click at the bubble centre via CGEventPost
//       at the SESSION tap (not HID — session keeps IMS happy).
//    4. Poll CGWindowList until a NEW small WeChat window appears (the
//       popup menu is a custom-drawn CGWindow, not an AX element).
//    5. Compute the screen position of 引用 (second-to-last item) from
//       the popup bounds minus the ~36pt bottom shadow pad, then click.
//    6. Hide + re-show WeChat via System Events to nudge the input-
//       method server into rebinding the reply field.
//
//  The rich Python fallback chain (AX tree walk, hit-test, title search,
//  offset-click) is omitted in v1 — the popup-click path is what
//  actually succeeds in practice.  We can port the fallbacks later if a
//  future WeChat build breaks the fast path.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum QuoteActionError: Error, CustomStringConvertible {
    case wechatNotRunning
    case rightClickFailed
    case popupNotFound
    case clickFailed

    var description: String {
        switch self {
        case .wechatNotRunning:   return "WeChat is not running"
        case .rightClickFailed:   return "Failed to post synthetic right-click"
        case .popupNotFound:      return "Context menu did not appear — bubble may be off-screen or AX permission denied"
        case .clickFailed:        return "Failed to post click on 引用"
        }
    }
}

enum QuoteAction {

    /// Synthesise right-click → click 引用 at the given screen point
    /// (CGWindow coords: top-left origin, y grows DOWN).
    static func quoteAt(_ point: CGPoint) throws {
        guard let pid = BubbleDetector.wechatPID() else {
            throw QuoteActionError.wechatNotRunning
        }

        // 1. Activate WeChat so it holds keyboard focus when the menu opens.
        activateWeChat(pid: pid)
        usleep(120_000)   // 120 ms for the activation to settle

        // 2. Snapshot WeChat-owned windows.
        let baseline = snapshotWindowIDs(pid: pid)

        // 3. Right-click.
        postRightClick(at: point)
        usleep(UInt32(Config.actionStepDelayMs) * 1000)

        // 4. Wait for a new small popup window.
        guard let popup = findPopupWindow(pid: pid, baseline: baseline, timeoutMs: 400) else {
            throw QuoteActionError.popupNotFound
        }

        // 5. Click the geometric position of 引用.
        guard let clickPt = secondToLastItemCenter(in: popup) else {
            throw QuoteActionError.clickFailed
        }
        QMLog.info("popup bounds=\(popup) click=\(clickPt)")
        postLeftClick(at: clickPt)

        // NOTE: the Python version followed this with a hide/show cycle
        // of WeChat via osascript to nudge the input-method server into
        // rebinding the reply field.  That kick was only necessary
        // because pynput's keyboard CGEventTap was running in parallel
        // and desynced IMS state with the synthetic mouse path.
        //
        // The Swift port has no pynput: both the right-click and the
        // left-click on 引用 are posted via CGEvent at .cgSessionEventTap
        // (above IMS), and the only CGEventTap we own is the key
        // capture, which has already been torn down with the overlay
        // by the time this function runs.  IMS therefore sees a clean
        // pointer-event sequence and leaves WeChat's reply field in
        // the correct input mode — no visible hide/show flash needed.
    }

    // MARK: - WeChat activation

    private static func activateWeChat(pid: pid_t) {
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

    /// Poll up to `timeoutMs` for a new WeChat-owned window in the
    /// popup size range.  Returns its CGWindowBounds.
    private static func findPopupWindow(
        pid: pid_t,
        baseline: Set<CGWindowID>,
        timeoutMs: Int
    ) -> CGRect? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var loggedOnce = false

        while Date() < deadline {
            guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                    as? [[String: Any]] else { usleep(40_000); continue }

            var candidates: [(layer: Int, rect: CGRect)] = []
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
                    candidates.append((layer, CGRect(x: x, y: y, width: w, height: h)))
                }
            }

            if !loggedOnce, !newInfos.isEmpty {
                QMLog.info("new WeChat windows after right-click: \(newInfos.count)")
                loggedOnce = true
            }

            if !candidates.isEmpty {
                // Highest layer = frontmost.
                candidates.sort { $0.layer > $1.layer }
                return candidates[0].rect
            }

            usleep(40_000)
        }
        return nil
    }

    /// Click target for "引用" (second-to-last item).
    /// Uses the same model as the Python version.
    private static func secondToLastItemCenter(in popup: CGRect) -> CGPoint? {
        let nItems: CGFloat = 10
        let pad: CGFloat = 3
        let bottomPad = Config.popupBottomPadPt
        let menuH = max(40, popup.height - bottomPad)
        let itemH = max(16, (menuH - 2 * pad) / nItems)

        var clickX = popup.origin.x + popup.width * 0.5
        var clickY = popup.origin.y + popup.height - bottomPad - pad - itemH * 1.5
        clickY = max(popup.origin.y + pad,
                     min(clickY, popup.origin.y + popup.height - pad))
        _ = clickX  // intentional alias

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
