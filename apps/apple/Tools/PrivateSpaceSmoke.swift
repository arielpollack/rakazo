import Foundation

@main enum PrivateSpaceSmoke {
  @MainActor final class FlakyStore: PrivateSpaceOperations {
    var calls: [String] = []
    var reject: Set<String> = ["create", "items", "save", "open"]
    let items = [
      SpaceTool(kind: "skill", id: "same", name: "Notes", availability: .init(allSpaces: true, spaceIds: ["home"])),
      SpaceTool(kind: "install", id: "same", name: "Notes", availability: .init(allSpaces: false, spaceIds: ["home"])),
    ]
    func attempt(_ name: String) throws {
      calls.append(name)
      if reject.remove(name) != nil { throw Failure("\(name) failed") }
    }
    func createPrivateSpace(name: String) async throws -> String {
      precondition(name == "Design")
      try await Task.sleep(for: .milliseconds(10))
      try attempt("create"); return "new"
    }
    func accountTools() async throws -> [SpaceTool] { try attempt("items"); return items }
    func chooseTools(_ selection: [SpaceTool.Key], for space: String) async throws {
      precondition(selection == [items[1].key] && space == "new"); try attempt("save")
    }
    func openPrivateSpace(_ id: String) async throws { precondition(id == "new"); try attempt("open") }
  }

  @MainActor static func main() async throws {
    if CommandLine.arguments.contains("--release-server") { try await release(); return }
    let fake = FlakyStore(), flow = PrivateSpaceFlow()
    for invalid in [" \n ", String(repeating: "😀", count: 31)] {
      flow.name = invalid
      let done = await flow.advance(using: fake); precondition(!done && fake.calls.isEmpty)
    }
    flow.name = String(repeating: "😀", count: 30); precondition(flow.validName)
    flow.name = " Design "
    async let first = flow.advance(using: fake); async let second = flow.advance(using: fake)
    let results = await [first, second]
    precondition(results == [false, false] && flow.issue == "create failed" && flow.name == " Design ")
    let loadFailure = await flow.advance(using: fake); precondition(!loadFailure && flow.issue == "items failed")
    let loaded = await flow.advance(using: fake); precondition(!loaded && flow.selection == [fake.items[0].key])
    flow.selection = [fake.items[1].key]
    let saveFailure = await flow.advance(using: fake); precondition(!saveFailure && flow.issue == "save failed")
    let openFailure = await flow.advance(using: fake); precondition(!openFailure && flow.issue == "open failed")
    let opened = await flow.advance(using: fake); let again = await flow.advance(using: fake)
    precondition(opened && !again && fake.calls == ["create", "create", "items", "items", "save", "save", "open", "open"])

    let sample = WorkspaceStore(sample: .initial, persistent: false)
    sample.changeIntegrations { library in
      library.installedPlugins = ["sample:figma"]; library.pluginNames = ["sample:figma": "Figma"]
      library.servers[0].allBots = true
    }
    let demo = PrivateSpaceFlow(); demo.name = "Studio"
    let chose = await demo.advance(using: sample)
    guard !chose, case .choosing(let id, let items) = demo.step else { throw Failure("Missing tool choices.") }
    precondition(items.filter { demo.selection.contains($0.key) }.map(\.name) == ["Release notes"])
    demo.selection = Set(items.filter { ["Linear", "Figma"].contains($0.name) }.map(\.key))
    let finished = await demo.advance(using: sample)
    precondition(finished && sample.navigation?.current.id == id && sample.sample!.spaces.count == 2)
    let restored = try JSONDecoder().decode(Sample.self, from: JSONEncoder().encode(sample.sample!))
    let reopened = WorkspaceStore(sample: restored, persistent: false)
    precondition(reopened.sampleIntegrations?.assignments["linear.app"] == ["sample-chief"])
    try await reopened.openPrivateSpace(id)
    let target = reopened.sampleIntegrations!
    precondition(target.servers.map(\.name) == ["Linear"] && target.servers[0].allBots == false)
    precondition(target.installedPlugins == ["sample:figma", IntegrationFixtures.repo("Linear")] && target.assignments.isEmpty && target.accounts.isEmpty)
    let skill = restored.accountTools.first { $0.kind == "skill" }!
    precondition(!skill.availability.allSpaces && skill.availability.spaceIds == ["local"])
    print("PASS: name limits, duplicate submission, retry at every step, typed identities, defaults, independent scopes and persisted choices.")
  }

  @MainActor static func release() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let raw = env["TEST_RUNNER_RAKAZO_TEST_ORIGIN"], let origin = try? Client.origin(raw),
      origin.host == "127.0.0.1", let password = env["TEST_RUNNER_RAKAZO_TEST_PASSWORD"]
    else { throw Failure("Run with the disposable loopback release fixture.") }
    let login = try await Client(server: origin).authenticate(email: "native@example.test", password: password, code: false)
    let store = WorkspaceStore(login: login); try await store.load()
    guard store.account?.email == "native@example.test", let home = store.navigation?.current.id,
      let homeAPI = store.client, try await store.accountTools().isEmpty else { throw Failure("Expected a fresh fixture.") }
    let empty = PrivateSpaceFlow(); empty.name = "No tools"
    let skipped = await empty.advance(using: store)
    guard skipped, store.navigation?.current.name == "No tools" else { throw Failure(empty.issue ?? "Did not skip empty picker.") }
    try await store.openPrivateSpace(home)
    func server(_ slug: String) async throws -> ToolServer {
      try await homeAPI.rpc("mcp/servers/create", ["slug": slug, "name": slug, "enabled": false,
        "transport": "streamable_http", "endpoint": "https://example.com/mcp"])
    }
    let global = try await server("all-spaces"), scoped = try await server("selected-only")
    let _: SpaceTool.Availability = try await homeAPI.rpc("availability/set", ["kind": "mcpServer", "id": global.id,
      "allSpaces": true, "spaceIds": [home]])
    let _: SpaceTool.Availability = try await homeAPI.rpc("availability/set", ["kind": "mcpServer", "id": scoped.id,
      "allSpaces": false, "spaceIds": [home]])
    let wizard = PrivateSpaceFlow(); wizard.name = "  Studio  "
    let pending = await wizard.advance(using: store)
    guard !pending, case .choosing(let id, let items) = wizard.step else {
      throw Failure(wizard.issue ?? "Missing picker after creation.")
    }
    guard items.count == 2, wizard.selection == [.init(kind: "mcpServer", id: global.id)],
      store.navigation?.current.id == home else {
      throw Failure("Unexpected release defaults: \(items.map { ($0.kind, $0.name, $0.availability.allSpaces) }), selected=\(wizard.selection.count)")
    }
    wizard.selection = [.init(kind: "mcpServer", id: scoped.id)]
    let done = await wizard.advance(using: store)
    guard done, store.navigation?.current.id == id, store.navigation?.current.name == "Studio",
      let newAPI = store.client else { throw Failure(wizard.issue ?? "Did not open the created space.") }
    let picked: [ToolServer] = try await newAPI.rpc("mcp/servers/list")
    let source: [ToolServer] = try await homeAPI.rpc("mcp/servers/list")
    let persisted: [SpaceTool] = try await newAPI.rpc("availability/items")
    guard picked.map(\.id) == [scoped.id], Set(source.map(\.id)) == [scoped.id, global.id],
      let excluded = persisted.first(where: { $0.id == global.id }), !excluded.availability.allSpaces,
      !excluded.availability.spaceIds.contains(id), excluded.availability.spaceIds.contains(home),
      store.navigation?.spaces.filter({ $0.name == "Studio" }).count == 1
    else { throw Failure("Release readback did not match the saved space choices.") }
    print("PASS: release API skipped empty picker, loaded real defaults, saved only chosen tools, preserved original workspace and opened exactly one new space.")
  }
}
