import Combine
import Foundation

struct SpaceTool: Codable {
  struct Key: Hashable {
    let kind: String, id: String
  }
  struct Availability: Codable {
    var allSpaces: Bool, spaceIds: [String]
  }
  let kind: String, id: String, name: String
  var availability: Availability
  var key: Key { Key(kind: kind, id: id) }
}

@MainActor protocol PrivateSpaceOperations {
  func createPrivateSpace(name: String) async throws -> String
  func accountTools() async throws -> [SpaceTool]
  func chooseTools(_ selection: [SpaceTool.Key], for space: String) async throws
  func openPrivateSpace(_ id: String) async throws
}

@MainActor final class PrivateSpaceFlow: ObservableObject {
  enum Step { case name, loadingTools(String), choosing(String, [SpaceTool]), opening(String), done }
  @Published var name = ""
  @Published private(set) var step = Step.name
  @Published private(set) var busy = false
  @Published private(set) var issue: String?
  @Published var selection: Set<SpaceTool.Key> = []
  static let nameLimit = 60
  var enteringName: Bool { if case .name = step { return true }; return false }
  var nameTooLong: Bool { name.utf16.count > Self.nameLimit }
  var validName: Bool { !nameTooLong && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  func advance(using store: PrivateSpaceOperations) async -> Bool {
    guard !busy else { return false }
    if case .done = step { return false }
    if enteringName && !validName { return false }
    busy = true
    issue = nil
    defer { busy = false }
    do {
      if case .name = step {
        let id = try await store.createPrivateSpace(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        step = .loadingTools(id)
      }
      if case .loadingTools(let id) = step {
        let items = try await store.accountTools()
        if !items.isEmpty {
          selection = Set(items.filter(\.availability.allSpaces).map(\.key))
          step = .choosing(id, items)
          return false
        }
        step = .opening(id)
      }
      if case .choosing(let id, let items) = step {
        try await store.chooseTools(items.map(\.key).filter(selection.contains), for: id)
        step = .opening(id)
      }
      if case .opening(let id) = step {
        try await store.openPrivateSpace(id)
        step = .done
        return true
      }
    } catch { issue = error.localizedDescription }
    return false
  }
}

extension WorkspaceStore: PrivateSpaceOperations {
  func createPrivateSpace(name: String) async throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf16.count <= PrivateSpaceFlow.nameLimit else {
      throw Failure("Enter a space name of up to 60 characters.")
    }
    if let api = client {
      let created: ObjectID = try await api.rpc("spaces/create", ["name": trimmed])
      return created.id
    }
    guard var local = sample else { throw Failure("No active workspace.") }
    let id = UUID().uuidString
    local.spaces.append(.init(id: id, name: trimmed, bots: [], groups: [], botSections: []))
    sample = local
    return id
  }

  func accountTools() async throws -> [SpaceTool] {
    if let api = client { return try await api.rpc("availability/items") }
    guard let sample else { throw Failure("No active workspace.") }
    return sample.accountTools
  }

  func chooseTools(_ selection: [SpaceTool.Key], for space: String) async throws {
    if let api = client {
      let _: Empty = try await api.rpc("availability/chooseForSpace", [
        "spaceId": space, "items": selection.map { ["kind": $0.kind, "id": $0.id] },
      ])
    } else if var local = sample {
      try local.chooseTools(Set(selection), for: space)
      sample = local
    } else { throw Failure("No active workspace.") }
  }

  func openPrivateSpace(_ id: String) async throws {
    try await load(space: id)
    guard navigation?.current.id == id else { throw Failure("Couldn’t open the new space. Try again.") }
  }
}

extension Sample {
  private func library(in space: String) -> SampleIntegrations {
    integrations?[space] ?? .initial(space: space)
  }
  var accountTools: [SpaceTool] {
    var tools: [SpaceTool.Key: SpaceTool] = [:]
    for space in spaces {
      let library = library(in: space.id)
      func include(_ kind: String, _ id: String, _ name: String) {
        let key = SpaceTool.Key(kind: kind, id: id)
        tools[key, default: SpaceTool(kind: kind, id: id, name: name,
          availability: .init(allSpaces: false, spaceIds: []))].availability.spaceIds.append(space.id)
      }
      for server in library.servers { include("mcpServer", server.id, server.name) }
      for plugin in library.installedPlugins ?? [] {
        include("install", plugin, library.pluginNames?[plugin] ?? String(plugin.split(separator: ":").last ?? "Plugin").capitalized)
      }
    }
    return (Array(tools.values) + (spaceSkills ?? [])).sorted {
      ($0.name, $0.kind, $0.id) < ($1.name, $1.kind, $1.id)
    }
  }

  mutating func chooseTools(_ selection: Set<SpaceTool.Key>, for space: String) throws {
    guard spaces.contains(where: { $0.id == space }) else { throw Failure("Space not found.") }
    let items = accountTools
    var target = library(in: space)
    for item in items {
      let scopes = item.availability
      let wanted = selection.contains(item.key)
      guard wanted != (scopes.allSpaces || scopes.spaceIds.contains(space)) else { continue }
      switch item.kind {
      case "mcpServer":
        if wanted, let home = scopes.spaceIds.first,
          var server = library(in: home).servers.first(where: { $0.id == item.id }) {
          server.allBots = false
          target.servers.append(server)
        } else if !wanted {
          target.servers.removeAll { $0.id == item.id }; target.assignments[item.id] = nil
        }
      case "install":
        if wanted {
          target.installedPlugins = (target.installedPlugins ?? []).union([item.id])
          target.pluginNames = (target.pluginNames ?? [:]).merging([item.id: item.name]) { _, name in name }
        } else { target.installedPlugins?.remove(item.id); target.pluginNames?[item.id] = nil }
      case "skill":
        if let index = spaceSkills?.firstIndex(where: { $0.key == item.key }) {
          let others = (scopes.allSpaces ? spaces.map(\.id) : scopes.spaceIds).filter { $0 != space }
          spaceSkills?[index].availability = .init(allSpaces: false, spaceIds: others + (wanted ? [space] : []))
        }
      default: break
      }
    }
    if integrations == nil { integrations = [:] }
    integrations?[space] = target
  }
}
