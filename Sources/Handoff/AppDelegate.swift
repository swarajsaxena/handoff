import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var controller: NotchController?
  private var statusItem: NSStatusItem?
  private var sessionStore: SessionStore!
  private var hookServer: HookServer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    let sessionStore = SessionStore()
    self.sessionStore = sessionStore
    controller = NotchController(sessionStore: sessionStore)
    controller?.start()
    installStatusItem()
    startClaudeCodeBridge()
  }

  func applicationWillTerminate(_ notification: Notification) {
    // Leaves the hooks themselves installed (nothing to reinstall next
    // launch) but removes the pidfile the bridge script checks, so
    // every hook fails fast instead of adding connect latency to
    // Claude Code while Handoff is closed.
    HookInstaller.removePidFile()
    hookServer?.stop()
    // Quitting while we hold focus would leave the user with no frontmost app.
    controller?.releaseFocus()
  }

  private func startClaudeCodeBridge() {
    let server = HookServer(sessionStore: sessionStore)
    hookServer = server
    Task {
      do {
        let (port, token) = try await server.start()
        try HookInstaller.install(port: port, token: token)
      } catch {
        NSLog("Handoff: failed to start the Claude Code hook bridge: \(error)")
      }
    }
  }

  /// A tiny menu bar item so the app is quittable without hunting for the process.
  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = item.button {
      button.image = NSImage(
        systemSymbolName: "rectangle.topthird.inset.filled",
        accessibilityDescription: "Handoff"
      )
      button.image?.isTemplate = true
    }

    let menu = NSMenu()

    let removeHooksItem = NSMenuItem(
      title: "Remove Claude Code Hooks",
      action: #selector(removeClaudeCodeHooks),
      keyEquivalent: ""
    )
    removeHooksItem.target = self
    menu.addItem(removeHooksItem)

    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit Handoff",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    item.menu = menu
    statusItem = item
  }

  @objc private func removeClaudeCodeHooks() {
    do {
      try HookInstaller.uninstall()
    } catch {
      NSLog("Handoff: failed to remove Claude Code hooks: \(error)")
    }
  }
}
