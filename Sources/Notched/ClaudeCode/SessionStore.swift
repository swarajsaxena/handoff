import AppKit
import Darwin
import Foundation

/// Ingests every Claude Code hook event and turns it into the dashboard's
/// live state: the task list, the activity feed, and the two decision-held
/// interaction types (`PermissionRequest`, form-mode `Elicitation`).
///
/// `@MainActor` because every stored property backs SwiftUI directly via
/// `@Published`; `HookServer` calls into this from background Network.framework
/// callbacks via plain `await`, which the compiler hops onto the main actor.
@MainActor
final class SessionStore: ObservableObject {
  @Published private(set) var tasks: [AgentTask] = []
  @Published private(set) var activity: [ActivityEntry] = []
  /// Best-effort heuristic counts — see docs/claude-code-integration-notes.md §7.
  @Published private(set) var shippedCount = 0
  @Published private(set) var testsPassedCount = 0
  /// Past sessions read from ~/.claude/projects on disk. Excludes any session
  /// id that is already live in `tasks`. Refreshed on panel open.
  @Published private(set) var recentSessions: [PastSession] = []

  /// Session ids, most-recently-first-seen order. Used only to keep
  /// stable relative ordering within a status tier in `rebuildTasksArray()`.
  private var order: [String] = []
  private var tasksById: [String: AgentTask] = [:]
  private var isLoadingRecents = false

  /// Sessions we've already chimed for, so republishing `tasks` — which
  /// happens on every hook event — can't re-ring the same request.
  private var chimedSessions: Set<String> = []

  private var permissionContinuations: [String: CheckedContinuation<Data, Never>] = [:]
  private var elicitationContinuations: [String: CheckedContinuation<Data, Never>] = [:]
  private var staleTaskTimer: Timer?

  private static let staleTaskPollInterval: TimeInterval = 5
  private static let idleTimeout: TimeInterval = 60
  private static let inFlightCap: TimeInterval = 600

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter
  }()

  init() {
    staleTaskTimer = Timer.scheduledTimer(
      withTimeInterval: Self.staleTaskPollInterval, repeats: true
    ) { [weak self] _ in
      Task { @MainActor in
        self?.reapStaleTasks()
      }
    }
    staleTaskTimer?.tolerance = 1
  }

  deinit {
    staleTaskTimer?.invalidate()
  }

  // MARK: - Recent sessions

  /// Reads past sessions from Claude Code's on-disk history and publishes
  /// them, excluding any session currently live in the task list.
  /// Returns immediately — IO runs off-main inside a Task.
  func refreshRecentSessions() {
    guard !isLoadingRecents else { return }
    isLoadingRecents = true
    Task {
      let sessions = await SessionHistoryReader.load()
      let liveIds = Set(tasksById.keys)
      recentSessions = sessions.filter { !liveIds.contains($0.id) }
      isLoadingRecents = false
    }
  }

  var needsYouCount: Int { tasks.filter { $0.status == .needsYou }.count }
  var waitingOnYouSince: Date? { tasks.compactMap(\.needsYouSince).min() }
  var runningCount: Int { tasks.filter { $0.status == .running }.count }
  /// A session exists and hasn't ended — shows the (static) mark.
  var hasAliveSession: Bool { tasks.contains { $0.status != .done } }
  /// The agent is mid-turn right now — spins the mark. `Stop` idles the
  /// session (turn over) so this goes false between prompts even though
  /// the session is still alive.
  var hasActiveSession: Bool { tasks.contains { $0.status == .running } }

  /// First live session with a pending `AskUserQuestion` questionnaire.
  var activeQuestion: (sessionId: String, info: AskQuestionInfo)? {
    guard let task = tasks.first(where: { $0.pendingQuestion != nil }),
      let info = task.pendingQuestion
    else { return nil }
    return (task.id, info)
  }

  var hasActiveQuestion: Bool { activeQuestion != nil }

  // MARK: - Observation-only events

  func ingest(_ envelope: HookEnvelope, terminalHeader: String?, pid: pid_t?) {
    if envelope.hookEventName?.provesInteractionResolved == true {
      releaseHeldInteraction(for: envelope.sessionId)
    }
    switch envelope.hookEventName {
    case .sessionStart: handleSessionStart(envelope, terminal: terminalHeader, pid: pid)
    case .userPromptSubmit: handleUserPromptSubmit(envelope, pid: pid)
    case .preToolUse: handlePreToolUse(envelope, pid: pid)
    case .postToolUse: handlePostToolUse(envelope, pid: pid)
    case .permissionDenied: handlePermissionDenied(envelope, pid: pid)
    case .notification: handleNotification(envelope, pid: pid)
    case .stop: handleStop(envelope, pid: pid)
    case .sessionEnd: handleSessionEnd(envelope, pid: pid)
    case .permissionRequest, .elicitation, .none:
      break  // routed through the decision-held methods below instead
    }
  }

  private func handleSessionStart(_ envelope: HookEnvelope, terminal: String?, pid: pid_t?) {
    upsert(envelope.sessionId, cwd: envelope.cwd, pid: pid) { task in
      task.status = .running
      task.startedAt = Date()
      task.toolInFlight = false
      if let model = envelope.model, !model.isEmpty { task.model = model }
      if let terminal, !terminal.isEmpty { task.terminal = terminal }
    }
  }

  private func handleUserPromptSubmit(_ envelope: HookEnvelope, pid: pid_t?) {
    upsert(envelope.sessionId, cwd: envelope.cwd, pid: pid) { task in
      if let prompt = envelope.prompt, !prompt.isEmpty {
        task.title = String(prompt.prefix(80))
      }
      task.transition(to: .running)
      task.startedAt = Date()
      task.toolInFlight = false
    }
  }

  private func handlePreToolUse(_ envelope: HookEnvelope, pid: pid_t?) {
    guard let toolName = envelope.toolName else { return }
    upsert(envelope.sessionId, cwd: envelope.cwd, pid: pid) { task in
      if let command = envelope.bashCommand {
        task.command = "$ \(command)"
        task.note = nil
      } else {
        task.command = nil
        task.note = "Running \(toolName)…"
      }
      task.isWarning = false
      task.toolInFlight = true
      task.transition(to: .running)
    }
  }

  private func handlePostToolUse(_ envelope: HookEnvelope, pid: pid_t?) {
    guard let toolName = envelope.toolName else { return }
    upsert(envelope.sessionId, cwd: envelope.cwd, pid: pid) { task in
      task.toolInFlight = false
      if task.status != .done { task.transition(to: .running) }
    }
    let repo = tasksById[envelope.sessionId]?.repo ?? repoName(fromCwd: envelope.cwd)
    let time = Self.timeFormatter.string(from: Date())

    if toolName == "Bash", let command = envelope.bashCommand {
      recordShippingSignal(command: command, repo: repo, time: time)
      recordTestSignal(
        command: command, stdout: envelope.toolResponse?["stdout"]?.stringValue, repo: repo,
        time: time)
    } else if toolName == "Write" || toolName == "Edit",
      let path = envelope.toolInput?["file_path"]?.stringValue
    {
      addActivity(time: time, repo: repo, message: "edited \((path as NSString).lastPathComponent)")
    }
  }

  private func recordShippingSignal(command: String, repo: String, time: String) {
    if command.contains("git push") {
      shippedCount += 1
      addActivity(time: time, repo: repo, message: "pushed via git push")
    } else if command.contains("gh pr create") {
      shippedCount += 1
      addActivity(time: time, repo: repo, message: "opened a pull request")
    }
  }

  private func recordTestSignal(command: String, stdout: String?, repo: String, time: String) {
    if let stdout, let match = stdout.range(of: #"\d+ passed"#, options: .regularExpression) {
      let text = String(stdout[match])
      testsPassedCount += Int(text.split(separator: " ").first ?? "0") ?? 0
      addActivity(time: time, repo: repo, message: "ran tests — \(text)")
    } else if command.contains("test") {
      addActivity(time: time, repo: repo, message: "ran \(command.prefix(40))")
    }
  }

  private func handlePermissionDenied(_ envelope: HookEnvelope, pid: pid_t?) {
    upsert(envelope.sessionId, cwd: envelope.cwd, pid: pid) { task in
      task.toolInFlight = false
      if task.status != .done { task.transition(to: .idle) }
    }
    let repo = tasksById[envelope.sessionId]?.repo ?? repoName(fromCwd: envelope.cwd)
    addActivity(
      time: Self.timeFormatter.string(from: Date()), repo: repo,
      message: "sandbox denied \(envelope.toolName ?? "tool")"
    )
  }

  private func handleNotification(_ envelope: HookEnvelope, pid: pid_t?) {
    // These types have no accompanying decision payload — surface as
    // needs-you (matches the terminal's own prompt), but the answer
    // still has to happen there. See docs/claude-code-integration-notes.md §8.
    guard let type = envelope.notificationType,
      ["permission_prompt", "idle_prompt", "agent_needs_input"].contains(type)
    else { return }
    upsert(envelope.sessionId, cwd: envelope.cwd, pid: pid) { task in
      if task.pendingInteraction == nil {
        if type == "idle_prompt" {
          task.transition(to: .idle)
        } else {
          task.transition(to: .needsYou)
        }
      }
    }
  }

  private func handleStop(_ envelope: HookEnvelope, pid: pid_t?) {
    upsert(envelope.sessionId, cwd: envelope.cwd, pid: pid) { task in
      task.transition(to: .idle)
      task.command = nil
      task.note = nil
      task.isWarning = false
      task.toolInFlight = false
    }
  }

  private func handleSessionEnd(_ envelope: HookEnvelope, pid: pid_t?) {
    upsert(envelope.sessionId, cwd: envelope.cwd, pid: pid) { task in
      if task.status != .done { task.transition(to: .done) }
      task.command = nil
      task.note = nil
      task.isWarning = false
      task.toolInFlight = false
    }
    trimDoneTasks()
  }

  // MARK: - Decision-held events

  /// Suspends until one of three things happens: `respond(sessionId:allow:)`
  /// / `answerQuestion` is called from the UI, the underlying connection dies
  /// (terminal closed, Claude Code gave up on its own timeout), or a later
  /// event proves the prompt was answered in the terminal instead
  /// (`releaseHeldInteraction`). Every path resumes with some decision, so
  /// the continuation is never leaked.
  func handlePermissionRequest(_ envelope: HookEnvelope, context: HTTPRequestContext, pid: pid_t?)
    async -> Data
  {
    let sessionId = envelope.sessionId

    // AskUserQuestion rides the permission flow: tool_name ==
    // "AskUserQuestion" with tool_input.questions. Hold the same
    // continuation registry; answer via allow + updatedInput.answers.
    if envelope.toolName == "AskUserQuestion" {
      let questions = Self.parseQuestions(from: envelope.toolInput)
      if !questions.isEmpty, let rawQuestions = envelope.toolInput?["questions"] {
        return await holdQuestion(
          sessionId: sessionId,
          cwd: envelope.cwd,
          pid: pid,
          info: AskQuestionInfo(rawQuestions: rawQuestions, questions: questions),
          context: context
        )
      }
      // Unparseable — fall through to the normal approve/deny path.
    }

    let toolName = envelope.toolName ?? "tool"
    let command = envelope.bashCommand ?? envelope.toolInput?.displayText

    // Only one request can be held per session, and the row can only
    // show one. If an earlier one is somehow still parked, let it go
    // rather than dropping its continuation on the floor — an
    // unresumed continuation leaks, and its `curl` would hang for the
    // bridge script's full 600s timeout.
    if let stale = permissionContinuations.removeValue(forKey: sessionId) {
      stale.resume(returning: HookResponse.empty())
    }

    upsert(sessionId, cwd: envelope.cwd, pid: pid) { task in
      if let command, !command.isEmpty { task.command = "$ \(command)" }
      task.note = "Needs permission to run \(toolName)"
      task.isWarning = true
      task.toolInFlight = false
      task.pendingInteraction = .permission(
        PermissionRequestInfo(toolName: toolName, command: command))
      task.transition(to: .needsYou)
    }

    return await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
      permissionContinuations[sessionId] = continuation
      context.onCancel { [weak self] in
        Task { @MainActor in
          self?.resolvePermission(sessionId: sessionId, data: HookResponse.empty(), revive: false)
        }
      }
    }
  }

  private func holdQuestion(
    sessionId: String,
    cwd: String?,
    pid: pid_t?,
    info: AskQuestionInfo,
    context: HTTPRequestContext
  ) async -> Data {
    if let stale = permissionContinuations.removeValue(forKey: sessionId) {
      stale.resume(returning: HookResponse.empty())
    }

    upsert(sessionId, cwd: cwd, pid: pid) { task in
      task.note = "Needs your answer"
      task.command = nil
      task.isWarning = false
      task.toolInFlight = false
      task.pendingInteraction = .question(info)
      task.transition(to: .needsYou)
    }

    return await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
      permissionContinuations[sessionId] = continuation
      context.onCancel { [weak self] in
        Task { @MainActor in
          self?.resolvePermission(sessionId: sessionId, data: HookResponse.empty(), revive: false)
        }
      }
    }
  }

  func answerQuestion(sessionId: String, answers: [String: JSONValue]) {
    guard let info = tasksById[sessionId]?.pendingQuestion else { return }
    resolvePermission(
      sessionId: sessionId,
      data: HookResponse.askUserQuestionAnswer(rawQuestions: info.rawQuestions, answers: answers)
    )
  }

  /// Freeform top-level `response` instead of structured answers — Claude
  /// receives "The user responded: …".
  func replyToQuestion(sessionId: String, response: String) {
    guard let info = tasksById[sessionId]?.pendingQuestion else { return }
    resolvePermission(
      sessionId: sessionId,
      data: HookResponse.askUserQuestionResponse(
        rawQuestions: info.rawQuestions, response: response)
    )
  }

  func cancelQuestion(sessionId: String) {
    resolvePermission(
      sessionId: sessionId,
      data: HookResponse.permissionDeny(message: "Question dismissed from Notched")
    )
  }

  func respond(sessionId: String, allow: Bool) {
    let data =
      allow
      ? HookResponse.permissionAllow()
      : HookResponse.permissionDeny(message: "Denied from Notched")
    resolvePermission(sessionId: sessionId, data: data)
  }

  /// Clearing the row is deliberately *not* behind the continuation
  /// lookup: if the request was already resolved some other way, the row
  /// still has to stop asking, or Approve/Deny become dead buttons on a
  /// permanently stuck task.
  private func resolvePermission(sessionId: String, data: Data, revive: Bool = true) {
    if let continuation = permissionContinuations.removeValue(forKey: sessionId) {
      continuation.resume(returning: data)
    }
    clearInteraction(sessionId: sessionId, revive: revive)
  }

  /// Only `mode: "form"` elicitations are handled here; `mode: "url"`
  /// (browser-based auth) has nothing to render as a form, so it's left
  /// to Claude Code's own fallback by answering with an empty decision.
  /// See docs/claude-code-integration-notes.md §2.
  func handleElicitation(_ envelope: HookEnvelope, context: HTTPRequestContext, pid: pid_t?) async
    -> Data
  {
    guard envelope.mode == "form",
      let elicitationId = envelope.elicitationId,
      let schema = envelope.requestedSchema
    else {
      return HookResponse.empty()
    }
    let fields = Self.parseFields(from: schema)
    guard !fields.isEmpty else { return HookResponse.empty() }

    let sessionId = envelope.sessionId
    upsert(sessionId, cwd: envelope.cwd, pid: pid) { task in
      task.toolInFlight = false
      task.pendingInteraction = .elicitation(
        ElicitationInfo(
          elicitationId: elicitationId,
          mcpServerName: envelope.mcpServerName ?? "MCP server",
          message: envelope.message ?? "Needs input",
          fields: fields
        ))
      task.transition(to: .needsYou)
    }

    return await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
      elicitationContinuations[elicitationId] = continuation
      context.onCancel { [weak self] in
        Task { @MainActor in
          self?.resolveElicitation(
            elicitationId: elicitationId,
            sessionId: sessionId,
            data: HookResponse.empty(),
            revive: false
          )
        }
      }
    }
  }

  func answerElicitation(sessionId: String, elicitationId: String, content: [String: JSONValue]) {
    resolveElicitation(
      elicitationId: elicitationId, sessionId: sessionId,
      data: HookResponse.elicitationAccept(content: content))
  }

  func declineElicitation(sessionId: String, elicitationId: String) {
    resolveElicitation(
      elicitationId: elicitationId, sessionId: sessionId, data: HookResponse.elicitationDecline())
  }

  private func resolveElicitation(
    elicitationId: String, sessionId: String, data: Data, revive: Bool = true
  ) {
    if let continuation = elicitationContinuations.removeValue(forKey: elicitationId) {
      continuation.resume(returning: data)
    }
    clearInteraction(sessionId: sessionId, revive: revive)
  }

  /// Whatever we were holding open got answered somewhere we can't see —
  /// almost always Claude Code's own terminal prompt. Release the parked
  /// request so its `curl` isn't left hanging, and stop counting the
  /// session as needing you.
  private func releaseHeldInteraction(for sessionId: String) {
    guard let task = tasksById[sessionId] else { return }
    guard task.pendingInteraction != nil || task.status == .needsYou else { return }

    if let elicitation = task.pendingElicitation {
      resolveElicitation(
        elicitationId: elicitation.elicitationId, sessionId: sessionId, data: HookResponse.empty())
    } else {
      resolvePermission(sessionId: sessionId, data: HookResponse.empty())
    }
  }

  /// Never revives a task that already finished, and never creates one:
  /// a resolution arriving after `Stop`/`SessionEnd` (or after
  /// `trimDoneTasks`) must not put a row back on the dashboard.
  private func clearInteraction(sessionId: String, revive: Bool) {
    guard tasksById[sessionId] != nil else { return }
    upsert(sessionId, cwd: nil) { task in
      task.pendingInteraction = nil
      task.isWarning = false
      task.command = nil
      task.note = nil
      if task.status == .needsYou {
        task.transition(to: revive ? .running : .idle)
      }
      if !revive {
        task.toolInFlight = false
      }
    }
  }

  private static func parseFields(from schema: JSONValue) -> [ElicitationField] {
    guard let properties = schema["properties"]?.objectValue else { return [] }
    // JSON object key order isn't preserved through our JSONValue decode;
    // sort for a stable render order rather than an arbitrary one.
    return properties.keys.sorted().compactMap { name in
      guard let definition = properties[name] else { return nil }
      let title = definition["title"]?.stringValue ?? name
      let type = definition["type"]?.stringValue

      if let options = definition["enum"]?.arrayValue?.compactMap(\.stringValue), !options.isEmpty {
        return ElicitationField(name: name, title: title, kind: .radio(options: options))
      }
      if type == "array",
        let options = definition["items"]?["enum"]?.arrayValue?.compactMap(\.stringValue)
      {
        return ElicitationField(name: name, title: title, kind: .multiSelect(options: options))
      }
      switch type {
      case "boolean": return ElicitationField(name: name, title: title, kind: .boolean)
      case "number", "integer": return ElicitationField(name: name, title: title, kind: .number)
      default: return ElicitationField(name: name, title: title, kind: .text)
      }
    }
  }

  private static func parseQuestions(from toolInput: JSONValue?) -> [AskQuestion] {
    guard let items = toolInput?["questions"]?.arrayValue else { return [] }
    return items.compactMap { item in
      guard let question = item["question"]?.stringValue,
        let optionValues = item["options"]?.arrayValue
      else { return nil }
      let options: [AskOption] = optionValues.compactMap { opt in
        guard let label = opt["label"]?.stringValue else { return nil }
        return AskOption(
          label: label,
          description: opt["description"]?.stringValue ?? "",
          preview: opt["preview"]?.stringValue
        )
      }
      guard !options.isEmpty else { return nil }
      return AskQuestion(
        question: question,
        header: item["header"]?.stringValue ?? String(question.prefix(12)),
        options: options,
        multiSelect: item["multiSelect"]?.boolValue ?? false
      )
    }
  }

  // MARK: - Storage helpers

  private func upsert(
    _ sessionId: String, cwd: String?, pid: pid_t? = nil, _ mutate: (inout AgentTask) -> Void
  ) {
    var task =
      tasksById[sessionId]
      ?? AgentTask(
        id: sessionId,
        status: .running,
        title: "Claude Code session",
        repo: repoName(fromCwd: cwd),
        branch: cwd.flatMap { GitBranchReader.branch(atRepoPath: $0) } ?? "—",
        model: "—",
        terminal: "—",
        startedAt: Date()
      )
    if let pid {
      task.pid = pid
    }
    mutate(&task)
    task.lastEventAt = Date()
    tasksById[sessionId] = task
    if !order.contains(sessionId) { order.insert(sessionId, at: 0) }
    rebuildTasksArray()
  }

  private func repoName(fromCwd cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return "—" }
    return (cwd as NSString).lastPathComponent
  }

  private func addActivity(time: String, repo: String, message: String) {
    activity.insert(ActivityEntry(time: time, repo: repo, message: message), at: 0)
    if activity.count > 20 { activity.removeLast(activity.count - 20) }
  }

  private func rebuildTasksArray() {
    tasks = order.compactMap { tasksById[$0] }.sorted { rank($0) < rank($1) }
    announceNeedsYou()
  }

  /// The only non-visual signal that the agent is blocked on you. Without it
  /// the sole cue is a glyph in a 32pt strip at the top of one screen, which
  /// you miss entirely if you're looking anywhere else.
  private func announceNeedsYou() {
    let waiting = Set(tasks.filter { $0.status == .needsYou }.map(\.id))
    // Ring for arrivals only, and once per batch however many arrive at once.
    let arrived = waiting.subtracting(chimedSessions)
    chimedSessions = waiting
    guard !arrived.isEmpty, Self.soundEnabled else { return }
    NSSound(named: Self.needsYouSoundName)?.play()
  }

  /// ponytail: a UserDefaults read, not a settings pane. Flip it with
  /// `defaults write com.swarajsaxena.notched NotchedSoundEnabled -bool false`
  /// until there's a preferences window to host it.
  private static var soundEnabled: Bool {
    UserDefaults.standard.object(forKey: "NotchedSoundEnabled") as? Bool ?? true
  }

  private static let needsYouSoundName = "Tink"  

  private func rank(_ task: AgentTask) -> Int {
    switch task.status {
    case .needsYou: return 0
    case .running: return 1
    case .idle: return 2
    case .done: return 3
    }
  }

  private func processAlive(_ pid: pid_t) -> Bool {
    if kill(pid, 0) == 0 {
      return true
    }
    return errno == EPERM
  }

  private func reapStaleTasks() {
    let now = Date()
    var didMutate = false

    for id in order {
      guard var task = tasksById[id], task.status != .done else { continue }

      if let pid = task.pid, !processAlive(pid) {
        task.transition(to: .done)
        task.pendingInteraction = nil
        task.command = nil
        task.note = nil
        task.isWarning = false
        task.toolInFlight = false
        tasksById[id] = task
        didMutate = true
        continue
      }

      guard task.status == .running else { continue }
      let gap = now.timeIntervalSince(task.lastEventAt)
      let overIdle = !task.toolInFlight && gap > Self.idleTimeout
      let overCap = gap > Self.inFlightCap
      guard overIdle || overCap else { continue }

      task.transition(to: .idle)
      task.command = nil
      task.note = nil
      task.toolInFlight = false
      tasksById[id] = task
      didMutate = true
    }

    guard didMutate else { return }
    trimDoneTasks()
    rebuildTasksArray()
  }

  /// Keeps memory/UI bounded across a long-running app session — old
  /// finished sessions don't need to stay visible forever.
  private func trimDoneTasks(keepingMax: Int = 20) {
    let doneIds = order.filter { tasksById[$0]?.status == .done }
    guard doneIds.count > keepingMax else { return }
    for id in doneIds.suffix(from: keepingMax) {
      tasksById.removeValue(forKey: id)
      order.removeAll { $0 == id }
    }
    rebuildTasksArray()
  }
}
