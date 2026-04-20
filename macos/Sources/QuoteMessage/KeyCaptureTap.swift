//
//  KeyCaptureTap.swift
//  Temporarily steal-and-swallow keyDown events while the overlay is up.
//
//  Why this exists
//  ---------------
//  `NSEvent.addGlobalMonitorForEvents` is strictly READ-ONLY — it can
//  see events headed to other apps but cannot stop them.  That's fine
//  for the Ctrl+Q hotkey, but during the overlay we need to SWALLOW
//  the A-H / Esc keys so they don't also land in WeChat's input field
//  (producing the "typed letter then flash" behaviour).
//
//  CGEventTap is the only macOS API that can both observe and drop
//  events destined for another process.  The historical SIGTRAP that
//  bit the Python port was NOT from CGEventTap itself — it came from
//  pynput calling `TSMGetInputSourceProperty` inside its callback,
//  which macOS 15 guards with a main-thread assertion.  Our callback
//  stays entirely within CGEvent / CoreFoundation, so the assertion
//  doesn't fire.
//
//  Threading
//  ---------
//  The tap callback runs on the main run loop (we install it there).
//  State shared with the delegate is gated by `mainThreadSync`.
//

import AppKit
import CoreGraphics

/// Decision returned by the tap's "should swallow?" query.
enum KeyCaptureDecision {
    /// Consume the event — do NOT forward to the frontmost app.
    /// The captured key is also delivered to the overlay asynchronously.
    case swallow
    /// Let the event through unmodified.
    case passthrough
}

/// Query object the tap consults for every keyDown.
protocol KeyCaptureDelegate: AnyObject {
    /// Called on the MAIN thread for every keyDown event.
    /// Return `.swallow` to drop the event and deliver it to the overlay.
    func keyCapture(shouldSwallow event: NSEvent) -> KeyCaptureDecision

    /// Called AFTER a swallowed key was accepted.  Always on main.
    func keyCaptureSwallowed(event: NSEvent)
}

final class KeyCaptureTap {

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Weakly held — the overlay owns the tap, not vice-versa.
    private weak var delegate: KeyCaptureDelegate?

    /// The C callback needs a raw pointer to self; we retain it until
    /// `stop()` and release in `stop()` to avoid a cycle.
    private var selfRef: Unmanaged<KeyCaptureTap>?

    init(delegate: KeyCaptureDelegate) {
        self.delegate = delegate
    }

    deinit { stop() }

    /// Install the tap.  Requires Accessibility permission (same one we
    /// already need for AX menu inspection / CGEvent post).  Returns
    /// true on success.  A failure here is non-fatal — the overlay just
    /// falls back to NSEvent-only capture (with the typing leak).
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }  // already running

        let ref = Unmanaged.passRetained(self)
        self.selfRef = ref
        let ptr = ref.toOpaque()

        // We only care about keyDown.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,          // above IME, same level as
                                              // our own CGEventPost calls
            place: .headInsertEventTap,       // run before anything else
            options: .defaultTap,             // must be .defaultTap (not
                                              // .listenOnly) to return nil
            eventsOfInterest: mask,
            callback: KeyCaptureTap.tapCallback,
            userInfo: ptr
        ) else {
            // Usually means Accessibility isn't granted to this .app.
            QMLog.info("CGEventTap create failed (accessibility permission?)")
            self.selfRef?.release()
            self.selfRef = nil
            return false
        }

        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)

        self.tap = newTap
        self.runLoopSource = src
        QMLog.info("KeyCaptureTap started")
        return true
    }

    func stop() {
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            self.runLoopSource = nil
        }
        if let t = tap {
            CGEvent.tapEnable(tap: t, enable: false)
            CFMachPortInvalidate(t)
            self.tap = nil
        }
        if let ref = selfRef {
            ref.release()
            self.selfRef = nil
        }
    }

    // MARK: - Callback

    /// C-style callback — no captures allowed.  `userInfo` is the
    /// opaque pointer to the owning `KeyCaptureTap`.
    private static let tapCallback: CGEventTapCallBack = {
        _, type, cgEvent, userInfo in

        // Re-enable the tap if macOS disabled us (happens after long
        // sleeps or if a callback runs too long).
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let userInfo {
                let me = Unmanaged<KeyCaptureTap>.fromOpaque(userInfo)
                    .takeUnretainedValue()
                if let t = me.tap {
                    CGEvent.tapEnable(tap: t, enable: true)
                }
            }
            return Unmanaged.passUnretained(cgEvent)
        }

        guard type == .keyDown, let userInfo else {
            return Unmanaged.passUnretained(cgEvent)
        }

        let me = Unmanaged<KeyCaptureTap>.fromOpaque(userInfo)
            .takeUnretainedValue()

        // NSEvent(cgEvent:) gives us the nice `charactersIgnoringModifiers`
        // + modifierFlags API the rest of the app already speaks.
        guard let nsEvent = NSEvent(cgEvent: cgEvent) else {
            return Unmanaged.passUnretained(cgEvent)
        }

        // The callback runs on the main run loop (we installed our source
        // onto CFRunLoopGetMain), so calling the delegate directly is safe.
        let decision = me.delegate?.keyCapture(shouldSwallow: nsEvent) ?? .passthrough

        switch decision {
        case .swallow:
            me.delegate?.keyCaptureSwallowed(event: nsEvent)
            return nil  // drop event — WeChat never sees it
        case .passthrough:
            return Unmanaged.passUnretained(cgEvent)
        }
    }
}
