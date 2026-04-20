//
//  Message.swift
//  One detected message bubble on screen.
//
//  Coordinates are in logical screen points (not pixels).  Origin is
//  AppKit's bottom-left? NO — `CGWindowListCreateImage` and our whole
//  detection stack use Core Graphics / CGWindow coords (top-left origin,
//  y grows DOWN), which is also what `CGEventCreateMouseEvent` consumes.
//  We stay in that space end-to-end to avoid flipping bugs.
//

import Foundation

struct Message {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    /// True if the user sent this message (green bubble, right-aligned).
    var fromSelf: Bool

    var center: CGPoint {
        CGPoint(x: x + width / 2, y: y + height / 2)
    }
}
