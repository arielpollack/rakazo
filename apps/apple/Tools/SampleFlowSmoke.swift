import Foundation

@main enum SampleFlowSmoke {
  @MainActor static func main() async throws {
    let file = URL(fileURLWithPath: CommandLine.arguments[1])
    let catalog = try JSONDecoder().decode(CatalogSeed.self, from: Data(contentsOf: file))
    var legacy = Sample.initial
    legacy.spaces[0].bots.removeAll {
      [Sample.computerTour, Sample.integrationTour].contains($0.id)
    }
    legacy.transcripts.removeValue(forKey: Sample.computerTour)
    legacy.transcripts.removeValue(forKey: Sample.integrationTour)
    legacy.computers = nil
    legacy.integrations = nil
    var restored = try JSONDecoder().decode(Sample.self, from: JSONEncoder().encode(legacy))
    restored.includeWalkthrough()
    restored.includeWalkthrough()
    precondition(restored.spaces[0].bots.filter { $0.id == Sample.computerTour }.count == 1)
    let store = WorkspaceStore(sample: restored, persistent: false)
    let entries = store.sampleIntegrations!.catalog(catalog)
    precondition(entries.count == 6 && entries.filter(\.connected).count == 2)
    precondition(catalog.apps.first { $0.slug == "gmail" }?.tools.count == 6)
    precondition(
      catalog.sources.contains { $0.domain == "linear.app" && $0.surfaces.contains("mcp") })
    let app = entries.first { $0.slug == "slack" }!
    let tour = Sample.integrationTour
    let appMessage = store.sample!.transcripts[tour]!.first { $0.blocks[0].kind == "app_connect" }!
      .id
    let mcpMessage = store.sample!.transcripts[tour]!.first { $0.blocks[0].kind == "mcp_approval" }!
      .id
    func card(_ id: String) -> String? {
      store.sample?.transcripts[tour]?.first { $0.id == id }?.blocks[0].status
    }
    store.resolveSampleConnection(chat: tour, message: appMessage, kind: "app_connect", allow: true)
    precondition(card(appMessage) == "pending")
    store.changeIntegrations {
      $0.connect(app)
      $0.connect(app)
    }
    store.resolveSampleConnection(chat: tour, message: appMessage, kind: "app_connect", allow: true)
    precondition(card(appMessage) == "connected" && store.sampleIntegrations!.accounts.count == 3)
    store.resolveSampleConnection(
      chat: tour, message: mcpMessage, kind: "mcp_approval", allow: true)
    store.resolveSampleConnection(
      chat: tour, message: mcpMessage, kind: "mcp_approval", allow: false)
    precondition(
      card(mcpMessage) == "connected"
        && store.sampleIntegrations!.assignments["linear.app"]!.contains(tour))
    precondition(
      store.sampleIntegrations!.servers.map(\.connectionLabel) == [
        "Connected", "Not working", "Sign in again", "Installing",
      ])
    let source = catalog.sources.first { $0.domain == "figma.com" }!
    store.changeIntegrations {
      $0.add(source)
      $0.add(source)
      $0.accounts.removeAll { $0.provider == "slack" }
    }
    precondition(
      store.sampleIntegrations!.servers.count == 5
        && !store.sampleIntegrations!.catalog(catalog).first { $0.slug == "slack" }!.connected)
    let bot = Sample.computerTour
    let first = UUID()
    let second = UUID()
    let run = store.sample!.computers![bot]!.pendingRun!
    store.editScreen(bot: bot, viewer: first) { $0.document = "Not allowed" }
    precondition(store.sample!.computers![bot]!.document == "Release review")
    precondition(store.sampleTakeover(bot: bot, viewer: first, run: run))
    precondition(!store.sampleTakeover(bot: bot, viewer: second, run: run))
    store.editScreen(bot: bot, viewer: first) {
      $0.reviewed = true
      $0.document = "Ship draft"
    }
    precondition(store.handBack(bot: bot, viewer: first))
    precondition(store.sample!.computers![bot]!.pendingRun == run)
    precondition(store.sampleTakeover(bot: bot, viewer: second, run: run))
    precondition(
      !store.handBack(bot: bot, viewer: first)
        && !store.answerScreenRequest(bot: bot, run: run, answer: .skipped))
    precondition(store.handBack(bot: bot, viewer: second, run: run, answer: .done))
    precondition(
      store.sample!.transcripts[bot]!.last!.text.contains("Ship draft")
        && store.sample!.computers![bot]!.reviewed)
    precondition(
      store.sample!.transcripts[bot]!.contains { $0.runId == run && $0.blocks[0].state == "Done" })
    store.requestSampleReview(bot: bot)
    precondition(!store.sampleTakeover(bot: bot, viewer: first, run: run))
    precondition(!store.answerScreenRequest(bot: bot, run: run, answer: .skipped))
    let next = store.sample!.computers![bot]!.pendingRun!
    precondition(store.answerScreenRequest(bot: bot, run: next, answer: .skipped))
    precondition(
      store.sample!.transcripts[bot]!.contains {
        $0.runId == next && $0.blocks[0].state == "Skipped"
      })
    let request = store.sample!.transcripts[bot]!.first {
      $0.blocks.first?.actions?.first?.id == "sample-host-review"
    }!.id
    store.runSampleHostTask(bot: bot)
    store.answerHostRequest(bot: bot, message: request, allowed: true)
    precondition(store.sample!.computers![bot]!.localResult == nil)
    precondition(!store.chooseSampleMac(accessibility: false, screenRecording: true))
    precondition(!store.chooseSampleMac(accessibility: true, screenRecording: false))
    precondition(store.chooseSampleMac(accessibility: true, screenRecording: true))
    store.answerHostRequest(bot: bot, message: request, allowed: true)
    precondition(
      store.sample!.transcripts[bot]!.last!.text.contains("Read Sample Notes → Desktop handoff"))
    store.sample?.host = .sandbox
    store.sample?.computers?[bot]?.localResult = nil
    store.runSampleHostTask(bot: bot)
    precondition(store.sample!.computers![bot]!.localResult == nil)
    let count = store.sample!.transcripts[bot]!.count
    store.answerHostRequest(bot: bot, message: request, allowed: false)
    precondition(count == store.sample!.transcripts[bot]!.count)
    let other = WorkspaceStore(sample: restored, persistent: false)
    other.resolveSampleConnection(
      chat: tour, message: mcpMessage, kind: "mcp_approval", allow: false)
    other.answerHostRequest(bot: bot, message: request, allowed: false)
    precondition(other.sample!.transcripts[bot]!.last!.text.contains("isolated"))
    precondition(
      other.sample!.computers![bot]!.localResult == nil
        && other.sampleIntegrations!.assignments["linear.app"]!.contains(tour) == false)
    precondition(store.sampleTakeover(bot: bot, viewer: first, run: nil))
    try await store.create(name: "Empty space", description: "", members: nil, privateSpace: true)
    precondition(store.sampleLeases.isEmpty)
    precondition(
      store.sampleIntegrations!.accounts.isEmpty && store.sampleIntegrations!.servers.isEmpty
        && !store.sampleTakeover(bot: bot, viewer: first, run: nil))
    try await store.load(space: "local")
    let persisted = try JSONDecoder().decode(Sample.self, from: JSONEncoder().encode(store.sample!))
    let reopened = WorkspaceStore(sample: persisted, persistent: false)
    precondition(
      reopened.sampleLeases.isEmpty && reopened.sampleIntegrations!.servers.count == 5
        && reopened.sample!.computers![bot]!.document == "Ship draft")
    print(
      "PASS: offline catalog, account/card grants, MCP states, workspace isolation, host consent, screen leases, run-scoped handback, skip and persistence"
    )
  }
}
