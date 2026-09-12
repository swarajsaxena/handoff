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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var claudeSpinDegrees: Double = 0
  private let spinTick = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

  var body: some View {
    HStack(alignment: .center, spacing: 0) {
      leftEar
      Spacer(minLength: 0)
      rightEar
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(spokenSummary)
    .onReceive(spinTick) { _ in
      // 30° per 100ms is ~50rpm, parked in peripheral vision for the whole of
      // every agent turn — squarely the kind of persistent motion Reduce Motion
      // exists to stop. The mark stays visible, it just holds still.
      // ponytail: the timer still ticks and does nothing; conditionally
      // subscribing costs more view-identity trouble than a 10Hz no-op is worth.
      guard !reduceMotion, indicator.effectiveIsWorking else { return }
      claudeSpinDegrees = (claudeSpinDegrees + 30).truncatingRemainder(dividingBy: 360)
    }
    .onChange(of: reduceMotion) { reduced in
      // Turning it on mid-spin shouldn't leave the mark frozen at an angle.
      if reduced { claudeSpinDegrees = 0 }
    }
  }

  private var spokenSummary: String {
    let count = indicator.effectiveNeedsYouCount
    if count > 0 {
      return count == 1 ? "1 session needs you" : "\(count) sessions need you"
    }
    if indicator.effectiveIsWorking { return "Agent working" }
    if indicator.hasAliveSession { return "Session idle" }
    return "No active sessions"
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
