import AppKit

/// Everything positional, derived once per screen.
/// All rects are in AppKit screen coordinates (origin bottom-left).
struct NotchMetrics {
  let screenFrame: CGRect
  let hasNotch: Bool

  /// Matches the physical cutout exactly, so the collapsed state is invisible.
  let collapsedSize: CGSize

  /// Tune freely — this is the "opened" panel. Width is half the screen.
  var expandedSize: CGSize { CGSize(width: screenFrame.width / 2, height: 400) }

  init(screen: NSScreen) {
    screenFrame = screen.frame

    let topInset = screen.safeAreaInsets.top
    let left = screen.auxiliaryTopLeftArea?.width ?? 0
    let right = screen.auxiliaryTopRightArea?.width ?? 0

    if topInset > 0, left > 0, right > 0 {
      hasNotch = true
      collapsedSize = CGSize(
        width: screen.frame.width - left - right,
        height: topInset
      )
    } else {
      // Non-notch Mac (or external display): fake a pill.
      hasNotch = false
      collapsedSize = CGSize(width: 200, height: 32)
    }
  }

  /// Top-centre anchored rect for a given size.
  private func anchored(_ size: CGSize) -> CGRect {
    CGRect(
      x: screenFrame.midX - size.width / 2,
      y: screenFrame.maxY - size.height,
      width: size.width,
      height: size.height
    )
  }

  var collapsedRect: CGRect { anchored(collapsedSize) }
  var expandedRect: CGRect { anchored(expandedSize) }

  func collapsedRect(leftEar: CGFloat, rightEar: CGFloat) -> CGRect {
    let base = collapsedRect
    return CGRect(
      x: base.minX - leftEar,
      y: base.minY,
      width: base.width + leftEar + rightEar,
      height: base.height
    )
  }

  /// The window itself never resizes — it's a fixed, generously-sized
  /// transparent canvas. Only the SwiftUI content inside animates.
  var windowFrame: CGRect {
    let height = expandedSize.height + 80
    return CGRect(
      x: screenFrame.minX,
      y: screenFrame.maxY - height,
      width: screenFrame.width,
      height: height
    )
  }
}
