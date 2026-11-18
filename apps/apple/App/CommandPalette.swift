import SwiftUI

struct CommandPalette: View {
  @ObservedObject var store: WorkspaceStore
  let choose: (Chat) -> Void, action: (Panel) -> Void, close: () -> Void
  @Environment(\.openURL) private var openURL
  @State private var query = ""
  @State private var selected: String?
  @State private var pageResults: (String, [PageItem]) = ("", [])
  @State private var pageIssue: String?
  @AppStorage("appearance") private var appearance = "System"
  @ScaledMetric(relativeTo: .body) private var searchHeight: CGFloat = 44
  private var term: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

  private enum Row: Identifiable {
    case command(SearchResult)
    case page(PageItem)
    case appearance(String)
    case web(String, String, URLQueryItem)
    var id: String {
      switch self {
      case .command(let result): result.id
      case .page(let page): "page/" + page.id
      case .appearance(let mode): "appearance/" + mode
      case .web(_, _, let query): "web/" + query.name + "/" + (query.value ?? "")
      }
    }
    var group: String {
      switch self {
      case .command(let result): result.chat != nil ? "Conversations" : "Actions"
      case .page: "Pages"
      case .appearance: "Appearance"
      case .web: "Open in Rakazo on the web"
      }
    }
  }
  private var rows: [Row] {
    let hits = SearchResult.results(store.navigation?.current.chats ?? [], term)
    let chats = hits.filter { $0.chat != nil }.enumerated().map { index, hit in
      var result = hit
      result.shortcut = index < 9 ? index + 1 : nil
      return Row.command(result)
    }
    let pages = pageResults.0 == term ? pageResults.1 : []
    let starts: (PageItem) -> Bool = {
      !term.isEmpty && $0.title.lowercased().hasPrefix(term.lowercased())
    }
    let ranked = (pages.filter(starts) + pages.filter { !starts($0) }).map(Row.page)
    let matches: (String) -> Bool = { term.isEmpty || $0.localizedCaseInsensitiveContains(term) }
    var actions = hits.filter { $0.panel != nil }.map(Row.command)
    if matches("Keyboard shortcuts") {
      actions.append(
        .command(
          .init(name: "Keyboard shortcuts", description: "Shortcut reference", panel: .shortcuts)))
    }
    actions += ["System", "Light", "Dark"].filter { matches("Appearance: " + $0) }.map(
      Row.appearance)
    if store.login != nil {
      let links: [(String, String, URLQueryItem)] =
        [
          ("Bot templates", "rectangle.grid.2x2", .init(name: "templates", value: nil)),
          ("Skills", "scroll", .init(name: "skills", value: nil)),
          ("MCP servers", "network", .init(name: "mcp", value: nil)),
        ]
        + [
          ("Models", "models"), ("Memory", "memory"), ("Approvals", "confirmations"),
          ("Vault", "vault"), ("Voice", "voice"), ("Usage", "usage"),
          ("Organization", "organization"), ("General", "general"),
        ].map { ("Settings: " + $0.0, "gearshape", .init(name: "settings", value: $0.1)) }
      actions += links.filter { matches($0.0) }.map { .web($0.0, $0.1, $0.2) }
    }
    return (pages.contains(where: starts) ? ranked + chats : chats + ranked) + actions
  }
  var body: some View {
    let results = rows
    let active = results.first(where: { $0.id == selected })?.id ?? results.first?.id
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("Command menu", systemImage: "command").font(.headline)
        Spacer()
        Button("Close", systemImage: "xmark.circle.fill", action: close).labelStyle(.iconOnly)
          .foregroundStyle(.secondary).keyboardShortcut(.cancelAction).accessibilityIdentifier(
            "close-command-menu")
      }.padding(.horizontal, 20).padding(.top, 18)
      HStack(spacing: 10) {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        CommandQuery(
          text: $query,
          move: { direction in
            guard !results.isEmpty else { return }
            let index = results.firstIndex { $0.id == active } ?? 0
            selected = results[(index + direction + results.count) % results.count].id
          }, accept: { if let row = results.first(where: { $0.id == active }) { open(row) } },
          digit: { index in
            let chats = results.compactMap { row -> Chat? in
              if case .command(let hit) = row { return hit.chat }
              return nil
            }
            if chats.indices.contains(index) { choose(chats[index]) }
          }, close: close
        ).frame(height: max(44, searchHeight)).accessibilityIdentifier("command-query")
      }.padding(.horizontal, 12).background(
        Ink.fill, in: RoundedRectangle(cornerRadius: Layout.Radius.control)
      )
      .padding(.horizontal, 16).padding(.vertical, 12)
      Divider()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
              if index == 0 || results[index - 1].group != row.group {
                Text(row.group).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                  .padding(.leading, 12).padding(.top, 10)
              }
              Button {
                open(row)
              } label: {
                Group {
                  switch row {
                  case .command(let hit): SearchRow(result: hit, shortcuts: true)
                  case .page(let page): Label(page.title, systemImage: "doc.text").font(.body)
                  case .appearance(let mode):
                    HStack {
                      Label(
                        mode,
                        systemImage: mode == "System"
                          ? "circle.lefthalf.filled" : mode == "Light" ? "sun.max" : "moon")
                      Spacer()
                      if appearance == mode {
                        Image(systemName: "checkmark").accessibilityLabel("Current appearance")
                      }
                    }
                  case .web(let title, let icon, _):
                    HStack {
                      Label(title, systemImage: icon)
                      Spacer()
                      Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
                    }
                  }
                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(
                  .horizontal, 10
                ).padding(.vertical, 2)
                  .background(
                    active == row.id ? Ink.fill : .clear,
                    in: RoundedRectangle(cornerRadius: Layout.Radius.control)
                  )
                  .contentShape(Rectangle())
              }.buttonStyle(.plain).accessibilityAddTraits(active == row.id ? .isSelected : [])
                .accessibilityIdentifier("command-" + row.id).id(row.id)
            }
            if results.isEmpty {
              ContentUnavailableView.search(text: term).frame(maxWidth: .infinity)
            }
            if let pageIssue {
              Text(pageIssue).font(.caption).foregroundStyle(.secondary).padding(10)
            }
          }.padding(.horizontal, 8).padding(.bottom, 8)
        }.onChange(of: active) { _, id in if let id { proxy.scrollTo(id) } }
      }
      #if os(macOS)
        Divider()
        HStack(spacing: 18) {
          Text("↑ ↓  Navigate")
          Text("↵  Open")
          Spacer()
          Text("esc  Close")
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 9)
          .accessibilityHidden(true)
      #endif
    }.background(Ink.canvas)
      .onChange(of: query) { _, _ in selected = nil }
      .task(id: term) {
        pageIssue = nil
        let search = term
        guard let api = store.client, search.count <= 200 else { return }
        do {
          if !search.isEmpty { try await Task.sleep(for: .milliseconds(160)) }
          var input: [String: Any] = ["limit": search.isEmpty ? 5 : 25]
          if !search.isEmpty { input["query"] = search }
          let reply: Pages = try await api.rpc("pages/list", input)
          try Task.checkCancellation()
          pageResults = (search, reply.items)
        } catch { if !Task.isCancelled { pageIssue = "Pages couldn’t be loaded." } }
      }
  }
  private func open(_ row: Row) {
    switch row {
    case .command(let hit):
      if let chat = hit.chat { choose(chat) } else if let panel = hit.panel { action(panel) }
    case .page(let page):
      let chat = store.navigation?.current.chats.first { $0.id == (page.groupId ?? page.botId) }
      if let url = store.link(chat, query: [.init(name: "page", value: page.id)]) {
        close()
        openURL(url)
      }
    case .appearance(let mode):
      appearance = mode
      close()
    case .web(_, _, let query):
      if let url = store.link(store.chat, query: [query]) {
        close()
        openURL(url)
      }
    }
  }
}
