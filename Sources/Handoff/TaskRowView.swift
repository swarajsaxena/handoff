import SwiftUI

/// Which approval button the keyboard is on. Deny is always the default:
/// approving runs a command, so Enter must never be the approving key.
enum ApprovalAction {
  case deny
  case approve
}

struct TaskRowView: View {
  let task: AgentTask
  let now: Date
  /// Non-nil only when this row is the one the keyboard is on.
  var approvalFocus: ApprovalAction? = nil
  @EnvironmentObject private var store: SessionStore

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        StatusDot(color: task.status.color)
          .padding(.top, 3)

        VStack(alignment: .leading, spacing: 3) {
          Text(task.title)
            .font(Theme.Text.title)
            .foregroundStyle(Theme.textPrimary)

          Text("\(task.repo) · \(task.branch) · \(task.model) · \(task.terminal)")
            .font(Theme.Text.body)
            .foregroundStyle(Theme.textSecondary)

          if let note = task.note {
            Text(note)
              .font(Theme.Text.body)
              .foregroundStyle(task.isWarning ? Theme.warning : Theme.textSecondary)
          }
          if let command = task.command {
            // No lineLimit: truncating this hides the tail of the very thing
            // you're being asked to authorise.
            Text(command)
              .font(Theme.Text.body)
              .foregroundStyle(Theme.command)
              .textSelection(.enabled)
          }
        }

        Spacer(minLength: 8)

        if task.needsApproval {
          ApprovalButtons(
            focus: approvalFocus,
            onApprove: { store.respond(sessionId: task.id, allow: true) },
            onDeny: { store.respond(sessionId: task.id, allow: false) }
          )
          .padding(.top, 2)
        }

        VStack(alignment: .trailing, spacing: 2) {
          Text(task.status.label)
            .font(Theme.Text.meta)
            .foregroundStyle(task.status.labelColor)
          Text(task.elapsedText(now: now))
            .font(Theme.Text.meta)
            .foregroundStyle(Theme.textDim)
        }
        .frame(width: 52, alignment: .trailing)
      }

      if let elicitation = task.pendingElicitation {
        QuestionView(sessionId: task.id, info: elicitation)
          .padding(.leading, 16)
      }
    }
    .padding(.vertical, 8)
    .padding(.horizontal, 4)
  }
}

private struct StatusDot: View {
  let color: Color
  var body: some View {
    Circle()
      .fill(color)
      .frame(width: 6, height: 6)
      .shadow(color: color.opacity(0.7), radius: 3)
  }
}

private struct ApprovalButtons: View {
  let focus: ApprovalAction?
  let onApprove: () -> Void
  let onDeny: () -> Void

  /// .buttonStyle(.plain) suppresses AppKit's own focus ring, so the focused
  /// control has to draw its own or keyboard users fly blind.
  private func focusRing(_ action: ApprovalAction) -> some View {
    RoundedRectangle(cornerRadius: 6)
      .stroke(focus == action ? Theme.accent : Color.clear, lineWidth: 2)
  }

  var body: some View {
    HStack(spacing: 10) {
      Button(action: onDeny) {
        Text("Deny")
          .font(Theme.mono(11, .medium))
          .foregroundStyle(Theme.textPrimary)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(Theme.surfaceRaised)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(Theme.textDim, lineWidth: 1)
          )
      }
      .buttonStyle(.plain)
      .overlay(focusRing(.deny))
      .accessibilityLabel("Deny permission request")
      .accessibilityAddTraits(.isButton)

      Button(action: onApprove) {
        Text("Approve")
          .font(Theme.mono(11, .medium))
          .foregroundStyle(Theme.accent)
          .padding(.horizontal, 12)
          .padding(.vertical, 6)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(Theme.surfaceRaised)
          )
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
          )
      }
      .buttonStyle(.plain)
      .overlay(focusRing(.approve))
      .accessibilityLabel("Approve permission request")
      .accessibilityAddTraits(.isButton)
    }
  }
}
