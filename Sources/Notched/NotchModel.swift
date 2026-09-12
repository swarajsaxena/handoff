import SwiftUI

final class NotchModel: ObservableObject {
  @Published var isExpanded = false
  @Published var indicator: CollapsedIndicator = .idle
  /// When true, hover-out must not collapse the panel (active questionnaire).
  @Published var isPinnedOpen = false
  /// Opened deliberately by the hotkey. Separate from `isPinnedOpen` because
  /// that one is written by the task subscription and would stomp this when a
  /// question clears — and because hover-open and intent-open have different
  /// dismissal rules.
  @Published var isHotkeyOpen = false

  let metrics: NotchMetrics

  init(metrics: NotchMetrics) {
    self.metrics = metrics
  }

  var currentSize: CGSize {
    if isExpanded {
      return metrics.expandedSize
    }
    return CGSize(
      width: metrics.collapsedSize.width + indicator.leftEarWidth + indicator.rightEarWidth,
      height: metrics.collapsedSize.height
    )
  }

  var horizontalOffset: CGFloat {
    if isExpanded { return 0 }
    return (indicator.rightEarWidth - indicator.leftEarWidth) / 2
  }

  var collapsedScreenRect: CGRect {
    metrics.collapsedRect(leftEar: indicator.leftEarWidth, rightEar: indicator.rightEarWidth)
  }
}
