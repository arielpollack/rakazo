#if os(macOS)
  import SwiftUI

  enum MarketCollection: Hashable, CaseIterable {
    case discover, manage, apps, servers, plugins
    var kind: MarketKind? {
      switch self {
      case .apps: return .app
      case .servers: return .server
      case .plugins: return .plugin
      default: return nil
      }
    }
    var title: String { kind?.plural ?? (self == .manage ? "My integrations" : "Discover") }
    var icon: String { kind?.symbol ?? (self == .manage ? "link" : "safari") }
  }

  struct MacMarketplace: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var collection = MarketCollection.discover
    @State private var search = ""
    @State private var category: String?
    @State private var detailID: String?
    @State private var problem: String?
    @State private var count = 6
    @State private var generation = 0
    @State private var directory = MarketDirectory()
    @State private var loaded = false
    @State private var refreshing = false
    @State private var setup: MarketSheet?
    @State private var returnFocus: MarketFocus?
    @State private var flow = MarketActionFlow()
    @FocusState private var focus: MarketFocus?

    init(store: WorkspaceStore, collection: MarketCollection = .discover, detailID: String? = nil) {
      self.store = store
      _collection = State(initialValue: collection)
      _detailID = State(initialValue: detailID)
    }

    var body: some View {
      GeometryReader { geometry in
        let wide = geometry.size.width >= 800
        ZStack {
          HStack(spacing: 0) {
            if wide {
              sidebar.frame(width: 176)
              Divider()
            }
            gallery(wide: wide, width: geometry.size.width - (wide ? 177 : 0))
          }.opacity(detailID == nil ? 1 : 0).allowsHitTesting(detailID == nil).accessibilityHidden(
            detailID != nil)
          if let detail = directory.items.first(where: { $0.id == detailID }) {
            detailView(detail, width: geometry.size.width)
          }
        }
      }.background(MarketStyle.canvas)
        .task(id: generation) { await refresh() }
        .sheet(
          item: $setup,
          onDismiss: {
            flow.close()
            refreshing = true
            generation += 1
          }
        ) { sheet in
          Group {
            switch sheet {
            case .management(let route): MacManagement(route, store: store, directory: directory)
            case .start(let item):
              MarketInstallReview(store: store, item: item, onFailure: { flow.report($0, for: item) }).frame(width: 460, height: 350)
            }
          }
        }
    }

    private var sidebar: some View {
      VStack(alignment: .leading, spacing: 5) {
        Label("Integrations", systemImage: "rectangle.3.group").font(
          .system(size: 15, weight: .medium)
        ).padding(.leading, 7).padding(.bottom, 19)
        railHeading("Workspace")
        railButton(.discover)
        railButton(.manage)
        railHeading("Types").padding(.top, 18)
        railButton(.apps)
        railButton(.servers)
        railButton(.plugins)
        Button { setup = .management(.skills) } label: { Label("Skills", systemImage: "book.closed").padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()) }.buttonStyle(.plain)
        Spacer()
      }.padding(.horizontal, 12).padding(.vertical, 24).frame(
        maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading
      ).background(MarketStyle.rail)
    }
    private func railHeading(_ title: String) -> some View {
      Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.leading, 7)
    }
    private func railButton(_ tab: MarketCollection) -> some View {
      Button {
        choose(tab)
      } label: {
        HStack(spacing: 9) {
          Image(systemName: tab.icon).frame(width: 15)
          Text(tab.title).lineLimit(1).fixedSize()
          Spacer(minLength: 0)
        }
        .padding(.horizontal, 9).frame(height: 32).background(
          tab == collection ? Color.primary.opacity(0.09) : .clear,
          in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
      }.buttonStyle(.plain).accessibilityAddTraits(tab == collection ? .isSelected : [])
    }
    private func choose(_ tab: MarketCollection) {
      collection = tab
      category = nil
      search = ""
      count = 6
      detailID = nil
    }
    private var closeButton: some View {
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark").foregroundStyle(.secondary).frame(width: 24, height: 28)
      }.buttonStyle(.plain).accessibilityLabel("Close marketplace").help("Close marketplace")
    }
    private var searchBox: some View {
      HStack(spacing: 7) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("Search integrations", text: $search).textFieldStyle(.plain).focused(
          $focus, equals: .search
        ).accessibilityLabel("Search integrations")
        if !search.isEmpty {
          Button {
            search = ""
            focus = .search
          } label: {
            Image(systemName: "xmark.circle.fill")
          }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear search")
        }
      }.padding(.horizontal, 10).frame(minWidth: 128, maxWidth: 220).frame(height: 32)
        .background(MarketStyle.tint, in: RoundedRectangle(cornerRadius: 7))
        .overlay {
          if focus == .search { RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor) }
        }
    }
    private func gallery(wide: Bool, width: CGFloat) -> some View {
      let inset: CGFloat = wide ? 26 : 18
      let columns = max(1, min(3, Int((width - inset * 2 + 12) / 222)))
      let visible = directory.filtered(kind: collection.kind, category: category, search: search)
      return VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 12) {
          if !wide {
            Menu {
              ForEach(MarketCollection.allCases, id: \.self) { tab in
                Button(tab.title) { choose(tab) }
              }
              Button("Skills") { setup = .management(.skills) }
            } label: {
              Image(systemName: "sidebar.left")
            }.menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Collections")
          }
          Text(collection.title).font(.system(size: wide ? 28 : 23, weight: .medium)).lineLimit(1)
          Spacer(minLength: 4)
          searchBox
          Button { setup = .management(.custom) } label: { Image(systemName: "plus") }.help("Add custom integration").accessibilityLabel("Add custom integration")
          closeButton
        }.padding(.horizontal, inset).padding(.vertical, wide ? 22 : 15)
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            if let problem {
              HStack {
                Problem(text: problem)
                Button("Retry") { generation += 1 }
              }
            }
            if !directory.warnings.isEmpty {
              HStack {
                Text(directory.warnings.joined(separator: " ")).font(.subheadline).foregroundStyle(
                  .secondary)
                Button("Retry") { generation += 1 }
              }
            }
            if !loaded && problem == nil {
              ProgressView("Loading integrations…").frame(maxWidth: .infinity)
            } else if collection == .manage {
              management
            } else {
              if collection == .discover && search.isEmpty && category == nil,
                let github = directory.items.first(where: {
                  $0.kind == .app && $0.brand == "github"
                })
              {
                MarketSpotlight { show(github) }.padding(.bottom, 5)
              }
              HStack {
                Text(
                  collection == .discover
                    ? "Explore integrations" : "Browse \(collection.title.lowercased())"
                ).font(.system(size: 19, weight: .medium))
                Spacer()
                Menu {
                  Button("All categories") { category = nil }
                  Divider()
                  ForEach(
                    Set(
                      directory.filtered(kind: collection.kind, category: nil, search: "").map(
                        \.category)
                    ).sorted(), id: \.self
                  ) { value in Button(value) { category = value } }
                } label: {
                  Label(category ?? "All categories", systemImage: "line.3.horizontal.decrease")
                }.fixedSize()
              }
              if visible.isEmpty && loaded {
                emptyView
              } else {
                LazyVGrid(
                  columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns),
                  alignment: .leading, spacing: 12
                ) {
                  ForEach(visible.prefix(count)) { item in
                    MarketCard(
                      item: item, waiting: flow.pending == item.id, failure: flow.failures[item.id],
                      blocked: refreshing || problem != nil, focus: $focus,
                      open: { show(item) }, act: { start(item) })
                  }
                }
                if visible.count > count {
                  Button {
                    count += 12
                  } label: {
                    Label("Show more integrations", systemImage: "chevron.down").labelStyle(
                      .titleAndIcon)
                  }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.vertical, 7).frame(
                    maxWidth: .infinity)
                }
              }
            }
          }.padding(.horizontal, inset).padding(.bottom, 18).frame(
            maxWidth: .infinity, alignment: .leading)
        }.id(collection)
      }.onChange(of: search) { _, _ in count = 6 }.onChange(of: category) { _, _ in count = 6 }
        .onKeyPress(characters: .alphanumerics, phases: .down) { press in
          guard focus != .search, setup == nil, detailID == nil,
            press.modifiers.subtracting(.shift).isEmpty
          else { return .ignored }
          search += press.characters
          focus = .search
          return .handled
        }
    }
    private var emptyView: some View {
      ContentUnavailableView {
        Label("No integrations found", systemImage: "magnifyingglass")
      } description: {
        Text("Try a different name or category.")
      } actions: {
        Button("Clear filters") {
          search = ""
          category = nil
        }
      }
    }
    private var management: some View {
      let accounts = directory.accounts.filter {
        search.isEmpty
          || ($0.displayName + " " + $0.provider).localizedCaseInsensitiveContains(search)
      }
      let installed = directory.items.filter {
        $0.confirmed != nil && $0.kind != .app
          && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search))
      }
      return VStack(alignment: .leading, spacing: 12) {
        Text("App accounts  \(accounts.count)").font(.title3.weight(.semibold))
        if accounts.isEmpty {
          Text("No matching accounts.").foregroundStyle(.secondary)
          Button("Discover apps") { choose(.apps) }
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
          ForEach(accounts) { account in
            let entry = directory.items.first {
              if case .app(let app, _) = $0.content {
                return app.connectorId == account.connectorId && app.slug == account.provider
              }
              return false
            }
            Button {
              if let entry, case .app(let app, _) = entry.content { setup = .management(.account(app, account)) } else { setup = .management(.account(.init(connectorId: account.connectorId, name: account.provider, slug: account.provider, connected: true, noAuth: false), account)) }
            } label: {
              HStack {
                MarketMark(
                  brand: MarketDirectory.brand(account.provider), size: 33,
                  publicLogo: entry?.publicLogo)
                VStack(alignment: .leading, spacing: 3) {
                  Text(account.displayName).fontWeight(.medium)
                  Text(entry?.name ?? account.provider).font(.subheadline).foregroundStyle(
                    .secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
              }.padding(13).frame(maxWidth: .infinity, alignment: .leading).contentShape(
                Rectangle())
            }.buttonStyle(.plain).overlay {
              RoundedRectangle(cornerRadius: 8).strokeBorder(MarketStyle.line)
            }
          }
        }
        ForEach([MarketKind.server, .plugin], id: \.self) { kind in
          let group = installed.filter { $0.kind == kind }
          if !group.isEmpty {
            Text("\(kind.plural)  \(group.count)").font(.title3.weight(.semibold)).padding(.top, 9)
            VStack(spacing: 0) {
              ForEach(group) { item in
                Button {
                  if case .server(_, let server?) = item.content {
                    setup = .management(.server(server))
                  } else {
                    show(item)
                  }
                } label: {
                  HStack {
                    MarketMark(
                      brand: item.brand, fallback: kind.symbol, size: 30,
                      publicLogo: item.publicLogo)
                    Text(item.name).fontWeight(.medium)
                    Spacer()
                    Label(
                      item.confirmed ?? "",
                      systemImage: item.needsAttention
                        ? "exclamationmark.circle" : "checkmark.circle"
                    ).font(.subheadline).foregroundStyle(
                      item.needsAttention ? Color.secondary : Color(nsColor: .systemGreen))
                    Image(systemName: "chevron.right").font(.caption)
                  }.padding(12).contentShape(Rectangle())
                }.buttonStyle(.plain)
                if item.id != group.last?.id { Divider() }
              }
            }.overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(MarketStyle.line) }
          }
        }
        ForEach(directory.installs.filter { install in
          (search.isEmpty || install.name.localizedCaseInsensitiveContains(search)) && (["api", "graphql", "mcp"].contains(install.kind) || (install.kind == "plugin" && !directory.items.contains { item in if case .plugin(let plugin, _) = item.content { return plugin.installedSource == install.source }; return false }))
        }) { install in
          Button { setup = .management(install.kind == "plugin" ? .plugin(install.source, install.source, install.name, false) : .source(install)) } label: {
            ManageRow(install.name, install.kind == "api" ? "Custom source · OpenAPI" : install.kind.capitalized) { Image(systemName: "chevron.right") }.padding(12).background(MarketStyle.tint, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
      }
    }
    private func detailView(_ item: MarketItem, width: CGFloat) -> some View {
      VStack(spacing: 0) {
        HStack {
          Button {
            detailID = nil
            focus = .card(item.id)
          } label: {
            Label(collection.title, systemImage: "chevron.left")
          }.buttonStyle(.plain).focused($focus, equals: .back)
          Text("/  " + item.name).foregroundStyle(.secondary)
          Spacer()
          closeButton
        }.padding(.horizontal, 24).padding(.vertical, 12)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            HStack {
              MarketMark(
                brand: item.brand, fallback: item.kind.symbol, size: 48, publicLogo: item.publicLogo
              )
              VStack(alignment: .leading) {
                Text(item.name).font(.largeTitle.weight(.semibold))
                Text(item.kind.rawValue + " · " + item.category).foregroundStyle(.secondary)
              }
            }
            Text(item.summary).font(.title3)
            MarketAction(
              item: item, waiting: flow.pending == item.id, failure: flow.failures[item.id],
              focus: $focus, act: { start(item) }
            ).disabled(refreshing || problem != nil)
            if let failure = flow.failures[item.id] { Problem(text: failure) }
            if case .server(_, let server?) = item.content {
              Button("Manage server and bot access") { setup = .management(.server(server)) }
            }
            if case .app(let entry, let accounts) = item.content {
              ForEach(accounts) { account in
                Button("Manage \(account.displayName)") { setup = .management(.account(entry, account)) }
              }
            }
            if item.confirmed == nil {
              Text("Review the requested access before approving setup.").font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Divider().padding(.vertical, 8)
            MarketDetailTools(item: item, api: store.client, wide: width >= 700)
          }.padding(30).frame(maxWidth: .infinity, alignment: .leading)
        }
      }.background(MarketStyle.canvas)
    }
    private func show(_ item: MarketItem) {
      switch item.content {
      case .server(_, let server?): setup = .management(.server(server))
      case .plugin(let plugin, _): setup = .management(.plugin(plugin.source, plugin.installedSource, plugin.displayName, false))
      case .app(let entry, _): setup = .management(.app(entry))
      default: detailID = item.id; focus = .back
      }
    }
    private func start(_ item: MarketItem) {
      guard setup == nil, !refreshing, problem == nil, flow.begin(item) else { return }
      returnFocus = .action(item.id)
      switch item.content {
      case .app(let entry, _): setup = .management(.authorize(entry))
      case .plugin(let plugin, _): setup = .management(.plugin(plugin.source, plugin.installedSource, plugin.displayName, true))
      case .server(_, let server?): setup = .management(.server(server))
      default: setup = .start(item)
      }
    }
    private func refresh() async {
      do {
        var result: MarketDirectory
        if let api = store.client {
          result = try await .load(api)
        } else if let library = store.sampleIntegrations {
          result = try .sample(library, seed: CatalogSeed.bundled.get())
          result.installs = try await store.managementInstalls()
        } else {
          throw Failure("Choose a workspace to browse integrations.")
        }
        try Task.checkCancellation()
        directory = result
        loaded = true
        problem = nil
        refreshing = false
        if let target = returnFocus {
          focus = target
          returnFocus = nil
          if case .action(let id) = target, let item = result.items.first(where: { $0.id == id }) {
            if let status = item.confirmed {
              if detailID == nil && !item.canResume { focus = .card(id) }
              AccessibilityNotification.Announcement("\(item.name): \(status)").post()
            } else if let failure = flow.failures[id] {
              AccessibilityNotification.Announcement(failure).post()
            }
          }
        }
        if let detailID, !result.items.contains(where: { $0.id == detailID }) {
          self.detailID = nil
        }
      } catch {
        if !Task.isCancelled {
          refreshing = false
          problem = error.localizedDescription
        }
      }
    }
  }

  enum MarketSheet: Identifiable {
    case start(MarketItem)
    case management(ManageRoute)
    var id: String {
      switch self {
      case .start(let item): return item.id
      case .management: return "management"
      }
    }
  }

  private struct MarketDetailTools: View {
    let item: MarketItem, api: Client?
    let wide: Bool
    @State private var tools: [IntegrationTool] = []
    @State private var message: String?
    var body: some View {
      let layout =
        wide
        ? AnyLayout(HStackLayout(alignment: .top, spacing: 30))
        : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
      return layout {
        VStack(alignment: .leading, spacing: 14) {
          Text("What your bot can do").font(.title3.weight(.semibold))
          if tools.isEmpty {
            Text(
              message
                ?? (item.kind == .app
                  ? "Tool availability depends on the provider and your permissions."
                  : "Review setup and availability for this integration in your workspace.")
            ).foregroundStyle(.secondary)
          }
          ForEach(tools.prefix(8), id: \.name) { tool in
            Label {
              VStack(alignment: .leading, spacing: 3) {
                Text(tool.name.replacingOccurrences(of: "_", with: " ").localizedCapitalized)
                  .fontWeight(.medium)
                Text(tool.description).foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: "bolt")
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        if item.brand == "slack" || item.brand == "github" {
          VStack(alignment: .leading, spacing: 6) {
            Label("Try asking", systemImage: "text.bubble").font(.subheadline)
            Text(
              item.brand == "slack"
                ? "“Catch me up on the latest discussion in #design.”"
                : "“What shipped in the latest release?”"
            ).font(.title3)
          }.padding(16).frame(maxWidth: wide ? 248 : .infinity, alignment: .leading).background(
            MarketStyle.tint, in: RoundedRectangle(cornerRadius: 9))
        }
      }.task(id: item.id) {
        tools = item.tools
        message = nil
        if api == nil, item.kind == .app, item.brand == "slack" {
          tools = [
            .init(name: "List channels", description: "Find channels in the connected workspace."),
            .init(
              name: "Read a conversation", description: "Fetch the recent messages in a channel."),
            .init(
              name: "Send a message", description: "Post to a channel the connection can access."),
          ]
        }
        guard let api, case .app(let entry, _) = item.content else { return }
        do {
          let result: [IntegrationTool] = try await api.rpc(
            "connections/tools", ["provider": entry.slug, "connectorId": entry.connectorId])
          try Task.checkCancellation()
          tools = result
        } catch { if !Task.isCancelled { message = "The provider’s tool list is unavailable." } }
      }
    }
  }
#endif
