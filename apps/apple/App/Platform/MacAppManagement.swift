#if os(macOS)
  import SwiftUI

  struct AppAccountsPage: View {
    @EnvironmentObject var session: ManagementSession
    let entry: CatalogEntry
    @State var accounts: [LinkedApp] = []
    @State var tools: [IntegrationTool] = []
    @State var expanded = true
    @State var ready = false
    @State var attempt = 0
    var body: some View {
      ManagePage("My integrations  /  Apps", entry.name, width: 650) {
        ManageGroup("Accounts") {
          if ready && accounts.isEmpty { Text("No connected accounts").foregroundStyle(.secondary) }
          ForEach(accounts) { account in
            ManageRow(account.displayName, account.status.capitalized) {
              Button("Manage…") { session.open(.account(entry, account)) }.accessibilityLabel(
                "Manage \(account.displayName)")
            }
          }
          Button(accounts.isEmpty ? "Connect \(entry.name)…" : "Add account…") {
            session.open(.authorize(entry))
          }.disabled(!ready || entry.noAuth)
        }
        ManageGroup {
          DisclosureGroup("Available tools · \(tools.count)", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 9) {
              ForEach(tools, id: \.name) { tool in ManageRow(tool.name, tool.description) }
              if tools.isEmpty { Text("No tools reported.").foregroundStyle(.secondary) }
            }.padding(.top, 7)
          }
        }
        if session.issue != nil { Button("Retry") { attempt += 1 } }
      } footer: {
        if !accounts.isEmpty {
          Button("Disconnect \(entry.name)…", role: .destructive) {
            let reviewed = accounts
            session.open(
              .confirm(
                "Disconnect \(entry.name)?",
                "Bots will lose access to these accounts. No provider data will be deleted.",
                reviewed.map(\.displayName),
                reviewed.count == 1
                  ? "Disconnect account" : "Disconnect \(reviewed.count) accounts",
                {
                  let remaining = try await session.store.linkedAccounts(entry)
                  for account in reviewed where remaining.contains(where: { $0.id == account.id }) {
                    try await session.store.revokeAccount(account)
                  }
                  session.back()
                }))
          }
        }
        Spacer()
        BackButton()
      }.task(id: attempt) {
        session.issue = nil
        do {
          accounts = try await session.store.linkedAccounts(entry)
          ready = true
          if let client = session.store.client {
            tools = try await client.rpc(
              "connections/tools", ["connectorId": entry.connectorId, "provider": entry.slug])
          } else {
            tools = try CatalogSeed.bundled.get().apps.first { $0.slug == entry.slug }?.tools ?? []
          }
        } catch { if !Task.isCancelled { session.issue = error.localizedDescription } }
      }
    }
  }

  struct AppAccountEditor: View {
    @EnvironmentObject var session: ManagementSession
    let entry: CatalogEntry, account: LinkedApp
    @State private var label = ""
    var body: some View {
      ManagePage(
        entry.name + "  /  Manage account", account.displayName,
        "Change how this account appears in Rakazo."
      ) {
        ManageField("Account label") { TextField("Account label", text: $label) }
        ManageGroup {
          ManageRow("Connection", account.status.capitalized)
          Divider()
          ManageRow("Disconnect this account", "Other \(entry.name) accounts stay connected.") {
            Button("Disconnect…") {
              session.open(
                .confirm(
                  "Disconnect \(account.displayName)?",
                  "Only this account will be removed from Rakazo.",
                  [account.displayName, entry.name], "Disconnect account",
                  {
                    try await session.store.revokeAccount(account)
                    session.back(2)
                  }))
            }
          }
        }
      } footer: {
        Spacer()
        BackButton("Cancel")
        Button("Save changes") {
          session.perform {
            try await session.store.renameAccount(account, to: clean)
            session.back()
          }
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(
          clean.isEmpty || clean.count > 80 || clean == account.displayName)
      }.onAppear { label = account.displayName }
    }
    private var clean: String { label.trimmingCharacters(in: .whitespacesAndNewlines) }
  }

  struct AppAuthorizationPage: View {
    @EnvironmentObject var session: ManagementSession
    @Environment(\.openURL) var openURL
    let entry: CatalogEntry
    @State var connectionID: String?
    @State var url: URL?
    var body: some View {
      ManagePage(
        "Connect  /  " + entry.name,
        connectionID == nil ? "Connect \(entry.name)" : "Finish connecting \(entry.name)",
        session.store.demo
          ? "Sample authorization · No provider is contacted."
          : "Authorize in your browser, then return to Rakazo."
      ) {
        ManageGroup {
          ManageRow(
            connectionID == nil ? "Ready to authorize" : "Waiting for authorization", entry.name
          ) { if let url { Button("Open again ↗") { openURL(url) } } }
        }
      } footer: {
        Spacer()
        BackButton("Cancel")
        Button(
          connectionID == nil
            ? (session.store.demo ? "Start sample authorization" : "Continue in browser ↗")
            : "Check connection"
        ) { session.perform { try await advance() } }.buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
      }
    }
    private func advance() async throws {
      let store = session.store
      if let client = store.client {
        if connectionID == nil {
          struct Begun: Decodable { let connectionId: String, authorizationUrl: String? }
          let result: Begun = try await client.rpc(
            "connections/begin",
            ["provider": entry.slug, "connectorId": entry.connectorId, "displayName": entry.name])
          connectionID = result.connectionId
          if result.authorizationUrl != nil {
            guard let link = MarketDirectory.secureURL(result.authorizationUrl) else {
              throw Failure("The provider did not return a secure authorization URL.")
            }
            url = link
            openURL(link)
            return
          }
        }
        guard let connectionID else { return }
        let account: LinkedApp = try await client.rpc(
          "connections/complete", ["connectionId": connectionID])
        guard account.status == "connected" else {
          if ["error", "revoked"].contains(account.status) {
            self.connectionID = nil
            url = nil
            throw Failure("Authorization was not granted. You can start again.")
          }
          throw Failure("Authorization is still pending.")
        }
      } else {
        guard connectionID != nil else {
          connectionID = UUID().uuidString
          return
        }
        store.changeIntegrations { library in
          let count = library.accounts.filter {
            $0.provider == entry.slug && $0.connectorId == entry.connectorId
          }.count
          library.accounts.append(
            .init(
              id: UUID().uuidString, connectorId: entry.connectorId, provider: entry.slug,
              displayName: count == 0 ? entry.name : "\(entry.name) \(count + 1)",
              status: "connected"))
        }
      }
      session.back()
    }
  }

  struct SourceChooserPage: View {
    @EnvironmentObject var session: ManagementSession
    var body: some View {
      ManagePage("Integrations  /  Add custom", "Add a custom integration") {
        ManageGroup("Source type") {
          ManageRow("Remote MCP server", "Connect an HTTP or SSE endpoint.") {
            Button("Set up…") { session.open(.configuration(nil, "streamable_http")) }
          }
          if session.store.mayConfigureStdio {
            Divider()
            ManageRow("Standard I/O server", "Admin only · Runs on the Rakazo server.") {
              Button("Set up…") { session.open(.configuration(nil, "stdio")) }
            }
          }
          Divider()
          ManageRow(
            "Remote MCP tool source", "Verify an endpoint and add its tools as a custom source."
          ) { Button("Set up…") { session.open(.sourceForm("mcp", nil)) } }
          Divider()
          ManageRow("OpenAPI document", "Discover tools from an API document.") {
            Button("Set up…") { session.open(.sourceForm("api", nil)) }
          }
          Divider()
          ManageRow("GraphQL endpoint", "Verify a schema and its credentials.") {
            Button("Set up…") { session.open(.sourceForm("graphql", nil)) }
          }
        }
        ManageGroup("Repository") {
          ManageRow("GitHub plugin", "Preview a connector, a skill pack, or both.") {
            Button("Preview…") { session.open(.repository) }
          }
        }
      } footer: {
        Spacer()
        BackButton("Cancel")
      }
    }
  }
  struct CustomSourcePage: View {
    @EnvironmentObject var session: ManagementSession
    @State var source: ManagedInstall
    var body: some View {
      ManagePage(
        "My integrations  /  Custom sources", source.name,
        source.kind == "api"
          ? "OpenAPI source" : source.kind == "graphql" ? "GraphQL source" : "Remote MCP source"
      ) {
        ManageGroup("Source configuration") {
          ManageRow("Endpoint", source.source) {
            Button("Configure…") { session.open(.sourceForm(source.kind, source)) }
          }
          Divider()
          ManageRow(
            "Authentication",
            [source.config.auth?.type, source.config.auth?.name].compactMap { $0 }.joined(
              separator: " · "))
        }
        ManageGroup {
          ManageRow(
            "Available in",
            source.availability?.allSpaces == true
              ? "All spaces"
              : session.store.navigation?.spaces.filter {
                source.availability?.spaceIds.contains($0.id) == true
              }.map(\.name).joined(separator: ", ") ?? "This space"
          ) {
            Button("Change…") {
              session.open(.scope("install", source.id, source.name, source.availability))
            }
          }
        }
      } footer: {
        Button("Remove source…", role: .destructive) {
          session.open(
            .confirm(
              "Remove \(source.name)?", "Bots will no longer have this source’s tools.",
              [source.source], "Remove source",
              {
                try await session.store.removeSource(source)
                session.close()
              }))
        }
        Spacer()
        BackButton()
      }
      .task {
        do {
          if let current = try await session.store.managementInstalls().first(where: {
            $0.id == source.id
          }) {
            source = current
          }
        } catch { session.issue = error.localizedDescription }
      }
    }
  }
  struct CustomSourceEditor: View {
    @EnvironmentObject var session: ManagementSession
    let kind: String, previous: ManagedInstall?
    @State private var name = ""
    @State private var url = ""
    @State private var method = "none"
    @State private var header = ""
    @State private var credential = ""
    @State private var replacement: ManagedInstall?
    var body: some View {
      ManagePage(
        "Integrations  /  Source",
        previous == nil ? "Add a custom source" : "Replace custom source",
        previous == nil
          ? "Verify the source before adding its tools."
          : "Verify a replacement before removing the old source. Stored credentials are not copied."
      ) {
        Group {
          ManageField("Display name") { TextField("Team handbook", text: $name) }
          ManageField(kind == "api" ? "OpenAPI document URL" : "Endpoint URL") {
            TextField(
              "https://docs.example/" + (kind == "api" ? "openapi.json" : "graphql"), text: $url)
          }
          ManageField("Authentication") {
            Picker("Method", selection: $method) {
              Text("None").tag("none")
              Text("Bearer token").tag("bearer")
              Text("API key header").tag("header")
            }.labelsHidden()
          }
          if method == "header" {
            ManageField("Header name") { TextField("x-api-key", text: $header) }
          }
          if method != "none" {
            ManageField("Credential") { SecureField("Enter a value", text: $credential) }
          }
        }.disabled(replacement != nil)
        if let previous {
          Text(
            session.store.demo
              ? "The replacement keeps this source’s space access."
              : previous.availability?.allSpaces == true
                ? "Verify a new source in all spaces before removing the old one."
                : "This source is restricted. The server cannot replace it without widening access."
          ).foregroundStyle(.secondary)
        }
        if replacement != nil {
          Text(
            "The replacement is saved. Retry to remove the old source; another replacement won’t be created."
          ).foregroundStyle(.secondary)
        }
        if session.store.demo {
          Text("Sample verification accepts fixture URLs ending in .example.").font(.caption)
            .foregroundStyle(.secondary)
        }
      } footer: {
        Spacer()
        BackButton("Cancel")
        Button(
          replacement != nil
            ? "Finish replacement" : previous == nil ? "Verify and add" : "Verify and replace"
        ) {
          session.perform {
            if replacement == nil {
              replacement = try await session.store.addSource(
                kind: kind, name: name, url: url, method: method, header: header,
                credential: credential, replacing: previous)
              credential = ""
            }
            if let previous, previous.id != replacement?.id {
              try await session.store.removeSource(previous)
            }
            if let replacement {
              if previous != nil { session.back() }
              session.replace(.source(replacement))
            }
          }
        }.buttonStyle(.borderedProminent).disabled(
          name.isEmpty || url.isEmpty
            || (!session.store.demo && previous != nil && previous?.availability?.allSpaces != true)
        )
      }.onAppear {
        if let previous {
          name = previous.name
          url = previous.kind == "api" && !session.store.demo ? "" : previous.source
          method = previous.config.auth?.type ?? "none"
          header = previous.config.auth?.name ?? ""
        }
      }
    }
  }
#endif
