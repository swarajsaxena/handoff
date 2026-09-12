import SwiftUI

/// Design tokens for the Handoff dashboard. Keeps colors, fonts and spacing
/// in one place so views never hardcode raw values.
enum Theme {
  // Surfaces
  static let background = Color(hex: 0x0A0A0A)
  static let surface = Color(hex: 0x161616)
  static let surfaceRaised = Color(hex: 0x1D1D1D)
  static let divider = Color.white.opacity(0.06)

  // Text
  static let textPrimary = Color.white.opacity(0.92)
  static let textSecondary = Color.white.opacity(0.5)
  static let textDim = Color.white.opacity(0.32)

  // Accents / status
  static let accent = Color(hex: 0xE8B84B)  // gold — "needs you" number
  static let statusNeedsYou = Color(hex: 0xF0604D)
  static let statusRunning = Color(hex: 0xE8B84B)
  static let statusDone = Color(hex: 0x3FB950)
  static let statusInfo = Color(hex: 0x58A6FF)
  static let claude = Color(hex: 0xD97757)

  static let command = Color(hex: 0x8FB98F)  // "$ cargo build …"
  static let warning = Color(hex: 0xF0844D)  // "Outside sandbox…"

  // Fonts (SF Mono)
  static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight, design: .monospaced)
  }

  /// Semantic type scale mapped to priority tiers, so size + weight reinforce
  /// hierarchy. Reference as `Theme.Text.title` (qualified to avoid clashing
  /// with SwiftUI's `Text`).
  ///
  /// The 8pt floor is deliberate and was re-confirmed against the real panel:
  /// an 11pt floor was tried and read as too heavy at this density. Noted as
  /// the one open accessibility item — 8pt is small for shipping, and the fix
  /// if it ever matters is scaling with the system text-size setting rather
  /// than a bigger constant.
  enum Text {
    static let hero = mono(24, .bold)  // the one NEEDS YOU number
    static let stat = mono(12, .semibold)  // KPI values
    static let title = mono(12, .semibold)  // task titles
    static let body = mono(12)  // metadata, notes, command, subs
    static let label = mono(8, .medium)  // uppercase eyebrows
    static let meta = mono(8)  // chrome, elapsed, feed, counts
  }

  // Spacing
  static let panelPadding: CGFloat = 16
  static let rowSpacing: CGFloat = 4
}

extension Color {
  init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }
}
