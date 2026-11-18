import Foundation

struct ManagedSkill: Codable, Identifiable {
  let id: String
  var name: String, description: String, source: String, readOnly: Bool
  var content: String?, availability: SpaceTool.Availability?, parentID: String?
  var editable: Bool { source == "user" && !readOnly }
}

struct PluginManifest: Codable {
  struct Connector: Codable { var name: String, endpoint: String; var transport: String? }
  struct Skipped: Codable { var name: String, reason: String }
  var name: String, digest: String, skills: [IntegrationTool], mcpServers: [Connector], skipped: [Skipped]
  var description: String?, pinnedSource: String?, installedSource: String?, repository: String?
  var version: String?, license: String?, author: String?, resolvedSha: String?, parts: [String]?
  var availableParts: Set<String> {
    Set((skills.isEmpty ? [] : ["skills"]) + (mcpServers.isEmpty ? [] : ["connector"]))
  }
}

struct ManagedInstall: Codable, Identifiable {
  struct Settings: Codable {
    struct Auth: Codable { var type: String, name: String? }
    var auth: Auth?, manifest: PluginManifest?
    init(auth: Auth? = nil, manifest: PluginManifest? = nil) { self.auth = auth; self.manifest = manifest }
    enum CodingKeys: String, CodingKey { case auth }
    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      auth = try values.decodeIfPresent(Auth.self, forKey: .auth)
      manifest = try? PluginManifest(from: decoder)
    }
    func encode(to encoder: Encoder) throws {
      if let manifest { try manifest.encode(to: encoder) }
      var values = encoder.container(keyedBy: CodingKeys.self)
      try values.encodeIfPresent(auth, forKey: .auth)
    }
  }
  var id: String, kind: String, name: String, source: String, config: Settings
  var version: String?, availability: SpaceTool.Availability?, secretConfigured: Bool?
  var parts: Set<String> { Set(config.manifest?.parts ?? Array(config.manifest?.availableParts ?? [])) }
}

struct IntegrationRecords: Codable {
  var skills: [ManagedSkill] = [], installs: [ManagedInstall] = []
}

extension SpaceTool.Availability {
  func includes(_ space: String) -> Bool { allSpaces || spaceIds.contains(space) }
  static func here(_ space: String) -> Self { .init(allSpaces: false, spaceIds: [space]) }
}

enum IntegrationFixtures {
  static let repositories = ["Linear", "Review Kit", "Slack triage", "Figma"]
  static func repo(_ name: String) -> String {
    "https://github.com/example/" + name.lowercased().replacingOccurrences(of: " ", with: "-")
  }
  static func manifest(_ name: String) -> PluginManifest {
    let skills: [IntegrationTool] = name == "Review Kit" ? [
      .init(name: "Review changes", description: "Read changes before handing work off."),
      .init(name: "Prepare handoff", description: "Write a concise summary for the next teammate.")
    ] : [.init(name: "Triage \(name) updates", description: "Group updates by owner and urgency."),
         .init(name: "Summarize \(name) activity", description: "Prepare a short team briefing.")]
    return .init(name: name, digest: "sample-revision", skills: skills,
      mcpServers: name == "Review Kit" || name == "Slack triage" ? [] : [.init(name: name + " MCP", endpoint: "https://tools.example/mcp")],
      skipped: [], description: skills[0].description, installedSource: repo(name), repository: repo(name), version: "1.2.0", license: "MIT", author: "Fixture library")
  }
  static let tools = ["Search memories", "Read memory", "Delete memory", "List projects", "Save memory", "Edit memory", "Read briefing"].map { IntegrationTool(name: $0, description: "") }
}

extension Sample {
  mutating func seedIntegrationManagement() {
    let home = "local"
    var library = integrations?[home] ?? .initial(space: home)
    library.accounts.append(.init(id: "sample-personal-mail", connectorId: "sample-apps", provider: "gmail", displayName: "Personal inbox", status: "connected"))
    library.servers.append(.init(id: "sample-brain", name: "Agentic Brain", transport: "streamable_http", oauthStatus: "reconnect", enabled: true, health: .init(status: "ok", toolCount: 7), allBots: false, oauthClientId: "workspace-brain", endpoint: "https://brain.example/mcp", slug: "agentic-brain", description: "Workspace memory for your bots.", availability: .here(home), sampleTools: IntegrationFixtures.tools))
    library.assignments["sample-brain"] = ["sample-chief", "sample-scout"]
    library.toolRules = ["sample-brain": ["sample-chief": ["Search memories", "Read memory", "List projects"]]]
    for index in library.servers.indices where library.servers[index].transport != "stdio" && library.servers[index].endpoint == nil {
      library.servers[index].endpoint = "https://\(MarketDirectory.brand(library.servers[index].name)).example/mcp"
    }
    var records = IntegrationRecords(skills: [
      .init(id: "sample-weekly-brief", name: "Weekly brief", description: "Prepare a concise team update.", source: "user", readOnly: false, content: "1. Gather the week’s decisions.\n2. Group open questions by owner.\n3. End with three next steps.", availability: .here(home)),
      .init(id: "sample-builtin", name: "Rakazo", description: "Workspace basics", source: "builtin", readOnly: true, content: "Use the workspace context to answer questions.")])
    for name in ["Review Kit", "Linear"] {
      var manifest = IntegrationFixtures.manifest(name)
      manifest.parts = name == "Linear" ? ["connector"] : ["skills"]
      let source = IntegrationFixtures.repo(name)
      records.installs.append(.init(id: source, kind: "plugin", name: name, source: source, config: .init(manifest: manifest), availability: .here(home)))
      library.installedPlugins = (library.installedPlugins ?? []).union([source])
      library.pluginNames = (library.pluginNames ?? [:]).merging([source: name]) { _, new in new }
      if name == "Linear", let index = library.servers.firstIndex(where: { $0.id == "linear.app" }) { library.servers[index].installId = source }
    }
    records.installs.append(.init(id: "sample-handbook", kind: "api", name: "Team handbook", source: "https://docs.example/openapi.json", config: .init(auth: .init(type: "header", name: "x-api-key")), availability: .here(home), secretConfigured: true))
    integrationRecords = records
    if integrations == nil { integrations = [:] }; integrations?[home] = library
  }
}

extension WorkspaceStore {
  var currentSpace: String { navigation?.current.id ?? "" }
  var mayConfigureStdio: Bool { demo || account?.isAdmin == true }

  func managementInstalls() async throws -> [ManagedInstall] {
    if let client { return try await client.rpc("capabilities/list") }
    return sample?.integrationRecords?.installs.filter { $0.availability?.includes(currentSpace) != false } ?? []
  }
  func managementSkills() async throws -> [ManagedSkill] {
    if let client { return try await client.rpc("agentSkills/list") }
    var skills = sample?.integrationRecords?.skills.filter { $0.availability?.includes(currentSpace) != false } ?? []
    for install in try await managementInstalls() where install.parts.contains("skills") {
      skills += (install.config.manifest?.skills ?? []).map { skill in
        .init(id: install.id + ":" + skill.name, name: skill.name, description: skill.description, source: "plugin", readOnly: true, content: "# " + skill.name + "\n\n" + skill.description, availability: install.availability, parentID: install.id)
      }
    }
    return skills
  }
  func readSkill(_ skill: ManagedSkill) async throws -> ManagedSkill {
    if let client { return try await client.rpc("agentSkills/get", ["skillId": skill.id]) }
    return skill
  }
  func writeSkill(_ skill: ManagedSkill?, name: String, description: String, body: String) async throws -> ManagedSkill {
    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard skill?.editable != false, !title.isEmpty, title.count <= 80, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, description.count <= 2000, body.count <= 100_000 else { throw Failure("Enter a name and description for an editable skill.") }
    var input = ["name": title, "description": description, "body": body]
    if let skill { input["skillId"] = skill.id }
    if let client { return try await client.rpc(skill == nil ? "agentSkills/create" : "agentSkills/update", input) }
    guard var local = sample, var records = local.integrationRecords else { throw Failure("No workspace.") }
    guard !records.skills.contains(where: { $0.id != skill?.id && $0.name.caseInsensitiveCompare(title) == .orderedSame }) else { throw Failure("A skill with this name already exists.") }
    let saved = ManagedSkill(id: skill?.id ?? UUID().uuidString, name: title, description: description, source: "user", readOnly: false, content: "---\nname: \(title)\ndescription: \(description)\n---\n\n" + body, availability: skill?.availability ?? .init(allSpaces: true, spaceIds: [currentSpace]))
    records.skills.removeAll { $0.id == saved.id }; records.skills.append(saved); local.integrationRecords = records; sample = local
    return saved
  }
  func deleteSkill(_ skill: ManagedSkill) async throws {
    guard skill.editable else { throw Failure("This skill is read only.") }
    if let client { let _: Empty = try await client.rpc("agentSkills/remove", ["skillId": skill.id]); return }
    sample?.integrationRecords?.skills.removeAll { $0.id == skill.id }
  }
  func writeSkillDocument(_ skill: ManagedSkill, document: String) async throws {
    guard skill.editable, !document.isEmpty, document.count <= 100_000 else { throw Failure("Enter a valid editable skill document.") }
    if let client { let _: ManagedSkill = try await client.rpc("agentSkills/update", ["skillId": skill.id, "content": document]); return }
    guard let index = sample?.integrationRecords?.skills.firstIndex(where: { $0.id == skill.id }) else { throw Failure("The skill no longer exists.") }
    var value = skill
    if document.hasPrefix("---\n") {
      guard let end = document.dropFirst(4).range(of: "\n---\n") else { throw Failure("Close the SKILL.md front matter with ---.") }
      let metadata = document.dropFirst(4)[..<end.lowerBound].components(separatedBy: "\n")
      func field(_ key: String) -> String { metadata.first(where: { $0.hasPrefix(key + ":") }).map { String($0.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces) } ?? "" }
      value.name = field("name"); value.description = field("description"); guard !value.name.isEmpty, !value.description.isEmpty else { throw Failure("The skill needs a name and description.") }
    }; value.content = document; sample?.integrationRecords?.skills[index] = value
  }
  func previewRepository(_ raw: String) async throws -> PluginManifest {
    if let client { return try await client.rpc("capabilities/pluginPreview", ["source": raw]) }
    guard let name = IntegrationFixtures.repositories.first(where: { [IntegrationFixtures.repo($0), "sample:" + $0.lowercased()].contains(raw) }) else { throw Failure("This repository isn’t in the sample catalog. Try https://github.com/example/linear.") }
    return IntegrationFixtures.manifest(name)
  }
  func setPlugin(_ existing: ManagedInstall?, preview: PluginManifest, source: String, parts: Set<String>) async throws {
    guard parts.isSubset(of: preview.availableParts), existing != nil || !parts.isEmpty else { throw Failure("Choose a supported part.") }
    if let client {
      if let existing { let _: Empty = try await client.rpc("capabilities/pluginParts", ["id": existing.id, "parts": parts.sorted()]) }
      else { let _: ObjectID = try await client.rpc("capabilities/install", ["name": preview.name, "kind": "plugin", "source": preview.pinnedSource ?? source, "pluginDigest": preview.digest, "pluginParts": parts.sorted()]) }; return
    }
    guard var local = sample, var records = local.integrationRecords else { throw Failure("No workspace.") }
    let key = existing?.id ?? preview.installedSource ?? source
    var manifest = preview; manifest.parts = parts.sorted()
    let scope = existing?.availability ?? .init(allSpaces: true, spaceIds: [currentSpace])
    records.installs.removeAll { $0.id == key }
    if !parts.isEmpty { records.installs.append(.init(id: key, kind: "plugin", name: manifest.name, source: preview.installedSource ?? source, config: .init(manifest: manifest), availability: scope)) }
    local.integrationRecords = records
    for space in local.spaces where scope.includes(space.id) {
      var library = local.integrations?[space.id] ?? .initial(space: space.id)
      if !parts.contains("connector") {
        let removed = library.servers.filter { $0.installId == key }; removed.forEach { library.dropServer($0.id) }
      } else if !library.servers.contains(where: { $0.installId == key }) {
        for entry in preview.mcpServers { library.servers.append(.init(id: key + ":" + entry.name, name: entry.name, transport: entry.transport ?? "streamable_http", oauthStatus: "none", enabled: true, health: .init(status: "unknown"), endpoint: entry.endpoint, availability: scope, installId: key)) }
      }
      if parts.isEmpty { library.installedPlugins?.remove(key); library.pluginNames?[key] = nil }
      else { library.installedPlugins = (library.installedPlugins ?? []).union([key]); library.pluginNames = (library.pluginNames ?? [:]).merging([key: preview.name]) { _, new in new } }
      local.integrations?[space.id] = library
    }; sample = local
  }
  func removeSource(_ item: ManagedInstall) async throws {
    if let client { let _: Empty = try await client.rpc("capabilities/remove", ["id": item.id]); return }
    sample?.integrationRecords?.installs.removeAll { $0.id == item.id }
  }
  func addSource(kind: String, name: String, url: String, method: String, header: String, credential: String) async throws -> ManagedInstall {
    guard ["api", "graphql", "mcp"].contains(kind), MarketDirectory.secureURL(url) != nil, !name.isEmpty else { throw Failure("Enter a name and secure URL.") }
    var auth = ["type": method]; if method == "header" { auth["name"] = header }
    var config: [String: Any] = ["auth": auth]; if kind == "api" { config["openApi"] = true }
    var input: [String: Any] = ["kind": kind, "name": name, "source": url, "config": config]
    if method != "none" { guard !credential.isEmpty, method != "header" || !header.isEmpty else { throw Failure("Enter the requested credential.") }; input["credential"] = credential }
    if let client { return try await client.rpc("capabilities/install", input) }
    guard let host = URL(string: url)?.host, host.hasSuffix(".example") else { throw Failure("Sample verification accepts fixture hosts ending in .example only.") }
    let result = ManagedInstall(id: UUID().uuidString, kind: kind, name: name, source: url, config: .init(auth: .init(type: method, name: method == "header" ? header : nil)), availability: .init(allSpaces: true, spaceIds: [currentSpace]), secretConfigured: method != "none")
    sample?.integrationRecords?.installs.append(result); return result
  }
}

extension SampleIntegrations {
  mutating func dropServer(_ id: String) {
    servers.removeAll { $0.id == id }; assignments[id] = nil; toolRules?[id] = nil
  }
}
