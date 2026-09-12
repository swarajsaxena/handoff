import AppKit
import Combine
import SwiftUI

final class NotchWindow: NSPanel {
  let metrics: NotchMetrics
  let model: NotchModel
  private var expansionObservation: AnyCancellable?
  private var indicatorObservation: AnyCancellable?
  private var questionObservation: AnyCancellable?
  /// True while this window should accept keyboard focus for a questionnaire.
  private var questionActive = false
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
      .map { tasks in tasks.contains { $0.pendingQuestion != nil } }
      .removeDuplicates()
      .sink { [weak self] active in
        guard let self else { return }
        // Only the window on the main screen grabs key focus so
        // multi-display setups don't fight over first responder.
        let isPrimary = self.screen == NSScreen.main
        self.questionActive = active && isPrimary
        self.model.isPinnedOpen = active
        if active {
          self.model.isExpanded = true
          if isPrimary {
            // LSUIElement + .nonactivatingPanel means the panel can be key
            // inside Notched while macOS still routes keyDown to the
            // frontmost app. Without real activation the form's text fields
            // and key monitor never see a keystroke. Activate first so the
            // app is frontmost before the panel is made key.
            self.previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
            self.makeKeyAndOrderFront(nil)
          }
        } else {
          if self.isKeyWindow {
            self.resignKey()
          }
          self.previousApp?.activate(options: [])
          self.previousApp = nil
        }
      }
  }

  override var canBecomeKey: Bool { questionActive }
  override var canBecomeMain: Bool { false }
}
