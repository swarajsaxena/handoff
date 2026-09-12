import AppKit
import SwiftUI

/// Full-panel takeover for a pending `AskUserQuestion` call. One question
/// at a time with a stepper, keyboard-first navigation, and structured
/// answers returned through `SessionStore.answerQuestion`.
struct QuestionFlowView: View {
  let sessionId: String
  let info: AskQuestionInfo
  @EnvironmentObject private var store: SessionStore

  @State private var currentStep = 0
  @State private var singleSelection: [String: String] = [:]
  @State private var multiSelection: [String: Set<String>] = [:]
  @State private var otherText: [String: String] = [:]
  @State private var highlighted = 0
  @State private var validationError: [String: String] = [:]
  @State private var isSubmitting = false
  @State private var showCancelConfirm = false
  @State private var flashSelectedID: String?
  @StateObject private var keyMonitor = QuestionKeyMonitor()
  @FocusState private var otherFieldFocused: Bool

  private static let otherSentinel = "\u{0}__other__"
  private var submitStepIndex: Int { info.questions.count }
  private var isOnSubmitStep: Bool { currentStep >= submitStepIndex }

  var body: some View {
    ZStack {
      VStack(alignment: .leading, spacing: 10) {
        stepperHeader
        Divider().background(Theme.divider)

        if isOnSubmitStep {
          submitStepBody
        } else {
          questionBody(info.questions[currentStep])
        }

        Spacer(minLength: 0)

        footerHints
      }
      .padding(Theme.panelPadding)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .opacity(isSubmitting || showCancelConfirm ? 0.45 : 1)
      .allowsHitTesting(!isSubmitting && !showCancelConfirm)

      if isSubmitting {
        loadingOverlay
      }

      if showCancelConfirm {
        cancelConfirmOverlay
      }
    }
    .onAppear {
      highlighted = 0
      keyMonitor.onKeyDown = { event in self.handleKey(event) }
      keyMonitor.start()
    }
    .onChange(of: currentStep) { _ in
      keyMonitor.onKeyDown = { event in self.handleKey(event) }
    }
    .onChange(of: highlighted) { _ in
      syncOtherFocus()
      keyMonitor.onKeyDown = { event in self.handleKey(event) }
    }
    .onChange(of: otherFieldFocused) { _ in
      keyMonitor.onKeyDown = { event in self.handleKey(event) }
    }
    .onChange(of: showCancelConfirm) { _ in
      keyMonitor.onKeyDown = { event in self.handleKey(event) }
    }
    .onChange(of: isSubmitting) { _ in
      keyMonitor.onKeyDown = { event in self.handleKey(event) }
    }
    .onDisappear {
      keyMonitor.stop()
    }
  }

  // MARK: - Stepper

  private var stepperHeader: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 6) {
        ForEach(Array(info.questions.enumerated()), id: \.element.id) { index, question in
          stepChip(
            title: question.header,
            index: index,
            completed: isAnswered(question),
            isSubmit: false
          )
        }
        stepChip(title: "Submit", index: submitStepIndex, completed: false, isSubmit: true)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Question steps")
  }

  private func stepChip(title: String, index: Int, completed: Bool, isSubmit: Bool) -> some View {
    let isActive = currentStep == index
    return Button {
      goToStep(index)
    } label: {
      HStack(spacing: 4) {
        if completed && !isSubmit {
          Image(systemName: "checkmark")
            .font(.system(size: 8, weight: .bold))
        } else if isSubmit {
          Image(systemName: "checkmark.circle")
            .font(.system(size: 8, weight: .semibold))
        } else {
          Image(systemName: "square")
            .font(.system(size: 8, weight: .regular))
        }
        Text(title)
          .font(Theme.Text.meta)
          .lineLimit(1)
      }
      .foregroundStyle(isActive ? Theme.accent : (completed ? Theme.statusDone : Theme.textDim))
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 5)
          .fill(isActive ? Theme.accent.opacity(0.14) : Color.clear)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5)
          .stroke(isActive ? Theme.accent.opacity(0.5) : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      "Step \(index + 1) of \(info.questions.count + 1), \(title)"
        + (isActive ? ", current" : "")
        + (completed ? ", completed" : "")
    )
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
  }

  // MARK: - Question body

  private func questionBody(_ question: AskQuestion) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(LocalizedStringKey(question.question))
        .font(Theme.Text.title)
        .foregroundStyle(Theme.accent)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)

      if let error = validationError[question.id] {
        Text(error)
          .font(Theme.Text.meta)
          .foregroundStyle(Theme.warning)
      }

      VStack(alignment: .leading, spacing: 4) {
        ForEach(Array(question.options.enumerated()), id: \.element.id) { index, option in
          optionRow(question: question, option: option, index: index)
        }
        otherRow(question: question, index: question.options.count)
      }
    }
  }

  private func optionRow(question: AskQuestion, option: AskOption, index: Int) -> some View {
    let isHighlighted = highlighted == index
    let isSelected = isOptionSelected(question, label: option.label)
    let isFlashing = flashSelectedID == option.id

    return Button {
      selectOption(question, label: option.label, advance: !question.multiSelect)
    } label: {
      HStack(alignment: .top, spacing: 8) {
        Image(
          systemName: question.multiSelect
            ? (isSelected ? "checkmark.square.fill" : "square")
            : (isSelected ? "largecircle.fill.circle" : "circle")
        )
        .foregroundStyle(isSelected || isFlashing ? Theme.accent : Theme.textDim)
        .frame(width: 14)

        VStack(alignment: .leading, spacing: 2) {
          Text("\(index + 1). \(option.label)")
            .font(Theme.Text.body)
            .foregroundStyle(Theme.textPrimary)
          if !option.description.isEmpty {
            Text(LocalizedStringKey(option.description))
              .font(Theme.Text.meta)
              .foregroundStyle(Theme.textSecondary)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 6)
          .fill(
            isFlashing
              ? Theme.statusDone.opacity(0.18)
              : (isHighlighted ? Theme.accent.opacity(0.10) : Color.clear)
          )
      )
      .overlay(
        RoundedRectangle(cornerRadius: 6)
          .stroke(
            isHighlighted ? Theme.accent.opacity(0.7) : Color.clear,
            lineWidth: 1
          )
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(option.label)
    .accessibilityValue(option.description)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private func otherRow(question: AskQuestion, index: Int) -> some View {
    let isHighlighted = highlighted == index
    let isSelected = isOtherSelected(question)
    let otherBinding = Binding(
      get: { otherText[question.id] ?? "" },
      set: { otherText[question.id] = $0 }
    )

    return VStack(alignment: .leading, spacing: 6) {
      Button {
        selectOther(question)
      } label: {
        HStack(spacing: 8) {
          Image(
            systemName: question.multiSelect
              ? (isSelected ? "checkmark.square.fill" : "square")
              : (isSelected ? "largecircle.fill.circle" : "circle")
          )
          .foregroundStyle(isSelected ? Theme.accent : Theme.textDim)
          .frame(width: 14)

          Text("\(index + 1). Type something.")
            .font(Theme.Text.body)
            .foregroundStyle(Theme.textPrimary)
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
          RoundedRectangle(cornerRadius: 6)
            .fill(isHighlighted ? Theme.accent.opacity(0.10) : Color.clear)
        )
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .stroke(isHighlighted ? Theme.accent.opacity(0.7) : Color.clear, lineWidth: 1)
        )
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Type something")
      .accessibilityAddTraits(isSelected ? [.isSelected] : [])

      if isSelected || isHighlighted {
        TextField("Type your answer", text: otherBinding, axis: .vertical)
          .textFieldStyle(.plain)
          .font(Theme.mono(11))
          .foregroundStyle(Theme.textPrimary)
          .lineLimit(1...4)
          .padding(8)
          .background(RoundedRectangle(cornerRadius: 5).fill(Theme.surface))
          .focused($otherFieldFocused)
          .onChange(of: otherText[question.id] ?? "") { _ in
            if !question.multiSelect {
              singleSelection[question.id] = Self.otherSentinel
            }
            validationError[question.id] = nil
          }
          .accessibilityLabel("Custom answer for \(question.header)")

        let count = (otherText[question.id] ?? "").count
        if count > 0 {
          Text("\(count) characters")
            .font(Theme.Text.meta)
            .foregroundStyle(Theme.textDim)
            .padding(.leading, 8)
        }
      }
    }
  }

  // MARK: - Submit step

  private var submitStepBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Ready to submit?")
        .font(Theme.Text.title)
        .foregroundStyle(Theme.accent)

      ForEach(info.questions) { question in
        HStack(alignment: .top, spacing: 8) {
          Image(systemName: isAnswered(question) ? "checkmark.circle.fill" : "exclamationmark.circle")
            .foregroundStyle(isAnswered(question) ? Theme.statusDone : Theme.warning)
          VStack(alignment: .leading, spacing: 2) {
            Text(question.header)
              .font(Theme.Text.meta)
              .foregroundStyle(Theme.textDim)
            Text(summary(for: question) ?? "Not answered")
              .font(Theme.Text.body)
              .foregroundStyle(isAnswered(question) ? Theme.textPrimary : Theme.warning)
          }
        }
      }

      HStack(spacing: 8) {
        Button("Cancel") {
          onEscape()
        }
        .buttonStyle(NotchSecondaryButtonStyle())
        .accessibilityLabel("Cancel questionnaire")

        Button("Submit answers") {
          submit()
        }
        .buttonStyle(NotchPrimaryButtonStyle())
        .opacity(allAnswered ? 1 : 0.45)
        .disabled(!allAnswered)
        .accessibilityLabel("Submit answers")
      }
    }
  }

  private var footerHints: some View {
    Text("Enter to select · Tab/Arrow keys to navigate · Esc to cancel")
      .font(Theme.Text.meta)
      .foregroundStyle(Theme.textDim)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var loadingOverlay: some View {
    VStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Sending…")
        .font(Theme.Text.body)
        .foregroundStyle(Theme.textSecondary)
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Theme.surfaceRaised)
    )
    .accessibilityLabel("Sending answers")
  }

  private var cancelConfirmOverlay: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("Discard answers?")
        .font(Theme.Text.title)
        .foregroundStyle(Theme.textPrimary)
      Text("You'll lose the progress you've made on this questionnaire.")
        .font(Theme.Text.body)
        .foregroundStyle(Theme.textSecondary)
      HStack(spacing: 8) {
        Button("Keep answering") {
          showCancelConfirm = false
        }
        .buttonStyle(NotchSecondaryButtonStyle())
        .accessibilityLabel("Keep answering")

        Button("Discard") {
          showCancelConfirm = false
          store.cancelQuestion(sessionId: sessionId)
        }
        .buttonStyle(NotchPrimaryButtonStyle())
        .accessibilityLabel("Discard answers")
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(Theme.surfaceRaised)
        .overlay(
          RoundedRectangle(cornerRadius: 8)
            .stroke(Theme.divider, lineWidth: 1)
        )
    )
    .padding(Theme.panelPadding)
  }

  // MARK: - Selection helpers

  private func isOptionSelected(_ question: AskQuestion, label: String) -> Bool {
    if question.multiSelect {
      return multiSelection[question.id]?.contains(label) ?? false
    }
    return singleSelection[question.id] == label
  }

  private func isOtherSelected(_ question: AskQuestion) -> Bool {
    if question.multiSelect {
      let text = otherText[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return !text.isEmpty
    }
    return singleSelection[question.id] == Self.otherSentinel
  }

  private func isAnswered(_ question: AskQuestion) -> Bool {
    answerValue(for: question) != nil
  }

  private var allAnswered: Bool {
    info.questions.allSatisfy(isAnswered)
  }

  private func hasAnyProgress() -> Bool {
    !singleSelection.isEmpty
      || multiSelection.values.contains { !$0.isEmpty }
      || otherText.values.contains {
        !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
  }

  private func answerValue(for question: AskQuestion) -> JSONValue? {
    let other = otherText[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if question.multiSelect {
      var labels = Array(multiSelection[question.id] ?? []).sorted()
      if !other.isEmpty { labels.append(other) }
      return labels.isEmpty ? nil : .string(labels.joined(separator: ", "))
    }
    guard let selected = singleSelection[question.id] else { return nil }
    if selected == Self.otherSentinel {
      return other.isEmpty ? nil : .string(other)
    }
    return .string(selected)
  }

  private func summary(for question: AskQuestion) -> String? {
    answerValue(for: question)?.stringValue
  }

  private func selectOption(_ question: AskQuestion, label: String, advance: Bool) {
    validationError[question.id] = nil
    if question.multiSelect {
      var current = multiSelection[question.id] ?? []
      if current.contains(label) {
        current.remove(label)
      } else {
        current.insert(label)
      }
      multiSelection[question.id] = current
      return
    }

    singleSelection[question.id] = label
    if advance {
      flashAndAdvance(optionID: label, from: question)
    }
  }

  /// Focus follows the highlight: landing on the Other row puts the caret in
  /// the field, leaving it takes the caret back out.
  private func syncOtherFocus() {
    guard !isOnSubmitStep else { return }
    let isOtherRow = highlighted == info.questions[currentStep].options.count
    // Same one-tick defer as selectOther: the field is rendered by this very
    // state change, so it isn't focusable until the next pass.
    DispatchQueue.main.async { self.otherFieldFocused = isOtherRow }
  }

  private func selectOther(_ question: AskQuestion) {
    validationError[question.id] = nil
    if !question.multiSelect {
      singleSelection[question.id] = Self.otherSentinel
    }
    // The field is only rendered once this row is selected, so focusing it in
    // the same state batch targets a view that doesn't exist yet and is
    // dropped. One tick later it's there.
    DispatchQueue.main.async { self.otherFieldFocused = true }
  }

  private func flashAndAdvance(optionID: String, from question: AskQuestion) {
    flashSelectedID = optionID
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      flashSelectedID = nil
      if let index = info.questions.firstIndex(where: { $0.id == question.id }) {
        goToStep(index + 1)
      }
    }
  }

  private func goToStep(_ step: Int) {
    let clamped = max(0, min(step, submitStepIndex))
    currentStep = clamped
    highlighted = 0
    otherFieldFocused = false
  }

  private func submit() {
    var answers: [String: JSONValue] = [:]
    for question in info.questions {
      guard let value = answerValue(for: question) else {
        validationError[question.id] = "This question is required"
        if let index = info.questions.firstIndex(where: { $0.id == question.id }) {
          goToStep(index)
        }
        return
      }
      answers[question.question] = value
    }
    isSubmitting = true
    store.answerQuestion(sessionId: sessionId, answers: answers)
  }

  // MARK: - Keyboard

  private func handleKey(_ event: NSEvent) -> Bool {
    if showCancelConfirm {
      switch event.keyCode {
      case 53:  // esc
        showCancelConfirm = false
        return true
      case 36, 76:  // return
        showCancelConfirm = false
        store.cancelQuestion(sessionId: sessionId)
        return true
      default:
        return false
      }
    }

    if isSubmitting { return true }

    // While the caret is in the Other field the user is typing, so only Esc,
    // row navigation and commit keys stay ours. ponytail: this costs up/down
    // as caret motion and Enter as a newline; the field still wraps to four
    // lines and left/right still move the caret. Revisit if anyone needs to
    // write a paragraph in here.
    if otherFieldFocused, ![53, 48, 125, 126, 36, 76].contains(event.keyCode) { return false }

    switch event.keyCode {
    case 53:  // esc
      onEscape()
      return true
    case 48:  // tab
      goToStep(currentStep + (event.modifierFlags.contains(.shift) ? -1 : 1))
      return true
    case 36, 76:  // return / keypad enter
      onEnter()
      return true
    default:
      break
    }

    guard !isOnSubmitStep else { return false }
    let question = info.questions[currentStep]
    let rowCount = question.options.count + 1
    switch event.keyCode {
    case 125:  // down
      highlighted = min(highlighted + 1, rowCount - 1)
      return true
    case 126:  // up
      highlighted = max(highlighted - 1, 0)
      return true
    case 49:  // space
      toggleHighlighted(question)
      return true
    default:
      return false
    }
  }

  private func onEscape() {
    if otherFieldFocused {
      otherFieldFocused = false
      return
    }
    if hasAnyProgress() {
      showCancelConfirm = true
    } else {
      store.cancelQuestion(sessionId: sessionId)
    }
  }

  private func onEnter() {
    if isOnSubmitStep {
      if allAnswered {
        submit()
      } else if let index = info.questions.firstIndex(where: { !isAnswered($0) }) {
        validationError[info.questions[index].id] = "This question is required"
        goToStep(index)
      }
      return
    }

    let question = info.questions[currentStep]
    if highlighted == question.options.count {
      let text = otherText[question.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      // Nothing typed yet: Enter just puts the caret in the field.
      guard !text.isEmpty else {
        selectOther(question)
        return
      }
      if !question.multiSelect {
        singleSelection[question.id] = Self.otherSentinel
      }
      goToStep(currentStep + 1)
      return
    }
    guard question.options.indices.contains(highlighted) else { return }
    let option = question.options[highlighted]
    if question.multiSelect {
      selectOption(question, label: option.label, advance: false)
    } else {
      selectOption(question, label: option.label, advance: true)
    }
  }

  private func toggleHighlighted(_ question: AskQuestion) {
    if highlighted == question.options.count {
      selectOther(question)
      return
    }
    guard question.options.indices.contains(highlighted) else { return }
    selectOption(question, label: question.options[highlighted].label, advance: false)
  }
}

/// Holds the local key-down monitor so the SwiftUI view struct isn't captured
/// by AppKit for the life of the questionnaire. The view refreshes
/// `onKeyDown` whenever relevant `@State` changes.
private final class QuestionKeyMonitor: ObservableObject {
  var onKeyDown: ((NSEvent) -> Bool)?
  private var monitor: Any?

  func start() {
    guard monitor == nil else { return }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self, let onKeyDown else { return event }
      return onKeyDown(event) ? nil : event
    }
  }

  func stop() {
    if let monitor {
      NSEvent.removeMonitor(monitor)
    }
    monitor = nil
    onKeyDown = nil
  }

  deinit {
    stop()
  }
}
