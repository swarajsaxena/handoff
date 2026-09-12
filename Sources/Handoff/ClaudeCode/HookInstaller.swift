import Foundation

/// Installs/removes the Claude Code hooks that bridge into `HookServer`, and
/// the small on-disk support files that make the bridge script fail fast
/// when Handoff isn't running. See docs/claude-code-integration-notes.md §3
/// for why these are `type: "command"` wrapper-script hooks rather than
/// declarative `http` hooks pointed at a literal, restart-fragile URL.
enum HookInstaller {
  static let managedEvents: [HookEventName] = [
    .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse,
    .permissionRequest, .permissionDenied, .notification,
    .stop, .sessionEnd, .elicitation,
  ]

  /// Substring that identifies a hook entry as ours, so re-running
  /// `install()`/`uninstall()` can find and replace/remove exactly our
  /// own entries without touching hooks from the user or another tool.
  private static let ownershipMarker = "hook-bridge.sh"

  private static var appSupportDirectory: URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support")
    return base.appendingPathComponent("Handoff", isDirectory: true)
  }

  private static var bridgeScriptURL: URL {
    appSupportDirectory.appendingPathComponent("hook-bridge.sh")
  }
  private static var bridgeConfigURL: URL {
    appSupportDirectory.appendingPathComponent("hook-bridge.json")
  }
  private static var pidFileURL: URL { appSupportDirectory.appendingPathComponent("handoff.pid") }

  private static var settingsURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
  }

  private static var settingsBackupURL: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      ".claude/settings.json.handoff-backup")
  }

  static func install(port: UInt16, token: String) throws {
    try FileManager.default.createDirectory(
      at: appSupportDirectory, withIntermediateDirectories: true)

    try writeBridgeConfig(port: port, token: token)
    try writeBridgeScript()
    try writePidFile()

    try mergeSettings { hooks in
      for event in managedEvents {
        var groups = removingOwnEntries(from: hooks[event.rawValue])
        groups.append([
          "hooks": [
            [
              "type": "command",
              "command": bridgeScriptURL.path,
              "args": [event.rawValue],
            ] as [String: Any]
          ]
        ])
        hooks[event.rawValue] = groups
      }
    }
  }

  /// Removes only the hooks we installed; the app's own pidfile removal
  /// (see `removePidFile()`) is what makes the bridge script fail fast
  /// once Handoff quits, so callers don't need to uninstall on every
  /// normal quit — this is for the explicit "remove Claude Code hooks"
  /// action the plan requires.
  static func uninstall() throws {
    try mergeSettings { hooks in
      for event in managedEvents {
        let groups = removingOwnEntries(from: hooks[event.rawValue])
        if groups.isEmpty {
          hooks.removeValue(forKey: event.rawValue)
        } else {
          hooks[event.rawValue] = groups
        }
      }
    }
    try? FileManager.default.removeItem(at: bridgeConfigURL)
    try? FileManager.default.removeItem(at: bridgeScriptURL)
    try? FileManager.default.removeItem(at: pidFileURL)
  }

  /// Called on quit. Leaves the hooks installed (so they don't need
  /// reinstalling next launch) but removes the pidfile the bridge script
  /// checks, so every hook fails fast — no output, ~0ms — instead of
  /// adding connect-timeout latency to every Claude Code tool call on
  /// this machine while Handoff is closed.
  static func removePidFile() {
    try? FileManager.default.removeItem(at: pidFileURL)
  }

  private static func removingOwnEntries(from value: Any?) -> [[String: Any]] {
    guard let groups = value as? [[String: Any]] else { return [] }
    return groups.filter { group in
      guard let hookList = group["hooks"] as? [[String: Any]] else { return true }
      return !hookList.contains { ($0["command"] as? String)?.contains(ownershipMarker) == true }
    }
  }

  // MARK: - settings.json read-modify-write

  private static func mergeSettings(_ mutate: (inout [String: Any]) -> Void) throws {
    try FileManager.default.createDirectory(
      at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
    )

    var root: [String: Any] = [:]
    if let data = try? Data(contentsOf: settingsURL),
      let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      root = parsed
      if !FileManager.default.fileExists(atPath: settingsBackupURL.path) {
        try? data.write(to: settingsBackupURL, options: .atomic)
      }
    }

    var hooks = (root["hooks"] as? [String: Any]) ?? [:]
    mutate(&hooks)
    root["hooks"] = hooks

    let data = try JSONSerialization.data(
      withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    let tempURL = settingsURL.appendingPathExtension("handoff-tmp")
    try data.write(to: tempURL, options: .atomic)

    if FileManager.default.fileExists(atPath: settingsURL.path) {
      _ = try FileManager.default.replaceItemAt(settingsURL, withItemAt: tempURL)
    } else {
      try FileManager.default.moveItem(at: tempURL, to: settingsURL)
    }
  }

  // MARK: - Bridge files

  private static func writeBridgeConfig(port: UInt16, token: String) throws {
    // Deliberately compact, single-line JSON: the bridge script parses
    // this with `sed`, not a JSON library, so the format must stay
    // exactly `{"port":N,"token":"..."}` with no incidental whitespace.
    let json = "{\"port\":\(port),\"token\":\"\(token)\"}"
    try json.write(to: bridgeConfigURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: bridgeConfigURL.path)
  }

  private static func writeBridgeScript() throws {
    let script = #"""
      #!/bin/sh
      # Generated by Handoff — do not edit by hand, `install()` overwrites
      # this on every launch. Forwards a Claude Code hook payload (on
      # stdin) to the app's loopback HTTP server. Fails fast (no output,
      # exit 0) whenever Handoff isn't running, so a closed app never
      # adds latency to Claude Code tool calls on this machine.
      EVENT="$1"
      SUPPORT_DIR="$(dirname "$0")"
      PIDFILE="$SUPPORT_DIR/handoff.pid"
      BRIDGE="$SUPPORT_DIR/hook-bridge.json"

      [ -f "$PIDFILE" ] || exit 0
      PID="$(cat "$PIDFILE" 2>/dev/null)"
      [ -n "$PID" ] || exit 0
      kill -0 "$PID" 2>/dev/null || exit 0

      [ -f "$BRIDGE" ] || exit 0
      PORT="$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$BRIDGE")"
      TOKEN="$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' "$BRIDGE")"
      [ -n "$PORT" ] && [ -n "$TOKEN" ] || exit 0

      curl -s --connect-timeout 1 --max-time 600 \
        -X POST "http://127.0.0.1:${PORT}/hook/${EVENT}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -H "X-Handoff-Terminal: ${TERM_PROGRAM:-}" \
        -H "X-Handoff-PID: ${PPID}" \
        --data-binary @-
      """#
    try script.write(to: bridgeScriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: bridgeScriptURL.path)
  }

  private static func writePidFile() throws {
    let pid = String(ProcessInfo.processInfo.processIdentifier)
    try pid.write(to: pidFileURL, atomically: true, encoding: .utf8)
  }
}
