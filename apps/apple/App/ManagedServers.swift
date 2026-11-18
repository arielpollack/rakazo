import Foundation

struct ServerDraft {
  struct Entry: Identifiable {
    let id = UUID(); var name: String, value = "", file = false
  }
  let original: ToolServer?
  var name: String, transport: String, endpoint: String, command: String, enabled: Bool, verbatim: Bool
  var method: String, token = "", arguments = "", headers: [Entry], environment: [Entry]
  var clientID: String, clientSecret = "", issuer = "", scopes = "", parameters = "", editOAuth = false
  init(_ server: ToolServer? = nil, transport initial: String = "streamable_http") {
    original = server; name = server?.name ?? ""; transport = server?.transport ?? initial
    endpoint = server?.endpoint ?? ""; command = server?.command ?? ""; enabled = server?.enabled ?? true
    verbatim = server?.verbatimResults ?? false; clientID = server?.oauthClientId ?? ""
    method = server == nil ? "none" : "stored"
    headers = (server?.headerKeys ?? []).map { Entry(name: $0) }
    environment = (server?.envKeys ?? []).map { Entry(name: $0) } + (server?.fileKeys ?? []).map { Entry(name: $0, file: true) }
  }
  var destinationChanged: Bool {
    guard let original else { return false }
    return transport != original.transport || (transport == "stdio" ? command != original.command : endpoint != original.endpoint)
  }
  func payload(admin: Bool) throws -> [String: Any] {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, title.count <= 120 else { throw Failure("Enter a server name (up to 120 characters).") }
    let generated = title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let slug = original?.slug ?? (generated.isEmpty ? "server-" + UUID().uuidString.prefix(8).lowercased() : String(generated.prefix(64)))
    var input: [String: Any] = ["name": title, "slug": slug, "enabled": enabled, "transport": transport, "description": original?.description ?? "", "verbatimResults": verbatim]
    if destinationChanged, let original, original.hasSecret == true || original.hasArgs == true || original.oauthClientId != nil || original.oauthStatus == "connected" || !(original.headerKeys ?? []).isEmpty || !(original.envKeys ?? []).isEmpty || !(original.fileKeys ?? []).isEmpty {
      guard method == "clear", original.hasArgs != true || original.command != command else { throw Failure("Choose Clear stored credentials before changing this destination. Stored credentials cannot move to a different server.") }
      input["oauthClient"] = NSNull()
    }
    func entries(_ rows: [Entry], pattern: String, caseInsensitive: Bool = false) throws -> [String: String] {
      var values = [String: String](), seen = Set<String>()
      for row in rows {
        guard row.name.range(of: pattern, options: .regularExpression) != nil, seen.insert(caseInsensitive ? row.name.lowercased() : row.name).inserted, !row.value.contains("\r") || !caseInsensitive, !row.value.contains("\n") || !caseInsensitive else { throw Failure("Each entry needs a valid, unique name and value.") }
        values[row.name] = row.value
      }; return values
    }
    if transport == "stdio" {
      guard admin, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("An administrator must provide the server command.") }
      input["command"] = command; input["args"] = arguments.components(separatedBy: .newlines).filter { !$0.isEmpty }
      let pattern = "^[A-Z_][A-Z0-9_]*$"; _ = try entries(environment, pattern: pattern)
      input["env"] = try entries(environment.filter { !$0.file }, pattern: pattern); input["files"] = try entries(environment.filter(\.file), pattern: pattern)
    } else {
      guard ["sse", "streamable_http"].contains(transport), let url = MarketDirectory.secureURL(endpoint), url.fragment == nil else { throw Failure("Enter an HTTPS server URL without embedded credentials or a fragment.") }
      input["endpoint"] = url.absoluteString
      input["headers"] = try entries(headers, pattern: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", caseInsensitive: true)
      if method == "bearer" { guard !token.isEmpty else { throw Failure("Enter the replacement token.") }; input["secret"] = token }
    }
    if method == "clear" { input["clearCredential"] = true }
    if editOAuth && method != "clear" {
      if clientID.isEmpty { input["oauthClient"] = NSNull() }
      else {
        var oauth = ["clientId": clientID, "scope": scopes, "authorizationParams": parameters]
        if !clientSecret.isEmpty { oauth["clientSecret"] = clientSecret }
        if transport == "stdio" || !issuer.isEmpty { guard MarketDirectory.secureURL(issuer) != nil else { throw Failure("Enter a secure authorization server URL.") }; oauth["authorizationServer"] = issuer }
        input["oauthClient"] = oauth
      }
    }; return input
  }
}

struct ToolGrant: Codable {
  var botId: String, serverId: String, allowAllTools: Bool, allowedTools: [String]
  var input: [String: Any] { ["serverId": serverId, "allowAllTools": allowAllTools, "allowedTools": allowedTools] }
}

extension WorkspaceStore {
  func managedServers() async throws -> [ToolServer] {
    if let client { return try await client.rpc("mcp/servers/list") }; return sampleIntegrations?.servers ?? []
  }
  func saveServer(_ draft: ServerDraft) async throws -> ToolServer {
    let input = try draft.payload(admin: mayConfigureStdio)
    if let client {
      if let original = draft.original { return try await client.rpc("mcp/servers/update", ["id": original.id, "config": input]) }
      return try await client.rpc("mcp/servers/create", input)
    }
    var saved = draft.original ?? ToolServer(id: UUID().uuidString, name: draft.name, transport: draft.transport, oauthStatus: "none", enabled: draft.enabled, health: .init(status: "unknown"), availability: .here(currentSpace))
    saved.name = draft.name; saved.slug = input["slug"] as? String; saved.transport = draft.transport; saved.endpoint = input["endpoint"] as? String; saved.command = input["command"] as? String; saved.enabled = draft.enabled; saved.verbatimResults = draft.verbatim
    if draft.destinationChanged || draft.editOAuth { saved.oauthStatus = "none"; saved.health = .init(status: "unknown"); saved.sampleTools = nil }
    if draft.editOAuth || draft.destinationChanged { saved.oauthClientId = draft.clientID.isEmpty || draft.method == "clear" ? nil : draft.clientID }
    let clear = draft.method == "clear"
    saved.headerKeys = clear ? [] : draft.headers.map(\.name); saved.envKeys = clear ? [] : draft.environment.filter { !$0.file }.map(\.name); saved.fileKeys = clear ? [] : draft.environment.filter(\.file).map(\.name)
    saved.hasSecret = !clear && (saved.hasSecret == true || !draft.token.isEmpty || !draft.headers.isEmpty || !draft.environment.isEmpty)
    saved.hasArgs = draft.transport == "stdio" && (!draft.arguments.isEmpty || (!draft.destinationChanged && saved.hasArgs == true))
    guard !(sampleIntegrations?.servers ?? []).contains(where: { $0.id != saved.id && $0.name.caseInsensitiveCompare(saved.name) == .orderedSame }) else { throw Failure("A server with that name already exists.") }
    updateSampleServer(saved); return saved
  }
  private func updateSampleServer(_ server: ToolServer) {
    guard var local = sample else { return }
    for space in local.spaces {
      var library = local.integrations?[space.id] ?? .initial(space: space.id)
      if let index = library.servers.firstIndex(where: { $0.id == server.id }) {
        library.servers[index] = server
      } else if space.id == currentSpace { library.servers.append(server) } else { continue }
      local.integrations?[space.id] = library
    }; sample = local
  }
  func removeServer(_ server: ToolServer) async throws {
    if let client { let _: Empty = try await client.rpc("mcp/servers/remove", ["id": server.id]); return }
    guard var local = sample else { return }; for space in local.spaces { local.integrations?[space.id]?.dropServer(server.id) }; sample = local
  }
  func testServer(_ server: ToolServer) async throws -> ToolServer {
    if let client { return try await client.rpc("mcp/servers/test", ["id": server.id]) }
    var result = server
    let success = server.enabled && server.oauthStatus != "reconnect" && (server.transport == "stdio" || URL(string: server.endpoint ?? "")?.host?.hasSuffix(".example") == true) && server.endpoint != "https://github.example/mcp"
    result.health = success ? .init(status: "ok", toolCount: server.sampleTools?.count ?? server.health.toolCount ?? 0) : .init(status: "error", message: server.oauthStatus == "reconnect" ? "Reconnect before testing this server." : "The sample endpoint did not respond.")
    updateSampleServer(result); return result
  }
  func beginServerSignIn(_ server: ToolServer) async throws -> URL? {
    guard let client else { return nil }
    struct Response: Decodable { let status: String, authorizationUrl: String? }
    let reply: Response = try await client.rpc("mcp/oauth/begin", ["serverId": server.id])
    if reply.status == "authorization_required", let url = MarketDirectory.secureURL(reply.authorizationUrl) { return url }
    guard ["already_connected", "authorization_not_requested"].contains(reply.status) else { throw Failure("The server did not return a secure authorization link.") }; return nil
  }
  func disconnectGrant(_ server: ToolServer) async throws {
    if let client { let _: Empty = try await client.rpc("mcp/oauth/disconnect", ["serverId": server.id]); return }
    var result = server; result.oauthStatus = "reconnect"; result.health = .init(status: "unknown"); updateSampleServer(result)
  }
  func completeSampleGrant(_ server: ToolServer) { guard demo else { return }; var result = server; result.oauthStatus = "connected"; updateSampleServer(result) }
  func grants(_ server: ToolServer) async throws -> [ToolGrant] {
    if let client { let list: [ToolGrant] = try await client.rpc("mcp/assignments/all"); return list.filter { $0.serverId == server.id } }
    let library = sampleIntegrations; return (library?.assignments[server.id] ?? []).map { bot in
      let allowed = library?.toolRules?[server.id]?[bot]; return ToolGrant(botId: bot, serverId: server.id, allowAllTools: allowed == nil, allowedTools: allowed ?? [])
    }
  }
  func saveAgents(_ server: ToolServer, all: Bool, bots: Set<String>) async throws {
    if let client { let _: Empty = try await client.rpc("mcp/servers/agents", ["id": server.id, "allBots": all, "botIds": bots.sorted()]); return }
    var result = sampleIntegrations?.servers.first { $0.id == server.id } ?? server; result.allBots = all; updateSampleServer(result)
    if !all { changeIntegrations { library in library.assignments[server.id] = bots; let retained = library.toolRules?[server.id]?.filter { bots.contains($0.key) }; library.toolRules?[server.id] = retained } }
  }
  func saveTools(_ grant: ToolGrant) async throws {
    if let client {
      var existing: [ToolGrant] = try await client.rpc("mcp/assignments/list", ["botId": grant.botId]); guard let index = existing.firstIndex(where: { $0.serverId == grant.serverId }) else { throw Failure("Save this bot’s access before changing its tools.") }
      existing[index] = grant
      let _: [ToolGrant] = try await client.rpc("mcp/assignments/replace", ["botId": grant.botId, "assignments": existing.map(\.input)]); return
    }
    changeIntegrations { library in var rules = library.toolRules ?? [:]; rules[grant.serverId, default: [:]][grant.botId] = grant.allowAllTools ? nil : grant.allowedTools; library.toolRules = rules }
  }
  func setScope(kind: String, id: String, scope: SpaceTool.Availability) async throws {
    guard !scope.spaceIds.isEmpty else { throw Failure("Select at least one space.") }
    if let client { let _: SpaceTool.Availability = try await client.rpc("availability/set", ["kind": kind, "id": id, "allSpaces": scope.allSpaces, "spaceIds": scope.spaceIds]); return }
    guard var local = sample else { throw Failure("No workspace.") }
    if kind == "skill", let index = local.integrationRecords?.skills.firstIndex(where: { $0.id == id }) { local.integrationRecords?.skills[index].availability = scope }
    if kind == "install", let index = local.integrationRecords?.installs.firstIndex(where: { $0.id == id }) { local.integrationRecords?.installs[index].availability = scope }
    let servers = local.spaces.flatMap { (local.integrations?[$0.id] ?? .initial(space: $0.id)).servers }.filter { kind == "mcpServer" ? $0.id == id : kind == "install" && $0.installId == id }
    for space in local.spaces {
      var library = local.integrations?[space.id] ?? .initial(space: space.id)
      for var server in servers { server.availability = scope
        if !scope.includes(space.id) { library.dropServer(server.id) }
        else if let index = library.servers.firstIndex(where: { $0.id == server.id }) { library.servers[index].availability = scope }
        else { library.servers.append(server) }
      }; local.integrations?[space.id] = library
    }; sample = local
  }
}
