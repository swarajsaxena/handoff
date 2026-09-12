import AppKit
import Combine
import SwiftUI

final class NotchWindow: NSPanel {
  let metrics: NotchMetrics
  let model: NotchModel
  private var expansionObservation: AnyCancellable?
  private var indicatorObservation: AnyCancellable?
  private var questionObservation: AnyCancellable?
  /// True while this window should accept keyboard focus: any pending
  /// interaction, or the dashboard opened deliberately.
  private var interactionActive = false
  /// Whoever was frontmost before a question stole activation, so typing
  /// can go back where it came from.
  private var previousApp: NSRunningApplication?

  init(screen: NSScreen, sessionStore: SessionStore) {
    metrics = NotchMetrics(screen: screen)
    model = NotchModel(metrics: metrics)

    super.init(
      contentRect: metrics.windowFrame,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )

    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    isMovable = false
    isMovableByWindowBackground = false
    isReleasedWhenClosed = false

    // Keep it above normal app content, but avoid global shield level so
    // macOS can animate/hide it correctly during Space swipe transitions.
    level = .statusBar

    collectionBehavior = [
      .canJoinAllSpaces,
      // Stationary keeps the overlay pinned over the physical cutout
      // during Space swipes, so the collapsed notch stays invisible
      // instead of sliding across the screen with the wallpaper.
      .stationary,
      .fullScreenAuxiliary,
      .ignoresCycle,
    ]

    // Click-through while collapsed so we never swallow menu bar clicks;
    // interactive while expanded so the approve/deny buttons and
    // elicitation forms in the dashboard can actually be tapped.
    ignoresMouseEvents = true

    // Visible in screenshots / recordings.
    sharingType = .readOnly

    let hosting = NSHostingView(
      rootView: NotchRootView(model: model).environmentObject(sessionStore))
    hosting.frame = CGRect(origin: .zero, size: metrics.windowFrame.size)
    hosting.autoresizingMask = [.width, .height]
    contentView = hosting

    setFrame(metrics.windowFrame, display: false)

    expansionObservation = model.$isExpanded.sink { [weak self] isExpanded in
      self?.ignoresMouseEvents = !isExpanded
    }

    // `$tasks` emits in willSet, before the stored property updates — so read
    // the emitted value here, never sessionStore.tasks (which is still stale).
    indicatorObservation = sessionStore.$tasks
      .map { tasks in
        CollapsedIndicator(
          hasAliveSession: tasks.contains { $0.status != .done },
          isWorking: tasks.contains { $0.status == .running },
          needsYouCount: tasks.filter { $0.status == .needsYou }.count
        )
      }
      .removeDuplicates()
      .sink { [weak self] indicator in
        self?.model.indicator = indicator
      }

    questionObservation = sessionStore.$tasks
      .map { tasks in
        PendingFocus(
          // Any pending interaction may be driven by keyboard: permission
          // approve/deny, an elicitation form, or a question.
          anyInteraction: tasks.contains { $0.pendingInteraction != nil },
          // Only the two that contain input controls pull activation over.
          // A bare permission request must not yank focus off the user's
          // terminal — that would fire on every Bash approval.
          form: tasks.contains { $0.pendingQuestion != nil || $0.pendingElicitation != nil }
        )
      }
      .removeDuplicates()
      .sink { [weak self] pending in
        guard let self else { return }
        // Exactly one window answers. Decided from the pointer, not
        // NSScreen.main — "main" means "screen with the key window", so it
        // changes under us the moment we take focus.
        let isTarget = self.screen == Self.targetScreen()
        self.interactionActive = pending.anyInteraction && isTarget
        // Only a form pins the panel open — it has to stay visible to be
        // filled in. A bare permission request leaves the panel alone and
        // just becomes focusable, so approvals don't pop it open all day.
        self.model.isPinnedOpen = pending.form
        if pending.form {
          self.model.isExpanded = true
        }
        if pending.form && isTarget {
          self.takeFocus()
        } else if !pending.form && !self.model.isHotkeyOpen {
          // Don't hand focus back while the user is deliberately using the
          // panel — this sink fires on every task change, not just form ones.
          self.releaseFocus()
        }
      }
  }

  /// The window that should answer. Every window evaluates this within one
  /// run-loop turn against an unmoved pointer, so they agree on one winner.
  /// ponytail: single-display Macs collapse to the only window either way.
  private static func targetScreen() -> NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
  }

  /// LSUIElement + .nonactivatingPanel means the panel can be key inside
  /// Handoff while macOS still routes keyDown to the frontmost app, and
  /// clicking a non-activating panel never activates us. Real activation is
  /// the only way a text field here ever sees a keystroke.
  func takeFocus() {
    // Capture only on the way in. Re-capturing while we already hold focus
    // would record Handoff itself, and the restore would hand activation
    // back to us — stranding it with nothing coming forward.
    if previousApp == nil {
      let frontmost = NSWorkspace.shared.frontmostApplication
      if frontmost != NSRunningApplication.current {
        previousApp = frontmost
      }
    }
    NSApp.activate(ignoringOtherApps: true)
    makeKeyAndOrderFront(nil)
  }

  /// Idempotent: nils out, so a double dismiss can't reactivate twice.
  func releaseFocus() {
    if isKeyWindow {
      resignKey()
    }
    previousApp?.activate(options: [])
    previousApp = nil
  }

  override var canBecomeKey: Bool { interactionActive || model.isHotkeyOpen }
  override var canBecomeMain: Bool { false }

  /// Esc on a deliberately-opened dashboard. A pending form owns its own Esc
  /// (cancel/confirm), so this only fires when nothing is being answered.
  override func cancelOperation(_ sender: Any?) {
    guard model.isHotkeyOpen, !model.isPinnedOpen else { return }
    model.isHotkeyOpen = false
    model.isExpanded = false
    releaseFocus()
  }
}

/// What the task list currently wants from this window.
private struct PendingFocus: Equatable {
  /// Anything awaiting the user — enough to allow keyboard focus.
  let anyInteraction: Bool
  /// Specifically something with input controls — enough to take focus.
  let form: Bool
}
