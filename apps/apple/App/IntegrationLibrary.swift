import Foundation

struct CatalogEntry: Decodable, Identifiable {
  let connectorId: String, name: String, slug: String, connected: Bool, noAuth: Bool
  var logo: String? = nil
  var id: String { connectorId + "/" + slug }
}

struct LinkedApp: Codable, Identifiable {
  let id: String, connectorId: String, provider: String
  var displayName: String, status: String
}

struct IntegrationTool: Decodable { let name: String, description: String }

struct CatalogSeed: Decodable {
  struct App: Decodable { let slug: String, name: String, noAuth: Bool, tools: [IntegrationTool] }
  struct Source: Decodable, Identifiable {
    let domain: String, surfaces: [String]
    var id: String { domain }
  }
  let apps: [App], sources: [Source]
  static let bundled = Result {
    guard let url = Bundle.main.url(forResource: "sample-catalog", withExtension: "json") else {
      throw Failure("The sample catalog is missing from the app bundle.")
    }
    return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
  }
}

struct ToolServer: Codable, Identifiable {
  struct Health: Codable {
    var status: String
    var message: String? = nil, code: String? = nil, toolCount: Int? = nil
  }
  let id: String, name: String, transport: String
  var oauthStatus: String, enabled: Bool, health: Health
  var allBots: Bool? = nil, oauthClientId: String? = nil
  var endpoint: String? = nil
  var connectionLabel: String {
    if !enabled { return "Disabled" }
    if health.code == "MCP_OAUTH_CLIENT_REQUIRED" && oauthClientId == nil {
      return "Needs OAuth client"
    }
    if oauthStatus == "reconnect" { return "Sign in again" }
    if health.status == "error" { return "Not working" }
    if oauthStatus == "connected" || health.status == "ok" { return "Connected" }
    return health.status == "installing" ? "Installing" : "Not connected"
  }
}

struct SampleIntegrations: Codable {
  var accounts: [LinkedApp] = []
  var servers: [ToolServer] = []
  var assignments: [String: Set<String>] = [:]
  var installedPlugins: Set<String>? = nil

  static func initial(space: String) -> Self {
    guard space == "local" else { return Self() }
    return Self(
      accounts: [
        LinkedApp(
          id: "sample-mail", connectorId: "sample-apps", provider: "gmail",
          displayName: "Team inbox", status: "connected"),
        LinkedApp(
          id: "sample-code", connectorId: "sample-apps", provider: "github",
          displayName: "Release watch", status: "connected"),
      ],
      servers: [
        ToolServer(
          id: "linear.app", name: "Linear", transport: "streamable_http", oauthStatus: "connected",
          enabled: true, health: .init(status: "ok", toolCount: 23), allBots: false),
        ToolServer(
          id: "github.com", name: "GitHub", transport: "streamable_http", oauthStatus: "none",
          enabled: true, health: .init(status: "error", message: "401 Unauthorized"), allBots: false
        ),
        ToolServer(
          id: "notion", name: "Notion", transport: "streamable_http", oauthStatus: "reconnect",
          enabled: true, health: .init(status: "ok", toolCount: 12), allBots: false),
        ToolServer(
          id: "files", name: "Files", transport: "stdio", oauthStatus: "none", enabled: true,
          health: .init(status: "installing"), allBots: false),
      ], assignments: ["linear.app": ["sample-chief"]])
  }
  func catalog(_ seed: CatalogSeed) -> [CatalogEntry] {
    seed.apps.map { app in
      CatalogEntry(
        connectorId: "sample-apps", name: app.name, slug: app.slug,
        connected: accounts.contains { $0.provider == app.slug && $0.status == "connected" },
        noAuth: app.noAuth)
    }
  }
  mutating func connect(_ entry: CatalogEntry) {
    guard
      !accounts.contains(where: { $0.provider == entry.slug && $0.connectorId == entry.connectorId && $0.status == "connected" }
      )
    else { return }
    accounts.append(
      .init(
        id: UUID().uuidString, connectorId: entry.connectorId, provider: entry.slug,
        displayName: entry.name, status: "connected"))
  }
  mutating func add(_ source: CatalogSeed.Source) {
    guard source.surfaces.contains("mcp"), !servers.contains(where: { $0.id == source.id }) else {
      return
    }
    servers.append(
      .init(
        id: source.id, name: source.domain, transport: "streamable_http", oauthStatus: "none",
        enabled: true, health: .init(status: "unknown"), allBots: false))
  }
}

extension WorkspaceStore {
  var sampleIntegrations: SampleIntegrations? {
    guard let sample, let space = navigation?.current.id else { return nil }
    return sample.integrations?[space] ?? .initial(space: space)
  }
  func changeIntegrations(_ change: (inout SampleIntegrations) -> Void) {
    guard var local = sample, let space = navigation?.current.id, var library = sampleIntegrations
    else { return }
    change(&library)
    if local.integrations == nil { local.integrations = [:] }
    local.integrations?[space] = library
    sample = local
  }
}
