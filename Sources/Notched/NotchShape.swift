import SwiftUI

/// The signature shape: concave (outward-bending) corners at the top where the
/// panel meets the menu bar, convex rounded corners at the bottom.
/// Note it deliberately draws `topRadius` points outside its frame on each
/// side — that overhang is what makes it read as continuous with the bezel.
struct NotchShape: Shape {
  var topRadius: CGFloat
  var bottomRadius: CGFloat

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(topRadius, bottomRadius) }
    set {
      topRadius = newValue.first
      bottomRadius = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path()

    path.move(to: CGPoint(x: rect.minX - topRadius, y: rect.minY))

    // Inverted top-left
    path.addQuadCurve(
      to: CGPoint(x: rect.minX, y: rect.minY + topRadius),
      control: CGPoint(x: rect.minX, y: rect.minY)
    )

    path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - bottomRadius))

    // Bottom-left
    path.addQuadCurve(
      to: CGPoint(x: rect.minX + bottomRadius, y: rect.maxY),
      control: CGPoint(x: rect.minX, y: rect.maxY)
    )

    path.addLine(to: CGPoint(x: rect.maxX - bottomRadius, y: rect.maxY))

    // Bottom-right
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRadius),
      control: CGPoint(x: rect.maxX, y: rect.maxY)
    )

    path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + topRadius))

    // Inverted top-right
    path.addQuadCurve(
      to: CGPoint(x: rect.maxX + topRadius, y: rect.minY),
      control: CGPoint(x: rect.maxX, y: rect.minY)
    )

    path.closeSubpath()
    return path
  }
}
