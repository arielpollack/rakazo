import SwiftUI

/// A helper, cloud agent or new bot named in the chat, drawn as the mobile app draws it: a helper
/// as an expandable card, a cloud agent as a card that opens its pull request or run, and a new
/// bot as its name in its own color.
struct SpecialMessageCard: View {
  let block: Message.Block
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void

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

  var body: some View {
    switch block.kind {
    case "subagent":
      HelperCard(
        helper: helper, stop: stopTarget, store: store, refresh: refresh, report: report
      ).id(helper.agentId)
    case "cloud_agent": CloudAgentCard(agent: cloudAgent)
    case "child_bot": ChildBotLine(bot: childBot, store: store)
    default: EmptyView()
    }
  }

  private var helper: HelperFields {
    block.fields(HelperFields.self)
      ?? HelperFields(
        agentId: message.id, name: block.name ?? "", task: block.task ?? "",
        status: block.status ?? "running", progress: block.progress, result: block.result)
  }

  /// A saved running card is a background helper's, which Stop names; a live one belongs to this
  /// turn.
  private var stopTarget: [String: Any]? {
    guard let bot = message.botId, !message.id.hasPrefix("subagent:") else { return nil }
    return ["botId": bot, "messageId": message.id]
  }

  private var cloudAgent: CloudAgentFields {
    block.fields(CloudAgentFields.self)
      ?? CloudAgentFields(title: block.title ?? "", status: block.status ?? "running", url: "")
  }

  private var childBot: ChildBotFields {
    block.fields(ChildBotFields.self)
      ?? ChildBotFields(
        botId: block.botId ?? "", name: block.name ?? "", status: block.status ?? "created")
  }
}

private struct HelperFields: Decodable {
  let agentId: String
  let name: String
  let task: String
  let status: String
  var progress: String?
  var result: String?
}

private struct CloudAgentFields: Decodable {
  let title: String
  let status: String
  let url: String
  var branch: String?
  var prUrl: String?
}

private struct ChildBotFields: Decodable {
  let botId: String
  let name: String
  let status: String
}

/// The mobile app's warning token, for work still under way.
private let warning = PlatformColor.pair(0x885A07, 0xDB941E)

/// Cards remembered open by agent id: a running helper's live card and the saved message that
/// replaces it have different ids, so its row appears again when the helper finishes.
@MainActor private enum OpenHelpers {
  static var ids = Set<String>()
}

private struct HelperCard: View {
  let helper: HelperFields
  /// The bot chat and card message Stop names, for a background helper.
  let stop: [String: Any]?
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void
  @State private var open: Bool
  @State private var stopping = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  init(
    helper: HelperFields, stop: [String: Any]?, store: WorkspaceStore,
    refresh: @escaping () async throws -> Void, report: @escaping (String) -> Void
  ) {
    self.helper = helper
    self.stop = stop
    self.store = store
    self.refresh = refresh
    self.report = report
    _open = State(initialValue: OpenHelpers.ids.contains(helper.agentId))
  }

  private var running: Bool { helper.status == "running" }
  /// A stopped helper settles as failed but did not fail, and shows no body.
  private var stopped: Bool { helper.status == "failed" && helper.result == "stopped" }
  private var failed: Bool { helper.status == "failed" && !stopped }
  /// Its result, or its progress while it works.
  private var resultText: String {
    guard !stopped else { return "" }
    if let result = helper.result, !result.isEmpty { return result }
    return helper.progress ?? ""
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: toggle) {
        VStack(alignment: .leading, spacing: 0) {
          HStack(spacing: Layout.Space.small) {
            Text(verbatim: SpecialNames.display(helper.name, fallback: "subagent"))
              .font(CardType.title).foregroundStyle(.primary)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(statusLabel).font(CardType.caption).foregroundStyle(statusColor)
            Image(systemName: "chevron.down").font(.system(size: 12))
              .foregroundStyle(.secondary).rotationEffect(.degrees(open ? 180 : 0))
              .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: open)
              .accessibilityHidden(true)
          }
          if !helper.task.isEmpty {
            Text(verbatim: helper.task).font(CardType.secondary).foregroundStyle(.secondary)
              .lineLimit(open ? nil : 1).frame(maxWidth: .infinity, alignment: .leading)
              .fixedSize(horizontal: false, vertical: open)
              .padding(.top, Layout.Space.small)
          }
        }.padding(.horizontal, Layout.Space.standard).padding(.vertical, 14)
          .frame(maxWidth: .infinity, minHeight: Layout.touch, alignment: .leading)
          .contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
      if running, stop != nil, store.client != nil {
        Button(action: stopHelper) {
          if stopping {
            ProgressView().controlSize(.small)
          } else {
            Text("Stop")
          }
        }.buttonStyle(CardButton(primary: false)).fixedSize().disabled(stopping)
          .padding(.horizontal, Layout.Space.standard).padding(.bottom, 14)
      }
      if open, !resultText.isEmpty {
        MessageText(content: resultText).equatable()
          .padding(.horizontal, Layout.Space.standard).padding(.bottom, 14).padding(.top, -6)
      }
    }.chatCard(padded: false)
  }

  private var statusLabel: String {
    if running { return "Running" }
    if stopped { return "Stopped" }
    if helper.status == "failed" { return "Failed" }
    if helper.status == "completed" { return "Completed" }
    return helper.status
  }

  private var statusColor: Color {
    if failed { return .red }
    if running { return warning }
    if stopped { return .secondary }
    return .green
  }

  private func toggle() {
    if open {
      OpenHelpers.ids.remove(helper.agentId)
    } else {
      OpenHelpers.ids.insert(helper.agentId)
    }
    open.toggle()
  }

  /// The card settles from the chat's events once the helper stops, so a stop that went through
  /// stays busy until then.
  private func stopHelper() {
    guard !stopping, let api = store.client, let stop else { return }
    stopping = true
    Task {
      do {
        let _: Empty = try await api.rpc("threads/stopHelper", stop)
        try await refresh()
      } catch {
        stopping = false
        report(error.localizedDescription)
      }
    }
  }
}

private struct CloudAgentCard: View {
  let agent: CloudAgentFields
  @Environment(\.openURL) private var openURL

  private var title: String { agent.title.isEmpty ? "Cloud agent" : agent.title }
  private var statusLabel: String {
    switch agent.status {
    case "running": "running"
    case "finished": "finished"
    case "cancelled": "cancelled"
    case "expired": "expired"
    default: "failed"
    }
  }
  private var running: Bool { agent.status == "running" }
  private var failed: Bool { agent.status != "running" && agent.status != "finished" }
  private var pullRequest: URL? { Self.https(agent.prUrl) }
  private var destination: URL? { pullRequest ?? Self.https(agent.url) }

  var body: some View {
    Button {
      if let destination { openURL(destination) }
    } label: {
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top, spacing: Layout.Space.small) {
          Text(verbatim: title).font(CardType.title).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 0)
          Text(statusLabel).font(CardType.caption)
            .foregroundStyle(failed ? .red : running ? warning : .green)
        }
        if pullRequest != nil {
          Text("Pull request").font(CardType.secondary).foregroundStyle(.secondary)
            .padding(.top, Layout.Space.small)
        } else if let branch = agent.branch, !branch.isEmpty {
          Text(verbatim: branch).font(CardType.secondary).foregroundStyle(.secondary)
            .padding(.top, Layout.Space.small)
        }
      }.chatCard().contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }.buttonStyle(.plain).disabled(destination == nil)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("\(title): \(statusLabel)")
      .accessibilityAddTraits(destination == nil ? [] : .isLink)
      .accessibilityRemoveTraits(destination == nil ? .isButton : [])
  }

  /// The address as given when it is https without credentials in it.
  static func https(_ value: String?) -> URL? {
    guard let value, !value.isEmpty, let parts = URLComponents(string: value),
      parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false, parts.user == nil,
      parts.password == nil
    else { return nil }
    return URL(string: value)
  }
}

/// A bot named inline in its color, opening its chat. A deleted, archived or missing bot keeps
/// only its name.
private struct ChildBotLine: View {
  let bot: ChildBotFields
  @ObservedObject var store: WorkspaceStore

  /// The bot as the workspace knows it, or as a group lists it.
  private var known: Chat? {
    if let chat = store.navigation?.current.bots.first(where: { $0.id == bot.botId }) {
      return chat
    }
    for group in store.navigation?.current.groups ?? [] {
      if let member = group.members?.first(where: { $0.botId == bot.botId }) {
        return Chat(
          id: bot.botId, name: member.name ?? bot.name, color: member.color,
          avatarSet: member.avatarSet)
      }
    }
    return nil
  }
  /// The chat a tap opens, while the bot is still in the sidebar.
  private var openable: Chat? {
    store.navigation?.current.chats.first { $0.id == bot.botId && !$0.isGroup }
  }

  var body: some View {
    let look = known
    let live = bot.status == "created" && look?.color != nil
    HStack(alignment: .center, spacing: 5) {
      Group {
        if live, let look {
          Avatar(chat: look, size: 16)
        } else {
          Image(systemName: "person").font(.system(size: 14)).foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
      }.frame(width: 16, height: 16)
      (Text(verbatim: bot.name).fontWeight(.medium)
        .foregroundColor(live ? look?.tint : .primary)
        + Text(suffix).foregroundColor(.secondary))
        .font(CardType.body)
    }.padding(.horizontal, Layout.Space.tight)
      .contentShape(Rectangle())
      .onTapGesture {
        if live, let openable { store.choose(openable) }
      }
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(live ? .isLink : [])
  }

  private var suffix: String {
    switch bot.status {
    case "archived": " archived"
    case "deleted": " deleted"
    default: ""
    }
  }
}

/// A name for display, else the fallback when it is empty, punctuation only, or an id.
enum SpecialNames {
  static func display(_ name: String?, fallback: String) -> String {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty, matches(trimmed, #"[\p{L}\p{N}]"#), !opaque(trimmed) else {
      return fallback
    }
    return trimmed
  }

  /// Complete tokens only, never substrings of prose or short handles.
  static func opaque(_ name: String) -> Bool {
    if matches(name, #"^__[A-Za-z0-9_-]+__$"#) { return true }
    if matches(name, #"^[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"#) { return true }
    // Cuid v1 has a fixed prefix and length; cuid2 is 24 lowercase alphanumerics.
    let digit = matches(name, "[0-9]")
    if digit && (matches(name, "^c[a-z0-9]{24}$") || matches(name, "^[a-z][a-z0-9]{23}$")) {
      return true
    }
    // Interspersed digits and unstructured casing; numbered words and handles stay names.
    return matches(name, "^[A-Za-z0-9_-]{20,}$") && matches(name, "[a-z]")
      && matches(name, "[A-Z]") && digit && !matches(name, "^[A-Za-z_-]+[0-9]+$")
      && !matches(name, "^[A-Za-z][a-z]*(?:[A-Z][a-z]+|[0-9]|[_-][A-Za-z][a-z]+)*$")
  }

  private static func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
  }
}
