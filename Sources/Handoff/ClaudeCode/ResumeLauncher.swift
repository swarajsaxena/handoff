import AppKit
import Foundation

/// Launches a terminal to resume a past Claude Code session.
///
/// Default: opens Terminal.app via NSAppleScript (no shell-quoting gymnastics).
/// Override: set UserDefaults key "resumeCommandTemplate" to a shell command
/// with {cwd} and {id} placeholders, e.g. for iTerm or Ghostty.
///
/// ponytail: single-quote ceiling — breaks only for project paths containing
/// a literal single-quote (extremely rare). Full shell-quoting upgrade
/// deferred until someone hits it.
@MainActor
enum ResumeLauncher {

  static let templateKey = "resumeCommandTemplate"
  private static let appleEventNotAuthorizedCode = -1743

  static func launch(session: PastSession) {
    guard FileManager.default.fileExists(atPath: session.cwd) else {
      NSLog("[Handoff] Resume skipped — cwd no longer exists: \(session.cwd)")
      return
    }

    if let template = UserDefaults.standard.string(forKey: templateKey) {
      runTemplate(template, cwd: session.cwd, id: session.id)
    } else {
      openInTerminalApp(cwd: session.cwd, id: session.id)
    }
  }

  // MARK: - Private

  private static func openInTerminalApp(cwd: String, id: String) {
    guard requestTerminalAutomationPermissionIfNeeded() else { return }

    // Single-quote the cwd to handle spaces; breaks on paths with ' (rare).
    let script = """
      tell application "Terminal"
          do script "cd '\(cwd)' && claude --resume \(id)"
          activate
      end tell
      """
    var error: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&error)
    guard let error else { return }
    NSLog("[Handoff] AppleScript error: \(error)")
    if isAppleEventsPermissionDenied(error) {
      presentAutomationPermissionAlert()
    }
  }

  private static func requestTerminalAutomationPermissionIfNeeded() -> Bool {
    let script = """
      tell application "Terminal"
          get name
      end tell
      """
    var error: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&error)
    guard let error else { return true }

    NSLog("[Handoff] AppleScript auth check error: \(error)")
    if isAppleEventsPermissionDenied(error) {
      presentAutomationPermissionAlert()
      return false
    }
    return true
  }

  private static func isAppleEventsPermissionDenied(_ error: NSDictionary) -> Bool {
    guard let code = error[NSAppleScript.errorNumber] as? Int else { return false }
    return code == appleEventNotAuthorizedCode
  }

  private static func presentAutomationPermissionAlert() {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Allow Terminal Automation"
    alert.informativeText =
      "Handoff needs permission to control Terminal to resume Claude Code sessions. Enable it in System Settings > Privacy & Security > Automation."
    alert.addButton(withTitle: "Open Settings")
    alert.addButton(withTitle: "Not now")

    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }
    openAutomationSettings()
  }

  private static func openAutomationSettings() {
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"),
      NSWorkspace.shared.open(url)
    {
      return
    }

    let settingsAppURL = URL(fileURLWithPath: "/System/Applications/System Settings.app")
    NSWorkspace.shared.open(settingsAppURL)
  }

  private static func runTemplate(_ template: String, cwd: String, id: String) {
    let cmd =
      template
      .replacingOccurrences(of: "{cwd}", with: cwd)
      .replacingOccurrences(of: "{id}", with: id)
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/bin/sh")
    proc.arguments = ["-c", cmd]
    do {
      try proc.run()
    } catch {
      NSLog("[Handoff] Template launch error: \(error)")
    }
  }
}
