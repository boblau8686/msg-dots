//
//  main.swift
//  QuoteMessage — 微信快速引用 (Swift port, macOS)
//
//  Bootstrap only: create the shared NSApplication, hook up the
//  AppDelegate, and run the Cocoa event loop.  All real logic lives
//  in AppDelegate + its collaborators.
//

import Cocoa

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// `.accessory` hides the Dock icon and the app's menu in the menu bar,
// leaving only our NSStatusItem (the Q icon).  This is also redundantly
// declared as `LSUIElement=YES` in Info.plist so macOS knows the policy
// at launch time — the call below would otherwise run *after* a brief
// Dock-icon flash.
app.setActivationPolicy(.accessory)

app.run()
