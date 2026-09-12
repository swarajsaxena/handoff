import Darwin
import Foundation
import OSLog
import Security

/// Runs the loopback HTTP server the generated hook-bridge script POSTs to,
/// and turns each authenticated request into a `SessionStore` call. Owns
/// the per-install bearer token; see docs/claude-code-integration-notes.md §3
/// for why hooks reach this server through a `type: "command"` wrapper
/// script rather than a declarative `type: "http"` hook.
final class HookServer {
  private static let logger = Logger(
    subsystem: "com.swarajsaxena.handoff", category: "hooks")

  private let server = LoopbackHTTPServer()
  private let sessionStore: SessionStore
  private(set) var token: String = ""
  private(set) var port: UInt16 = 0

  init(sessionStore: SessionStore) {
    self.sessionStore = sessionStore
  }

  @discardableResult
  func start() async throws -> (port: UInt16, token: String) {
    let token = Self.generateToken()
    self.token = token
    server.handler = { [weak self] context in
      await self?.handle(context) ?? .status(503)
    }
    port = try await server.start()
    return (port, token)
  }

  func stop() {
    server.stop()
  }

  private func handle(_ context: HTTPRequestContext) async -> HTTPResponse {
    let request = context.request

    guard request.method == "POST" else { return .status(405) }
    guard request.path.hasPrefix("/hook/") else { return .status(404) }
    guard let auth = request.header("Authorization"), auth == "Bearer \(token)" else {
      return .status(401)
    }

    // `HookEnvelope.CodingKeys` already spells out the snake_case JSON
    // keys explicitly — do not also set `.convertFromSnakeCase` here,
    // it double-transforms the keys and every field silently fails to
    // decode.
    guard let envelope = try? JSONDecoder().decode(HookEnvelope.self, from: request.body) else {
      Self.logger.error("decode failed path=\(request.path, privacy: .public)")
      return .status(400)
    }

    let terminalHeader = request.header("X-Handoff-Terminal")
    let claudePID = request.header("X-Handoff-PID").flatMap(Int32.init)
    Self.logHook(envelope, terminal: terminalHeader, pid: claudePID)

    switch envelope.hookEventName {
    case .permissionRequest:
      let data = await sessionStore.handlePermissionRequest(
        envelope, context: context, pid: claudePID)
      return .json(data)
    case .elicitation:
      let data = await sessionStore.handleElicitation(envelope, context: context, pid: claudePID)
      return .json(data)
    case nil:
      return .status(400)
    default:
      await sessionStore.ingest(envelope, terminalHeader: terminalHeader, pid: claudePID)
      return .json(HookResponse.empty())
    }
  }

  private static func logHook(_ envelope: HookEnvelope, terminal: String?, pid: pid_t?) {
    var parts = [
      "event=\(envelope.hookEventNameRaw)"
    ]
    if let cwd = envelope.cwd { parts.append("cwd=\(cwd)") }
    if let toolName = envelope.toolName { parts.append("tool=\(toolName)") }
    if let notificationType = envelope.notificationType {
      parts.append("notification=\(notificationType)")
    }
    if let terminal, !terminal.isEmpty { parts.append("terminal=\(terminal)") }
    if let pid { parts.append("pid=\(pid)") }
    let line = parts.joined(separator: " ")
    logger.info("\(line, privacy: .public)")
    print("[hook] \(line)")  // ponytail: quick stdout tap, drop when os_log stream is enough
  }

  private static func generateToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    if status != errSecSuccess {
      // SecRandomCopyBytes failing is effectively unheard of on macOS;
      // fall back rather than crash the app over a local auth token.
      var generator = SystemRandomNumberGenerator()
      for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &generator) }
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }
}
