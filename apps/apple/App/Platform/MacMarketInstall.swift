#if os(macOS)
  import SwiftUI

  private struct MarketPluginPreview: Decodable {
    struct Skill: Decodable { let name: String, description: String }
    struct Connector: Decodable { let name: String, endpoint: String }
    struct Skipped: Decodable { let name: String, reason: String }
    let name: String, digest: String, pinnedSource: String?, skills: [Skill],
      mcpServers: [Connector], skipped: [Skipped]
  }

  struct MarketInstallReview: View {
    @ObservedObject var store: WorkspaceStore
    let item: MarketItem, onFailure: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var preview: MarketPluginPreview?
    @State private var parts = Set<String>()
    @State private var problem: String?
    @State private var busy = false
    @State private var loading = false
    @State private var savedID: String?
    @State private var signInURL: URL?
    @State private var credential = ""
    @State private var createdHere = false
    @State private var slug = "integration-" + UUID().uuidString.prefix(8).lowercased()
    private var source: MarketSource? {
      if case .server(let source, _) = item.content { return source }
      return nil
    }
    private var needsCredential: Bool { source?.auth == "header" || source?.auth == "bearer" }
    private var hasServer: Bool {
      if case .server(_, let server) = item.content { return savedID != nil || server != nil }
      return false
    }
    private var enabled: Bool {
      if busy || loading { return false }
      if item.kind == .plugin && !store.demo { return preview != nil && !parts.isEmpty }
      return store.demo || !needsCredential || hasServer || !credential.isEmpty
    }
    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 12) {
          MarketMark(
            brand: item.brand, fallback: item.kind.symbol, size: 40, publicLogo: item.publicLogo)
          VStack(alignment: .leading, spacing: 3) {
            Text(item.actionTitle).font(.title2.weight(.semibold))
            Text(item.kind.rawValue).foregroundStyle(.secondary)
          }
        }.padding(22)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if store.demo {
              Label("Sample workspace", systemImage: "desktopcomputer").font(.headline)
              Text("This changes only the sample on this device. No provider is contacted.")
              Text(item.summary).foregroundStyle(.secondary)
              if item.kind == .app {
                DisclosureGroup("Sample outcomes") {
                  Button("Simulate provider failure") {
                    onFailure("The simulated provider did not authorize this connection.")
                    dismiss()
                  }
                }
              }
            } else if item.kind == .plugin {
              if loading { ProgressView("Reading plugin contents…") }
              if let preview {
                Text("Choose what to install").font(.headline)
                if !preview.mcpServers.isEmpty {
                  part(
                    "connector", "Connectors",
                    preview.mcpServers.map { $0.name + " · " + $0.endpoint })
                }
                if !preview.skills.isEmpty {
                  part("skills", "Skills", preview.skills.map { $0.name + " · " + $0.description })
                }
                if preview.mcpServers.isEmpty && preview.skills.isEmpty {
                  Text("This plugin has no supported parts.").foregroundStyle(.secondary)
                }
                ForEach(preview.skipped.indices, id: \.self) { index in
                  Text("Skipped: \(preview.skipped[index].name) · \(preview.skipped[index].reason)")
                    .font(.caption).foregroundStyle(.secondary)
                }
              }
            } else if let source {
              Text("Server endpoint").font(.headline)
              Text(source.endpoint ?? source.domain).textSelection(.enabled)
              if source.auth == "oauth" {
                Text(
                  "Review and approve access in your browser. Adding the server does not assign it to a bot."
                ).foregroundStyle(.secondary)
              } else if needsCredential && (!hasServer || source.auth == "bearer" || createdHere) {
                SecureField(
                  source.auth == "header" ? (source.headerName ?? "API key") : "Bearer token",
                  text: $credential)
                Text(
                  hasServer
                    ? "Leave blank to check the saved credential, or enter a replacement."
                    : "Rakazo sends this credential to the selected server. Bot access is managed separately."
                ).font(.subheadline).foregroundStyle(.secondary)
              } else {
                Text(
                  "After adding the server, manage its status and bot access in My integrations."
                ).foregroundStyle(.secondary)
              }
              if let signInURL { Link("Reopen provider sign-in", destination: signInURL) }
            }
            if let problem {
              Problem(text: problem)
              if item.kind == .plugin && preview == nil && !store.demo {
                Button("Retry preview") { Task { await fetchPreview() } }
              }
            }
          }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
        Divider()
        HStack {
          Spacer()
          Button(savedID == nil ? "Cancel" : "Close") { dismiss() }.keyboardShortcut(.cancelAction)
            .disabled(busy)
          Button(
            signInURL != nil
              ? "Check connection"
              : savedID != nil
                ? "Retry setup"
                : item.kind == .app
                  ? "Approve sample" : item.kind == .plugin ? "Install" : "Add server"
          ) { Task { await confirm() } }.keyboardShortcut(.defaultAction).disabled(!enabled)
        }.padding(16)
      }.background(MarketStyle.canvas).task { await fetchPreview() }.interactiveDismissDisabled(
        busy)
    }
    private func part(_ key: String, _ title: String, _ names: [String]) -> some View {
      VStack(alignment: .leading, spacing: 5) {
        Toggle(
          "\(title) (\(names.count))",
          isOn: Binding(
            get: { parts.contains(key) },
            set: { if $0 { parts.insert(key) } else { parts.remove(key) } }))
        ForEach(names.indices, id: \.self) { index in
          Text(names[index]).font(.subheadline).foregroundStyle(.secondary)
        }
      }
    }
    private func fetchPreview() async {
      guard let api = store.client, case .plugin(let plugin, _) = item.content, !loading else {
        return
      }
      loading = true
      problem = nil
      defer { loading = false }
      do {
        let result: MarketPluginPreview = try await api.rpc(
          "capabilities/pluginPreview", ["source": plugin.source])
        try Task.checkCancellation()
        preview = result
        if !result.mcpServers.isEmpty { parts.insert("connector") }
        if !result.skills.isEmpty { parts.insert("skills") }
      } catch {
        if !Task.isCancelled {
          problem = error.localizedDescription
          onFailure(problem)
        }
      }
    }
    private func confirm() async {
      guard enabled else { return }
      busy = true
      problem = nil
      defer { busy = false }
      do {
        if let api = store.client {
          switch item.content {
          case .plugin(let plugin, _):
            guard let preview else { return }
            let _: ObjectID = try await api.rpc(
              "capabilities/install",
              [
                "kind": "plugin", "name": preview.name,
                "source": preview.pinnedSource ?? plugin.source, "config": [String: String](),
                "pluginDigest": preview.digest, "pluginParts": parts.sorted(),
              ])
          case .server(let source?, let existing):
            guard let endpoint = MarketDirectory.secureURL(source.endpoint) else {
              throw Failure("No secure endpoint was provided by the catalog.")
            }
            if savedID == nil {
              let listed: [ToolServer] = try await api.rpc("mcp/servers/list")
              if let prior = existing ?? listed.first(where: { $0.endpoint == source.endpoint }) {
                savedID = prior.id
                if existing == nil { credential = "" }
              } else {
                var input: [String: Any] = [
                  "name": item.name, "slug": slug, "transport": "streamable_http",
                  "endpoint": endpoint.absoluteString,
                ]
                if source.auth == "bearer" { input["secret"] = credential }
                if source.auth == "header" {
                  guard let header = source.headerName, !header.isEmpty else {
                    throw Failure("The catalog did not supply the credential header name.")
                  }
                  input["headers"] = [header: credential]
                }
                let server: ToolServer = try await api.rpc("mcp/servers/create", input)
                savedID = server.id
                createdHere = true
                credential = ""
              }
            }
            guard let savedID else { return }
            if !credential.isEmpty {
              if source.auth == "bearer" {
                let _: ToolServer = try await api.rpc(
                  "mcp/servers/update", ["id": savedID, "secret": credential])
              } else if createdHere, source.auth == "header", let header = source.headerName {
                let config: [String: Any] = [
                  "name": item.name, "slug": slug, "transport": "streamable_http",
                  "endpoint": endpoint.absoluteString, "headers": [header: credential],
                ]
                let _: ToolServer = try await api.rpc(
                  "mcp/servers/update", ["id": savedID, "config": config])
              } else {
                throw Failure(
                  "Edit this server’s existing headers in Rakazo, then retry the check.")
              }
              credential = ""
            }
            if source.auth == "oauth" && signInURL == nil {
              struct Reply: Decodable { let status: String, authorizationUrl: String? }
              let result: Reply = try await api.rpc("mcp/oauth/begin", ["serverId": savedID])
              if result.status == "authorization_required" {
                guard let url = MarketDirectory.secureURL(result.authorizationUrl) else {
                  throw Failure("The provider did not return a secure sign-in link.")
                }
                signInURL = url
                openURL(url)
                return
              }
              guard ["already_connected", "authorization_not_requested"].contains(result.status)
              else { throw Failure("The server did not confirm its authorization status.") }
            }
            if signInURL != nil {
              let latest: [ToolServer] = try await api.rpc("mcp/servers/list")
              guard latest.first(where: { $0.id == savedID })?.oauthStatus == "connected" else {
                throw Failure("Sign-in isn’t complete. Finish in your browser, then check again.")
              }
            }
            let tested: ToolServer = try await api.rpc("mcp/servers/test", ["id": savedID])
            guard tested.health.status == "ok" else {
              throw Failure(
                tested.health.message ?? "The server was saved but its health check did not pass.")
            }
          default: return
          }
        } else {
          store.changeIntegrations { item.approveSample(in: &$0) }
        }
        onFailure(nil)
        dismiss()
      } catch {
        if !Task.isCancelled {
          problem = error.localizedDescription
          onFailure(problem)
        }
      }
    }
  }
#endif
