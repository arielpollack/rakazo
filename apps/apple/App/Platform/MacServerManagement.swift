#if os(macOS)
  import SwiftUI
  import AuthenticationServices

  @MainActor func mcpBrowserCallback(_ url: URL, via session: WebAuthenticationSession) async throws
    -> URL
  {
    if #available(macOS 14.4, *) {
      return try await session.authenticate(
        using: url, callback: .customScheme("rakazo"), preferredBrowserSession: .shared,
        additionalHeaderFields: [:])
    }
    return try await session.authenticate(
      using: url, callbackURLScheme: "rakazo", preferredBrowserSession: .shared)
  }

  private func transportName(_ value: String) -> String {
    value == "stdio" ? "Standard I/O" : value == "sse" ? "Server-sent events" : "Streamable HTTP"
  }

  struct ManagedServerPage: View {
    @EnvironmentObject var session: ManagementSession
    @State var server: ToolServer
    @State private var grants: [ToolGrant] = []
    @State private var ready = false
    @State private var attempt = 0
    @State private var owner: ManagedInstall?
    private var botNames: [String] {
      grants.compactMap { grant in
        session.store.navigation?.current.bots.first { $0.id == grant.botId }?.name
      }.sorted()
    }
    var body: some View {
      ManagePage(
        "My integrations  /  MCP servers", server.name, server.description ?? "", width: 680,
        badge: server.connectionLabel
      ) {
        ManageGroup {
          ManageRow(
            server.oauthStatus == "reconnect" ? "Authorization expired" : "Connection status",
            server.health.message
              ?? (server.oauthStatus == "reconnect"
                ? "Reconnect to restore tool access. Your saved configuration is unchanged."
                : server.connectionLabel)
          ) {
            if server.oauthStatus == "connected" {
              Button("Disconnect OAuth…") {
                session.open(
                  .confirm(
                    "Disconnect OAuth?", "The configuration and bot assignments stay saved.",
                    [server.name], "Disconnect OAuth",
                    {
                      try await session.store.disconnectGrant(server)
                      session.back()
                    }))
              }
            } else if server.enabled {
              Button(server.oauthStatus == "reconnect" ? "Reconnect…" : "Sign in…") {
                session.open(.reconnect(server))
              }
            }
          }
        }
        ManageGroup("Server configuration") {
          ManageRow(
            transportName(server.transport),
            server.endpoint ?? server.command ?? "No command reported")
          if let id = server.oauthClientId {
            Divider()
            ManageRow("OAuth", id)
          }
        }
        ManageGroup("Access") {
          ManageRow(
            server.allBots == true ? "All bots" : "Selected bots",
            grants.compactMap { grant in
              session.store.navigation?.current.bots.first { $0.id == grant.botId }?.name
            }.sorted().joined(separator: ", ")
          ) { Button("Manage…") { session.open(.access(server)) } }
          Divider()
          ManageRow(
            server.health.toolCount.map { "\($0) discovered tools" } ?? "Tool discovery",
            "Last reported by the server"
          ) { Button("View tools…") { session.open(.tools(server, nil)) } }
        }
        if !ready { Button("Refresh server") { attempt += 1 } }
      } footer: {
        if server.installId != nil {
          Button("Manage parent plugin…") {
            if let owner { session.open(.plugin(owner.source, owner.id, owner.name, false)) }
          }.disabled(owner == nil)
        } else {
          Button("Remove server…", role: .destructive) {
            session.open(
              .confirm(
                "Remove \(server.name)?",
                "The server, credentials, and bot assignments will be removed.",
                [server.name, transportName(server.transport)]
                  + (server.allBots == true ? ["All bots"] : botNames), "Remove server",
                {
                  try await session.store.removeServer(server)
                  session.close()
                }))
          }.disabled(!ready)
        }
        Spacer()
        Button("Test connection") { session.open(.test(server)) }.disabled(!server.enabled)
        Button("Edit configuration…") { session.open(.configuration(server, server.transport)) }
          .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(
            !ready || (server.transport == "stdio" && !session.store.mayConfigureStdio))
      }.task(id: attempt) {
        do {
          ready = false
          guard
            let fresh = try await session.store.managedServers().first(where: { $0.id == server.id }
            )
          else { throw Failure("This server is no longer available in this space.") }
          server = fresh
          grants = try await session.store.grants(fresh)
          if let parent = fresh.installId {
            owner = try await session.store.managementInstalls().first { $0.id == parent }
          }
          ready = true
        } catch { if !Task.isCancelled { session.issue = error.localizedDescription } }
      }
    }
  }

  struct MacServerEditor: View {
    @EnvironmentObject var session: ManagementSession
    @State var draft: ServerDraft
    @State var tab = "Connection"
    init(_ server: ToolServer?, transport: String, tab: String = "Connection") {
      _draft = State(initialValue: .init(server, transport: transport))
      _tab = State(initialValue: tab)
    }
    var body: some View {
      ManagePage(
        (draft.original?.name ?? "MCP servers") + "  /  Configuration",
        draft.original == nil ? "Add MCP server" : "Edit server configuration",
        draft.transport == "stdio"
          ? "Admin only · Runs on your Rakazo server, not on this Mac." : ""
      ) {
        Picker("Configuration", selection: $tab) {
          ForEach(["Connection", "Credentials", "Advanced"], id: \.self) { Text($0) }
        }.labelsHidden().pickerStyle(.segmented)
        switch tab {
        case "Connection":
          ManageField("Server name") { TextField("Name", text: $draft.name) }
          ManageField("Transport") {
            Picker("Transport", selection: $draft.transport) {
              Text("Streamable HTTP").tag("streamable_http")
              Text("Server-sent events (SSE)").tag("sse")
              if session.store.mayConfigureStdio { Text("Standard I/O (stdio)").tag("stdio") }
            }.labelsHidden()
          }
          if draft.transport == "stdio" {
            ManageField("Command") { TextField("/path/to/server", text: $draft.command) }
            ManageField("Replacement arguments · one per line") {
              TextField(
                draft.original?.hasArgs == true ? "Stored · leave blank to keep" : "Arguments",
                text: $draft.arguments, axis: .vertical
              ).lineLimit(1...5)
            }
          } else {
            ManageField("Server URL") {
              TextField("https://tools.example/mcp", text: $draft.endpoint)
            }
          }
          Toggle("Server enabled", isOn: $draft.enabled).toggleStyle(.switch)
        case "Credentials":
          ManageField("Method") {
            Picker("Method", selection: $draft.method) {
              if draft.original != nil {
                Text("Keep stored credentials").tag("stored")
                Text("Clear stored credentials").tag("clear")
              } else {
                Text("No credential").tag("none")
              }
              if draft.transport != "stdio" {
                Text("Bearer token").tag("bearer")
                Text("API key header").tag("header")
              }
              Text("OAuth").tag("oauth")
            }.labelsHidden()
          }
          if draft.method == "clear" {
            Text("Saving clears stored tokens, headers, environment values, and files.")
              .foregroundStyle(.secondary)
          } else {
            if draft.method == "bearer" {
              ManageField("Replacement access token") {
                SecureField("Enter token", text: $draft.token)
              }
            }
            if draft.method == "oauth" || draft.original?.oauthClientId != nil {
              ManageGroup("OAuth client") {
                ManageRow(
                  draft.original?.oauthClientId ?? "Automatic registration",
                  "Stored secrets are never displayed."
                ) { Toggle("Replace…", isOn: $draft.editOAuth).toggleStyle(.button) }
                if draft.editOAuth { oauthFields }
              }
            }
            if draft.transport == "stdio" {
              entries("Environment & files", rows: $draft.environment, environment: true)
            } else {
              entries("HTTP headers", rows: $draft.headers, environment: false)
            }
          }
        default:
          Toggle("Return tool results verbatim", isOn: $draft.verbatim)
          ManageGroup("OAuth overrides") {
            Toggle("Replace OAuth settings", isOn: $draft.editOAuth)
            if draft.editOAuth {
              oauthFields
              ManageField("Authorization server") {
                TextField("https://accounts.example", text: $draft.issuer)
              }
              ManageField("Scopes") { TextField("Space-separated scopes", text: $draft.scopes) }
              ManageField("Authorization parameters") {
                TextField("prompt=consent", text: $draft.parameters)
              }
            }
          }
        }
      } footer: {
        Spacer()
        BackButton("Cancel")
        Button(
          draft.original == nil ? (draft.enabled ? "Add and test" : "Add server") : "Save changes"
        ) {
          session.perform {
            let saved = try await session.store.saveServer(draft)
            if draft.original == nil {
              session.replace(.server(saved))
              if draft.enabled { session.open(.test(saved)) }
            } else {
              session.back()
            }
          }
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(
          draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    @ViewBuilder private var oauthFields: some View {
      ManageField("Client ID") { TextField("Client ID", text: $draft.clientID) }
      ManageField("Client secret") {
        SecureField("Leave blank to keep the same client’s secret", text: $draft.clientSecret)
      }
      Text(
        "Replacing OAuth settings also replaces the scopes and authorization parameters. Review them in Advanced."
      ).font(.caption).foregroundStyle(.secondary)
    }
    private func entries(_ title: String, rows: Binding<[ServerDraft.Entry]>, environment: Bool)
      -> some View
    {
      ManageGroup(title) {
        ForEach(rows) { row in
          HStack {
            TextField(environment ? "VARIABLE" : "Header name", text: row.name)
            SecureField("Value · blank keeps stored", text: row.value)
            if environment { Toggle("File", isOn: row.file) }
            Button {
              rows.wrappedValue.removeAll { $0.id == row.wrappedValue.id }
            } label: {
              Image(systemName: "minus.circle")
            }.accessibilityLabel("Remove entry")
          }
        }
        Button(environment ? "Add entry…" : "Add header…") {
          rows.wrappedValue.append(.init(name: ""))
        }
      }
    }
  }

  struct ServerAgentsPage: View {
    @EnvironmentObject var session: ManagementSession
    let server: ToolServer
    @State private var all = false
    @State private var selected = Set<String>()
    @State private var grants: [ToolGrant] = []
    @State private var ready = false
    @State private var scope: SpaceTool.Availability?
    @State private var savedAll = false
    private var unsaved: Bool { all != savedAll || selected != Set(grants.map(\.botId)) }
    var body: some View {
      ManagePage(
        server.name + "  /  Access", "Agent access",
        "Choose which bots may use this server and its tools."
      ) {
        ManageGroup {
          ManageRow(
            "Available in",
            server.installId != nil
              ? "Inherited from the parent plugin"
              : scope?.allSpaces == true
                ? "All spaces"
                : session.store.navigation?.spaces.filter {
                  scope?.spaceIds.contains($0.id) == true
                }.map(\.name).joined(separator: ", ") ?? session.store.navigation?.current.name
                  ?? ""
          ) {
            if server.installId == nil {
              Button("Change…") { session.open(.scope("mcpServer", server.id, server.name, scope)) }
                .disabled(!ready || unsaved)
            }
          }
        }
        Picker("Agent access", selection: $all) {
          Text("Selected bots").tag(false)
          Text("All bots").tag(true)
        }.pickerStyle(.segmented).labelsHidden()
        if !all {
          ManageGroup {
            ForEach(session.store.navigation?.current.bots ?? []) { bot in
              HStack {
                Toggle(bot.name, isOn: membership(bot.id, in: $selected))
                Spacer()
                if let grant = grants.first(where: { $0.botId == bot.id }),
                  selected.contains(bot.id)
                {
                  Button(grant.allowAllTools ? "All tools…" : "\(grant.allowedTools.count) tools…")
                  { session.open(.tools(server, grant)) }.disabled(unsaved)
                }
              }
            }
          }
        }
      } footer: {
        Spacer()
        BackButton("Cancel")
        Button("Save access") {
          session.perform {
            try await session.store.saveAgents(server, all: all, bots: selected)
            session.back()
          }
        }.buttonStyle(.borderedProminent).disabled(!ready)
      }
      .task {
        do {
          let fresh = try await session.store.managedServers().first { $0.id == server.id }
          guard let fresh else { throw Failure("Server no longer available.") }
          all = fresh.allBots == true
          savedAll = all
          scope = fresh.availability
          grants = try await session.store.grants(fresh)
          selected = Set(grants.map(\.botId))
          ready = true
        } catch { session.issue = error.localizedDescription }
      }
    }
  }

  struct ServerToolsPage: View {
    @EnvironmentObject var session: ManagementSession
    let server: ToolServer, grant: ToolGrant?
    @State private var selected = Set<String>()
    @State private var all = false
    @State private var filter = ""
    @State private var newName = ""
    var body: some View {
      let tools = Set((server.sampleTools ?? []).map(\.name)).union(grant?.allowedTools ?? [])
        .union(selected).sorted()
      ManagePage(
        server.name + "  /  Tools",
        grant.flatMap { value in
          session.store.navigation?.current.bots.first { $0.id == value.botId }.map {
            "Tools for " + $0.name
          }
        } ?? "Discovered tools"
      ) {
        if grant != nil {
          Picker("Tool access", selection: $all) {
            Text("Selected tools only").tag(false)
            Text("All tools").tag(true)
          }.pickerStyle(.segmented).labelsHidden()
        }
        if grant == nil || !all {
          if !tools.isEmpty {
            TextField("Filter tools", text: $filter)
            ManageGroup {
              ForEach(
                tools.filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) },
                id: \.self
              ) { name in
                if grant != nil {
                  Toggle(name, isOn: membership(name, in: $selected))
                } else {
                  Text(name)
                }
              }
            }
          }
          if server.sampleTools == nil {
            Text("The server reports a discovery count, not a list of names.").foregroundStyle(
              .secondary)
            if grant != nil {
              HStack {
                TextField("Exact tool name", text: $newName)
                Button("Add") {
                  selected.insert(newName)
                  newName = ""
                }.disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              }
            }
          }
        }
      } footer: {
        Spacer()
        BackButton(grant == nil ? "Done" : "Cancel")
        if var grant {
          Button("Save tool access") {
            grant.allowAllTools = all
            grant.allowedTools = all ? [] : selected.sorted()
            let saved = grant
            session.perform {
              try await session.store.saveTools(saved)
              session.back()
            }
          }.buttonStyle(.borderedProminent)
        }
      }.onAppear {
        all = grant?.allowAllTools ?? false
        selected = Set(grant?.allowedTools ?? [])
      }
    }
  }

  struct ServerSignInPage: View {
    @EnvironmentObject var session: ManagementSession
    @Environment(\.webAuthenticationSession) var browser
    @Environment(\.openURL) private var openURL
    let server: ToolServer
    @State private var waiting = false
    @State private var browserURL: URL?
    var body: some View {
      ManagePage(
        server.name + "  /  OAuth", "Reconnect \(server.name)",
        session.store.demo
          ? "Sample authorization · No provider is contacted."
          : "Authorize in your browser, then return to Rakazo."
      ) {
        ManageGroup {
          ManageRow(
            waiting || browserURL != nil ? "Waiting for authorization" : "Ready to authorize",
            server.endpoint ?? server.name)
          if let browserURL { Link("Reopen sign-in", destination: browserURL) }
        }
      } footer: {
        Spacer()
        BackButton("Cancel")
        Button(
          waiting || browserURL != nil
            ? "Check connection"
            : (session.store.demo ? "Start sample sign-in" : "Continue in browser ↗")
        ) {
          session.perform {
            if session.store.demo {
              if waiting {
                session.store.completeSampleGrant(server)
                session.back()
              } else {
                waiting = true
              }
              return
            }
            if browserURL != nil {
              try await session.store.verifyBrowserGrant(server.id)
              session.back()
              return
            }
            switch try await session.store.authorizeServer(
              server.id, using: { try await mcpBrowserCallback($0, via: browser) })
            {
            case .finished: session.back()
            case .finishInBrowser(let url):
              browserURL = url
              openURL(url)
            }
          }
        }.buttonStyle(.borderedProminent)
      }
    }
  }
  struct ServerTestPage: View {
    @EnvironmentObject var session: ManagementSession
    let server: ToolServer
    @State private var result: ToolServer?
    @State private var checking = true
    @State private var attempt = 0
    var body: some View {
      ManagePage(
        server.name + "  /  Health",
        checking
          ? "Testing connection…"
          : result?.health.status == "ok" ? "Connection verified" : "Connection test failed"
      ) {
        ManageGroup {
          ManageRow(transportName(server.transport), server.endpoint ?? server.command ?? "")
          if checking {
            ProgressView().controlSize(.small)
          } else if let result {
            Divider()
            Text(
              result.health.message ?? result.health.toolCount.map { "\($0) tools available" }
                ?? result.connectionLabel)
          }
        }
      } footer: {
        BackButton("Close")
        Spacer()
        if !checking {
          Button("Edit configuration…") {
            session.replace(.configuration(server, server.transport))
          }
          Button("Test again") { attempt += 1 }.buttonStyle(.borderedProminent)
        }
      }.task(id: attempt) {
        checking = true
        session.issue = nil
        do { result = try await session.store.testServer(server) } catch {
          session.issue = error.localizedDescription
        }
        checking = false
      }
    }
  }
#endif
