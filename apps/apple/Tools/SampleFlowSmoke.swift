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
    legacy.integrationRecords = nil
    legacy.spaceSkills = nil
    var restored = try JSONDecoder().decode(Sample.self, from: JSONEncoder().encode(legacy))
    restored.includeWalkthrough()
    restored.includeWalkthrough()
    precondition(restored.spaces[0].bots.filter { $0.id == Sample.computerTour }.count == 1)
    let store = WorkspaceStore(sample: restored, persistent: false)
    let entries = store.sampleIntegrations!.catalog(catalog)
    try await checkManagement(seed: catalog)
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
    precondition(card(appMessage) == "connected" && store.sampleIntegrations!.accounts.count == 4)
    store.resolveSampleConnection(
      chat: tour, message: mcpMessage, kind: "mcp_approval", allow: true)
    store.resolveSampleConnection(
      chat: tour, message: mcpMessage, kind: "mcp_approval", allow: false)
    precondition(
      card(mcpMessage) == "connected"
        && store.sampleIntegrations!.assignments["linear.app"]!.contains(tour))
    precondition(
      store.sampleIntegrations!.servers.map(\.connectionLabel) == [
        "Connected", "Not working", "Sign in again", "Installing", "Sign in again",
      ])
    let source = catalog.sources.first { $0.domain == "figma.com" }!
    store.changeIntegrations {
      $0.add(source)
      $0.add(source)
      $0.accounts.removeAll { $0.provider == "slack" }
    }
    precondition(
      store.sampleIntegrations!.servers.count == 6
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
    let emptyID = try await store.createPrivateSpace(name: "Empty space")
    try await store.openPrivateSpace(emptyID)
    precondition(store.sampleLeases.isEmpty)
    precondition(
      store.sampleIntegrations!.accounts.isEmpty && store.sampleIntegrations!.servers.isEmpty
        && !store.sampleTakeover(bot: bot, viewer: first, run: nil))
    try await store.load(space: "local")
    let persisted = try JSONDecoder().decode(Sample.self, from: JSONEncoder().encode(store.sample!))
    let reopened = WorkspaceStore(sample: persisted, persistent: false)
    precondition(
      reopened.sampleLeases.isEmpty && reopened.sampleIntegrations!.servers.count == 6
        && reopened.sample!.computers![bot]!.document == "Ship draft")
    print(
      "PASS: offline catalog, account/card grants, MCP states, workspace isolation, host consent, screen leases, run-scoped handback, skip and persistence"
    )
  }

  @MainActor static func checkManagement(seed: CatalogSeed) async throws {
    func expect(_ value: Bool, _ message: String) throws { if !value { throw Failure(message) } }
    let store = WorkspaceStore(sample: .initial, persistent: false)
    let gmail = store.sampleIntegrations!.catalog(seed).first { $0.slug == "gmail" }!
    let mailboxes = try await store.linkedAccounts(gmail)
    try expect(mailboxes.count == 2, "Expected independent accounts.")
    try await store.renameAccount(mailboxes[0], to: "Team updates")
    try expect(try await store.linkedAccounts(gmail).first?.displayName == "Team updates", "Account rename was lost.")
    try await store.revokeAccount(mailboxes[0]); try expect(try await store.linkedAccounts(gmail).map(\.id) == [mailboxes[1].id], "Disconnected the wrong account.")
    let brain = try await store.managedServers().first { $0.id == "sample-brain" }!
    try expect(try await store.testServer(brain).health.status == "error", "Expired authorization unexpectedly succeeded.")
    let pending: Void? = try? await store.verifyBrowserGrant(brain.id)
    try expect(pending == nil, "Browser sign-in was accepted before the server confirmed it.")
    store.completeSampleGrant(brain)
    try await store.verifyBrowserGrant(brain.id)
    let signed = try await store.managedServers().first { $0.id == brain.id }!
    try expect(try await store.testServer(signed).health.toolCount == 7, "Reconnected server did not discover tools.")
    let successful = URL(string: "rakazo://mcp-oauth?code=fixture&state=expected")!
    try expect(try WorkspaceStore.oauthCompletion(successful, sessionID: "expected")["code"] == "fixture", "Callback was not accepted.")
    for invalid in ["rakazo://other?code=fixture&state=expected", "rakazo://mcp-oauth?code=fixture&state=stale", "rakazo://mcp-oauth?error=access_denied&state=expected", "rakazo://mcp-oauth?code=one&code=two&state=expected"] {
      try expect((try? WorkspaceStore.oauthCompletion(URL(string: invalid)!, sessionID: "expected")) == nil, "Accepted an invalid callback.")
    }
    let source = IntegrationFixtures.repo("Linear"); let preview = try await store.previewRepository(source)
    func plugin() async throws -> ManagedInstall? { try await store.managementInstalls().first { $0.source == source } }
    try await store.setPlugin(try await plugin(), preview: preview, source: source, parts: ["connector", "skills"])
    guard let packaged = try await store.managementSkills().first(where: { $0.parentID == source }) else { throw Failure("Installed skills did not enter the library.") }
    try expect(!packaged.editable, "Packaged skill was editable.")
    let denied = try? await store.writeSkill(packaged, name: "Rewrite", description: "Read only", body: "Fixture"); try expect(denied == nil, "Writable plugin skill.")
    try await store.setPlugin(try await plugin(), preview: preview, source: source, parts: ["connector"])
    try expect(try await !store.managementSkills().contains { $0.parentID == source }, "Removed skills remain visible.")
    try expect(try await store.managedServers().contains { $0.installId == source }, "Removing skills removed the connector.")
    try await store.setPlugin(try await plugin(), preview: preview, source: source, parts: [])
    try expect(try await plugin() == nil, "Plugin was not removed.")
    let custom = try await store.addSource(kind: "graphql", name: "Reports", url: "https://reports.example/graphql", method: "header", header: "X-Reports", credential: "not-persisted-fixture")
    try await store.setScope(kind: "install", id: custom.id, scope: .here(store.currentSpace))
    let scoped = try await store.managementInstalls().first { $0.id == custom.id }!
    let replacement = try await store.addSource(kind: "graphql", name: "New reports", url: "https://reports.example/v2", method: "none", header: "", credential: "", replacing: scoped)
    try expect(replacement.id == custom.id && replacement.availability?.allSpaces == false, "Replacement widened access.")
    let serialized = try JSONEncoder().encode(store.sample!); try expect(!String(decoding: serialized, as: UTF8.self).contains("not-persisted-fixture"), "Fixture stored a credential value.")
    let home = store.currentSpace, other = try await store.createPrivateSpace(name: "Isolated")
    try await store.openPrivateSpace(other); try expect(try await !store.managementInstalls().contains { $0.id == replacement.id }, "Unexpected cross-space access.")
    try await store.openPrivateSpace(home); try await store.removeSource(replacement)
    try expect(try await !store.managementInstalls().contains { $0.id == replacement.id }, "Custom source was not removed.")
    print("PASS: independent accounts, reconnect and callback validation, independent plugin parts, read-only skills, scoped replacement, credential redaction and removal.")
  }
}
