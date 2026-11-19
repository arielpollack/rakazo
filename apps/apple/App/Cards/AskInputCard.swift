import SwiftUI

/// A bot's request that is answered with typed input rather than a picked action, drawn as the
/// mobile app's ask block: a question answered from the composer, a masked secret or texted code,
/// or a login, card or contact filled in a sheet.
struct AskInputCard: View {
  let block: Message.Block
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void
  /// Whether this person may answer the card, as the thread decides from its waiting runs (the
  /// mobile app's `answerableAskMessageIds`); nil decides from this message alone.
  let answerable: Bool?
  /// Whether this person may dismiss the secret request (`dismissableAskMessageIds`); nil decides
  /// from this message alone.
  let dismissable: Bool?
  private let ask: AskFields

  @State private var answer = ""
  @State private var error: String?
  @State private var submitting = false
  @State private var sheetOpen = false
  @State private var saved = false
  @State private var sentOnce = false
  @State private var dismissed = false
  @State private var accepted = 0

  init(
    block: Message.Block, message: Message, chat: Chat, store: WorkspaceStore,
    refresh: @escaping () async throws -> Void, report: @escaping (String) -> Void,
    answerable: Bool? = nil, dismissable: Bool? = nil
  ) {
    self.block = block
    self.message = message
    self.chat = chat
    _store = ObservedObject(wrappedValue: store)
    self.refresh = refresh
    self.report = report
    self.answerable = answerable
    self.dismissable = dismissable
    ask = block.fields(AskFields.self) ?? AskFields()
  }

  private var answered: Bool { saved || dismissed || block.status == "answered" }
  private var secretInput: Bool { block.input == "secret" && block.approvalEffectId == nil }
  private var question: Bool {
    !secretInput && block.approvalEffectId == nil && block.instructionUpdate == nil
  }
  private var answeredQuestion: Bool { answered && question }
  private var itemType: String? { secretInput ? ask.credential?.auth.type : nil }
  /// A bot's message has no author, so it is the run's own person's unless it names another.
  private var owner: Bool { message.author.map { $0.id == store.account?.userId } ?? true }
  private var canAnswer: Bool {
    answerable
      ?? (store.client != nil && message.runId != nil && block.status != "answered" && owner)
  }
  private var canDismiss: Bool { dismissable ?? (canAnswer && secretInput) }
  /// A login, credential or code is for the run's person, so only they can fill one in; others
  /// see the card without fields or buttons.
  private var ownerOnly: Bool {
    secretInput && (ask.credential != nil || ask.oneTimeCode != nil) && !canDismiss
  }
  private var destination: String? {
    if let credential = ask.credential { return Self.destinationLabel(credential) }
    if let code = ask.oneTimeCode {
      return "Only enter a code \(Self.siteHost(code.origin)) sent you."
    }
    return nil
  }
  private var incomplete: Bool {
    ask.oneTimeCode != nil ? Self.normalizedCode(answer) == nil : answer.isEmpty
  }
  private var secretLabel: String {
    ask.purpose == "password" ? "Password" : ask.purpose == "api_key" ? "API key" : "Code"
  }
  private var submitLabel: String { ask.oneTimeCode != nil ? "Continue" : "Save" }
  private var declined: Bool { dismissed || block.dismissed == true }
  private var answeredLabel: String {
    declined
      ? "Dismissed"
      : sentOnce || ask.remembered == false || ask.oneTimeCode != nil ? "Sent" : "Saved"
  }
  /// An answered question whose answer reads as the person's own message right after it.
  private var answerIsSeparate: Bool {
    question && block.status == "answered" && block.answerMessageId != nil
      && !(block.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  private var title: String { AskCard.plain(block.text ?? "") }

  var body: some View {
    Group {
      if let type = itemType, ["login", "card", "contact"].contains(type),
        let credential = ask.credential
      {
        itemRow(type, credential)
      } else {
        inputCard
      }
    }.sensoryFeedback(.success, trigger: accepted)
  }

  /// A login, card or contact: one compact row whose sheet takes the values.
  private func itemRow(_ type: String, _ credential: AskFields.Credential) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Image(systemName: Self.kindSymbol(type)).font(.system(size: 17))
          .frame(width: 34, height: 34)
          .background(Ink.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: title).font(CardType.title).lineLimit(2)
          if let destination {
            Text(verbatim: destination).font(CardType.secondary).foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        if answered {
          HStack(spacing: 4) {
            if !declined { Image(systemName: "checkmark").font(.system(size: 14)) }
            Text(answeredLabel).font(CardType.secondary.weight(.medium))
          }.foregroundStyle(.secondary)
        } else if canAnswer && !ownerOnly {
          Button("Add") { sheetOpen = true }.buttonStyle(CardButton(primary: false)).fixedSize()
            .disabled(submitting)
        }
      }
      if !answered && canAnswer && !ownerOnly && canDismiss {
        Button("Dismiss", action: dismiss).buttonStyle(.borderless).font(CardType.caption)
          .tint(.primary).disabled(submitting)
      }
      if !answered && !canAnswer {
        Text("Waiting for this bot’s response.").font(CardType.caption).foregroundStyle(.secondary)
      }
      if let error { Text(error).font(CardType.caption).foregroundStyle(.red) }
    }.padding(.horizontal, 14).padding(.vertical, 12).chatCard(padded: false)
      .rakazoSheet(
        isPresented: Binding(
          get: { sheetOpen && type == "login" }, set: { if !$0 { sheetOpen = false } })
      ) {
        LoginAskSheet(
          title: title, destination: Self.destinationLabel(credential),
          replacedSite: ask.replaces?.origin, loginFields: ask.loginFields,
          // Once a save is accepted, or the viewer can no longer answer, the open sheet clears
          // its own fields, then closes itself.
          pending: canAnswer && !answered && !ownerOnly,
          onClose: { sheetOpen = false }
        ) { fields, remember in
          var input: [String: Any] = [
            "answer": "",
            "fields": fields.map { ["label": $0.label, "value": $0.value, "hidden": $0.hidden] },
          ]
          if !remember { input["remember"] = false }
          try await send(input)
          sentOnce = !remember
          saved = true
          sheetOpen = false
        }
      }
      .rakazoSheet(
        isPresented: Binding(
          get: { sheetOpen && type != "login" && !answered },
          set: { if !$0 { sheetOpen = false } })
      ) {
        ItemAskSheet(
          card: type == "card", title: title, onClose: { sheetOpen = false },
          onSave: { value in
            try await send(["answer": value])
            saved = true
          })
      }
  }

  private var inputCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: title).font(CardType.title)
        .foregroundStyle(answeredQuestion ? .secondary : .primary)
        .lineLimit(secretInput ? 2 : nil).fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      if secretInput, let destination {
        Text(verbatim: destination).font(CardType.secondary).foregroundStyle(.secondary)
      }
      if secretInput, ask.sharedBrowser == true, !ownerOnly, !answered {
        Text("The bot's browser stays signed in for everyone in this space")
          .font(CardType.secondary).foregroundStyle(.secondary)
      }
      if secretInput, let replaced = ask.replaces, !ownerOnly, !answered {
        Text("Replaces the login saved for \(replaced.origin)").font(CardType.secondary)
          .foregroundStyle(.secondary)
      }
      if let detail = block.detail, !secretInput || ask.oneTimeCode != nil {
        Text(verbatim: detail).font(CardType.secondary).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      // A question is answered from the composer; only a secret is typed into the card.
      if answered && !answerIsSeparate {
        // Dismissed reads like a declined approval, not a success.
        Text(secretInput ? answeredLabel : "Answered: \(block.answer ?? "Done")")
          .font(CardType.secondary.weight(.medium))
          .foregroundStyle(answeredQuestion || declined ? Color.secondary : Color.green)
          .padding(.top, secretInput ? 12 : 0)
      } else if !answered && secretInput && !canAnswer {
        Text("Waiting for this bot’s response.").font(CardType.caption).foregroundStyle(.secondary)
      } else if !answered && secretInput && !ownerOnly {
        secretField
      }
      if let error { Text(error).font(CardType.caption).foregroundStyle(.red) }
    }.chatCard()
  }

  private var secretField: some View {
    VStack(alignment: .leading, spacing: 10) {
      SecureField(secretLabel, text: $answer).textFieldStyle(.plain)
        .secretEntry(Self.fieldTraits(ask.purpose, ask.credential?.auth.type))
        .disabled(submitting).onSubmit(submit)
        .padding(.horizontal, 12).padding(.vertical, 9).frame(minHeight: 42)
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line) }
        .accessibilityLabel(secretLabel)
      // Wraps at large text sizes so neither button is pushed off the card.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 6) { buttons }
        VStack(spacing: 6) { buttons }
      }
    }
  }

  @ViewBuilder private var buttons: some View {
    Button(action: submit) {
      ZStack {
        Text(submitLabel).opacity(submitting ? 0 : 1)
        if submitting { ProgressView().controlSize(.small).tint(Ink.canvas) }
      }.frame(minWidth: 100, maxWidth: .infinity)
    }.buttonStyle(CardButton(primary: true)).disabled(incomplete || submitting)
    if canDismiss {
      Button(action: dismiss) {
        Text("Dismiss").frame(minWidth: 100, maxWidth: .infinity)
      }.buttonStyle(CardButton(primary: false)).disabled(submitting)
    }
  }

  private func dismiss() {
    guard !submitting else { return }
    submitting = true
    error = nil
    answer = ""
    Task {
      defer { submitting = false }
      do {
        try await send(["answer": "", "dismiss": true])
        dismissed = true
      } catch { self.error = "Could not send answer" }
    }
  }

  private func submit() {
    guard !submitting, !incomplete else { return }
    let value = answer
    submitting = true
    error = nil
    answer = ""
    Task {
      defer { submitting = false }
      do {
        try await send(["answer": value])
        saved = true
      } catch { self.error = AskErrorCopy.secret(error) }
    }
  }

  /// Sends an answer or dismissal; returns once the server accepts it.
  private func send(_ input: [String: Any]) async throws {
    guard let api = store.client, let run = message.runId else { return }
    var body = chat.target
    body["runId"] = run
    body["messageId"] = message.id
    body.merge(input) { $1 }
    let _: Empty = try await api.rpc("threads/answer", body)
    accepted += 1
    // The answer is saved once the server accepts it; a failed refresh only delays the card.
    do { try await refresh() } catch { report(error.localizedDescription) }
  }
}

// MARK: - The ask's fields

private struct AskFields: Decodable {
  var purpose: String?
  var credential: Credential?
  var oneTimeCode: Site?
  var replaces: Site?
  var loginFields: [String]?
  var sharedBrowser: Bool?
  var remembered: Bool?
  struct Credential: Decodable {
    var name: String
    var origin: String?
    var auth: Auth
    struct Auth: Decodable { var type: String }
  }
  struct Site: Decodable { var origin: String }
}

extension AskInputCard {
  /// The host a site card shows, or the origin when it does not parse.
  fileprivate static func siteHost(_ origin: String) -> String {
    guard let url = URLComponents(string: origin), let host = url.host, !host.isEmpty else {
      return origin
    }
    let standard = url.scheme == "https" ? 443 : url.scheme == "http" ? 80 : nil
    guard let port = url.port, port != standard else { return host }
    return "\(host):\(port)"
  }

  /// The line under a credential request's prompt: a command variable's name, a login's host,
  /// a card's or contact's kind, or another credential's saved site.
  fileprivate static func destinationLabel(_ credential: AskFields.Credential) -> String {
    let origin = credential.origin ?? ""
    switch credential.auth.type {
    case "command":
      return "Command variable $"
        + credential.name.uppercased().replacingOccurrences(of: "-", with: "_")
    case "login": return siteHost(origin)
    case "card": return "Card"
    case "contact": return "Contact"
    default: return origin
    }
  }

  fileprivate static func kindSymbol(_ type: String) -> String {
    switch type {
    case "login": "key"
    case "card": "creditcard"
    default: "mappin.and.ellipse"
    }
  }

  /// A texted code as typed into a page: spaces dropped, then groups of letters and digits joined
  /// by single dashes, at least 4 of them and at most 12 characters in all.
  fileprivate static func normalizedCode(_ answer: String) -> String? {
    let code = answer.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    guard code.utf16.count <= 12,
      code.replacingOccurrences(of: "-", with: "").utf16.count >= 4,
      code.range(of: #"^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$"#, options: .regularExpression) != nil
    else { return nil }
    return code
  }

  /// The AutoFill a masked field offers: saved passwords for a login or password, nothing for a
  /// credential or API key, and the texted code for a connector's code.
  fileprivate static func fieldTraits(_ purpose: String?, _ auth: String?) -> SecretEntry {
    if auth == "login" || (purpose == "password" && auth != "command") { return .password }
    if auth != nil || purpose == "api_key" { return .noAutofill }
    return .oneTimeCode
  }

  /// In the sample workspace, a message sent while the bot waits on a question answers it, as
  /// the server does for a run waiting on one.
  static func answerSampleQuestion(_ items: inout [Message], with reply: Message) {
    guard
      let text = reply.blocks.first(where: { $0.kind == "text" })?.text?
        .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
      let row = items.lastIndex(where: {
        $0.role == "bot" && $0.runId != nil && $0.blocks.contains(where: \.plainQuestion)
      }), let slot = items[row].blocks.firstIndex(where: \.plainQuestion)
    else { return }
    items[row].blocks[slot].status = "answered"
    items[row].blocks[slot].answer = text
    items[row].blocks[slot].answerMessageId = reply.id
  }
}

/// The mobile app's error copy for an answer that failed.
enum AskErrorCopy {
  static let blocked =
    "This item is blocked for bots. Allow it in the Vault, or dismiss the request."
  static let unchosen =
    "This bot can't use this item. Change it in the Vault, or dismiss the request."
  /// A secret answer's refusal, or the fallback: its other errors could echo the value.
  static func secret(_ error: Error) -> String {
    let message = (error as? Failure)?.message ?? ""
    return [blocked, unchosen].contains(message) ? message : "Could not send answer"
  }
  /// The server's own words for a refusal, or the fallback for anything technical.
  static func text(_ error: Error, fallback: String) -> String {
    if error is URLError { return "Could not reach the server" }
    let message =
      (error as? Failure)?.message.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return message.isEmpty ? fallback : message
  }
}

// MARK: - Text entry traits

private enum SecretEntry {
  case password, oneTimeCode, noAutofill
  case cardNumber, cardExpiry, cardCode, cardName
  case name, street1, street2, city, region, postalCode, country, phone, email
}

extension View {
  /// The keyboard and AutoFill a protected or form field offers.
  @ViewBuilder fileprivate func secretEntry(_ entry: SecretEntry) -> some View {
    #if os(iOS)
      let content: UITextContentType? =
        switch entry {
        case .password: .password
        case .oneTimeCode: .oneTimeCode
        case .noAutofill: nil
        case .cardNumber: .creditCardNumber
        case .cardExpiry: .creditCardExpiration
        case .cardCode: .creditCardSecurityCode
        case .cardName: .creditCardName
        case .name: .name
        case .street1: .streetAddressLine1
        case .street2: .streetAddressLine2
        case .city: .addressCity
        case .region: .addressState
        case .postalCode: .postalCode
        case .country: .countryName
        case .phone: .telephoneNumber
        case .email: .emailAddress
        }
      let keyboard: UIKeyboardType =
        switch entry {
        case .cardNumber, .cardCode: .numberPad
        case .cardExpiry: .numbersAndPunctuation
        case .phone: .phonePad
        case .email: .emailAddress
        default: .default
        }
      let capitalized = [SecretEntry.cardName, .name, .street1, .street2, .city, .region, .country]
        .contains(entry)
      self.textContentType(content).keyboardType(keyboard)
        .textInputAutocapitalization(
          entry == .postalCode ? .characters : capitalized ? .words : .never
        )
        .autocorrectionDisabled()
    #else
      switch entry {
      case .password: self.textContentType(.password).autocorrectionDisabled()
      case .oneTimeCode: self.textContentType(.oneTimeCode).autocorrectionDisabled()
      default: self.autocorrectionDisabled()
      }
    #endif
  }
}

// MARK: - Sheet type

private enum SheetType {
  #if os(macOS)
    static let title = Font.system(size: 17, weight: .semibold)
    static let destination = Font.system(size: 13)
    static let note = Font.system(size: 11)
  #else
    static let title = Font.title3.weight(.semibold)
    static let destination = Font.subheadline
    static let note = Font.footnote
  #endif
}

// MARK: - Login sheet

private struct LoginField {
  var label: String
  var value: String
  var hidden: Bool
}

/// A website sign-in, typed or filled from saved passwords. The values live only in this sheet's
/// state and are cleared whether saving succeeds or fails, and before the sheet closes.
private struct LoginAskSheet: View {
  let title: String
  let destination: String
  let replacedSite: String?
  let loginFields: [String]?
  /// False once the card is answered or can no longer be answered; the sheet then closes.
  let pending: Bool
  let onClose: () -> Void
  /// `remember` is false when "Save to Vault" was turned off: the login is for this run only.
  let onSave: ([LoginField], Bool) async throws -> Void
  @State private var fields: [LoginField]
  @State private var remember = true
  @State private var error: String?
  @State private var submitting = false
  @State private var closing = false
  @FocusState private var focus: Int?

  init(
    title: String, destination: String, replacedSite: String?, loginFields: [String]?,
    pending: Bool, onClose: @escaping () -> Void,
    onSave: @escaping ([LoginField], Bool) async throws -> Void
  ) {
    self.title = title
    self.destination = destination
    self.replacedSite = replacedSite
    self.loginFields = loginFields
    self.pending = pending
    self.onClose = onClose
    self.onSave = onSave
    _fields = State(initialValue: Self.cardFields(loginFields))
  }

  private var labels: [String] { loginFields ?? ["Username", "Password"] }
  private var editable: Bool { !submitting && !closing }
  private var incomplete: Bool { !Self.valid(fields) }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: title).font(SheetType.title).lineLimit(2)
              .accessibilityAddTraits(.isHeader)
            Text(verbatim: destination).font(SheetType.destination).padding(.bottom, 8)
            if let replacedSite {
              Text("Replaces the login saved for \(replacedSite)").font(SheetType.note)
                .foregroundStyle(.secondary).padding(.top, -8).padding(.bottom, 8)
            }
          }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        }
        ForEach(fields.indices, id: \.self) { index in
          Section {
            field(index)
            Toggle("Hidden", isOn: $fields[index].hidden).disabled(!editable)
          }
        }
        Section {
          Toggle("Save to Vault", isOn: $remember).disabled(submitting || closing)
        }
        if let error {
          Section {
            Text(error).font(SheetType.note).foregroundStyle(.red)
          }.listRowBackground(Color.clear)
        }
      }.formStyle(.grouped).inlineMobileTitle()
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
          ToolbarItem(placement: .confirmationAction) {
            if submitting {
              ProgressView().controlSize(.small)
            } else {
              Button(remember ? "Save" : "Continue", action: save).disabled(incomplete)
            }
          }
        }
    }.integrationSheet()
      .defaultFocus($focus, 0)
      // Closing goes through Cancel while a field holds text, so the values are cleared first.
      .interactiveDismissDisabled(submitting || fields.contains { !$0.value.isEmpty })
      .onChange(of: pending, initial: true) { _, open in if !open { close() } }
  }

  @ViewBuilder private func field(_ index: Int) -> some View {
    let name = index < labels.count ? labels[index] : fields[index].label
    let last = index == fields.count - 1
    Group {
      if fields[index].hidden {
        SecureField(name, text: $fields[index].value)
      } else {
        TextField(name, text: $fields[index].value)
      }
    }.secretEntry(fields[index].hidden ? .password : .noAutofill)
      .focused($focus, equals: index).submitLabel(last ? .done : .next)
      .onSubmit { if last { save() } else { focus = index + 1 } }
      .disabled(!editable).accessibilityLabel(name)
  }

  private func clear() {
    for index in fields.indices { fields[index].value = "" }
  }

  /// Empties the fields before the sheet goes, so the system never offers to save them.
  private func close() {
    guard !closing else { return }
    closing = true
    clear()
    focus = nil
    Task {
      try? await Task.sleep(for: .milliseconds(150))
      onClose()
    }
  }

  private func save() {
    guard !submitting, !incomplete else { return }
    let answer = fields
    clear()
    submitting = true
    error = nil
    Task {
      defer { submitting = false }
      do { try await onSave(answer, remember) } catch { self.error = AskErrorCopy.secret(error) }
    }
  }

  /// The empty fields a login card starts with. The default Username and Password card starts
  /// Username visible; fields the bot names start hidden, except those whose label is made only
  /// of identifier words (ID number, phone, email).
  static func cardFields(_ requested: [String]?) -> [LoginField] {
    guard let requested else {
      return [
        .init(label: "Username", value: "", hidden: false),
        .init(label: "Password", value: "", hidden: true),
      ]
    }
    return requested.map { .init(label: $0, value: "", hidden: !LoginLabel.identifier($0)) }
  }

  /// Whether the fields make a login the server accepts: one to eight, each labeled, each with a
  /// value (a visible one trimmed), labels all different, and not too long in all.
  static func valid(_ fields: [LoginField]) -> Bool {
    guard (1...8).contains(fields.count) else { return false }
    var labels = Set<String>()
    var saved: [[String: Any]] = []
    for field in fields {
      let label = field.label.trimmingCharacters(in: .whitespacesAndNewlines)
      let value =
        field.hidden ? field.value : field.value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard (1...64).contains(label.utf16.count), field.value.utf16.count <= 4096,
        !value.isEmpty, labels.insert(label.lowercased()).inserted
      else { return false }
      saved.append(["label": label, "value": value, "hidden": field.hidden])
    }
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: ["fields": saved], options: .withoutEscapingSlashes),
      let json = String(data: data, encoding: .utf8)
    else { return false }
    return json.utf16.count <= 16_384
  }
}

/// Whether a login field's label names an identifier, which a sign-in without a password field
/// needs typed into a text field. English and Hebrew.
private enum LoginLabel {
  static let identifiers: Set<String> = [
    "id", "user", "username", "login", "email", "mail", "phone", "mobile", "cell", "tel",
    "telephone", "account", "member", "customer", "זהות", "תז", "טלפון", "נייד", "פלאפון",
    "סלולרי", "מייל", "אימייל", "דואל", "משתמש", "חשבון", "לקוח", "חבר",
  ]
  static let fillers: Set<String> = [
    "number", "no", "num", "name", "address", "or", "and", "of", "your", "the", "last", "first",
    "digit", "digits", "national", "tax", "employee", "e", "תעודת", "מספר", "שם", "כתובת", "או",
    "של", "ו", "אחרונות", "ספרות", "לאומי", "עובד", "מס",
  ]

  static func words(_ label: String) -> [String] {
    let plain = label.precomposedStringWithCompatibilityMapping
      .decomposedStringWithCanonicalMapping
      .replacingOccurrences(of: #"[\p{M}\p{Cf}]"#, with: "", options: .regularExpression)
      .lowercased()
    // Spaces and punctuation separate words; any other symbol or emoji is a word of its own.
    guard
      let pattern = try? NSRegularExpression(
        pattern: #"[\p{L}\p{N}.'"׳״]+|[^\p{L}\p{N}\p{Z}\s\p{P}№]"#)
    else { return [] }
    let text = plain as NSString
    return pattern.matches(in: plain, range: NSRange(location: 0, length: text.length)).map {
      text.substring(with: $0.range).replacingOccurrences(
        of: #"[.'"׳״]"#, with: "", options: .regularExpression)
    }.filter { !$0.isEmpty }
  }

  static func known(_ word: String, _ set: Set<String>) -> Bool {
    // Hebrew attaches "the" to a word: הטלפון.
    set.contains(word) || (word.hasPrefix("ה") && set.contains(String(word.dropFirst())))
  }

  static func identifier(_ label: String) -> Bool {
    let words = words(label)
    return words.contains { known($0, identifiers) }
      && words.allSatisfy {
        $0.range(of: #"^\p{N}+$"#, options: .regularExpression) != nil
          || known($0, identifiers) || known($0, fillers)
      }
  }
}

// MARK: - Card and contact sheet

/// A card or contact a bot asked for. The protected values live only in this sheet's state and
/// are cleared on save and before it closes; the item saves under the name the bot gave it.
private struct ItemAskSheet: View {
  let card: Bool
  let title: String
  let onClose: () -> Void
  let onSave: (String) async throws -> Void
  @State var number = ""
  @State var expiry = ""
  @State var cvc = ""
  @State var cardName = ""
  @State var contact: [String: String] = [:]
  @State var error: String?
  @State var submitting = false
  @State var closing = false

  private static let contactFields: [(key: String, label: String, max: Int, entry: SecretEntry)] =
    [
      ("name", "Full name", 200, .name), ("line1", "Address", 200, .street1),
      ("line2", "Address line 2", 200, .street2), ("city", "City", 100, .city),
      ("region", "State or region", 100, .region),
      ("postalCode", "ZIP or postal code", 20, .postalCode), ("country", "Country", 100, .country),
      ("phone", "Phone", 40, .phone), ("email", "Email", 254, .email),
    ]

  private var editable: Bool { !submitting && !closing }
  private var value: String? { card ? cardValue : contactValue }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Text(verbatim: title).font(SheetType.title).lineLimit(2)
            .accessibilityAddTraits(.isHeader)
            .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        }
        if card { cardSection } else { contactSection }
        if let error {
          Section {
            Text(error).font(SheetType.note).foregroundStyle(.red)
          }.listRowBackground(Color.clear)
        }
      }.formStyle(.grouped).inlineMobileTitle()
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: close).disabled(submitting)
          }
          ToolbarItem(placement: .confirmationAction) {
            if submitting {
              ProgressView().controlSize(.small)
            } else {
              Button("Save", action: submit).disabled(value == nil)
            }
          }
        }
    }.integrationSheet()
      // A save in flight keeps the sheet open, so its failure is still shown here; closing goes
      // through Cancel while a protected value is typed, so it is cleared first.
      .interactiveDismissDisabled(submitting || !number.isEmpty || !cvc.isEmpty)
  }

  private var cardSection: some View {
    Section {
      HStack(alignment: .lastTextBaseline) {
        entry("Card number", $number, .cardNumber)
        if let brand = Self.typedBrand(number) {
          Text(brand).font(SheetType.note).foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 12) {
        entry("Expiry", $expiry, .cardExpiry, placeholder: "MM/YY")
        Divider()
        entry("Security code", $cvc, .cardCode, secure: true)
      }
      entry("Name on card", $cardName, .cardName)
    }
  }

  private var contactSection: some View {
    Section {
      let fields = Self.contactFields
      contactEntry(fields[0])
      contactEntry(fields[1])
      contactEntry(fields[2])
      HStack(spacing: 12) {
        contactEntry(fields[3])
        Divider()
        contactEntry(fields[4])
      }
      HStack(spacing: 12) {
        contactEntry(fields[5])
        Divider()
        contactEntry(fields[6])
      }
      contactEntry(fields[7])
      contactEntry(fields[8])
    }
  }

  private func contactEntry(_ field: (key: String, label: String, max: Int, entry: SecretEntry))
    -> some View
  {
    entry(
      field.label,
      Binding(get: { contact[field.key] ?? "" }, set: { contact[field.key] = $0 }), field.entry)
  }

  private func entry(
    _ label: String, _ text: Binding<String>, _ kind: SecretEntry, placeholder: String? = nil,
    secure: Bool = false
  ) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(SheetType.note).foregroundStyle(.secondary)
      Group {
        if secure {
          SecureField(label, text: text, prompt: placeholder.map { Text($0) })
        } else {
          TextField(label, text: text, prompt: placeholder.map { Text($0) })
        }
      }.labelsHidden().textFieldStyle(.plain).secretEntry(kind).disabled(!editable)
        .accessibilityLabel(label)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }

  private func clear() {
    number = ""
    cvc = ""
  }

  private func close() {
    guard !closing else { return }
    closing = true
    clear()
    Task {
      try? await Task.sleep(for: .milliseconds(150))
      onClose()
    }
  }

  private func submit() {
    guard !submitting, let value else { return }
    clear()
    submitting = true
    error = nil
    Task {
      defer { submitting = false }
      do {
        try await onSave(value)
        close()
      } catch { self.error = AskErrorCopy.secret(error) }
    }
  }

  /// The card as the vault saves it, or nil while the form doesn't make one: a number that passes
  /// the issuers' check, an expiry, and a security code of 3 or 4 digits when there is one.
  private var cardValue: String? {
    let digits = number.replacingOccurrences(of: #"[\s-]"#, with: "", options: .regularExpression)
    let code = cvc.trimmingCharacters(in: .whitespacesAndNewlines)
    let holder = cardName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard digits.range(of: "^[0-9]{12,19}$", options: .regularExpression) != nil,
      Self.luhn(digits), let expiry = Self.parseExpiry(expiry),
      (2000...2100).contains(expiry.year),
      code.range(of: "^([0-9]{3,4})?$", options: .regularExpression) != nil,
      holder.utf16.count <= 200
    else { return nil }
    var card: [String: Any] = [
      "number": digits, "expMonth": expiry.month, "expYear": expiry.year,
    ]
    if !code.isEmpty { card["cvc"] = code }
    if !holder.isEmpty { card["name"] = holder }
    return Self.json(card)
  }

  /// The contact as the vault saves it: every field optional, but at least one filled in.
  private var contactValue: String? {
    var fields: [String: Any] = [:]
    for field in Self.contactFields {
      let text = (contact[field.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard text.utf16.count <= field.max else { return nil }
      if !text.isEmpty { fields[field.key] = text }
    }
    return fields.isEmpty ? nil : Self.json(fields)
  }

  private static func json(_ object: [String: Any]) -> String? {
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: .withoutEscapingSlashes)
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  /// Whether a card number passes the Luhn check every issuer's numbers do.
  static func luhn(_ digits: String) -> Bool {
    var sum = 0
    for (index, character) in digits.reversed().enumerated() {
      guard var digit = character.wholeNumberValue else { return false }
      if index % 2 == 1 {
        digit *= 2
        if digit > 9 { digit -= 9 }
      }
      sum += digit
    }
    return sum % 10 == 0
  }

  /// An expiry as people type it ("08/28", "8/2028", "0828") as a month and four-digit year.
  static func parseExpiry(_ text: String) -> (month: Int, year: Int)? {
    let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let pattern = try? NSRegularExpression(
        pattern: #"^([0-9]{1,2})\s*(?:[/\-.]\s*)?([0-9]{2}|[0-9]{4})$"#),
      let match = pattern.firstMatch(
        in: typed, range: NSRange(location: 0, length: (typed as NSString).length)),
      let month = Int((typed as NSString).substring(with: match.range(at: 1))),
      let year = Int((typed as NSString).substring(with: match.range(at: 2))),
      (1...12).contains(month)
    else { return nil }
    return (month, year < 100 ? 2000 + year : year)
  }

  /// The network a typed number belongs to, once there are enough digits to tell.
  static func typedBrand(_ number: String) -> String? {
    let digits = number.filter(\.isASCII).filter(\.isNumber)
    guard digits.count >= 2 else { return nil }
    let brands: [(String, String)] = [
      ("^4", "Visa"), ("^(5[1-5]|222[1-9]|22[3-9]|2[3-6]|27[01]|2720)", "Mastercard"),
      ("^3[47]", "Amex"), ("^(6011|65|64[4-9]|622)", "Discover"),
      ("^3(0[0-5]|[68])", "Diners Club"), ("^35(2[89]|[3-8])", "JCB"), ("^62", "UnionPay"),
    ]
    return brands.first { digits.range(of: $0.0, options: .regularExpression) != nil }?.1
  }
}
