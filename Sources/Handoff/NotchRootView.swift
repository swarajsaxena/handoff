import SwiftUI

private enum NotchRootDebug {
  /// Master toggle for all notch border overlays.
  static let showBorders = false
  /// Debug-only overlay for visualizing the app notch cutout path.
  static let showAppCutoutBorder = showBorders
  /// Debug-only overlay for visualizing the physical Mac notch footprint.
  static let showMacNotchBorder = showBorders
  static let macNotchBottomRadius: CGFloat = 10
}

private struct PhysicalMacNotchShape: Shape {
  let bottomRadius: CGFloat

  func path(in rect: CGRect) -> Path {
    var path = Path()
    let radius = min(bottomRadius, min(rect.width, rect.height) / 2)

    path.move(to: CGPoint(x: rect.minX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
      control: CGPoint(x: rect.maxX, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
    path.addQuadCurve(
      to: CGPoint(x: rect.minX, y: rect.maxY - radius),
      control: CGPoint(x: rect.minX, y: rect.maxY)
    )
    path.closeSubpath()
    return path
  }
}

struct NotchRootView: View {
  @ObservedObject var model: NotchModel
  @EnvironmentObject private var store: SessionStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var size: CGSize { model.currentSize }
  private var expandedTopRadius: CGFloat { 20 }
  private var expandedBottomRadius: CGFloat { 20 }

  private var notchShape: NotchShape {
    NotchShape(
      topRadius: model.isExpanded ? expandedTopRadius : 8,
      bottomRadius: model.isExpanded ? expandedBottomRadius : 10
    )
  }
  private var expandedShadowOpacity: Double { model.isExpanded ? 0.20 : 0 }
  private var expandedAmbientShadowOpacity: Double { model.isExpanded ? 0.16 : 0 }

  var body: some View {
    VStack(spacing: 0) {
      notchShape
        .fill(Theme.background)
        .frame(width: size.width, height: size.height)
        .overlay {
          ZStack(alignment: .top) {
            if NotchRootDebug.showAppCutoutBorder {
              notchShape
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                .frame(width: size.width, height: size.height)
            }

            if NotchRootDebug.showMacNotchBorder, model.metrics.hasNotch {
              PhysicalMacNotchShape(bottomRadius: NotchRootDebug.macNotchBottomRadius)
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                .frame(
                  width: model.metrics.collapsedSize.width,
                  height: model.metrics.collapsedSize.height
                )
                .offset(x: -model.horizontalOffset)
            }
          }
        }
        .shadow(color: .black.opacity(expandedShadowOpacity), radius: 20, x: 0, y: 14)
        .shadow(color: .black.opacity(expandedAmbientShadowOpacity), radius: 10, x: 0, y: 3)
        .overlay {
          Group {
            if let active = store.activeQuestion {
              QuestionFlowView(sessionId: active.sessionId, info: active.info)
            } else {
              DashboardView(isExpanded: model.isExpanded, isInteractive: model.isHotkeyOpen)
            }
          }
          .frame(width: size.width, height: size.height, alignment: .top)
          .clipShape(notchShape)
          .opacity(model.isExpanded ? 1 : 0)
          // Reduce Motion keeps the cross-fade but drops the zoom and defocus,
          // which are the parts that read as movement.
          .blur(radius: reduceMotion ? 0 : (model.isExpanded ? 0 : 8))
          .scaleEffect(reduceMotion ? 1 : (model.isExpanded ? 1 : 0.8))
          .allowsHitTesting(model.isExpanded)
        }
        .overlay {
          CollapsedIndicatorView(indicator: model.indicator)
            .frame(width: size.width, height: size.height, alignment: .top)
            .opacity(model.isExpanded ? 0 : 1)
            .allowsHitTesting(false)
        }
        .offset(x: model.horizontalOffset)
        .animation(
          reduceMotion ? .easeInOut(duration: 0.2) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.55),
          value: model.isExpanded
        )
        .animation(
          reduceMotion ? .easeInOut(duration: 0.2) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.4),
          value: model.indicator
        )

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}
