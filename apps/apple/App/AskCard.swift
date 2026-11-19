import SwiftUI

/// A bot's question with answers to pick, or a request to approve an action, drawn as the mobile
/// app draws it: options read as a list of answers, an approval as Allow and Deny buttons.
struct AskCard: View {
  let block: Message.Block
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void
  @State private var sending: String?

  private var actions: [Message.Block.Action] { block.actions ?? [] }
  private var answered: Bool { block.status == "answered" }
  /// A question the bot asked, as opposed to an action waiting for approval.
  private var question: Bool {
    block.approvalEffectId == nil && block.instructionUpdate == nil && block.input != "secret"
      && block.credential == nil && block.oneTimeCode == nil
  }
  private var approval: Bool {
    guard block.approvalEffectId != nil else { return false }
    let ids = Set(actions.map(\.id))
    return ids.contains("allow") && ids.contains("deny")
      && ids.isSubset(of: ["allow", "always", "deny"])
  }
  private var canAnswer: Bool { !answered && block.expired != true && message.runId != nil }
  private var chosen: Message.Block.Action? {
    guard answered, let answer = block.answer?.trimmingCharacters(in: .whitespaces),
      !answer.isEmpty
    else { return nil }
    return actions.first { $0.id == answer }
      ?? actions.first { $0.label.lowercased() == answer.lowercased() }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let text = block.text {
        Text(verbatim: block.instructionUpdate != nil ? "Update instructions?" : Self.plain(text))
          .font(TypeRole.message.weight(.medium))
          .foregroundStyle(question && answered ? .secondary : .primary)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }
      if let detail = block.detail {
        let code =
          block.detailFormat == "code"
          || (block.detailFormat == nil && block.approvalEffectId != nil)
        Text(verbatim: detail)
          .font(code ? Self.code : TypeRole.summary)
          .foregroundStyle(
            block.detailFormat == "text" && !(question && answered) ? .primary : .secondary
          )
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
          .padding(.top, block.text == nil ? 0 : Layout.Space.small)
      }
      if question {
        if answered || canAnswer { options }
        if answered, chosen == nil, block.answerMessageId == nil, let answer = block.answer {
          outcome("Answered: \(answer)", color: .secondary)
        }
      } else if answered || block.expired == true {
        outcome(
          answerLabel, color: block.answer == "deny" || block.expired == true ? .secondary : .green)
      } else if canAnswer {
        buttons
      } else {
        Text("No longer active").font(Self.caption).foregroundStyle(.secondary).padding(
          .top, Layout.Space.medium)
      }
    }.padding(.horizontal, Layout.Space.standard).padding(.vertical, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        Ink.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous)
      ).frame(maxWidth: 576, alignment: .leading)
  }

  /// A question's answers, as a list; the one picked keeps a checkmark.
  private var options: some View {
    VStack(spacing: Layout.Space.small) {
      ForEach(actions, id: \.id) { action in
        let picked = chosen?.id == action.id
        let inactive = answered || sending != nil
        Button {
          answer(action.id)
        } label: {
          HStack(spacing: 10) {
            Text(verbatim: action.label).foregroundStyle(
              answered && !picked ? .secondary : .primary)
            Spacer(minLength: 0)
            if sending == action.id {
              ProgressView().controlSize(.small)
            } else if picked {
              Image(systemName: "checkmark").foregroundStyle(.secondary)
            }
          }.font(TypeRole.message).padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: Layout.touch, alignment: .leading)
            .background(picked ? Ink.selection : Ink.canvas, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(inactive)
          .opacity(inactive && !picked && sending != action.id ? 0.6 : 1)
          .accessibilityAddTraits(picked ? .isSelected : [])
      }
    }.padding(.top, Layout.Space.medium)
  }

  /// An approval's choices, Allow first and filled.
  private var buttons: some View {
    HStack(spacing: 6) {
      ForEach(actions, id: \.id) { action in
        let primary = action.id == "allow" || action.id == "always"
        Button {
          answer(action.id)
        } label: {
          HStack(spacing: 6) {
            if sending == action.id { ProgressView().controlSize(.small) }
            Text(label(action))
          }
        }.buttonStyle(Pill(primary: primary)).fixedSize().disabled(sending != nil)
      }
    }.padding(.top, Layout.Space.medium)
  }

  /// Filled in ink for the choice that goes ahead, outlined for the others.
  private struct Pill: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
      configuration.label.font(TypeRole.message.weight(.medium))
        .foregroundStyle(primary ? Ink.canvas : Color.primary)
        .padding(.horizontal, 16).frame(minHeight: Layout.pointer + 4)
        .background(primary ? Color.primary : Ink.canvas, in: Capsule())
        .overlay { if !primary { Capsule().strokeBorder(Ink.line) } }
        .opacity(configuration.isPressed ? 0.75 : enabled ? 1 : 0.5).contentShape(Capsule())
    }
  }

  private func outcome(_ text: String, color: Color) -> some View {
    Text(text).font(TypeRole.summary.weight(.medium)).foregroundStyle(color).padding(
      .top, Layout.Space.medium)
  }

  private var answerLabel: String {
    if block.expired == true { return "Expired" }
    if block.instructionUpdate != nil {
      return block.answer == "deny" ? "Dismissed" : "Allowed once"
    }
    guard let answer = block.answer else { return "Answered" }
    let picked = actions.first { $0.id == answer }
    if approval || picked?.outcome != nil {
      if picked?.outcome == "created" { return "Created" }
      if picked?.outcome == "cancelled" { return "Cancelled" }
      if answer == "allow" { return allowsSpace ? "Allowed in this space" : "Allowed once" }
      if answer == "always" { return "Always allowed" }
      if answer == "deny" { return "Denied" }
    }
    return "Answered: \(picked?.label ?? answer)"
  }

  /// The server's labels on the user's-computer approval, whose allow covers the whole Space.
  private var allowsSpace: Bool {
    actions.contains { ["Allow in this space", "Allow for this chat"].contains($0.label) }
  }

  private func label(_ action: Message.Block.Action) -> String {
    if block.instructionUpdate != nil { return action.id == "allow" ? "Apply" : "Dismiss" }
    guard approval || action.outcome != nil else { return action.label }
    if action.outcome == "created" { return "Create space" }
    if action.outcome == "cancelled" { return "Cancel" }
    switch action.id {
    case "allow": return allowsSpace ? "Allow in this space" : "Allow once"
    case "always": return block.site.map { "Always allow \($0)" } ?? "Always allow this tool"
    case "deny": return "Deny"
    default: return action.label
    }
  }

  private func answer(_ choice: String) {
    guard sending == nil, canAnswer, let api = store.client, let run = message.runId else { return }
    sending = choice
    Task {
      defer { sending = nil }
      do {
        let _: Empty = try await api.rpc(
          "threads/answer",
          chat.target.merging([
            "messageId": message.id, "runId": run, "answer": choice,
            "clientNonce": UUID().uuidString,
          ]) { $1 })
        try await refresh()
      } catch { report(error.localizedDescription) }
    }
  }

  // The mobile card's caption sizes, on each platform's own scale.
  #if os(macOS)
    static let code = Font.system(size: 12, design: .monospaced), caption = Font.system(size: 12)
  #else
    static let code = Font.system(.footnote, design: .monospaced), caption = Font.footnote
  #endif

  /// A title as plain text: names in it were escaped for the web's Markdown.
  static func plain(_ text: String) -> String {
    text.replacingOccurrences(of: #"\\([\\`*_\[\]<>~|])"#, with: "$1", options: .regularExpression)
  }
}
