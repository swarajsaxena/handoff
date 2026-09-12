import SwiftUI

private enum CollapsedIndicatorDebug {
  /// Turn on to always show both ears for sizing/debug.
  static let forceEars = false
  static let forcedNeedsYouCount = 88
}

struct CollapsedIndicator: Equatable {
  private static let sharedEarWidth: CGFloat = 36

  /// Session is alive (not ended) — show the mark.
  var hasAliveSession: Bool
  /// Agent is mid-turn — spin the mark. Subset of `hasAliveSession`.
  var isWorking: Bool
  var needsYouCount: Int

  static let idle = CollapsedIndicator(hasAliveSession: false, isWorking: false, needsYouCount: 0)

  var effectiveHasAliveSession: Bool {
    if CollapsedIndicatorDebug.forceEars { return true }
    return hasAliveSession
  }

  var effectiveIsWorking: Bool {
    if CollapsedIndicatorDebug.forceEars { return true }
    return isWorking
  }

  var effectiveNeedsYouCount: Int {
    if CollapsedIndicatorDebug.forceEars { return CollapsedIndicatorDebug.forcedNeedsYouCount }
    return needsYouCount
  }

  var leftEarWidth: CGFloat {
    effectiveHasAliveSession ? Self.sharedEarWidth : 0
  }

  var rightEarWidth: CGFloat {
    guard effectiveNeedsYouCount > 0 else { return 0 }
    return Self.sharedEarWidth
  }
}

struct CollapsedIndicatorView: View {
  let indicator: CollapsedIndicator
  @State private var claudeSpinDegrees: Double = 0
  private let spinTick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      leftEar
      Spacer(minLength: 0)
      rightEar
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .accessibilityHidden(true)
    .onReceive(spinTick) { _ in
      guard indicator.effectiveIsWorking else { return }
      claudeSpinDegrees = (claudeSpinDegrees + 30).truncatingRemainder(dividingBy: 360)
    }
  }

  private var leftEar: some View {
    Group {
      if indicator.leftEarWidth > 0 {
        ClaudeMark()
          .fill(Theme.claude)
          .frame(width: 16, height: 16)
          .rotationEffect(.degrees(claudeSpinDegrees))
          .animation(nil, value: claudeSpinDegrees)
          .frame(width: indicator.leftEarWidth, alignment: .center)
          .frame(maxHeight: .infinity, alignment: .center)
      } else {
        Color.clear.frame(width: 0)
      }
    }
  }

  private var rightEar: some View {
    Group {
      if indicator.rightEarWidth > 0 {
        Text("\(min(indicator.effectiveNeedsYouCount, 99))")
          .font(Theme.mono(12, .semibold))
          .foregroundStyle(Theme.statusNeedsYou)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
          .frame(width: indicator.rightEarWidth, alignment: .center)
          .frame(maxHeight: .infinity, alignment: .center)
      } else {
        Color.clear.frame(width: 0)
      }
    }
  }
}

#Preview("Collapsed Indicators") {
  VStack {
    CollapsedIndicatorView(indicator: .idle)
      .frame(width: 240, height: 32)
      .background(Color.black)
    CollapsedIndicatorView(indicator: .init(hasAliveSession: true, isWorking: true, needsYouCount: 0))
      .frame(width: 240, height: 32)
      .background(Color.black)
    CollapsedIndicatorView(indicator: .init(hasAliveSession: true, isWorking: false, needsYouCount: 0))
      .frame(width: 240, height: 32)
      .background(Color.black)
    CollapsedIndicatorView(indicator: .init(hasAliveSession: false, isWorking: false, needsYouCount: 3))
      .frame(width: 240, height: 32)
      .background(Color.black)
    CollapsedIndicatorView(indicator: .init(hasAliveSession: true, isWorking: true, needsYouCount: 12))
      .frame(width: 240, height: 32)
      .background(Color.black)
  }
}
