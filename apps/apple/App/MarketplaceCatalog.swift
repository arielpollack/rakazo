import Foundation

enum MarketKind: String, CaseIterable {
  case app = "App"
  case server = "MCP server"
  case plugin = "Plugin"
  var plural: String { self == .server ? "MCP servers" : rawValue + "s" }
  var symbol: String {
    self == .app ? "macwindow" : self == .server ? "server.rack" : "puzzlepiece.extension"
  }
}

struct MarketPlugin: Decodable {
  let id: String, displayName: String, description: String, source: String, installedSource: String
  let category: String?, domains: [String]
  var logo: String? = nil
  var name: String?, hasConnector: Bool?, skillCount: Int?
}

struct MarketSource {
  let id: String, domain: String, name: String, summary: String
  var endpoint: String? = nil
  var auth: String? = nil
  var headerName: String? = nil
}

struct MarketItem: Identifiable {
  enum Content {
    case app(CatalogEntry, [LinkedApp])
    case plugin(MarketPlugin, installed: Bool)
    case server(MarketSource?, ToolServer?)
  }
  let id: String, name: String, brand: String, category: String, summary: String, content: Content
  var tools: [IntegrationTool] = []
  var publicLogo: URL? {
    let raw: String?
    switch content {
    case .app(let entry, _): raw = entry.logo
    case .plugin(let plugin, _): raw = plugin.logo
    case .server: return nil
    }
    guard let url = MarketDirectory.secureURL(raw), let host = url.host?.lowercased(),
      [
        "cdn.jsdelivr.net", "raw.githubusercontent.com", "assets.pipedream.net",
        "logos.composio.dev", "assets.composio.dev",
      ].contains(host)
    else { return nil }
    return url
  }
  var kind: MarketKind {
    switch content {
    case .app: return .app
    case .plugin: return .plugin
    case .server: return .server
    }
  }
  var confirmed: String? {
    switch content {
    case .app(let entry, let accounts):
      let active = accounts.filter { $0.status == "connected" }
      if let first = active.first {
        return "Connected · " + (active.count == 1 ? first.displayName : "\(active.count) accounts")
      }
      return entry.connected ? "Connected" : entry.noAuth ? "Available · No sign-in" : nil
    case .plugin(_, let installed): return installed ? "Installed" : nil
    case .server(_, let server):
      guard let server else { return nil }
      if server.connectionLabel == "Not connected", server.health.status == "unknown" {
        return "Configured · Not checked"
      }
      if server.connectionLabel != "Connected" { return server.connectionLabel }
      return server.health.toolCount.map { "Configured · \($0) tools" } ?? "Configured"
    }
  }
  var needsAttention: Bool {
    if case .server(_, let server?) = content { return server.connectionLabel != "Connected" }
    return false
  }
  var canResume: Bool {
    if case .server(let source?, let server?) = content {
      return source.endpoint != nil && server.enabled && server.connectionLabel != "Connected"
    }
    return false
  }
  var actionTitle: String {
    switch kind {
    case .app: return "Connect \(name)"
    case .plugin: return "Install \(name)"
    case .server: return "Add \(name) server"
    }
  }
  var domain: String {
    switch content {
    case .server(let source, _): return source?.domain ?? ""
    case .plugin(let plugin, _): return plugin.domains.joined(separator: " ")
    case .app: return ""
    }
  }
  func approveSample(in library: inout SampleIntegrations) {
    switch content {
    case .app(let entry, _): library.connect(entry)
    case .plugin(let plugin, _):
      library.installedPlugins = (library.installedPlugins ?? []).union([plugin.installedSource])
      if library.pluginNames == nil { library.pluginNames = [:] }
      library.pluginNames?[plugin.installedSource] = plugin.displayName
    case .server(let source?, _): library.add(.init(domain: source.domain, surfaces: ["mcp"]))
    case .server(nil, _): break
    }
  }
}

struct MarketActionFlow {
  private(set) var pending: String?
  private(set) var failures: [String: String] = [:]
  mutating func begin(_ item: MarketItem) -> Bool {
    guard pending == nil, item.confirmed == nil || item.canResume else { return false }
    failures[item.id] = nil
    pending = item.id
    return true
  }
  mutating func report(_ failure: String?, for item: MarketItem) {
    guard pending == item.id else { return }
    failures[item.id] = failure
  }
  mutating func close() { pending = nil }
}

struct MarketDirectory {
  var items: [MarketItem] = [], accounts: [LinkedApp] = [], warnings: [String] = []
  var installs: [ManagedInstall] = []
  static let brands: [String: (name: String, category: String, summary: String)] = [
    "gmail": ("Gmail", "Communication", "Find email threads and draft replies in your mailbox."),
    "slack": ("Slack", "Communication", "Find channels and read recent conversations."),
    "google-drive": ("Google Drive", "Files & docs", "Look up shared files and folders in Drive."),
    "google-calendar": (
      "Google Calendar", "Scheduling", "Find upcoming events and check your calendar."
    ),
    "github": ("GitHub", "Development", "Look up releases and issues in your repositories."),
    "figma": ("Figma", "Design", "Look up design files and their comments."),
    "linear": ("Linear", "Productivity", "Work with issues and projects through a bot."),
    "notion": ("Notion", "Productivity", "Find a page or database in your workspace."),
    "asana": ("Asana", "Productivity", "Find tasks and follow work across projects."),
  ]
  static func brand(_ raw: String) -> String {
    switch raw.lowercased() {
    case "googlecalendar": return "google-calendar"
    case "googledrive": return "google-drive"
    case "linear.app": return "linear"
    case "figma.com": return "figma"
    case "github.com": return "github"
    case "slack.com": return "slack"
    case "asana.com": return "asana"
    default: return raw.lowercased()
    }
  }
  static func secureURL(_ raw: String?) -> URL? {
    guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
      url.host?.isEmpty == false,
      url.user == nil, url.password == nil
    else { return nil }
    return url
  }
  static func sample(_ library: SampleIntegrations, seed: CatalogSeed) -> Self {
    var figma = MarketPlugin(
      id: "sample-figma", displayName: "Figma", description: brands["figma"]!.summary,
      source: "sample:figma", installedSource: "sample:figma", category: "Design",
      domains: ["figma.com"])
    figma.hasConnector = true; figma.skillCount = 2
    let additions = IntegrationFixtures.repositories.filter { $0 != "Figma" }.map { title in
      let preview = IntegrationFixtures.manifest(title)
      return MarketPlugin(id: "fixture:" + title, displayName: title, description: preview.description ?? title, source: IntegrationFixtures.repo(title), installedSource: IntegrationFixtures.repo(title), category: "Productivity", domains: [], name: title == "Slack triage" ? "Slack" : title, hasConnector: !preview.mcpServers.isEmpty, skillCount: preview.skills.count)
    }
    let sources = seed.sources.filter { $0.surfaces.contains("mcp") }.map { source in
      let info = brands[brand(source.domain)]
      return MarketSource(
        id: source.domain, domain: source.domain, name: info?.name ?? source.domain,
        summary: info?.summary ?? "")
    }
    return assemble(
      apps: library.catalog(seed), accounts: library.accounts, plugins: [figma] + additions,
      installed: library.installedPlugins ?? [], sources: sources, servers: library.servers,
      tools: Dictionary(uniqueKeysWithValues: seed.apps.map { ($0.slug, $0.tools) }))
  }
  static func assemble(
    apps: [CatalogEntry], accounts: [LinkedApp], plugins: [MarketPlugin], installed: Set<String>,
    sources: [MarketSource], servers: [ToolServer], tools: [String: [IntegrationTool]] = [:]
  ) -> Self {
    let accounts = accounts.filter { $0.status != "revoked" }
    var items = apps.map { entry in
      let mark = brand(entry.slug)
      let info = brands[mark]
      return MarketItem(
        id: "app:" + entry.id, name: entry.name, brand: mark, category: info?.category ?? "Other",
        summary: info?.summary ?? "Use \(entry.name) from a Rakazo conversation.",
        content: .app(
          entry,
          accounts.filter { $0.connectorId == entry.connectorId && $0.provider == entry.slug }),
        tools: tools[entry.slug] ?? [])
    }
    items += plugins.map { plugin in
      let mark =
        plugin.domains.lazy.map(brand).first { brands[$0] != nil } ?? brand(plugin.displayName)
      return MarketItem(
        id: "plugin:" + plugin.id, name: plugin.displayName, brand: mark,
        category: plugin.category ?? brands[mark]?.category ?? "Other", summary: plugin.description,
        content: .plugin(plugin, installed: installed.contains(plugin.installedSource)))
    }
    var matched = Set<String>()
    for source in sources {
      let mark = brand(source.domain)
      let server = servers.first {
        !matched.contains($0.id)
          && ($0.id == source.id || (source.endpoint != nil && $0.endpoint == source.endpoint))
      }
      if let server { matched.insert(server.id) }
      items.append(
        .init(
          id: "source:" + source.id, name: source.name, brand: mark,
          category: brands[mark]?.category ?? "Other",
          summary: source.summary, content: .server(source, server)))
    }
    for server in servers where !matched.contains(server.id) {
      let mark = brand(server.name)
      items.append(
        .init(
          id: "server:" + server.id, name: server.name, brand: mark,
          category: brands[mark]?.category ?? "Other",
          summary: server.health.message ?? "Manage this workspace’s MCP server and bot access.",
          content: .server(nil, server)))
    }
    let order = [
      "App:gmail", "App:slack", "App:google-drive", "Plugin:figma", "MCP server:linear",
      "App:notion",
    ]
    func rank(_ item: MarketItem) -> Int {
      order.firstIndex(of: item.kind.rawValue + ":" + item.brand) ?? order.count
    }
    items.sort { (rank($0), $0.name.lowercased(), $0.id) < (rank($1), $1.name.lowercased(), $1.id) }
    return Self(items: items, accounts: accounts)
  }
  func filtered(kind: MarketKind?, category: String?, search: String) -> [MarketItem] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return items.filter {
      (kind == nil || $0.kind == kind) && (category == nil || $0.category == category)
        && (query.isEmpty
          || [$0.name, $0.category, $0.domain, $0.summary, $0.kind.rawValue].contains {
            $0.localizedCaseInsensitiveContains(query)
          })
    }
  }
  private struct PluginFeed: Decodable {
    let entries: [MarketPlugin], unavailableRegistries: [String]
  }
  private struct SourceFeed: Decodable {
    struct Result: Decodable {
      struct Surface: Decodable {
        struct Auth: Decodable { let type: String, headerName: String? }
        let kind: String, slug: String, source: String?, auth: Auth?
      }
      let name: String, domain: String, description: String, surfaces: [Surface]
    }
    let results: [Result]
  }
  static func load(_ api: Client) async throws -> Self {
    var warnings: [String] = []
    async let servers: [ToolServer] = api.rpc("mcp/servers/list")
    async let pluginFeed: PluginFeed = api.rpc("marketplace/catalog", ["query": ""])
    async let installs: [ManagedInstall] = api.rpc("capabilities/list")
    async let sourceFeed: SourceFeed = api.rpc("capabilities/catalogSearch", ["query": ""])
    let catalog: [CatalogEntry] = try await api.rpc("connections/catalog")
    let accounts: [LinkedApp] = try await api.rpc("connections/list")
    var plugins: [MarketPlugin] = []
    var installed = Set<String>()
    var sources: [MarketSource] = []
    var configured: [ToolServer] = []
    var records: [ManagedInstall] = []
    do { records = try await installs; installed = Set(records.filter { $0.kind == "plugin" }.map(\.source)) }
    catch { warnings.append("Installed sources could not be loaded.") }
    do {
      let feed = try await pluginFeed
      plugins = feed.entries
      if !feed.unavailableRegistries.isEmpty {
        warnings.append("Some plugin registries are unavailable.")
      }
    } catch { warnings.append("The plugin directory is unavailable.") }
    do {
      configured = try await servers
      for result in try await sourceFeed.results {
        for surface in result.surfaces
        where surface.kind == "mcp" && secureURL(surface.source) != nil {
          sources.append(
            .init(
              id: result.domain + ":" + surface.slug, domain: result.domain, name: result.name,
              summary: result.description, endpoint: surface.source, auth: surface.auth?.type,
              headerName: surface.auth?.headerName))
        }
      }
    } catch { warnings.append("The MCP directory is partly unavailable.") }
    try Task.checkCancellation()
    var directory = assemble(
      apps: catalog, accounts: accounts, plugins: plugins, installed: installed, sources: sources,
      servers: configured)
    directory.warnings = warnings
    directory.installs = records
    return directory
  }
}
