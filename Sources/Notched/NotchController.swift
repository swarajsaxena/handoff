import AppKit

final class NotchController {
  private var windows: [NotchWindow] = []
  private var tracker: MouseTracker?
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

  private func rebuildWindows() {
    windows.forEach { $0.orderOut(nil) }
    windows = NSScreen.screens.map { NotchWindow(screen: $0, sessionStore: sessionStore) }
    windows.forEach { $0.orderFrontRegardless() }
  }

  private func handleMouse(at point: NSPoint) {
    for window in windows {
      // Questionnaire pins the panel open — hover-out must not dismiss mid-answer.
      // `isPinnedOpen` is set from NotchWindow's main-actor task subscription.
      if window.model.isPinnedOpen {
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
