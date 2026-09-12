import Foundation

/// The Claude Code hook events we install and understand. `hook_event_name`
/// in every payload matches one of these. The terminal name (which has no
/// field of its own in any payload) rides along separately as an
/// `X-Handoff-Terminal` HTTP header the bridge script adds to every
/// request — see `HookServer` and docs/claude-code-integration-notes.md §3.
enum HookEventName: String, Decodable {
  case sessionStart = "SessionStart"
  case userPromptSubmit = "UserPromptSubmit"
  case preToolUse = "PreToolUse"
  case postToolUse = "PostToolUse"
  case permissionRequest = "PermissionRequest"
  case permissionDenied = "PermissionDenied"
  case notification = "Notification"
  case stop = "Stop"
  case sessionEnd = "SessionEnd"
  case elicitation = "Elicitation"

  /// True for the events Claude Code can only emit once a decision we were
  /// holding open has already been made — usually in its own terminal
  /// prompt, which runs in parallel with our hook and can win. Nothing in
  /// the protocol announces that directly, so `SessionStore` treats these
  /// as the signal. Deliberately excludes `PreToolUse` (each hook is its
  /// own connection, so it can land *after* the `PermissionRequest` for the
  /// same call) and `Notification` (`permission_prompt` fires alongside a
  /// live request, not after it).
  var provesInteractionResolved: Bool {
    switch self {
    case .postToolUse, .permissionDenied, .userPromptSubmit, .stop, .sessionEnd:
      return true
    case .sessionStart, .preToolUse, .permissionRequest, .notification, .elicitation:
      return false
    }
  }
}

/// Every field we read across every hook event, flattened into one struct.
/// Verified field names against `code.claude.com/docs/en/hooks.md` (fetched
/// 2026-07-29) — see docs/claude-code-integration-notes.md for citations.
/// Unknown/unused fields are simply absent from this struct; `JSONDecoder`
/// ignores keys it isn't told about.
struct HookEnvelope: Decodable {
  let sessionId: String
  let cwd: String?
  let hookEventNameRaw: String
  let permissionMode: String?

  // PreToolUse / PostToolUse / PermissionRequest / PermissionDenied
  let toolName: String?
  let toolInput: JSONValue?
  let toolResponse: JSONValue?

  // Notification
  let message: String?
  let notificationType: String?

  // SessionStart
  let source: String?
  let model: String?

  // UserPromptSubmit
  let prompt: String?

  // SessionEnd / PermissionDenied
  let reason: String?

  // Stop
  let lastAssistantMessage: String?

  // Elicitation (form mode only — see docs/claude-code-integration-notes.md §2)
  let mcpServerName: String?
  let requestedSchema: JSONValue?
  let mode: String?
  let elicitationId: String?

  var hookEventName: HookEventName? { HookEventName(rawValue: hookEventNameRaw) }

  enum CodingKeys: String, CodingKey {
    case sessionId = "session_id"
    case cwd
    case hookEventNameRaw = "hook_event_name"
    case permissionMode = "permission_mode"
    case toolName = "tool_name"
    case toolInput = "tool_input"
    case toolResponse = "tool_response"
    case message
    case notificationType = "notification_type"
    case source
    case model
    case prompt
    case reason
    case lastAssistantMessage = "last_assistant_message"
    case mcpServerName = "mcp_server_name"
    case requestedSchema = "requested_schema"
    case mode
    case elicitationId = "elicitation_id"
  }
}

/// The `command` under Bash's `tool_input`, when present — the common case
/// we render as a note/command line in the dashboard.
extension HookEnvelope {
  var bashCommand: String? { toolInput?["command"]?.stringValue }
}

/// Builds the exact `hookSpecificOutput` JSON bodies Claude Code expects
/// back from `PermissionRequest` and `Elicitation` command hooks. Every
/// shape here is copied verbatim from the verified docs, not inferred.
enum HookResponse {
  /// A hook that answers nothing (pure-observation events like
  /// `PostToolUse`, `Notification`, `Stop`). Claude Code treats an empty
  /// JSON object as "no decision" for every event that supports one.
  static func empty() -> Data { Data("{}".utf8) }

  static func permissionAllow() -> Data {
    encode([
      "hookSpecificOutput": [
        "hookEventName": "PermissionRequest",
        "decision": ["behavior": "allow"],
      ]
    ])
  }

  static func permissionDeny(message: String) -> Data {
    encode([
      "hookSpecificOutput": [
        "hookEventName": "PermissionRequest",
        "decision": ["behavior": "deny", "message": message],
      ]
    ])
  }

  static func elicitationAccept(content: [String: JSONValue]) -> Data {
    encode([
      "hookSpecificOutput": [
        "hookEventName": "Elicitation",
        "action": "accept",
        "content": content.mapValues(jsonEncodableValue),
      ]
    ])
  }

  static func elicitationDecline() -> Data {
    encode([
      "hookSpecificOutput": [
        "hookEventName": "Elicitation",
        "action": "decline",
      ]
    ])
  }

  /// Allow a `PermissionRequest` for `AskUserQuestion`, echoing the
  /// original `questions` array and supplying the user's `answers`
  /// (keys = question text, values = selected label / comma-joined labels /
  /// free-text). See docs for `AskUserQuestion` + PermissionRequest
  /// `updatedInput`.
  static func askUserQuestionAnswer(rawQuestions: JSONValue, answers: [String: JSONValue])
    -> Data
  {
    encode([
      "hookSpecificOutput": [
        "hookEventName": "PermissionRequest",
        "decision": [
          "behavior": "allow",
          "updatedInput": [
            "questions": jsonEncodableValue(rawQuestions),
            "answers": answers.mapValues(jsonEncodableValue),
          ],
        ],
      ]
    ])
  }

  /// Allow with a top-level freeform `response` instead of structured
  /// `answers` — Claude receives "The user responded: …".
  static func askUserQuestionResponse(rawQuestions: JSONValue, response: String) -> Data {
    encode([
      "hookSpecificOutput": [
        "hookEventName": "PermissionRequest",
        "decision": [
          "behavior": "allow",
          "updatedInput": [
            "questions": jsonEncodableValue(rawQuestions),
            "response": response,
          ],
        ],
      ]
    ])
  }

  private static func jsonEncodableValue(_ value: JSONValue) -> Any {
    switch value {
    case .string(let s): return s
    case .number(let n): return n
    case .bool(let b): return b
    case .null: return NSNull()
    case .array(let a): return a.map(jsonEncodableValue)
    case .object(let o): return o.mapValues(jsonEncodableValue)
    }
  }

  private static func encode(_ object: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
  }
}
