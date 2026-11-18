import Combine
import Foundation

@MainActor final class AppSession: ObservableObject {
  @Published var workspace: WorkspaceStore?
  @Published var launchError: String?
  private var inMemoryOnly = false
  init() {
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("--test-sample") {
        workspace = WorkspaceStore(sample: .initial, persistent: false)
        return
      }
      if ProcessInfo.processInfo.arguments.contains("--test-login") { return }
    #endif
    if UserDefaults.standard.bool(forKey: "sample.active") {
      enterSample()
      return
    }
    do {
      if let login = try Vault.read() {
        workspace = WorkspaceStore(login: login)
        return
      }
    } catch {
      launchError = error.localizedDescription
      return
    }
  }
  func enterSample() {
    var sample =
      UserDefaults.standard.data(forKey: "sample.workspace").flatMap {
        try? JSONDecoder().decode(Sample.self, from: $0)
      } ?? .initial
    sample.includeWalkthrough()
    workspace = WorkspaceStore(sample: sample, persistent: true)
    UserDefaults.standard.set(true, forKey: "sample.active")
  }
  func connect(_ login: Login, remember: Bool = true) throws {
    if remember { try Vault.save(login) }
    inMemoryOnly = !remember
    launchError = nil
    UserDefaults.standard.removeObject(forKey: "sample.active")
    workspace = WorkspaceStore(login: login)
  }
  func leave() async throws {
    guard let previous = workspace else { return }
    if let client = previous.client {
      var unscoped = client
      unscoped.space = nil
      _ = try await unscoped.post("api/auth/sign-out", [:])
      if !inMemoryOnly { try Vault.clear() }
    }
    workspace = nil
    inMemoryOnly = false
    UserDefaults.standard.removeObject(forKey: "sample.active")
  }
  func forget() throws {
    if !inMemoryOnly, workspace?.demo != true { try Vault.clear() }
    inMemoryOnly = false
    workspace = nil
    launchError = nil
    UserDefaults.standard.removeObject(forKey: "sample.active")
  }
}

@MainActor final class WorkspaceStore: ObservableObject, Identifiable {
  let id = UUID()
  let login: Login?
  let persistent: Bool
  @Published var sample: Sample? {
    didSet {
      if persistent, let sample, let data = try? JSONEncoder().encode(sample) {
        UserDefaults.standard.set(data, forKey: "sample.workspace")
      }
    }
  }
  @Published var account: Account?
  @Published var navigation: NavigationData?
  @Published var selected: String? { didSet { if oldValue != selected { anchorMessage = nil } } }
  @Published var anchorMessage: String?
  @Published var error: String?
  @Published var sampleLeases: [String: UUID] = [:]
  var drafts: [String: String] = [:]
  private var generation = UUID()
  var demo: Bool { login == nil }
  var chat: Chat? { navigation?.current.chats.first { $0.id == selected } }
  var client: Client? {
    login.map { Client(server: $0.server, token: $0.token, space: navigation?.current.id) }
  }
  init(login: Login) {
    self.login = login
    self.persistent = false
  }
  init(sample: Sample, persistent: Bool) {
    self.login = nil
    self.persistent = persistent
    self.sample = sample
    self.account = Sample.account
    useSampleSpace(sample.spaces[0].id)
  }
  private func useSampleSpace(_ id: String) {
    guard let sample, let current = sample.spaces.first(where: { $0.id == id }) else { return }
    if navigation?.current.id != id { sampleLeases.removeAll() }
    navigation = NavigationData(
      current: current, spaces: sample.spaces.map { Named(id: $0.id, name: $0.name) })
  }
  func load(space: String? = nil) async throws {
    if demo {
      useSampleSpace(space ?? navigation?.current.id ?? "local")
      if !containsSelected { selected = nil }
      return
    }
    guard let login else { return }
    let ticket = UUID()
    generation = ticket
    let api = Client(
      server: login.server, token: login.token, space: space ?? navigation?.current.id)
    async let nav: NavigationData = api.rpc("spaces/list")
    async let user: Account = api.rpc("me")
    let (next, me) = try await (nav, user)
    try Task.checkCancellation()
    guard generation == ticket else { return }
    let changed = navigation?.current.id != next.current.id
    navigation = next
    account = me
    if changed || !containsSelected {
      selected = nil
      anchorMessage = nil
    }
    error = nil
  }
  private var containsSelected: Bool {
    navigation?.current.chats.contains { $0.id == selected } == true
  }
  func choose(_ chat: Chat) {
    anchorMessage = nil
    selected = chat.id
  }
  func update(
    _ chat: Chat, name: String? = nil, description: String? = nil, instructions: String? = nil,
    pinned: Bool? = nil, members: [String]? = nil
  ) async throws {
    guard let space = navigation?.current.id else { throw Failure("No active workspace.") }
    var input = chat.target
    if let name { input["name"] = name }
    if let description { input["description"] = description }
    if let instructions {
      input["instructions"] = instructions
      input["expectedInstructions"] = chat.instructions ?? ""
    }
    if let pinned { input["pinned"] = pinned }
    var newRoster: [Chat.Member]?
    if let members {
      guard let original = chat.members, Set(members).count == members.count,
        (2...10).contains(members.count), let spaceBots = navigation?.current.bots
      else { throw Failure("Choose 2 to 10 different bots.") }
      input["botIds"] = members
      input["expectedBotIds"] = original.compactMap(\.botId)
      newRoster = try members.map { id in
        if let member = original.first(where: { $0.botId == id }) { return member }
        guard let bot = spaceBots.first(where: { $0.id == id && $0.archivedAt == nil }) else {
          throw Failure("That bot is no longer available.")
        }
        return Chat.Member(botId: bot.id, name: bot.name, color: bot.color)
      }
    }
    guard input.count > 1 else { return }
    if let api = client {
      let _: Empty = try await api.rpc(chat.isGroup ? "groups/update" : "bots/update", input)
    }
    guard navigation?.current.id == space else { return }
    modifyChat(chat) { current in
      if let name { current.name = name }
      if let description { current.description = description }
      if let instructions { current.instructions = instructions }
      if let pinned { current.pinned = pinned }
      if let newRoster { current.members = newRoster }
    }
  }
  func mark(_ chat: Chat, unread: Bool, from messageID: String? = nil) async throws {
    let space = navigation?.current.id
    if let api = client {
      var input = chat.target
      if unread { input["messageId"] = messageID }
      let _: Empty = try await api.rpc(unread ? "threads/markUnread" : "threads/markRead", input)
    }
    guard space == navigation?.current.id else { return }
    modifyChat(chat) { $0.unread = unread }
  }
  private func modifyChat(_ chat: Chat, _ change: (inout Chat) -> Void) {
    guard var nav = navigation else { return }
    let key = chat.isGroup ? \Workspace.groups : \Workspace.bots
    guard let index = nav.current[keyPath: key].firstIndex(where: { $0.id == chat.id }) else {
      return
    }
    change(&nav.current[keyPath: key][index])
    navigation = nav
    if var local = sample, let index = local.spaces.firstIndex(where: { $0.id == nav.current.id }) {
      local.spaces[index] = nav.current
      sample = local
    }
  }
  func draftKey(_ chat: Chat) -> String { "\(navigation?.current.id ?? "")/\(chat.id)" }
  func create(name: String, description: String, members: [String]?, privateSpace: Bool)
    async throws
  {
    guard let space = navigation?.current.id else { return }
    if var local = sample, let index = local.spaces.firstIndex(where: { $0.id == space }) {
      let id = UUID().uuidString
      if privateSpace {
        local.spaces.append(.init(id: id, name: name, bots: [], groups: [], botSections: []))
        sample = local
        useSampleSpace(id)
        selected = nil
        return
      }
      let chat = Chat(
        id: id, name: name, color: "#2A92FE", description: description,
        updatedAt: Date.now.ISO8601Format(), members: members?.map { Chat.Member(botId: $0) })
      if members == nil {
        local.spaces[index].bots.append(chat)
      } else {
        local.spaces[index].groups.append(chat)
      }
      sample = local
      useSampleSpace(space)
      selected = id
    } else if let api = client {
      if privateSpace {
        let created: ObjectID = try await api.rpc("spaces/create", ["name": name])
        try await load(space: created.id)
        return
      }
      let created: ObjectID
      if let members {
        created = try await api.rpc("groups/create", ["name": name, "botIds": members])
      } else {
        created = try await api.rpc("bots/create", ["name": name, "description": description])
      }
      try await load()
      if navigation?.current.id == space { selected = created.id }
    }
  }
  func snapshot(_ chat: Chat) async throws -> ThreadData {
    if let api = client { return try await api.rpc("threads/get", chat.target) }
    return ThreadData(threadId: chat.id, messages: sample?.transcripts[chat.id] ?? [], cursor: 0)
  }
  func demoSend(
    _ text: String, files: [Upload], chat: Chat, reply: Message?, excerpt: String? = nil
  ) {
    guard var local = sample, let space = navigation?.current.id,
      let index = local.spaces.firstIndex(where: { $0.id == space })
    else { return }
    var items = local.transcripts[chat.id] ?? []
    var message = Sample.message((items.last?.seq ?? 0) + 1, "user", text)
    message.blocks =
      (text.isEmpty ? [] : message.blocks)
      + files.map { Message.Block(kind: "file", name: $0.name) }
    if let reply {
      message.replyPreview = .init(text: reply.text)
      message.replyToMessageId = reply.id
      message.replyQuote = excerpt
    }
    items.append(message)
    items.append(
      Sample.message(
        message.seq + 1, "bot",
        "Saved in this sample workspace. Connect your server for a live bot reply."))
    local.transcripts[chat.id] = items
    if chat.isGroup, let row = local.spaces[index].groups.firstIndex(where: { $0.id == chat.id }) {
      local.spaces[index].groups[row].preview = items.last?.text
      local.spaces[index].groups[row].updatedAt = message.createdAt
    } else if let row = local.spaces[index].bots.firstIndex(where: { $0.id == chat.id }) {
      local.spaces[index].bots[row].preview = items.last?.text
      local.spaces[index].bots[row].updatedAt = message.createdAt
    }
    sample = local
    useSampleSpace(space)
  }
  func react(_ emoji: String, to parent: Message, chat: Chat, nonce: String) async throws {
    guard TranscriptRows.emoji.contains(emoji), !parent.id.hasPrefix("progress:"),
      !parent.id.hasPrefix("subagent:"),
      !parent.blocks.contains(where: { $0.kind == "channel_message" })
    else { return }
    if let api = client {
      let _: Empty = try await api.rpc(
        "threads/react",
        chat.target.merging(["messageId": parent.id, "reaction": emoji, "clientNonce": nonce]) {
          $1
        })
    } else if var local = sample, let last = local.transcripts[chat.id]?.last,
      local.transcripts[chat.id]?.contains(where: { $0.id == parent.id }) == true
    {
      var reaction = Sample.message(last.seq + 1, "user", emoji)
      reaction.replyToMessageId = parent.id
      local.transcripts[chat.id, default: []].append(reaction)
      sample = local
    }
  }
  func link(_ chat: Chat? = nil, query: [URLQueryItem] = []) -> URL? {
    guard let login else { return nil }
    var url = login.server.appendingPathComponent("app")
    if let chat {
      if chat.isGroup { url.appendPathComponent("g") }
      url.appendPathComponent(chat.id)
    }
    return query.isEmpty ? url : url.appending(queryItems: query)
  }
}
