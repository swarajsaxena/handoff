import SwiftUI

/// Renders one `Elicitation` form (`mode: "form"` only — see
/// docs/claude-code-integration-notes.md §2) inline under a `TaskRowView`,
/// and reports the answer back through `SessionStore`.
struct QuestionView: View {
  let sessionId: String
  let info: ElicitationInfo
  @EnvironmentObject private var store: SessionStore

  @State private var textValues: [String: String] = [:]
  @State private var boolValues: [String: Bool] = [:]
  @State private var radioValues: [String: String] = [:]
  @State private var multiSelectValues: [String: Set<String>] = [:]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(info.message)
        .font(Theme.Text.body)
        .foregroundStyle(Theme.textPrimary)

      Text(info.mcpServerName)
        .font(Theme.Text.meta)
        .foregroundStyle(Theme.textDim)

      ForEach(info.fields) { field in
        fieldView(field)
      }

      HStack(spacing: 6) {
        Button("Cancel", role: .cancel) {
          store.declineElicitation(sessionId: sessionId, elicitationId: info.elicitationId)
        }
        .buttonStyle(NotchSecondaryButtonStyle())
        .accessibilityLabel("Cancel this request")
        .accessibilityAddTraits(.isButton)

        Button("Submit") {
          store.answerElicitation(
            sessionId: sessionId, elicitationId: info.elicitationId, content: buildContent())
        }
        .buttonStyle(NotchPrimaryButtonStyle())
        .accessibilityLabel("Submit this form")
        .accessibilityAddTraits(.isButton)
      }
    }
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Theme.surfaceRaised)
    )
  }

  @ViewBuilder
  private func fieldView(_ field: ElicitationField) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(field.title)
        .font(Theme.Text.meta)
        .foregroundStyle(Theme.textSecondary)

      switch field.kind {
      case .text, .number:
        TextField("", text: textBinding(for: field.name))
          .textFieldStyle(.plain)
          .font(Theme.mono(11))
          .foregroundStyle(Theme.textPrimary)
          .padding(6)
          .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface))
          .accessibilityLabel(field.title)

      case .boolean:
        Toggle(isOn: boolBinding(for: field.name)) {
          EmptyView()
        }
        .toggleStyle(.switch)
        .labelsHidden()
        .accessibilityLabel(field.title)

      case .radio(let options):
        VStack(alignment: .leading, spacing: 4) {
          ForEach(options, id: \.self) { option in
            radioRow(option, field: field)
          }
        }

      case .multiSelect(let options):
        VStack(alignment: .leading, spacing: 4) {
          ForEach(options, id: \.self) { option in
            checkboxRow(option, field: field)
          }
        }
      }
    }
  }

  private func radioRow(_ option: String, field: ElicitationField) -> some View {
    let isSelected = radioValues[field.name] == option
    return Button {
      radioValues[field.name] = option
    } label: {
      HStack(spacing: 6) {
        Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(isSelected ? Theme.accent : Theme.textDim)
        Text(option)
          .font(Theme.Text.body)
          .foregroundStyle(Theme.textPrimary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private func checkboxRow(_ option: String, field: ElicitationField) -> some View {
    let isSelected = multiSelectValues[field.name]?.contains(option) ?? false
    return Button {
      var current = multiSelectValues[field.name] ?? []
      if isSelected { current.remove(option) } else { current.insert(option) }
      multiSelectValues[field.name] = current
    } label: {
      HStack(spacing: 6) {
        Image(systemName: isSelected ? "checkmark.square.fill" : "square")
          .foregroundStyle(isSelected ? Theme.accent : Theme.textDim)
        Text(option)
          .font(Theme.Text.body)
          .foregroundStyle(Theme.textPrimary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private func textBinding(for name: String) -> Binding<String> {
    Binding(
      get: { textValues[name] ?? "" },
      set: { textValues[name] = $0 }
    )
  }

  private func boolBinding(for name: String) -> Binding<Bool> {
    Binding(
      get: { boolValues[name] ?? false },
      set: { boolValues[name] = $0 }
    )
  }

  private func buildContent() -> [String: JSONValue] {
    var content: [String: JSONValue] = [:]
    for field in info.fields {
      switch field.kind {
      case .text:
        content[field.name] = .string(textValues[field.name] ?? "")
      case .number:
        content[field.name] = .number(Double(textValues[field.name] ?? "") ?? 0)
      case .boolean:
        content[field.name] = .bool(boolValues[field.name] ?? false)
      case .radio:
        if let value = radioValues[field.name] { content[field.name] = .string(value) }
      case .multiSelect:
        let values = multiSelectValues[field.name] ?? []
        content[field.name] = .array(values.map(JSONValue.string))
      }
    }
    return content
  }
}

struct NotchPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.mono(11, .semibold))
      .foregroundStyle(.black)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(Theme.textPrimary.opacity(configuration.isPressed ? 0.7 : 1))
      )
  }
}

struct NotchSecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(Theme.mono(11, .medium))
      .foregroundStyle(Theme.textSecondary)
      .padding(.horizontal, 10)
      .padding(.vertical, 5)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .stroke(Theme.divider, lineWidth: 1)
          .opacity(configuration.isPressed ? 0.5 : 1)
      )
  }
}
