import AppKit

// Top-level entry point for the SwiftPM-built app bundle. We still set
// accessory activation at runtime so there is no Dock icon and no main menu.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
