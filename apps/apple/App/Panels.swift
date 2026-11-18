import SwiftUI

struct CreateForm: View {
  @ObservedObject var store: WorkspaceStore
  let kind: Panel
  let finished: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var description = ""
  @State private var members: Set<String> = []
  @State private var busy = false
  @State private var problem: String?
  var title: String {
    kind == .group ? "New group chat" : "New bot"
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("Name") { TextField("Name", text: $name).accessibilityIdentifier("newName") }
        if kind == .bot {
          Section("Description") {
            TextField("What does this bot help with?", text: $description, axis: .vertical)
              .lineLimit(2...5)
          }
        }
        if kind == .group {
          Section("Choose at least two bots") {
            ForEach(store.navigation?.current.bots.filter { $0.archivedAt == nil } ?? []) { bot in
              Button {
                if !members.insert(bot.id).inserted { members.remove(bot.id) }
              } label: {
                HStack {
                  Avatar(chat: bot, size: 30)
                  Text(bot.name)
                  Spacer()
                  Image(systemName: members.contains(bot.id) ? "checkmark.circle.fill" : "circle")
                }
              }
            }
          }
        }
        if let problem { Problem(text: problem) }
      }.navigationTitle(title).toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") { create() }.disabled(
            busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || (kind == .group && members.count < 2)
          ).accessibilityIdentifier("createSubmit")
        }
      }
    }.interactiveDismissDisabled(busy)
  }
  func create() {
    busy = true
    problem = nil
    Task {
      defer { busy = false }
      do {
        try await store.create(
          name: name.trimmingCharacters(in: .whitespacesAndNewlines), description: description,
          members: kind == .group ? Array(members) : nil)
        finished()
      } catch { problem = error.localizedDescription }
    }
  }
}

struct AccountView: View {
  @ObservedObject var store: WorkspaceStore
  @EnvironmentObject var session: AppSession
  @Environment(\.dismiss) private var dismiss
  @AppStorage("appearance") private var appearance = "System"
  @State private var busy = false
  @State private var problem: String?
  @State private var confirmForget = false
  var body: some View {
    NavigationStack {
      Form {
        Section("Account") {
          LabeledContent("Name", value: store.account?.name ?? "—")
          if let email = store.account?.email, !email.isEmpty {
            LabeledContent("Email", value: email)
          }
          LabeledContent("Server", value: store.login?.server.absoluteString ?? "On-device sample")
        }
        Picker("Appearance", selection: $appearance) {
          ForEach(["System", "Light", "Dark"], id: \.self) { Text($0) }
        }
        if let url = store.link() { Link("Open full workspace on the web ↗", destination: url) }
        Button(store.demo ? "Connect a server" : "Sign out") {
          busy = true
          Task {
            defer { busy = false }
            do {
              try await session.leave()
              dismiss()
            } catch { problem = error.localizedDescription }
          }
        }.disabled(busy)
        if let problem {
          Problem(text: problem)
          Button("Forget session on this device", role: .destructive) { confirmForget = true }
        }
      }.navigationTitle("Settings").toolbar {
        #if os(iOS)
          ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        #endif
      }.confirmationDialog(
        "Remove the local session? The server session may still be active.",
        isPresented: $confirmForget, titleVisibility: .visible
      ) {
        Button("Forget on this device", role: .destructive) {
          do {
            try session.forget()
            dismiss()
          } catch { problem = error.localizedDescription }
        }
      }
    }
  }
}

struct ActivityView: View {
  @ObservedObject var store: WorkspaceStore
  let open: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var filter = "active"
  @State private var rows: [Activity] = []
  @State private var problem: String?
  @State private var busy = true
  var body: some View {
    NavigationStack {
      VStack {
        Picker("Activity", selection: $filter) {
          Text("Active").tag("active")
          Text("Recent").tag("recent")
        }.pickerStyle(.segmented).padding()
        if busy {
          ProgressView()
        } else if let problem {
          Problem(text: problem).padding()
          Button("Retry") { Task { await load() } }
        } else if rows.isEmpty {
          Spacer()
          Notice(
            symbol: "bell", title: filter == "active" ? "No active runs" : "No recent activity",
            detail: "Bot activity appears here.")
          Spacer()
        } else {
          List(rows) { run in
            Button {
              open(run.groupId ?? run.botId)
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                Text(run.groupName ?? run.botName).bold()
                Text(run.promptSnippet).lineLimit(2)
                Text("\(run.status.capitalized) · \(Clock.label(run.updatedAt))").font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        Spacer(minLength: 0)
      }.navigationTitle("Activity").toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }.task(id: filter) { await load() }
    }
  }
  func load() async {
    busy = true
    problem = nil
    let selected = filter
    do {
      let result: Activities
      if let api = store.client {
        result = try await api.rpc("runs/list", ["filter": selected])
      } else {
        result = Activities(runs: [])
      }
      try Task.checkCancellation()
      rows = result.runs
      busy = false
    } catch {
      if !Task.isCancelled {
        problem = error.localizedDescription
        busy = false
      }
    }
  }
}

struct ConnectionsView: View {
  @ObservedObject var store: WorkspaceStore
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var phase
  @State private var entries: [CatalogEntry] = []
  @State private var accounts: [LinkedApp] = []
  @State private var managing: LinkedApp?
  @State private var showingServers = false
  @State private var search = ""
  @State private var problem: String?
  @State private var pending: CatalogEntry?
  @State private var busy = false
  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Picker("Integration type", selection: $showingServers) {
          Text("Apps").tag(false)
          Text("MCP servers").tag(true)
        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal).padding(.vertical, 8)
        if showingServers { ToolServersView(store: store, search: search) } else { appList }
      }.navigationTitle("Connect apps").searchable(text: $search, prompt: "Search integrations")
        .toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }.task(id: phase == .active) { if store.demo || phase == .active { await load() } }
        .sheet(item: $managing, onDismiss: { Task { await load() } }) { account in
          ConnectionDetails(store: store, account: account).integrationSheet()
        }.sheet(item: $pending, onDismiss: { Task { await load() } }) { entry in
          if let api = store.client {
            ConnectorAuthorization(
              api: api, provider: entry.slug, connector: entry.connectorId, name: entry.name,
              origin: nil
            ).integrationSheet()
          } else {
            SampleAppReview(store: store, entry: entry).integrationSheet()
          }
        }
    }
  }
  private var matchingAccounts: [LinkedApp] {
    accounts.filter {
      search.isEmpty
        || ($0.displayName + " " + $0.provider).localizedCaseInsensitiveContains(search)
    }
  }
  private var matchingEntries: [CatalogEntry] {
    entries.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
  }
  private var appList: some View {
    List {
      if let problem {
        Problem(text: problem)
        Button("Retry") { Task { await load() } }
      }
      if busy {
        ProgressView()
      } else if entries.isEmpty && accounts.isEmpty && search.isEmpty && problem == nil {
        Notice(symbol: "puzzlepiece.extension", title: "No integrations available")
      }
      if !matchingAccounts.isEmpty {
        Section("Your connections") {
          ForEach(matchingAccounts) { account in
            Button {
              managing = account
            } label: {
              HStack {
                Label(account.displayName, systemImage: "link")
                Spacer()
                Text(account.status.capitalized).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.caption)
              }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("connection-" + account.id)
          }
        }
      }
      if !matchingEntries.isEmpty {
        Section("App catalog") {
          ForEach(matchingEntries) { entry in
            HStack {
              Image(systemName: "puzzlepiece.extension")
              Text(entry.name)
              Spacer()
              if entry.connected || entry.noAuth {
                Text(entry.connected ? "Connected" : "Available").font(.caption).foregroundStyle(
                  .secondary)
              } else {
                Button("Connect") { pending = entry }.buttonStyle(.bordered)
                  .accessibilityIdentifier("connect-" + entry.slug)
              }
            }
          }
        }
      }
      if !busy && problem == nil && !search.isEmpty && matchingAccounts.isEmpty
        && matchingEntries.isEmpty
      {
        ContentUnavailableView.search(text: search)
      }
    }
  }
  func load() async {
    busy = true
    problem = nil
    defer { busy = false }
    do {
      if let library = store.sampleIntegrations {
        entries = library.catalog(try CatalogSeed.bundled.get())
        accounts = library.accounts
        return
      }
      guard let api = store.client else { return }
      async let catalog: [CatalogEntry] = api.rpc("connections/catalog")
      async let linked: [LinkedApp] = api.rpc("connections/list")
      let (available, connected) = try await (catalog, linked)
      try Task.checkCancellation()
      entries = available
      accounts = connected.filter { $0.status != "revoked" }
    } catch {
      if !Task.isCancelled { problem = error.localizedDescription }
    }
  }
}

struct ConnectorAuthorization: View {
  struct Origin { let botId: String, threadId: String, messageId: String }
  private struct Authorization: Decodable { let connectionId: String, authorizationUrl: String? }
  private struct StateReply: Decodable { let status: String }
  let api: Client, provider: String, connector: String?, name: String, origin: Origin?
  var startOnPresentation = false
  var onFailure: (String?) -> Void = { _ in }
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var phase
  @Environment(\.openURL) private var openURL
  @State private var connectionId: String?
  @State private var authorizationURL: URL?
  @State private var problem: String?
  @State private var status: String?
  @State private var busy = false
  @State private var started = false
  var body: some View {
    NavigationStack {
      Form {
        Section("Connect \(name)") {
          Label(name, systemImage: "puzzlepiece.extension").font(.headline)
          Text(
            "This connection is for the current Rakazo workspace. Review the provider’s permissions before approving access."
          )
          if let status { Text(status).foregroundStyle(.secondary) }
          if let problem { Problem(text: problem) }
        }
        Section {
          if busy { ProgressView() }
          Button(connectionId == nil ? "Continue to authorization" : "Check connection") {
            Task { await advance() }
          }.disabled(busy)
          if let authorizationURL {
            Link("Reopen authorization in browser", destination: authorizationURL)
          }
        }
      }.navigationTitle("Authorization").inlineMobileTitle()
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }.disabled(busy)
          }
        }
        .onChange(of: phase) { _, state in
          if state == .active && connectionId != nil { Task { await advance() } }
        }
    }.interactiveDismissDisabled(busy).task {
      if startOnPresentation && !started { started = true; await advance() }
    }
  }
  private func advance() async {
    guard !busy else { return }
    busy = true
    problem = nil
    defer { busy = false }
    do {
      if connectionId == nil {
        var input = ["provider": provider, "displayName": name]
        input["connectorId"] = connector
        let started: Authorization = try await api.rpc("connections/begin", input)
        if let raw = started.authorizationUrl {
          guard let url = URL(string: raw), url.scheme?.lowercased() == "https",
            url.host?.isEmpty == false, url.user == nil, url.password == nil
          else { throw Failure("Authorization link was not a secure web address.") }
          connectionId = started.connectionId
          authorizationURL = url
          status = "Finish authorization in your browser, then return here."
          openURL(url)
          return
        }
        connectionId = started.connectionId
      }
      guard let connectionId else { return }
      let result: StateReply = try await api.rpc(
        "connections/complete", ["connectionId": connectionId])
      guard result.status == "connected" else {
        if result.status == "revoked" || result.status == "error" {
          self.connectionId = nil
          authorizationURL = nil
          status = result.status == "revoked" ? "Authorization was revoked." : "The provider could not authorize this connection. Try again."
          onFailure(status)
        } else {
          status = "Authorization is still pending. You can check again after approving it."
        }
        return
      }
      if let origin {
        var input = [
          "provider": provider, "botId": origin.botId, "threadId": origin.threadId,
          "messageId": origin.messageId,
        ]
        input["connectorId"] = connector
        let _: Empty = try await api.rpc("onboarding/appConnected", input)
      }
      onFailure(nil)
      dismiss()
    } catch { problem = error.localizedDescription; onFailure(problem) }
  }
}

struct ConnectionDetails: View {
  @ObservedObject var store: WorkspaceStore
  let account: LinkedApp
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var tools: [IntegrationTool] = []
  @State private var problem: String?
  @State private var busy = false
  @State private var confirming = false
  @State private var loading = true
  var body: some View {
    NavigationStack {
      Form {
        Section("Account") {
          TextField("Connection name", text: $name)
          LabeledContent("Provider", value: account.provider)
          LabeledContent("Status", value: account.status.capitalized)
        }
        Section("Available tools") {
          if loading {
            ProgressView()
          } else if tools.isEmpty && problem == nil {
            Text("No tools reported").foregroundStyle(.secondary)
          }
          ForEach(tools, id: \.name) { tool in
            VStack(alignment: .leading, spacing: 4) {
              Text(tool.name)
              Text(tool.description).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        if let problem { Problem(text: problem) }
        Section { Button("Disconnect account", role: .destructive) { confirming = true } }
      }.navigationTitle("Connection").inlineMobileTitle().toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { change(revoke: false) }.disabled(
            clean.isEmpty || clean.count > 80 || clean == account.displayName)
        }
      }.disabled(busy).interactiveDismissDisabled(busy)
        .task {
          name = account.displayName
          defer { loading = false }
          do {
            if let api = store.client {
              tools = try await api.rpc(
                "connections/tools",
                ["connectorId": account.connectorId, "provider": account.provider])
            } else {
              tools =
                try CatalogSeed.bundled.get().apps.first { $0.slug == account.provider }?.tools
                ?? []
            }
          } catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }.confirmationDialog(
          "Disconnect \(account.displayName)?", isPresented: $confirming, titleVisibility: .visible
        ) {
          Button("Disconnect", role: .destructive) { change(revoke: true) }
        } message: {
          Text("Bots in this workspace will no longer be able to use this account.")
        }
    }
  }
  private var clean: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  func change(revoke: Bool) {
    guard !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        if store.demo {
          store.changeIntegrations { library in
            if revoke {
              library.accounts.removeAll { $0.id == account.id }
            } else if let index = library.accounts.firstIndex(where: { $0.id == account.id }) {
              library.accounts[index].displayName = clean
            }
          }
        } else if let api = store.client, revoke {
          let _: Empty = try await api.rpc("connections/revoke", ["connectionId": account.id])
        } else if let api = store.client {
          let _: LinkedApp = try await api.rpc(
            "connections/rename", ["connectionId": account.id, "displayName": clean])
        }
        dismiss()
      } catch { problem = error.localizedDescription }
    }
  }
}
