//
//  MenuItemFinder.swift
//  Accessibility helpers for locating a context-menu item by title.
//

import ApplicationServices
import CoreGraphics
import Foundation

enum MenuItemFinder {
    static func findMenuItemCenter(
        pid: pid_t,
        titles: [String],
        timeoutMs: Int = 400
    ) -> CGPoint? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        let wanted = Set(titles.map(normalizeTitle).filter { !$0.isEmpty })
        var observedTitles = Set<String>()

        while Date() < deadline {
            if let hit = findOnce(pid: pid, wanted: wanted, observedTitles: &observedTitles) {
                return hit
            }
            usleep(40_000)
        }

        let seen = observedTitles.sorted().joined(separator: " / ")
        QMLog.info("AX menu miss for titles=\(titles); observed=[\(seen)]")
        return nil
    }

    private static func findOnce(
        pid: pid_t,
        wanted: Set<String>,
        observedTitles: inout Set<String>
    ) -> CGPoint? {
        let appElement = AXUIElementCreateApplication(pid)
        var roots: [AXUIElement] = [appElement]

        if let focused = copyAttribute(appElement, kAXFocusedUIElementAttribute) {
            roots.append(focused as! AXUIElement)
        }
        if let windows = copyAttribute(appElement, kAXWindowsAttribute) as? [AXUIElement] {
            roots.append(contentsOf: windows)
        }
        if let children = copyAttribute(appElement, kAXChildrenAttribute) as? [AXUIElement] {
            roots.append(contentsOf: children)
        }

        let systemWide = AXUIElementCreateSystemWide()
        if let focused = copyAttribute(systemWide, kAXFocusedUIElementAttribute) {
            roots.append(focused as! AXUIElement)
        }

        var visited = Set<CFHashCode>()
        for root in roots {
            if let hit = search(
                root,
                wanted: wanted,
                observedTitles: &observedTitles,
                visited: &visited,
                depth: 0
            ) {
                return hit
            }
        }
        return nil
    }

    private static func search(
        _ element: AXUIElement,
        wanted: Set<String>,
        observedTitles: inout Set<String>,
        visited: inout Set<CFHashCode>,
        depth: Int
    ) -> CGPoint? {
        guard depth <= 8 else { return nil }

        let hash = CFHash(element)
        guard !visited.contains(hash) else { return nil }
        visited.insert(hash)

        let role = copyAttribute(element, kAXRoleAttribute) as? String
        let title = copyAttribute(element, kAXTitleAttribute) as? String

        if role == (kAXMenuItemRole as String), let title {
            let normalized = normalizeTitle(title)
            if !normalized.isEmpty {
                observedTitles.insert(title)
            }
            if titleMatches(normalized, wanted: wanted),
               let center = center(of: element) {
                return center
            }
        }

        guard roleAllowsDescent(role),
              let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let hit = search(
                child,
                wanted: wanted,
                observedTitles: &observedTitles,
                visited: &visited,
                depth: depth + 1
            ) {
                return hit
            }
        }
        return nil
    }

    private static func roleAllowsDescent(_ role: String?) -> Bool {
        guard let role else { return true }
        return role == (kAXApplicationRole as String)
            || role == (kAXWindowRole as String)
            || role == (kAXMenuRole as String)
            || role == (kAXMenuBarRole as String)
            || role == (kAXGroupRole as String)
            || role == (kAXScrollAreaRole as String)
            || role == (kAXUnknownRole as String)
    }

    private static func center(of element: AXUIElement) -> CGPoint? {
        guard let positionRef = copyAttribute(element, kAXPositionAttribute),
              let sizeRef = copyAttribute(element, kAXSizeAttribute) else {
            return nil
        }
        let positionValue = positionRef as! AXValue
        let sizeValue = sizeRef as! AXValue

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0, size.height > 0 else {
            return nil
        }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    private static func titleMatches(_ title: String, wanted: Set<String>) -> Bool {
        wanted.contains(where: { expected in
            title == expected || title.contains(expected)
        })
    }

    private static func normalizeTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
