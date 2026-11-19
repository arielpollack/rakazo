import SwiftUI

/// An email or message a bot drafted for an integration, held for review: the person edits it,
/// then sends or discards it, as the mobile app's outgoing draft card.
struct OutgoingDraftCard: View {
  let block: Message.Block
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void
  /// Whether this person may answer the card, as the thread decides from its waiting runs; nil
  /// decides from this message alone.
  let answerable: Bool?
  private let draft: DraftFields.Draft?

  @State private var values: DraftValues
  /// The answer being sent, then the one the server accepted until the card is re-read.
  @State private var sending: String?
  @State private var submitted: String?
  @State private var error: String?
  @Environment(\.displayScale) private var displayScale

  init(
    block: Message.Block, message: Message, chat: Chat, store: WorkspaceStore,
    refresh: @escaping () async throws -> Void, report: @escaping (String) -> Void,
    answerable: Bool? = nil
  ) {
    self.block = block
    self.message = message
    self.chat = chat
    _store = ObservedObject(wrappedValue: store)
    self.refresh = refresh
    self.report = report
    self.answerable = answerable
    let draft = block.fields(DraftFields.self)?.outgoingDraft
    self.draft = draft
    _values = State(initialValue: draft?.values ?? DraftValues(kind: "message", to: "", body: ""))
  }

  /// A bot's message has no author, so it is the run's own person's unless it names another.
  private var owner: Bool { message.author.map { $0.id == store.account?.userId } ?? true }
  private var canAnswer: Bool {
    (answerable ?? (block.status != "answered" && owner)) && message.runId != nil
      && store.client != nil
  }
  /// Only a committed card replaces local edits with the server's reviewed values.
  private var status: String {
    let decision = (block.status == "answered" ? block.answer : nil) ?? submitted
    if block.expired == true { return "expired" }
    if decision == "deny" { return "discarded" }
    if decision?.isEmpty == false { return "approved" }
    return canAnswer ? "pending" : "inactive"
  }
  private var shown: DraftValues {
    block.status == "answered" ? draft?.values ?? values : values
  }
  private var hairline: CGFloat { 1 / displayScale }

  var body: some View {
    if let draft { card(draft) }
  }

  private func card(_ draft: DraftFields.Draft) -> some View {
    let open = status == "pending"
    let editable = open && sending == nil
    let email = shown.kind == "email"
    return VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 8) {
          Image(systemName: email ? "envelope" : "bubble.left").font(.system(size: 16))
            .accessibilityHidden(true)
          Text("\(draft.source) draft").font(CardType.caption)
        }.foregroundStyle(.secondary)
        if open, let detail = block.detail {
          Text(verbatim: detail).font(CardType.secondary).padding(.leading, 10)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .leading) { Rectangle().fill(.orange).frame(width: 2) }
        }
        if shown.kind == "email" {
          if open && values.kind == "email" {
            TextField(
              "Subject", text: Binding(get: { values.subject ?? "" }, set: { values.subject = $0 })
            ).textFieldStyle(.plain).font(Self.headline).disabled(!editable)
          } else if let subject = shown.subject, !subject.isEmpty {
            Text(verbatim: subject).font(Self.headline).textSelection(.enabled)
          }
        }
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text("To").font(CardType.caption).foregroundStyle(.secondary)
          if open {
            TextField("", text: $values.to, axis: .vertical).textFieldStyle(.plain)
              .font(CardType.body).recipientEntry(email: email).disabled(!editable)
              .accessibilityLabel("To")
          } else {
            Text(verbatim: shown.to).font(CardType.body).textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }.padding(.bottom, 10)
          .overlay(alignment: .bottom) { Rectangle().fill(Ink.line).frame(height: hairline) }
        if open {
          TextField("Message", text: $values.body, axis: .vertical).textFieldStyle(.plain)
            .font(CardType.body).frame(minHeight: 72, alignment: .topLeading)
            .disabled(!editable)
        } else {
          Text(verbatim: shown.body).font(CardType.body).textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }.padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
      HStack(spacing: 14) {
        Spacer(minLength: 0)
        if open, let run = message.runId {
          Button("Discard") { answer("deny", run: run) }.buttonStyle(.plain)
            .font(CardType.secondary).foregroundStyle(.secondary).disabled(sending != nil)
          Button {
            answer(Self.answer(values), run: run)
          } label: {
            ZStack {
              Text("Send").opacity(sending != nil && sending != "deny" ? 0 : 1)
              if sending != nil && sending != "deny" {
                ProgressView().controlSize(.small).tint(Ink.canvas)
              }
            }
          }.buttonStyle(CardButton(primary: true)).fixedSize()
            .disabled(sending != nil || !Self.valid(values))
        } else {
          Text(
            status == "expired"
              ? "Expired"
              : status == "discarded"
                ? "Discarded" : status == "approved" ? "Approved" : "No longer active"
          ).font(CardType.caption).foregroundStyle(.secondary)
        }
      }.padding(.horizontal, 16).padding(.vertical, 8).frame(maxWidth: .infinity)
        .background(Ink.fill)
        .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: hairline) }
      if let error {
        Text(error).font(CardType.caption).foregroundStyle(.red).padding(.horizontal, 16)
          .padding(.bottom, 12)
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
      .background(Ink.fill)
      .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(
          Ink.line, lineWidth: hairline)
      }
      .frame(maxWidth: 576, alignment: .leading)
  }

  private func answer(_ answer: String, run: String) {
    guard sending == nil, let api = store.client else { return }
    sending = answer
    error = nil
    Task {
      defer { sending = nil }
      do {
        let _: Empty = try await api.rpc(
          "threads/answer",
          chat.target.merging(["messageId": message.id, "runId": run, "answer": answer]) { $1 })
        submitted = answer
      } catch {
        self.error = AskErrorCopy.text(error, fallback: "Couldn’t submit the draft")
        return
      }
      do { try await refresh() } catch { report(error.localizedDescription) }
    }
  }

  #if os(macOS)
    private static let headline = Font.system(size: 17, weight: .semibold)
  #else
    private static let headline = Font.title3.weight(.semibold)
  #endif

  /// The reviewed draft as the server reads an approval of it.
  private static func answer(_ values: DraftValues) -> String {
    var draft: [String: Any] = ["kind": values.kind, "to": values.to, "body": values.body]
    if values.kind == "email" { draft["subject"] = values.subject ?? "" }
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: ["outgoingDraft": draft], options: .withoutEscapingSlashes),
      let json = String(data: data, encoding: .utf8)
    else { return "" }
    return json
  }

  /// Whether the edited draft is one the server sends: an email to one address with a subject
  /// or body, or a message to one destination with a body.
  private static func valid(_ values: DraftValues) -> Bool {
    let body = values.body.trimmingCharacters(in: .whitespacesAndNewlines)
    guard values.body.utf16.count <= 16_000 else { return false }
    if values.kind == "email" {
      let subject = values.subject ?? ""
      return values.to.utf16.count <= 254
        && values.to.range(of: emailPattern, options: .regularExpression) != nil
        && subject.utf16.count <= 998 && !subject.contains(where: \.isNewline)
        && (!subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !body.isEmpty)
    }
    return values.kind == "message" && (1...254).contains(values.to.utf16.count)
      && !values.to.contains(where: \.isWhitespace) && !body.isEmpty
  }

  private static let emailPattern =
    #"^(?:[A-Za-z0-9_'+\-]+\.)*[A-Za-z0-9_'+\-]*[A-Za-z0-9_+-]@(?:[A-Za-z0-9][A-Za-z0-9\-]*\.)+[A-Za-z]{2,}$"#
}

private struct DraftFields: Decodable {
  let outgoingDraft: Draft
  struct Draft: Decodable {
    let source: String
    let values: DraftValues
  }
}

private struct DraftValues: Decodable, Equatable {
  var kind: String
  var to: String
  var subject: String?
  var body: String
}

extension View {
  /// An address field: an email keyboard for an email, never capitalized or corrected.
  @ViewBuilder fileprivate func recipientEntry(email: Bool) -> some View {
    #if os(iOS)
      keyboardType(email ? .emailAddress : .default).textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    #else
      autocorrectionDisabled()
    #endif
  }
}
