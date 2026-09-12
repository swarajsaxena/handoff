import SwiftUI

struct TaskRowView: View {
  let task: AgentTask
  let now: Date
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
            Text(command)
              .font(Theme.Text.body)
              .foregroundStyle(Theme.command)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 8)

        if task.needsApproval {
          ApprovalButtons(
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
  let onApprove: () -> Void
  let onDeny: () -> Void

  var body: some View {
    HStack(spacing: 6) {
      Button(action: onDeny) {
        Text("Deny")
          .font(Theme.mono(11, .medium))
          .foregroundStyle(Theme.textSecondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .stroke(Theme.divider, lineWidth: 1)
          )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Deny permission request")
      .accessibilityAddTraits(.isButton)

      Button(action: onApprove) {
        Text("Approve")
          .font(Theme.mono(11, .semibold))
          .foregroundStyle(.black)
          .padding(.horizontal, 10)
          .padding(.vertical, 5)
          .background(
            RoundedRectangle(cornerRadius: 6)
              .fill(Theme.textPrimary)
          )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Approve permission request")
      .accessibilityAddTraits(.isButton)
    }
  }
}
