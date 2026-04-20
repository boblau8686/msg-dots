// swift-tools-version: 5.9
//
// Swift Package Manager manifest for QuoteMessage.
//
// Why SPM (and not an Xcode project)?
//   * All config is text-only, so diffs review cleanly in git.
//   * No IDE lock-in -- `swift build` / `swift run` from the terminal.
//   * Bundling the produced executable into an `.app` with an Info.plist
//     is 20 lines of bash (see ../build.sh) instead of an opaque
//     `project.pbxproj` that merge-conflicts every time two people
//     touch the file list.

import PackageDescription

let package = Package(
    name: "QuoteMessage",
    platforms: [.macOS(.v12)],
    targets: [
        .executableTarget(
            name: "QuoteMessage",
            path: "Sources/QuoteMessage"
        )
    ]
)
