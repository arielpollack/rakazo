import Foundation

enum SampleHost: String, Codable { case sandbox, thisMac }
enum TakeoverAnswer: String {
  case done = "Done"
  case skipped = "Skipped"
}

struct SampleComputer: Codable {
  var document = "Release review"
  var reviewed = false
  var pendingRun: String?
  var response: String?
  var localResult: String?
}

extension Sample {
  static let computerTour = "sample-computer-tour", integrationTour = "sample-integration-tour"
  mutating func includeFeatureTours() {
    guard let index = spaces.firstIndex(where: { $0.id == "local" }) else { return }
    let date = Date.now.addingTimeInterval(-90000)
    if !spaces[index].bots.contains(where: { $0.id == Self.computerTour }) {
      let chat = Chat(
        id: Self.computerTour, name: "Computer walkthrough", color: "#A97EFE::shape_6",
        description: "A sample bot computer", preview: "Review the release checklist on my screen.",
        updatedAt: date.ISO8601Format(), computerMode: "dedicated")
      spaces[index].bots.append(chat)
      transcripts[chat.id] = [
        Self.message(1, "user", "Prepare the release checklist for review.", at: date)
      ]
      requestReview(bot: chat.id, at: date)
    }
    if spaces[index].bots.contains(where: { $0.id == Self.computerTour }),
      !(transcripts[Self.computerTour] ?? []).contains(where: {
        $0.blocks.contains { $0.actions?.first?.id == "sample-host-review" }
      })
    {
      var ask = Self.message(
        (transcripts[Self.computerTour]?.last?.seq ?? 0) + 1, "bot", "", at: date)
      ask.blocks = [
        .init(
          kind: "ask", text: "May I read the release note on your sample Mac?", status: "pending",
          actions: [.init(id: "sample-host-review", label: "Review access")])
      ]
      transcripts[Self.computerTour, default: []].append(ask)
    }
    if !spaces[index].bots.contains(where: { $0.id == Self.integrationTour }) {
      let chat = Chat(
        id: Self.integrationTour, name: "Integrations walkthrough", color: "#00C972",
        description: "Sample connection requests", preview: "Two connections to review.",
        updatedAt: date.ISO8601Format())
      spaces[index].bots.append(chat)
      var app = Self.message(2, "bot", "", at: date)
      app.threadId = chat.id
      app.blocks = [
        .init(
          kind: "app_connect", name: "Slack", status: "pending", provider: "slack",
          connectorId: "sample-apps")
      ]
      var mcp = Self.message(3, "bot", "", at: date)
      mcp.threadId = chat.id
      mcp.blocks = [
        .init(
          kind: "mcp_approval", name: "Linear", status: "pending", transport: "streamable_http",
          serverId: "linear.app", needsOAuth: false)
      ]
      transcripts[chat.id] = [
        Self.message(1, "user", "Connect our chat and issue tracker.", at: date), app, mcp,
      ]
    }
  }
  mutating func requestReview(bot: String, at date: Date = .now) {
    var computer = computers?[bot] ?? SampleComputer()
    guard computer.pendingRun == nil else { return }
    let run = UUID().uuidString
    computer.pendingRun = run
    computer.response = nil
    computer.reviewed = false
    if computers == nil { computers = [:] }
    computers?[bot] = computer
    var request = Self.message((transcripts[bot]?.last?.seq ?? 0) + 1, "bot", "", at: date)
    request.botId = bot
    request.runId = run
    request.threadId = bot
    request.blocks = [
      .init(
        kind: "computer", text: "Review the release checklist on my screen, then hand it back.",
        state: "Needs you")
    ]
    transcripts[bot, default: []].append(request)
  }
  mutating func resolveReview(bot: String, run: String, answer: TakeoverAnswer) -> Bool {
    guard var computer = computers?[bot], computer.pendingRun == run, var items = transcripts[bot],
      let index = items.firstIndex(where: { $0.runId == run }),
      let slot = items[index].blocks.firstIndex(where: {
        $0.kind == "computer" && $0.state == "Needs you"
      })
    else { return false }
    items[index].blocks[slot].state = answer.rawValue
    let reply =
      answer == .done
      ? "I have control again. The checklist is titled “\(computer.document)” and marked \(computer.reviewed ? "reviewed" : "not reviewed")."
      : "I’ll continue without the review."
    items.append(Self.message((items.last?.seq ?? 0) + 1, "bot", reply))
    computer.pendingRun = nil
    computer.response = reply
    computers?[bot] = computer
    transcripts[bot] = items
    return true
  }
}

extension WorkspaceStore {
  func sampleBot(_ bot: String) -> Bool {
    demo && navigation?.current.bots.contains { $0.id == bot } == true
  }
  func sampleTakeover(bot: String, viewer: UUID, run: String?) -> Bool {
    guard sampleBot(bot), sampleLeases[bot] == nil || sampleLeases[bot] == viewer,
      run == nil || run == sample?.computers?[bot]?.pendingRun
    else { return false }
    sampleLeases[bot] = viewer
    return true
  }
  func editScreen(bot: String, viewer: UUID, change: (inout SampleComputer) -> Void) {
    guard sampleBot(bot), sampleLeases[bot] == viewer, var local = sample else { return }
    var computer = local.computers?[bot] ?? SampleComputer()
    change(&computer)
    if local.computers == nil { local.computers = [:] }
    local.computers?[bot] = computer
    sample = local
  }
  @discardableResult func handBack(
    bot: String, viewer: UUID, run: String? = nil, answer: TakeoverAnswer? = nil
  ) -> Bool {
    guard sampleLeases[bot] == viewer else { return false }
    if let answer {
      guard sampleBot(bot), let run, var local = sample,
        local.resolveReview(bot: bot, run: run, answer: answer)
      else { return false }
      sample = local
    }
    sampleLeases.removeValue(forKey: bot)
    return true
  }
  func requestSampleReview(bot: String) {
    guard sampleBot(bot), sampleLeases[bot] == nil else { return }
    sample?.requestReview(bot: bot)
  }
  func runSampleHostTask(bot: String) {
    guard sampleBot(bot), var local = sample, local.host == .thisMac else { return }
    var computer = local.computers?[bot] ?? SampleComputer()
    computer.localResult =
      "Read Sample Notes → Desktop handoff: the release draft is ready for review."
    if local.computers == nil { local.computers = [:] }
    local.computers?[bot] = computer
    sample = local
  }
  func chooseSampleMac(accessibility: Bool, screenRecording: Bool) -> Bool {
    guard demo, sample != nil, accessibility, screenRecording else { return false }
    sample?.host = .thisMac
    return true
  }
  func answerHostRequest(bot: String, message: String, allowed: Bool) {
    guard sampleBot(bot), var local = sample,
      let row = local.transcripts[bot]?.firstIndex(where: { $0.id == message }),
      let slot = local.transcripts[bot]?[row].blocks.firstIndex(where: {
        $0.actions?.first?.id == "sample-host-review" && $0.status == "pending"
      }),
      !allowed || local.host == .thisMac
    else { return }
    local.transcripts[bot]?[row].blocks[slot].status = "answered"
    local.transcripts[bot]?[row].blocks[slot].answer = allowed ? "Allowed" : "Declined"
    if allowed {
      sample = local
      runSampleHostTask(bot: bot)
      local = sample ?? local
    }
    let reply =
      allowed
      ? local.computers?[bot]?.localResult ?? "Read the sample note."
      : "I’ll stay on the isolated computer."
    local.transcripts[bot, default: []].append(
      Sample.message((local.transcripts[bot]?.last?.seq ?? 0) + 1, "bot", reply))
    sample = local
  }
  func answerScreenRequest(bot: String, run: String, answer: TakeoverAnswer) -> Bool {
    guard sampleBot(bot), sampleLeases[bot] == nil, var local = sample,
      local.resolveReview(bot: bot, run: run, answer: answer)
    else { return false }
    sample = local
    return true
  }
  func resolveSampleConnection(chat: String, message: String, kind: String, allow: Bool) {
    guard sampleBot(chat), var local = sample, var items = local.transcripts[chat],
      let row = items.firstIndex(where: { $0.id == message }),
      let slot = items[row].blocks.firstIndex(where: { $0.kind == kind && $0.status == "pending" }),
      let space = navigation?.current.id, var library = sampleIntegrations
    else { return }
    let block = items[row].blocks[slot]
    if kind == "mcp_approval",
      let server = library.servers.first(where: { $0.id == block.serverId })
    {
      if allow {
        guard server.connectionLabel == "Connected" else { return }
        library.assignments[server.id, default: []].insert(chat)
      }
    } else if kind == "app_connect", allow {
      guard
        library.accounts.contains(where: {
          $0.provider == block.provider && $0.connectorId == block.connectorId
            && $0.status == "connected"
        })
      else { return }
    } else {
      return
    }
    items[row].blocks[slot].status = allow ? "connected" : "dismissed"
    local.transcripts[chat] = items
    if local.integrations == nil { local.integrations = [:] }
    local.integrations?[space] = library
    sample = local
  }
}
