#if os(macOS)
  import SwiftUI

  struct RepositoryPage: View {
    @EnvironmentObject var session: ManagementSession
    @State private var url = ""
    var body: some View {
      ManagePage(
        "Discover  /  Import", "Import from GitHub",
        "Preview what the repository contains before adding anything."
      ) {
        ManageField("Repository URL") { TextField("https://github.com/example/linear", text: $url) }
        if session.store.demo {
          Button("Use sample repository") { url = IntegrationFixtures.repo("Linear") }
        }
      } footer: {
        Spacer()
        BackButton("Cancel")
        Button("Preview repository") {
          let source = url.trimmingCharacters(in: .whitespacesAndNewlines)
          guard let link = MarketDirectory.secureURL(source),
            link.host?.lowercased() == "github.com", link.pathComponents.count >= 3
          else {
            session.issue = "Enter a GitHub repository URL."
            return
          }
          session.open(.plugin(source, source, link.lastPathComponent, true))
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(url.isEmpty)
      }
    }
  }

  struct PluginManagementPage: View {
    @EnvironmentObject var session: ManagementSession
    let source: String, key: String, name: String, review: Bool
    @State private var manifest: PluginManifest?
    @State private var installed: ManagedInstall?
    @State private var servers: [ToolServer] = []
    @State private var skills: [ManagedSkill] = []
    @State private var selected = Set<String>()
    @State private var attempt = 0
    @State private var loading = true
    private var app: CatalogEntry? {
      let plugin = session.directory.items.compactMap {
        if case .plugin(let value, _) = $0.content, value.installedSource == key { return value }
        return nil
      }.first
      guard let plugin else { return nil }
      let keys = [plugin.name ?? plugin.displayName, plugin.displayName].map {
        $0.lowercased().filter(\.isLetterOrNumber)
      }
      return session.directory.items.compactMap {
        if case .app(let entry, _) = $0.content,
          keys.contains(entry.name.lowercased().filter(\.isLetterOrNumber))
            || keys.contains(entry.slug.lowercased().filter(\.isLetterOrNumber))
        {
          return entry
        }
        return nil
      }.first
    }
    var body: some View {
      ManagePage(
        review ? "GitHub import  /  Preview" : "My integrations  /  Plugins",
        manifest.map { review && installed == nil ? "Review " + $0.name : $0.name }
          ?? (loading ? name : "Couldn’t load this repository"), manifest?.description ?? "",
        width: 670,
        badge: installed.map {
          $0.parts == manifest?.availableParts ? "Installed" : "Partially installed"
        } ?? "Plugin"
      ) {
        if loading {
          ProgressView("Loading plugin…")
        } else if let manifest {
          HStack {
            Text(
              [manifest.author, manifest.version, manifest.license].compactMap { $0 }.joined(
                separator: "  ·  ")
            ).foregroundStyle(.secondary)
            Spacer()
            if let url = MarketDirectory.secureURL(manifest.repository ?? source) {
              Link("View source ↗", destination: url)
            }
          }
          if review && installed == nil, let revision = manifest.resolvedSha {
            ManageRow("Source revision", String(revision.prefix(12)))
          }
          Text(installed != nil ? "Installed parts" : "Included in this plugin").font(.headline)
          HStack(alignment: .top, spacing: 12) {
            if let app {
              partTile("App account", app.name, "Managed separately", icon: "person.crop.circle") {
                Button("Manage accounts…") { session.open(.app(app)) }
              }
            }
            if !manifest.mcpServers.isEmpty && app == nil {
              part(
                "connector",
                manifest.mcpServers.count == 1
                  ? manifest.mcpServers[0].name : "\(manifest.mcpServers.count) MCP servers",
                installed?.parts.contains("connector") == true
                  ? "Connected in this workspace" : "Make the plugin’s tools available to bots.",
                manifest: manifest)
            }
            if !manifest.skills.isEmpty {
              part(
                "skills", "\(manifest.skills.count) skills",
                manifest.skills.prefix(2).map(\.name).joined(separator: " · "), manifest: manifest)
            }
          }
          if !servers.isEmpty {
            ManageGroup("Connected servers") {
              ForEach(servers) { server in
                ManageRow(server.name, server.connectionLabel) {
                  Button("Manage connector…") { session.open(.server(server)) }
                }
              }
            }
          }
          if !manifest.skills.isEmpty {
            ManageGroup("Skills preview") {
              ForEach(manifest.skills, id: \.name) { skill in
                ManageRow(skill.name, skill.description) {
                  if let match = skills.first(where: {
                    $0.source == "plugin" && $0.name == skill.name
                  }), installed?.parts.contains("skills") == true {
                    Button("Read") { session.open(.skill(match)) }
                  }
                }
              }
            }
          }
          if !manifest.skipped.isEmpty {
            ManageGroup("Not included") {
              ForEach(manifest.skipped.indices, id: \.self) { index in
                ManageRow(manifest.skipped[index].name, manifest.skipped[index].reason)
              }
            }
          }
          if let installed {
            ManageGroup {
              ManageRow(
                "Available in",
                installed.availability?.allSpaces == true
                  ? "All spaces"
                  : session.store.navigation?.spaces.filter {
                    installed.availability?.spaceIds.contains($0.id) == true
                  }.map(\.name).joined(separator: ", ") ?? "This space"
              ) {
                Button("Change…") {
                  session.open(
                    .scope("install", installed.id, installed.name, installed.availability))
                }
              }
            }
          }
        } else {
          ManageGroup {
            ManageRow("Repository preview unavailable", source)
            Text("Check the repository URL or retry the preview.").foregroundStyle(.secondary)
          }
        }
      } footer: {
        if let installed, let manifest {
          Button("Remove plugin…", role: .destructive) {
            confirm(
              [], title: "Remove \(installed.name) entirely?", action: "Remove plugin",
              manifest: manifest)
          }
        }
        Spacer()
        BackButton(loading || manifest == nil || (review && installed == nil) ? "Cancel" : "Done")
        if !loading && manifest == nil {
          Button("Retry preview") { attempt += 1 }.buttonStyle(.borderedProminent)
        }
        if let manifest, review && installed == nil {
          Button("Add selected items") { save(selected, manifest: manifest) }.buttonStyle(
            .borderedProminent
          ).disabled(selected.isEmpty)
        }
      }
      .task(id: attempt) { await load() }
    }
    @ViewBuilder private func part(
      _ part: String, _ title: String, _ caption: String, manifest: PluginManifest
    ) -> some View {
      let active = installed?.parts.contains(part) == true
      partTile(
        part == "connector" ? "Connector" : "Skill pack", title, caption,
        icon: part == "connector" ? "cable.connector" : "books.vertical"
      ) {
        if review && installed == nil {
          Toggle("Add \(title)", isOn: membership(part, in: $selected)).labelsHidden()
        } else if active {
          Button("Remove \(part == "connector" ? "connector" : "skills")…") {
            var next = installed?.parts ?? []
            next.remove(part)
            confirm(
              next, title: "Remove \(title.lowercased())?",
              action: part == "connector" ? "Remove connector" : "Remove skills", manifest: manifest
            )
          }
        } else {
          Button(part == "connector" ? "Connect" : "Add skills") {
            save((installed?.parts ?? []).union([part]), manifest: manifest)
          }
        }
      }
    }
    private func partTile<Control: View>(
      _ label: String, _ title: String, _ caption: String, icon: String,
      @ViewBuilder control: () -> Control
    ) -> some View {
      VStack(alignment: .leading, spacing: 8) {
        Label(label, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        Text(title).font(.headline)
        Text(caption).font(.callout).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true)
        Spacer(minLength: 4)
        control()
      }.padding(14).frame(maxWidth: .infinity, minHeight: 134, alignment: .topLeading)
        .background(MarketStyle.tint, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
          RoundedRectangle(cornerRadius: 10).strokeBorder(MarketStyle.line, lineWidth: 0.7)
        }
    }
    private func confirm(
      _ parts: Set<String>, title: String, action: String, manifest: PluginManifest
    ) {
      let scope = installed?.availability?.allSpaces == true ? "all spaces" : "its selected spaces"
      var rows: [String] = []
      if installed?.parts.contains("connector") == true && !parts.contains("connector") {
        rows += manifest.mcpServers.map(\.name)
      }
      if installed?.parts.contains("skills") == true && !parts.contains("skills") {
        rows += manifest.skills.map(\.name)
      }
      session.open(
        .confirm(
          title,
          "This changes \(scope)."
            + (parts.isEmpty
              ? ""
              : parts.contains("connector")
                ? " The connector stays installed." : " The skills stay installed."),
          rows, action,
          {
            try await session.store.setPlugin(
              installed, preview: manifest, source: source, parts: parts)
            if parts.isEmpty { session.close() } else { session.back() }
          }))
    }
    private func save(_ parts: Set<String>, manifest: PluginManifest) {
      session.perform {
        try await session.store.setPlugin(
          installed, preview: manifest, source: source, parts: parts)
        attempt += 1
      }
    }
    private func load() async {
      loading = true
      defer { loading = false }
      session.issue = nil
      do {
        let installs = try await session.store.managementInstalls()
        var record = installs.first { $0.kind == "plugin" && [$0.source, $0.id].contains(key) }
        var preview: PluginManifest
        if let record {
          guard let saved = record.config.manifest else {
            throw Failure("The installed plugin manifest is unavailable.")
          }
          preview = saved
        } else {
          preview = try await session.store.previewRepository(source)
          if let match = installs.first(where: {
            $0.kind == "plugin" && $0.source == preview.installedSource
          }) {
            record = match
            if let pinned = match.config.manifest { preview = pinned }
          }
        }
        installed = record
        manifest = preview
        selected = preview.availableParts
        if app != nil { selected.remove("connector") }
        if let record {
          servers = try await session.store.managedServers().filter { $0.installId == record.id }
          skills = try await session.store.managementSkills()
        } else {
          servers = []
          skills = []
        }
      } catch { if !Task.isCancelled { session.issue = error.localizedDescription } }
    }
  }
  extension Character { fileprivate var isLetterOrNumber: Bool { isLetter || isNumber } }
#endif
