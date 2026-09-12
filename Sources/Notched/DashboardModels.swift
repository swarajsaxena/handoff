import Darwin
import SwiftUI

enum TaskStatus {
  case needsYou, running, idle, done

  var color: Color {
    switch self {
    case .needsYou: return Theme.statusNeedsYou
    case .running: return Theme.statusRunning
    case .idle: return Theme.statusDone
    case .done: return Theme.statusDone
    }
  }

  var label: String {
    switch self {
    case .needsYou: return "needs you"
    case .running: return "running"
    case .idle: return "idle"
    case .done: return "done"
    }
  }

  var labelColor: Color {
    switch self {
    case .needsYou, .running: return Theme.textSecondary
    case .idle, .done: return Theme.textDim
    }
  }
}

/// A pending, user-answerable interaction surfaced by a Claude Code hook.
/// At most one is active per session — see `SessionStore`.
enum PendingInteraction {
  case permission(PermissionRequestInfo)
  case elicitation(ElicitationInfo)
  case question(AskQuestionInfo)
}

struct PermissionRequestInfo {
  let toolName: String
  let command: String?
}

struct ElicitationInfo {
  let elicitationId: String
  let mcpServerName: String
  let message: String
  let fields: [ElicitationField]
}

/// Parsed `AskUserQuestion` tool input held while the notch questionnaire
/// is open. `rawQuestions` is the verbatim `questions` array from
/// `tool_input` and must be echoed back in `updatedInput.questions`.
struct AskQuestionInfo {
  let rawQuestions: JSONValue
  let questions: [AskQuestion]
}

struct AskQuestion: Identifiable {
  var id: String { header + "|" + question }
  let question: String
  let header: String
  let options: [AskOption]
  let multiSelect: Bool
}

struct AskOption: Identifiable {
  var id: String { label }
  let label: String
  let description: String
  let preview: String?
}

/// One field of a `requested_schema` form, reduced to what `QuestionView`
/// needs to render it. See docs/claude-code-integration-notes.md §2 for the
/// verified schema this is parsed from.
struct ElicitationField: Identifiable {
  enum Kind {
    case text
    case number
    case boolean
    case radio(options: [String])
    case multiSelect(options: [String])
  }

  var id: String { name }
  let name: String
  let title: String
  let kind: Kind
}

struct AgentTask: Identifiable {
  /// Claude Code's `session_id`. Using it (rather than a fresh `UUID()`
  /// per event) is what lets repeated hook updates mutate one stable row
  /// instead of the list reshuffling on every event.
  let id: String
  var status: TaskStatus
  var title: String
  var repo: String
  var branch: String
  var model: String
  var terminal: String
  var note: String? = nil
  var command: String? = nil
  /// Shown in orange as a sandbox/permission warning.
  var isWarning: Bool = false
  var startedAt: Date = Date()
  var lastEventAt: Date = Date()
  var pid: pid_t? = nil
  var toolInFlight: Bool = false
  /// When this task most recently entered `.needsYou`, cleared the moment
  /// it leaves that state. Drives the header's "WAITING ON YOU" timer.
  var needsYouSince: Date? = nil
  var pendingInteraction: PendingInteraction? = nil

  var needsApproval: Bool {
    if case .permission = pendingInteraction { return true }
    return false
  }

  var pendingElicitation: ElicitationInfo? {
    if case .elicitation(let info) = pendingInteraction { return info }
    return nil
  }

  var pendingQuestion: AskQuestionInfo? {
    if case .question(let info) = pendingInteraction { return info }
    return nil
  }

  mutating func transition(to newStatus: TaskStatus) {
    needsYouSince = (newStatus == .needsYou) ? (needsYouSince ?? Date()) : nil
    status = newStatus
  }

  func elapsedText(now: Date) -> String {
    Self.durationText(now.timeIntervalSince(startedAt))
  }

  static func durationText(_ interval: TimeInterval) -> String {
    let seconds = max(0, Int(interval))
    if seconds < 60 { return "\(seconds)s" }
    let minutes = seconds / 60
    if minutes < 60 { return "\(minutes)m" }
    return "\(minutes / 60)h\(minutes % 60)m"
  }
}

/// A past Claude Code session read from ~/.claude/projects on disk.
/// Shown in the "Recent Sessions" section when the panel is open.
struct PastSession: Identifiable {
  let id: String  // Claude Code session_id (= jsonl filename without extension)
  let title: String
  let cwd: String
  let repo: String  // last path component of cwd
  let branch: String?  // from ai-title / gitBranch field in jsonl, optional
  let lastActive: Date  // jsonl file mtime
}

struct ActivityEntry: Identifiable {
  let id = UUID()
  let time: String
  let repo: String
  let message: String
}

/// Static sample data mirroring the mockup, used only by `#Preview`s now
/// that `DashboardView` reads live data from `SessionStore`.
enum SampleData {
  static let tasks: [AgentTask] = [
    AgentTask(
      id: "preview-1", status: .needsYou,
      title: "Compile the release binary",
      repo: "api-server", branch: "feat/search", model: "GPT-5.5", terminal: "Ghostty",
      note: "Outside sandbox: needs network to fetch crates",
      command: "$ cargo build --release --target aarch64-apple-darwin",
      isWarning: true,
      startedAt: Date().addingTimeInterval(-60),
      pendingInteraction: .permission(
        PermissionRequestInfo(toolName: "Bash", command: "cargo build --release"))
    ),
    AgentTask(
      id: "preview-2", status: .running,
      title: "Build the production bundle",
      repo: "web-app", branch: "feat/onboarding", model: "Opus 5", terminal: "Cursor",
      command: "$ npm run build",
      startedAt: Date().addingTimeInterval(-60)
    ),
    AgentTask(
      id: "preview-3", status: .done,
      title: "Reconcile Q3 invoices",
      repo: "payments", branch: "fix/webhook-retry", model: "Composer 1", terminal: "Warp",
      startedAt: Date().addingTimeInterval(-60)
    ),
    AgentTask(
      id: "preview-4", status: .done,
      title: "Wire Stripe webhook retries",
      repo: "checkout-api", branch: "feat/stripe", model: "Opus 5", terminal: "iTerm2",
      startedAt: Date().addingTimeInterval(-60)
    ),
    AgentTask(
      id: "preview-5", status: .done,
      title: "Generate token exports",
      repo: "design-system", branch: "feat/tokens", model: "Opus 5", terminal: "Ghostty",
      startedAt: Date().addingTimeInterval(-60)
    ),
    AgentTask(
      id: "preview-6", status: .done,
      title: "Provision staging cluster",
      repo: "infra", branch: "main", model: "K3", terminal: "Ghostty",
      startedAt: Date().addingTimeInterval(-60)
    ),
  ]

  static let activity: [ActivityEntry] = [
    ActivityEntry(time: "09:22", repo: "checkout-api", message: "ran npm test — 42"),
    ActivityEntry(time: "09:22", repo: "design-system", message: "tokens/color.ts +38"),
    ActivityEntry(time: "09:21", repo: "payments", message: "opened PR #218 — reconcile"),
    ActivityEntry(time: "09:21", repo: "checkout-api", message: "sandbox denied network"),
    ActivityEntry(time: "09:21", repo: "api-server", message: "sandbox denied network"),
  ]
}
