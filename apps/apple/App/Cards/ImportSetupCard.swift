import SwiftUI

/// What a new bot still needs, as the mobile app's import setup card lists it. Model keys and
/// routines to turn on open their web screens; servers and skills are finished on the web.
struct ImportSetupCard: View {
  let block: Message.Block
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void
  @State private var state: SetupState?
  @Environment(\.scenePhase) private var phase
  @Environment(\.openURL) private var openURL

  init(
    block: Message.Block, message: Message, chat: Chat, store: WorkspaceStore,
    refresh: @escaping () async throws -> Void, report: @escaping (String) -> Void
  ) {
    self.block = block
    self.message = message
    self.chat = chat
    self.store = store
    self.refresh = refresh
    self.report = report
  }

  private var botId: String? { message.botId ?? (chat.isGroup ? nil : chat.id) }

  var body: some View {
    let items = block.fields(Fields.self)?.items ?? []
    // Undo empties the checklist as well as marking it, so older clients hide it too.
    if block.undone != true && !items.isEmpty {
      Group {
        if let state, items.allSatisfy({ $0.done(in: state) == true }) {
          HStack(spacing: Layout.Space.small) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
              .foregroundStyle(.green).accessibilityHidden(true)
            Text("Setup complete").font(CardType.secondary).foregroundStyle(.primary)
          }
        } else {
          VStack(alignment: .leading, spacing: Layout.Space.tight) {
            Text("Finish setting up").font(CardType.title).foregroundStyle(.primary)
              .accessibilityAddTraits(.isHeader)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in row(item) }
          }
        }
      }.chatCard().frame(maxWidth: 340, alignment: .leading)
        // Read again on return from a screen it opened, and when the thread brings a new block.
        .task(id: Reload(block: block.wire?.value, active: phase == .active)) {
          guard phase == .active else { return }
          await load(items)
        }
    }
  }

  private func row(_ item: Item) -> some View {
    let done = state.flatMap { item.done(in: $0) } == true
    let detail = [item.detail, item.verifiable ? "" : "Check this yourself"].filter { !$0.isEmpty }
      .joined(separator: " · ")
    return HStack(spacing: Layout.Space.medium) {
      VStack(alignment: .leading, spacing: 1) {
        Text(verbatim: item.displayName).font(CardType.secondary).foregroundStyle(.primary)
          .lineLimit(1)
        if !detail.isEmpty {
          Text(verbatim: detail).font(CardType.secondary).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      if done {
        Image(systemName: "checkmark").font(.system(size: 16)).foregroundStyle(.green)
          .accessibilityLabel("Done")
      } else if let url = target(item) {
        Button("Open") { openURL(url) }.buttonStyle(CardButton(primary: false)).fixedSize()
          .accessibilityLabel("Open \(item.displayName)")
      }
    }.padding(.vertical, 6).frame(minHeight: 48)
  }

  /// Model keys open Models settings and a routine opens its editor, both on the web: the native
  /// app has neither screen. Servers and skills have no button.
  private func target(_ item: Item) -> URL? {
    switch item.kind {
    case "model":
      return store.link(chat, query: [.init(name: "settings", value: "models")])
    case "routine":
      guard let botId, let routine = item.routineId else { return nil }
      let bot = store.navigation?.current.bots.first { $0.id == botId } ?? Chat(id: botId, name: "")
      return store.link(bot, query: [.init(name: "routine", value: routine)])
    default: return nil
    }
  }

  private func load(_ items: [Item]) async {
    guard let api = store.client, let botId else { return }
    var providers: [String] = []
    var serverIds: [String] = []
    var routineIds: [String] = []
    for item in items {
      switch item.kind {
      case "model": providers.append(item.provider ?? "")
      case "mcp": serverIds.append(item.serverId ?? "")
      case "routine": routineIds.append(item.routineId ?? "")
      default: break
      }
    }
    let body: [String: Any] = [
      "botId": botId, "providers": providers, "serverIds": serverIds, "routineIds": routineIds,
    ]
    // As on mobile, a failed read keeps what was last seen: rows simply show no checkmark.
    if let read: SetupState = try? await api.rpc("bots/importSetupState", body) { state = read }
  }

  private struct Reload: Equatable {
    let block: JSONValue?
    let active: Bool
  }

  private struct Fields: Decodable { let items: [Item] }

  /// `bots/importSetupState`: whether each checkable item is done. A server can also be
  /// `unverifiable`, which never counts as done.
  struct SetupState: Decodable {
    let providers: [String: Bool]
    let serverIds: [String: JSONValue]
    let routineIds: [String: Bool]
  }

  /// One row of the checklist: a model key, a server, a routine or a skill.
  struct Item: Decodable {
    let kind: String
    var title: String?, name: String?, provider: String?, providerName: String?
    var serverId: String?, routineId: String?
    var needs: [Need]?

    var displayName: String { (kind == "model" ? title : name) ?? "" }
    /// Skills, and servers that need a program or local paths, cannot be checked by Rakazo; such
    /// rows are never shown as done.
    var verifiable: Bool {
      if kind == "skill" { return false }
      if kind != "mcp" { return true }
      return !(needs ?? []).contains { $0.kind == "program" || $0.kind == "local_paths" }
    }
    /// Nil when it cannot be checked.
    func done(in state: SetupState) -> Bool? {
      guard verifiable else { return nil }
      switch kind {
      case "model": return state.providers[provider ?? ""] == true
      case "mcp": return state.serverIds[serverId ?? ""] == .bool(true)
      case "routine": return state.routineIds[routineId ?? ""] == true
      default: return nil
      }
    }
    /// The row's second line: what it still needs.
    var detail: String {
      switch kind {
      case "model": return Need(kind: "api_key", provider: providerName ?? provider).text ?? ""
      case "routine": return Need(kind: "turn_on").text ?? ""
      default: return (needs ?? []).compactMap(\.text).joined(separator: ", ")
      }
    }
  }

  /// What an item needs, worded as the web checklist words it.
  struct Need: Decodable {
    let kind: String
    var provider: String?
    var names: [String]?
    var name: String?

    var text: String? {
      let names = (names ?? []).joined(separator: ", ")
      switch kind {
      case "api_key": return "API key for \(provider ?? "")"
      case "credentials": return "Credentials: \(names)"
      case "env": return "Environment variables: \(names)"
      case "program": return "Program: \(name ?? "")"
      case "local_paths": return "Uses paths on your computer"
      case "requires": return "Needs: \(names)"
      case "turn_on": return "Paused"
      case "webhook": return "Point its source at the new webhook"
      case "email_address": return "Needs an email address"
      case "chat_app": return "Connect it to \(provider ?? "")"
      case "bundled_files": return "Uses files that are not imported"
      default: return nil
      }
    }
  }
}
