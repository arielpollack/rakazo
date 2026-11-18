import Foundation

@main enum IntegrationServerSmoke {
  struct Assignment: Decodable { let botId: String, serverId: String }
  struct Preview: Decodable { let image: String? }

  static func main() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let raw = environment["TEST_RUNNER_RAKAZO_TEST_ORIGIN"],
      let password = environment["TEST_RUNNER_RAKAZO_TEST_PASSWORD"],
      let origin = try? Client.origin(raw), origin.host == "127.0.0.1"
    else { throw Failure("Run only through the disposable upstream server fixture.") }
    let login = try await Client(server: origin).authenticate(
      email: "native@example.test", password: password, code: false)
    var api = Client(server: origin, token: login.token)
    let account: Account = try await api.rpc("me")
    guard account.email == "native@example.test" else {
      throw Failure("Expected a fixture account.")
    }
    let roster: NavigationData = try await api.rpc("spaces/list")
    api.space = roster.current.id
    let bot: ObjectID = try await api.rpc("bots/create", ["name": "Grant review"])
    let _: [CatalogEntry] = try await api.rpc("connections/catalog")
    let _: [LinkedApp] = try await api.rpc("connections/list")
    let server: ToolServer = try await api.rpc(
      "mcp/servers/create",
      [
        "slug": "scope-check", "name": "Scope check", "enabled": false,
        "transport": "streamable_http", "endpoint": "https://example.com/mcp",
      ])
    let _: Empty = try await api.rpc(
      "mcp/servers/agents",
      [
        "id": server.id, "allBots": false, "botIds": [bot.id],
      ])
    let list: [ToolServer] = try await api.rpc("mcp/servers/list")
    let marketplace = try await MarketDirectory.load(api)
    let listing = marketplace.items.first { if case .server(_, let configured?) = $0.content { return configured.id == server.id }; return false }
    guard listing?.confirmed == "Disabled", listing?.needsAttention == true else {
      throw Failure("The native marketplace did not show the actual configured server.")
    }
    print("PASS: release marketplace loaded \(marketplace.items.count) listings and read back the configured server. Directory warnings: \(marketplace.warnings)")
    let grants: [Assignment] = try await api.rpc("mcp/assignments/all")
    guard
      list.contains(where: {
        $0.id == server.id && $0.allBots == false && $0.connectionLabel == "Disabled"
      }),
      grants.filter({ $0.serverId == server.id }).map(\.botId) == [bot.id]
    else { throw Failure("Expected to read back the saved per-bot grant.") }
    let _: Empty = try await api.rpc(
      "mcp/servers/agents",
      [
        "id": server.id, "allBots": false, "botIds": [String](),
      ])
    let after: [Assignment] = try await api.rpc("mcp/assignments/all")
    guard !after.contains(where: { $0.serverId == server.id }) else {
      throw Failure("Grant was not removed.")
    }
    let stale = UUID().uuidString
    let still: Preview = try await api.rpc("computer/preview", ["botId": bot.id, "runId": stale])
    guard still.image == nil else { throw Failure("Unrelated run returned a computer image.") }
    print(
      "PASS: release API decoded app catalog/accounts, listed a disabled MCP server, saved/read/removed one bot grant, and returned no image for an unrelated run. No provider or screen input used."
    )
  }
}
