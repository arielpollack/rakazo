import SwiftUI

extension View {
  @ViewBuilder func integrationSheet() -> some View {
    #if os(macOS)
      frame(minWidth: 400, idealWidth: 480, minHeight: 300, idealHeight: 410)
    #else
      self
    #endif
  }
}

struct SampleAppReview: View {
  @ObservedObject var store: WorkspaceStore
  let entry: CatalogEntry
  var didConnect: () -> Void = {}
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      Form {
        Section("Connect \(entry.name)") {
          Label(entry.name, systemImage: "puzzlepiece.extension")
          Text("Sample authorization. No account is contacted.").foregroundStyle(.secondary)
        }
        Section("Available tools") {
          ForEach(
            (try? CatalogSeed.bundled.get().apps.first { $0.slug == entry.slug }?.tools) ?? [],
            id: \.name
          ) { tool in
            Text(tool.description).font(.callout)
          }
        }
      }.formStyle(.grouped).navigationTitle("Authorization").inlineMobileTitle().toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Connect") {
            store.changeIntegrations { $0.connect(entry) }
            didConnect()
            dismiss()
          }
        }
      }
    }
  }
}

struct ToolServersView: View {
  @ObservedObject var store: WorkspaceStore
  let search: String
  @State private var liveServers: [ToolServer] = []
  @State private var problem: String?
  @State private var loading = true
  @State private var version = 0
  @State private var selected: ToolServer?
  @State private var sources: [CatalogSeed.Source] = []
  private var servers: [ToolServer] { store.sampleIntegrations?.servers ?? liveServers }
  private var shown: [ToolServer] {
    servers.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
  }
  private var available: [CatalogSeed.Source] {
    sources.filter { source in
      source.surfaces.contains("mcp") && !servers.contains { $0.id == source.id }
        && (search.isEmpty || source.domain.localizedCaseInsensitiveContains(search))
    }
  }
  var body: some View {
    List {
      if loading {
        ProgressView()
      } else if let problem {
        Problem(text: problem)
        Button("Retry") { version += 1 }
      } else {
        if !shown.isEmpty {
          Section("Your servers") {
            ForEach(shown) { server in
              Button {
                selected = server
              } label: {
                HStack {
                  Label(
                    server.name,
                    systemImage: server.transport == "stdio" ? "terminal" : "server.rack")
                  Spacer()
                  Text(server.connectionLabel).font(.caption).foregroundStyle(.secondary)
                  Image(systemName: "chevron.right").font(.caption)
                }.contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityIdentifier("mcp-" + server.id)
            }
          }
        }
        if !available.isEmpty {
          Section("From the public catalog") {
            ForEach(available) { source in
              HStack {
                VStack(alignment: .leading) {
                  Text(source.domain)
                  Text(source.surfaces.map { $0.uppercased() }.joined(separator: " · ")).font(
                    .caption
                  ).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add") {
                  store.changeIntegrations { $0.add(source) }
                  selected = servers.first { $0.id == source.id }
                }
                .accessibilityLabel("Add \(source.domain)")
              }
            }
          }
        }
        if shown.isEmpty && available.isEmpty {
          if search.isEmpty {
            Notice(symbol: "server.rack", title: "No MCP servers")
          } else {
            ContentUnavailableView.search(text: search)
          }
        }
      }
    }.task(id: version) {
      loading = true
      problem = nil
      defer { if !Task.isCancelled { loading = false } }
      do {
        if let api = store.client {
          let result: [ToolServer] = try await api.rpc("mcp/servers/list")
          try Task.checkCancellation()
          liveServers = result
        } else {
          sources = try CatalogSeed.bundled.get().sources
        }
      } catch { if !Task.isCancelled { problem = error.localizedDescription } }
    }.rakazoSheet(item: $selected, onDismiss: { version += 1 }) { server in
      ServerAccessView(store: store, server: server).integrationSheet()
    }
  }
}

struct ServerAccessView: View {
  struct Assignment: Decodable { let botId: String, serverId: String }
  @ObservedObject var store: WorkspaceStore
  let server: ToolServer
  @Environment(\.dismiss) private var dismiss
  @State private var allBots = false
  @State private var ready = false
  @State private var saving = false
  @State private var selected = Set<String>()
  @State private var problem: String?
  private var current: ToolServer {
    store.sampleIntegrations?.servers.first { $0.id == server.id } ?? server
  }
  var body: some View {
    NavigationStack {
      Form {
        Section {
          LabeledContent("Status", value: current.connectionLabel)
          LabeledContent(
            "Transport",
            value: server.transport == "stdio"
              ? "Local process"
              : server.transport == "sse" ? "Server-sent events" : "Streamable HTTP")
          if let count = current.health.toolCount {
            LabeledContent("Discovered tools", value: "\(count)")
          }
          if let reason = current.health.message {
            Text(reason).font(.caption).foregroundStyle(.secondary)
          }
          if store.demo, current.connectionLabel != "Connected" {
            Button(
              current.oauthStatus == "reconnect" ? "Simulate sign-in" : "Simulate successful check"
            ) {
              store.changeIntegrations { library in
                guard let index = library.servers.firstIndex(where: { $0.id == server.id }) else {
                  return
                }
                library.servers[index].oauthStatus =
                  current.oauthStatus == "reconnect" ? "connected" : current.oauthStatus
                library.servers[index].health = .init(
                  status: "ok", toolCount: current.health.toolCount ?? 1)
              }
            }
          }
        }
        Section("Agent access") {
          if !ready && problem == nil { ProgressView() }
          if ready {
            Toggle("All bots", isOn: $allBots)
            if !allBots {
              ForEach(store.navigation?.current.bots ?? []) { chat in
                Toggle(
                  chat.name,
                  isOn: Binding(
                    get: { selected.contains(chat.id) },
                    set: { enabled in
                      if enabled { selected.insert(chat.id) } else { selected.remove(chat.id) }
                    }))
              }
            }
          }
          if let problem {
            Problem(text: problem)
            if !ready { Button("Retry") { Task { await load() } } }
          }
        }
      }.formStyle(.grouped).navigationTitle(server.name).inlineMobileTitle().toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { Task { await save() } }.disabled(!ready || saving)
        }
      }.disabled(saving).interactiveDismissDisabled(saving).task { await load() }
    }
  }
  func load() async {
    problem = nil
    do {
      if let library = store.sampleIntegrations {
        selected = library.assignments[server.id] ?? []
      } else if let api = store.client {
        let values: [Assignment] = try await api.rpc("mcp/assignments/all")
        try Task.checkCancellation()
        selected = Set(values.filter { $0.serverId == server.id }.map(\.botId))
      }
      allBots = server.allBots ?? false
      ready = true
    } catch { if !Task.isCancelled { problem = error.localizedDescription } }
  }
  func save() async {
    guard !saving, ready else { return }
    saving = true
    defer { saving = false }
    let botIDs = allBots ? Set<String>() : selected
    do {
      if let api = store.client {
        let _: Empty = try await api.rpc(
          "mcp/servers/agents", ["id": server.id, "allBots": allBots, "botIds": botIDs.sorted()])
      } else {
        store.changeIntegrations { library in
          guard let index = library.servers.firstIndex(where: { $0.id == server.id }) else {
            return
          }
          library.servers[index].allBots = allBots
          library.assignments[server.id] = botIDs
        }
      }
      dismiss()
    } catch { problem = error.localizedDescription }
  }
}
