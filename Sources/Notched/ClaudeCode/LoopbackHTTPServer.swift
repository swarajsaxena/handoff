import Foundation
import Network

/// A parsed HTTP request. `headers` keys are lowercased.
struct HTTPRequest {
  let method: String
  let path: String
  let headers: [String: String]
  let body: Data

  func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse {
  let status: Int
  let body: Data
  var headers: [String: String] = [:]

  static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
    HTTPResponse(status: status, body: data, headers: ["Content-Type": "application/json"])
  }

  static func status(_ code: Int) -> HTTPResponse {
    HTTPResponse(status: code, body: Data())
  }
}

/// Wraps one in-flight request so a handler that awaits a long time (holding
/// a `PermissionRequest`/`Elicitation` open for the user to answer) can be
/// told the underlying connection died — e.g. the terminal was closed before
/// anyone tapped Approve/Deny — and clean up instead of leaking state.
/// Never resolve a pending interaction implicitly on cancellation with an
/// "allow": always treat connection loss as "give up", matching the
/// fail-closed default Claude Code itself uses on timeout.
final class HTTPRequestContext {
  let request: HTTPRequest
  private let lock = NSLock()
  private var cancellationHandlers: [() -> Void] = []
  private var isCancelled = false

  init(request: HTTPRequest) { self.request = request }

  func onCancel(_ handler: @escaping () -> Void) {
    lock.lock()
    if isCancelled {
      lock.unlock()
      handler()
      return
    }
    cancellationHandlers.append(handler)
    lock.unlock()
  }

  fileprivate func cancel() {
    lock.lock()
    guard !isCancelled else {
      lock.unlock()
      return
    }
    isCancelled = true
    let handlers = cancellationHandlers
    cancellationHandlers = []
    lock.unlock()
    handlers.forEach { $0() }
  }
}

/// Minimal HTTP/1.1 server bound to loopback only, built directly on
/// Network.framework so this package pulls in no third-party dependency.
/// Deliberately narrow: POST only, one request per connection
/// (`Connection: close`), `Content-Length` framing only (no chunked
/// transfer-encoding, which Claude Code's HTTP hook client doesn't send).
///
/// `@unchecked Sendable`: every mutable property is only ever touched from
/// closures scheduled on `queue`, a single serial `DispatchQueue` — that
/// confinement is the actual safety mechanism, the compiler just can't see
/// it through GCD's API.
final class LoopbackHTTPServer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "com.notched.hookserver.io")
  private var listener: NWListener?
  private var activeConnections: [ObjectIdentifier: HTTPConnection] = [:]

  /// Rejects bodies over this size before they're ever handed to a JSON
  /// decoder. Hook payloads are small metadata + short tool inputs; this
  /// is generous headroom, not a real-world ceiling.
  var maxBodySize: Int = 2 * 1024 * 1024

  /// Set before calling `start()`. Invoked on an arbitrary Task, never on
  /// `queue` — safe to `await` inside for as long as the caller's hook
  /// timeout allows (up to 600s for `PermissionRequest`/`Elicitation`).
  var handler: ((HTTPRequestContext) async -> HTTPResponse)?

  /// Binds to `127.0.0.1` with a kernel-assigned ephemeral port and
  /// returns that port once the listener is ready.
  func start() async throws -> UInt16 {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { [weak self] in
        guard let self else { return }
        var didResume = false
        do {
          let params = NWParameters.tcp
          params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
          let listener = try NWListener(using: params)
          self.listener = listener
          listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
          }
          listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
              guard !didResume else { return }
              didResume = true
              continuation.resume(returning: listener.port?.rawValue ?? 0)
            case .failed(let error):
              guard !didResume else { return }
              didResume = true
              continuation.resume(throwing: error)
            default:
              break
            }
          }
          listener.start(queue: self.queue)
        } catch {
          guard !didResume else { return }
          didResume = true
          continuation.resume(throwing: error)
        }
      }
    }
  }

  func stop() {
    queue.async { [weak self] in
      self?.listener?.cancel()
      self?.listener = nil
      self?.activeConnections.values.forEach { $0.forceClose() }
      self?.activeConnections.removeAll()
    }
  }

  private func accept(_ connection: NWConnection) {
    let conn = HTTPConnection(connection: connection, queue: queue, maxBodySize: maxBodySize)
    conn.onRequest = { [weak self] context in
      await self?.handler?(context) ?? .status(404)
    }
    conn.onFinish = { [weak self, weak conn] in
      guard let conn else { return }
      self?.activeConnections.removeValue(forKey: ObjectIdentifier(conn))
    }
    activeConnections[ObjectIdentifier(conn)] = conn
    conn.start()
  }
}

/// Owns one accepted TCP connection: incrementally buffers bytes until a
/// full request is framed, dispatches it once, writes back a single
/// response, then closes. All buffer/state mutation happens on `queue`;
/// the (possibly long) `await onRequest?()` call runs off-queue so a
/// pending permission/elicitation never blocks other connections.
///
/// `@unchecked Sendable` for the same reason as `LoopbackHTTPServer`: all
/// mutable state is confined to `queue`, including the one hop back onto
/// it after the off-queue `await`.
private final class HTTPConnection: @unchecked Sendable {
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let maxBodySize: Int

  private var buffer = Data()
  private var requestLine: (method: String, path: String)?
  private var headers: [String: String] = [:]
  private var contentLength = 0
  private var dispatched = false
  private var responded = false
  private var finished = false
  private var activeContext: HTTPRequestContext?

  var onRequest: ((HTTPRequestContext) async -> HTTPResponse)?
  var onFinish: (() -> Void)?

  init(connection: NWConnection, queue: DispatchQueue, maxBodySize: Int) {
    self.connection = connection
    self.queue = queue
    self.maxBodySize = maxBodySize
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      switch state {
      case .failed, .cancelled:
        self?.queue.async { self?.finish() }
      default:
        break
      }
    }
    connection.start(queue: queue)
    receive()
  }

  func forceClose() {
    queue.async { [weak self] in self?.finish() }
  }

  /// Keeps a read outstanding even after the request has been dispatched.
  /// An outstanding receive is the only way Network.framework reports that
  /// the peer went away — a half-closed connection leaves the state at
  /// `.ready`, so `stateUpdateHandler` alone never fires. A handler parked
  /// on an unanswered permission/elicitation depends on that report to
  /// release itself instead of waiting forever. Bytes arriving after
  /// dispatch are discarded: this server answers one request per
  /// connection and does not pipeline.
  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, isComplete, error in
      guard let self else { return }
      self.queue.async {
        guard !self.finished else { return }
        if !self.dispatched, let data, !data.isEmpty {
          self.buffer.append(data)
          if self.buffer.count > self.maxBodySize {
            self.respondAndClose(.status(413))
            return
          }
          self.tryParse()
        }
        if error != nil || isComplete {
          self.finish()
          return
        }
        self.receive()
      }
    }
  }

  private static let headerTerminator = Data("\r\n\r\n".utf8)

  private func tryParse() {
    if requestLine == nil {
      guard let range = buffer.range(of: Self.headerTerminator) else { return }
      let headerData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
      guard let headerText = String(data: headerData, encoding: .utf8) else {
        respondAndClose(.status(400))
        return
      }
      let lines = headerText.components(separatedBy: "\r\n")
      guard let first = lines.first else {
        respondAndClose(.status(400))
        return
      }
      let parts = first.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
      guard parts.count >= 2 else {
        respondAndClose(.status(400))
        return
      }
      requestLine = (method: String(parts[0]), path: String(parts[1]))
      for line in lines.dropFirst() where !line.isEmpty {
        guard let colonIndex = line.firstIndex(of: ":") else { continue }
        let key = line[line.startIndex..<colonIndex]
          .trimmingCharacters(in: .whitespaces).lowercased()
        let value = line[line.index(after: colonIndex)...]
          .trimmingCharacters(in: .whitespaces)
        headers[key] = value
      }
      contentLength = Int(headers["content-length"] ?? "0") ?? 0
      buffer.removeSubrange(buffer.startIndex..<range.upperBound)
    }

    guard let requestLine, buffer.count >= contentLength else { return }

    dispatched = true
    let body = Data(buffer.prefix(contentLength))
    let request = HTTPRequest(
      method: requestLine.method, path: requestLine.path, headers: headers, body: body)
    let context = HTTPRequestContext(request: request)
    activeContext = context

    Task {
      let response = await onRequest?(context) ?? .status(404)
      self.queue.async {
        self.responded = true
        self.respondAndClose(response)
      }
    }
  }

  private func respondAndClose(_ response: HTTPResponse) {
    guard !finished else { return }
    var head = "HTTP/1.1 \(response.status) \(HTTPStatusText.text(for: response.status))\r\n"
    var headers = response.headers
    headers["Content-Length"] = "\(response.body.count)"
    headers["Connection"] = "close"
    for (key, value) in headers {
      head += "\(key): \(value)\r\n"
    }
    head += "\r\n"

    var payload = Data(head.utf8)
    payload.append(response.body)

    connection.send(
      content: payload,
      completion: .contentProcessed { [weak self] _ in
        self?.queue.async { self?.finish() }
      })
  }

  private func finish() {
    guard !finished else { return }
    finished = true
    if !responded { activeContext?.cancel() }
    connection.cancel()
    onFinish?()
  }
}

private enum HTTPStatusText {
  static func text(for code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 404: return "Not Found"
    case 405: return "Method Not Allowed"
    case 413: return "Payload Too Large"
    default: return "Internal Server Error"
    }
  }
}
