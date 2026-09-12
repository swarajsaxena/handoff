import AppKit

final class NotchController {
  private var windows: [NotchWindow] = []
  private var tracker: MouseTracker?
  private var hotKey: HotKey?
  private let sessionStore: SessionStore

  /// A little slack around the collapsed notch so it's easy to hit.
  private let hoverPadding: CGFloat = 6

  init(sessionStore: SessionStore) {
    self.sessionStore = sessionStore
  }

  func start() {
    rebuildWindows()

    tracker = MouseTracker { [weak self] point in
      self?.handleMouse(at: point)
    }
    tracker?.start()

    // The controller owns this, not AppDelegate: it holds the windows and is
    // the only thing that can pick which screen's panel to open.
    hotKey = HotKey { [weak self] in
      DispatchQueue.main.async { self?.toggleFromHotkey() }
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(screenParametersChanged),
      name: NSApplication.didChangeScreenParametersNotification,
      object: nil
    )

    // Space-change notifications are posted on NSWorkspace's own
    // notification center, not NotificationCenter.default.
    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(activeSpaceChanged),
      name: NSWorkspace.activeSpaceDidChangeNotification,
      object: nil
    )
  }

  @objc private func screenParametersChanged() {
    rebuildWindows()
  }

  /// Hide instantly when a Space switch kicks in, then fade back once the
  /// swipe animation has settled, so the notch never rides the transition.
  @objc private func activeSpaceChanged() {
    hideDuringSpaceTransition()
  }

  private var reappearWorkItem: DispatchWorkItem?

  private func hideDuringSpaceTransition() {
    reappearWorkItem?.cancel()

    for window in windows {
      // Collapse so the expanded panel can never ride the swipe;
      // the collapsed shape matches the cutout and is invisible.
      window.model.isExpanded = false
      window.alphaValue = 0
    }

    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      for window in self.windows {
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.25
          window.animator().alphaValue = 1
        }
      }
    }
    reappearWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: work)
  }

  /// ⌃⌥N. Opens the panel on whichever screen the pointer is on and gives it
  /// real keyboard focus; pressing again puts focus back where it came from.
  private func toggleFromHotkey() {
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    guard let target = windows.first(where: { $0.screen == screen }) ?? windows.first else {
      return
    }

    // Mid-answer: focus it, never close it. Dismissal there belongs to the
    // questionnaire's own cancel flow. Checked across every window, not just
    // the one under the pointer — otherwise pressing this on a second display
    // opens a panel there and steals keystrokes from a form still waiting on
    // the first, with nothing to hand them back.
    if let pinned = windows.first(where: { $0.model.isPinnedOpen }) {
      pinned.takeFocus()
      return
    }

    if target.model.isHotkeyOpen {
      target.model.isHotkeyOpen = false
      target.model.isExpanded = false
      target.releaseFocus()
    } else {
      // Set before takeFocus: canBecomeKey is read inside makeKeyAndOrderFront.
      target.model.isHotkeyOpen = true
      target.model.isExpanded = true
      target.takeFocus()
    }
  }

  /// Hands activation back to whatever app we took it from, if we took it.
  func releaseFocus() {
    windows.forEach { $0.releaseFocus() }
  }

  private func rebuildWindows() {
    // Hand activation back before dropping the windows; a window torn down
    // while it holds focus strands it on a panel that no longer exists.
    windows.forEach { $0.releaseFocus() }
    windows.forEach { $0.orderOut(nil) }
    windows = NSScreen.screens.map { NotchWindow(screen: $0, sessionStore: sessionStore) }
    windows.forEach { $0.orderFrontRegardless() }
  }

  private func handleMouse(at point: NSPoint) {
    for window in windows {
      // Questionnaire pins the panel open — hover-out must not dismiss mid-answer.
      // `isPinnedOpen` is set from NotchWindow's main-actor task subscription;
      // `isHotkeyOpen` means the user asked for it and the mouse isn't in charge.
      if window.model.isPinnedOpen || window.model.isHotkeyOpen {
        if !window.model.isExpanded { window.model.isExpanded = true }
        continue
      }

      let metrics = window.metrics

      // Hysteresis: once open, the whole expanded panel keeps it open.
      // With a real notch, hit the cutout exactly; only the fake pill gets slack.
      let padding = metrics.hasNotch ? 0 : hoverPadding
      let zone =
        window.model.isExpanded
        // ponytail: -2 top so the exclusive maxY edge still counts as inside
        //           when the cursor sits on the very top row of the screen.
        ? metrics.expandedRect.insetBy(dx: 0, dy: -2)
        : window.model.collapsedScreenRect.insetBy(dx: -padding, dy: -padding)

      let inside = zone.contains(point)
      if window.model.isExpanded != inside {
        window.model.isExpanded = inside
      }
    }
  }
}
