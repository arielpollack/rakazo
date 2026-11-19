import SwiftUI

/// A question a tool's server asked while its call waits, as the mobile app's tool question card.
/// Every word of it is the server's, shown as plain text.
struct ToolQuestionCard: View {
  let block: Message.Block
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void
  /// Whether this person may answer the card, as the thread decides from its running runs; nil
  /// decides from this message alone.
  let answerable: Bool?
  private let card: ToolQuestionFields?

  @State private var values: ToolQuestionDraft
  /// The action being sent, then the one the server accepted until the card is re-read.
  @State private var sending: String?
  @State private var sent: String?
  @State private var error: String?

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
    let card = block.fields(ToolQuestionFields.self)
    self.card = card
    _values = State(initialValue: Self.initialDraft(card?.question.fields ?? []))
  }

  /// A bot's message has no author, so it is the run's own person's unless it names another.
  private var owner: Bool { message.author.map { $0.id == store.account?.userId } ?? true }
  private var canAnswer: Bool {
    (answerable ?? (message.runId != nil && owner)) && store.client != nil
  }

  var body: some View {
    if let card { content(card) }
  }

  private func content(_ card: ToolQuestionFields) -> some View {
    let status = Self.shownStatus(card.status, sent: sent)
    let open = status == "pending" && canAnswer
    return VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: card.question.source).font(CardType.caption).foregroundStyle(.secondary)
      Text(verbatim: card.question.message).font(CardType.body)
        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      if open {
        ForEach(card.question.fields, id: \.name) { field in
          QuestionField(field: field, value: binding(field), disabled: sending != nil)
        }
        HStack(spacing: 8) {
          Button {
            answer("accept", card)
          } label: {
            ZStack {
              Text("Accept").opacity(sending == "accept" ? 0 : 1)
              if sending == "accept" { ProgressView().controlSize(.small).tint(Ink.canvas) }
            }
          }.buttonStyle(CardButton(primary: true)).fixedSize().disabled(sending != nil)
          Button("Decline") { answer("decline", card) }.buttonStyle(CardButton(primary: false))
            .fixedSize().disabled(sending != nil)
        }
        if let error { Text(error).font(CardType.caption).foregroundStyle(.red) }
      } else if status != "pending" {
        Text(status == "accepted" ? "Sent" : status == "declined" ? "Declined" : "Expired")
          .font(CardType.secondary.weight(.medium))
          .foregroundStyle(status == "accepted" ? Color.green : Color.secondary)
      }
    }.chatCard()
  }

  private func binding(_ field: ToolQuestionFields.Field) -> Binding<ToolQuestionDraftValue?> {
    Binding(get: { values[field.name] }, set: { values[field.name] = $0 })
  }

  private func answer(_ action: String, _ card: ToolQuestionFields) {
    guard sending == nil, let api = store.client else { return }
    var input = chat.target
    input["messageId"] = message.id
    input["action"] = action
    if action == "accept" { input["values"] = Self.sentValues(card.question.fields, values) }
    sending = action
    error = nil
    Task {
      defer { sending = nil }
      do {
        let _: Empty = try await api.rpc("threads/answerToolQuestion", input)
        sent = action
      } catch {
        self.error = AskErrorCopy.text(error, fallback: "Could not submit this answer")
        return
      }
      do { try await refresh() } catch { report(error.localizedDescription) }
    }
  }

  /// What a card shows: its stored status, or the answer this client just sent until it lands.
  private static func shownStatus(_ status: String, sent: String?) -> String {
    guard status == "pending", let sent else { return status }
    return sent == "accept" ? "accepted" : "declined"
  }

  /// What a form starts with on every client: the server's defaults. A required yes/no field
  /// starts off and a required choice on its first option; an optional one the server gave no
  /// default starts unset, so an untouched form sends nothing for it.
  private static func initialDraft(_ fields: [ToolQuestionFields.Field]) -> ToolQuestionDraft {
    var draft: ToolQuestionDraft = [:]
    for field in fields {
      switch field.type {
      case "boolean":
        if case .bool(let value) = field.defaultValue {
          draft[field.name] = .flag(value)
        } else if field.required {
          draft[field.name] = .flag(false)
        }
      case "choice":
        if case .string(let value) = field.defaultValue {
          draft[field.name] = .text(value)
        } else if field.required, let first = field.options?.first {
          draft[field.name] = .text(first.value)
        }
      default:
        switch field.defaultValue {
        case .string(let value): draft[field.name] = .text(value)
        case .number(let value): draft[field.name] = .text(numberText(value))
        case .bool(let value): draft[field.name] = .text(String(value))
        default: break
        }
      }
    }
    return draft
  }

  /// A number as JavaScript writes it: whole numbers without a decimal point.
  private static func numberText(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e21 ? String(Int64(value)) : String(value)
  }

  /// The values to send: empty fields left out, numbers parsed, and a date-time as RFC 3339 with
  /// its offset. Text that does not parse is sent as typed, so the server names the field.
  private static func sentValues(
    _ fields: [ToolQuestionFields.Field], _ draft: ToolQuestionDraft
  ) -> [String: Any] {
    var out: [String: Any] = [:]
    for field in fields {
      switch draft[field.name] {
      case nil, .text(""): continue
      case .flag(let value): out[field.name] = value
      case .text(let value):
        if field.type == "number" {
          // A comma-decimal keyboard types 1,5: one comma and no point reads as the decimal mark.
          let typed = value.trimmingCharacters(in: .whitespacesAndNewlines)
          let decimal =
            typed.range(of: #"^-?[0-9]*,[0-9]+$"#, options: .regularExpression) != nil
            ? typed.replacingOccurrences(of: ",", with: ".") : typed
          if !typed.isEmpty, let number = Double(decimal), number.isFinite {
            out[field.name] = number
          } else {
            out[field.name] = value
          }
        } else if field.type == "text", field.format == "date-time" {
          out[field.name] = dateTime(value).map(isoTime.string(from:)) ?? value
        } else {
          out[field.name] = value
        }
      }
    }
    return out
  }

  private static let isoTime: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
  }()

  /// A typed date and time as a browser reads one: with its offset, or else in local time.
  private static func dateTime(_ text: String) -> Date? {
    let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let zoned = ISO8601DateFormatter()
    for options: ISO8601DateFormatter.Options in [
      [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
    ] {
      zoned.formatOptions = options
      if let date = zoned.date(from: typed) { return date }
    }
    let local = DateFormatter()
    local.locale = Locale(identifier: "en_US_POSIX")
    for format in [
      "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
      "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
    ] {
      local.dateFormat = format
      if let date = local.date(from: typed) { return date }
    }
    // A date alone is midnight UTC.
    local.dateFormat = "yyyy-MM-dd"
    local.timeZone = TimeZone(identifier: "UTC")
    return local.date(from: typed)
  }
}

/// A form as the person types it: numbers stay text until sent.
private typealias ToolQuestionDraft = [String: ToolQuestionDraftValue]
private enum ToolQuestionDraftValue: Equatable {
  case text(String)
  case flag(Bool)
}

private struct ToolQuestionFields: Decodable {
  let question: Question
  let status: String
  struct Question: Decodable {
    let source: String
    let message: String
    let fields: [Field]
  }
  struct Field: Decodable {
    let name: String
    let label: String
    let description: String?
    let required: Bool
    let type: String
    let format: String?
    let maxLength: Int?
    let integer: Bool?
    let minimum: Double?
    let options: [Option]?
    let defaultValue: JSONValue?
    enum CodingKeys: String, CodingKey {
      case name, label, description, required, type, format, maxLength, integer, minimum, options
      case defaultValue = "default"
    }
  }
  struct Option: Decodable {
    let value: String
    let label: String
  }
}

/// One field of a tool's question: a switch, a menu of choices, or a text box.
private struct QuestionField: View {
  let field: ToolQuestionFields.Field
  @Binding var value: ToolQuestionDraftValue?
  let disabled: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      switch field.type {
      case "boolean":
        Toggle(isOn: Binding(get: { value == .flag(true) }, set: { value = .flag($0) })) {
          Text(verbatim: field.label).font(CardType.secondary)
        }.disabled(disabled)
      case "choice":
        HStack(spacing: 8) {
          Text(verbatim: field.label).font(CardType.secondary)
          Spacer(minLength: 0)
          Picker(field.label, selection: choice) {
            // A menu shows its first entry when nothing is chosen, so an optional choice offers
            // None first rather than looking picked.
            if !field.required { Text("None").tag("") }
            ForEach(field.options ?? [], id: \.value) { option in
              Text(verbatim: option.label).tag(option.value)
            }
          }.pickerStyle(.menu).labelsHidden().fixedSize().disabled(disabled)
        }.frame(minHeight: Layout.touch)
      default:
        Text(verbatim: field.label).font(CardType.secondary)
        TextField(field.label, text: text).textFieldStyle(.plain).labelsHidden()
          .questionEntry(field).disabled(disabled)
          .padding(.horizontal, 12).padding(.vertical, 9).frame(minHeight: 42)
          .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line) }
      }
      if let description = field.description {
        Text(verbatim: description).font(CardType.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var choice: Binding<String> {
    Binding(
      get: {
        if case .text(let current) = value { return current }
        return ""
      }, set: { value = .text($0) })
  }

  private var text: Binding<String> {
    Binding(
      get: {
        switch value {
        case .text(let current): current
        case .flag(let current): String(current)
        case nil: ""
        }
      },
      set: { typed in
        guard field.type == "text", let limit = field.maxLength, typed.utf16.count > limit else {
          value = .text(typed)
          return
        }
        var kept = ""
        for character in typed {
          guard kept.utf16.count + character.utf16.count <= limit else { break }
          kept.append(character)
        }
        value = .text(kept)
      })
  }
}

extension View {
  /// The keyboard a question's text box offers for its field's type and format.
  @ViewBuilder fileprivate func questionEntry(_ field: ToolQuestionFields.Field) -> some View {
    #if os(iOS)
      let keyboard: UIKeyboardType =
        field.type == "number"
        // The number pads have no minus key.
        ? (field.minimum.map { $0 < 0 } ?? true
          ? .numbersAndPunctuation : field.integer == true ? .numberPad : .decimalPad)
        : field.format == "email" ? .emailAddress : field.format == "uri" ? .URL : .default
      keyboardType(keyboard)
        .textInputAutocapitalization(
          field.type == "text" && field.format == nil ? .sentences : .never)
    #else
      self
    #endif
  }
}
