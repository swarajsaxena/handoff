import AppKit

/// Because the window is click-through, we can't rely on SwiftUI's `.onHover`.
/// A global mouse-moved monitor is the reliable route — and unlike keyboard
/// monitors, it needs no Accessibility permission.
final class MouseTracker {
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private let onMove: (NSPoint) -> Void

  init(onMove: @escaping (NSPoint) -> Void) {
    self.onMove = onMove
  }

  func start() {
    globalMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
    ) { [weak self] _ in
      self?.onMove(NSEvent.mouseLocation)
    }

    localMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.mouseMoved]
    ) { [weak self] event in
      self?.onMove(NSEvent.mouseLocation)
      return event
    }
  }

  func stop() {
    if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    globalMonitor = nil
    localMonitor = nil
  }

  deinit { stop() }
}
