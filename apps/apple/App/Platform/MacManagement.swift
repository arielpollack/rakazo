#if os(macOS)
  import SwiftUI

  enum ManageRoute {
    case app(CatalogEntry)
    case account(CatalogEntry, LinkedApp)
    case authorize(CatalogEntry)
    case server(ToolServer)
    case configuration(ToolServer?, String)
    case access(ToolServer)
    case tools(ToolServer, ToolGrant?)
    case reconnect(ToolServer)
    case test(ToolServer)
    case custom
    case sourceForm(String, ManagedInstall?)
    case source(ManagedInstall)
    case repository
    case plugin(String, String, String, Bool)
    case skills
    case skill(ManagedSkill?)
    case packs
    case scope(String, String, String, SpaceTool.Availability?)
    case confirm(String, String, [String], String, @MainActor () async throws -> Void)
  }

  @MainActor final class ManagementSession: ObservableObject {
    struct Page: Identifiable {
      let id = UUID()
      let route: ManageRoute
    }
    @Published var pages: [Page]
    @Published var busy = false
    @Published var issue: String?
    let store: WorkspaceStore
    let directory: MarketDirectory
    var close: () -> Void = {}
    init(_ route: ManageRoute, store: WorkspaceStore, directory: MarketDirectory) {
      pages = [.init(route: route)]
      self.store = store
      self.directory = directory
    }
    func open(_ route: ManageRoute) {
      issue = nil
      pages.append(.init(route: route))
    }
    func replace(_ route: ManageRoute) {
      issue = nil
      pages[pages.count - 1] = .init(route: route)
    }
    func back(_ count: Int = 1) {
      issue = nil
      if pages.count <= count { close() } else { pages.removeLast(count) }
    }
    func perform(_ operation: @escaping @MainActor () async throws -> Void) {
      guard !busy else { return }
      busy = true
      issue = nil
      Task {
        defer { busy = false }
        do { try await operation() } catch {
          if !Task.isCancelled { issue = error.localizedDescription }
        }
      }
    }
  }

  struct MacManagement: View {
    @StateObject private var session: ManagementSession
    @Environment(\.dismiss) private var dismiss
    init(_ route: ManageRoute, store: WorkspaceStore, directory: MarketDirectory) {
      _session = StateObject(
        wrappedValue: ManagementSession(route, store: store, directory: directory))
    }
    var body: some View {
      Group { if let page = session.pages.last { destination(page.route).id(page.id) } }
        .environmentObject(session).onAppear { session.close = { dismiss() } }
        .interactiveDismissDisabled(session.busy).fitPrivateSpaceSheet(true)
    }
    @ViewBuilder private func destination(_ route: ManageRoute) -> some View {
      switch route {
      case .server(let server): ManagedServerPage(server: server)
      case .configuration(let server, let transport): MacServerEditor(server, transport: transport)
      case .access(let server): ServerAgentsPage(server: server)
      case .tools(let server, let grant): ServerToolsPage(server: server, grant: grant)
      case .reconnect(let server): ServerSignInPage(server: server)
      case .test(let server): ServerTestPage(server: server)
      case .scope(let kind, let id, let name, let scope):
        ScopePage(kind: kind, id: id, name: name, initial: scope)
      case .custom: SourceChooserPage()
      case .sourceForm(let kind, let source): CustomSourceEditor(kind: kind, previous: source)
      case .source(let source): CustomSourcePage(source: source)
      case .app(let entry): AppAccountsPage(entry: entry)
      case .account(let entry, let account): AppAccountEditor(entry: entry, account: account)
      case .authorize(let entry): AppAuthorizationPage(entry: entry)
      case .plugin(let source, let key, let name, let review):
        PluginManagementPage(source: source, key: key, name: name, review: review)
      case .repository: RepositoryPage()
      case .skills: SkillsLibraryPage()
      case .packs: SkillPacksPage()
      case .skill(let value): SkillEditorPage(original: value)
      case .confirm(let title, let subtitle, let items, let action, let operation):
        ManagePage("Confirm change", title, subtitle, width: 492) {
          ManageGroup {
            ForEach(items, id: \.self) { Text($0).frame(maxWidth: .infinity, alignment: .leading) }
          }
        } footer: {
          Spacer()
          BackButton("Cancel")
          Button(action, role: .destructive) { session.perform(operation) }
        }
      }
    }
  }

  struct ManagePage<Content: View, Footer: View>: View {
    @EnvironmentObject var session: ManagementSession
    let path: String, title: String, subtitle: String, width: CGFloat
    let badge: String?
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer
    @State private var height: CGFloat = 280
    private var identity: (brand: String, symbol: String) {
      switch session.pages.last?.route {
      case .app(let entry), .account(let entry, _), .authorize(let entry):
        (MarketDirectory.brand(entry.slug), "app.connected.to.app.below.fill")
      case .plugin(_, _, let name, _): (MarketDirectory.brand(name), "puzzlepiece.extension")
      case .server, .configuration, .access, .tools, .test, .reconnect: ("", "server.rack")
      case .skill, .skills, .packs: ("", "books.vertical")
      case .repository: ("github", "shippingbox")
      case .confirm: ("", "exclamationmark.triangle")
      case .scope: ("", "square.stack.3d.up")
      default: ("", "point.3.connected.trianglepath.dotted")
      }
    }
    init(
      _ path: String, _ title: String, _ subtitle: String = "", width: CGFloat = 592,
      badge: String? = nil, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer
    ) {
      self.path = path
      self.title = title
      self.subtitle = subtitle
      self.width = width
      self.badge = badge
      self.content = content()
      self.footer = footer()
    }
    var body: some View {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 8) {
          if session.pages.count > 1 {
            Button {
              session.back()
            } label: {
              Image(systemName: "chevron.backward").padding(4)
            }.buttonStyle(.plain).accessibilityLabel("Back")
          }
          Text(path).lineLimit(1)
          Spacer()
          Button {
            session.close()
          } label: {
            Image(systemName: "xmark").padding(4)
          }.buttonStyle(.plain).accessibilityLabel("Close integration management")
        }.font(.callout).foregroundStyle(.secondary).padding(.horizontal, 18).frame(height: 36)
          .background(MarketStyle.rail)
        Divider()
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 13) {
              MarketMark(brand: identity.brand, fallback: identity.symbol, size: 38)
                .accessibilityHidden(true)
              VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 24, weight: .semibold)).textSelection(.enabled)
                if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
              }
              if let badge {
                Spacer(minLength: 8)
                Text(badge).font(.caption.weight(.semibold)).padding(.horizontal, 8).padding(
                  .vertical, 4
                ).background(MarketStyle.tint, in: Capsule())
              }
            }.padding(.bottom, 5)
            content
            if let issue = session.issue {
              Label(issue, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                .textSelection(.enabled)
            }
          }.padding(.horizontal, 23).padding(.vertical, 20).frame(
            maxWidth: .infinity, alignment: .leading
          )
          .background {
            GeometryReader { proxy in
              Color.clear.preference(key: ManagementHeight.self, value: proxy.size.height)
            }
          }
        }.frame(
          height: min(
            height,
            max(
              185,
              min(
                520,
                (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame.height.advanced(by: -190)
                  ?? 490))))
        Divider()
        HStack(spacing: 9) {
          if session.busy { ProgressView().controlSize(.small) }
          footer
        }.controlSize(.regular)
          .padding(.horizontal, 18).padding(.vertical, 11).background(MarketStyle.rail)
      }.frame(width: min(width, (NSScreen.main?.visibleFrame.width ?? width + 40) - 40)).background(
        MarketStyle.canvas
      )
      .onPreferenceChange(ManagementHeight.self) { if $0 > 0 { height = ceil($0) } }.disabled(
        session.busy)
    }
  }
  private struct ManagementHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
      value = max(value, nextValue())
    }
  }

  struct ManageGroup<Content: View>: View {
    var title: String
    let content: Content
    init(_ title: String = "", @ViewBuilder content: () -> Content) {
      self.title = title
      self.content = content()
    }
    var body: some View {
      VStack(alignment: .leading, spacing: 6) {
        if !title.isEmpty { Text(title).font(.headline) }
        VStack(alignment: .leading, spacing: 11) { content }.padding(13).frame(
          maxWidth: .infinity, alignment: .leading
        )
        .background(MarketStyle.tint, in: RoundedRectangle(cornerRadius: 9)).overlay {
          RoundedRectangle(cornerRadius: 9).strokeBorder(MarketStyle.line, lineWidth: 0.6)
        }
      }
    }
  }
  struct ManageRow<Accessory: View>: View {
    let title: String, caption: String, accessory: Accessory
    init(
      _ title: String, _ caption: String = "",
      @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
      self.title = title
      self.caption = caption
      self.accessory = accessory()
    }
    var body: some View {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 3) {
          Text(title).fontWeight(.medium)
          if !caption.isEmpty {
            Text(caption).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
          }
        }
        Spacer(minLength: 6)
        accessory
      }
    }
  }
  struct ManageField<Content: View>: View {
    let title: String, content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
      self.title = title
      self.content = content()
    }
    var body: some View {
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.callout.weight(.medium))
        content.accessibilityLabel(title)
      }.textFieldStyle(.roundedBorder).controlSize(.large)
    }
  }
  struct BackButton: View {
    @EnvironmentObject var session: ManagementSession
    var title: String
    init(_ title: String = "Done") { self.title = title }
    var body: some View { Button(title) { session.back() }.keyboardShortcut(.cancelAction) }
  }
  struct ScopePage: View {
    @EnvironmentObject var session: ManagementSession
    let kind: String, id: String, name: String, initial: SpaceTool.Availability?
    @State private var all = false
    @State private var selected = Set<String>()
    var body: some View {
      ManagePage(name + "  /  Availability", "Available in") {
        ManageGroup {
          Toggle("All spaces", isOn: $all)
          if !all {
            Divider()
            ForEach(session.store.navigation?.spaces ?? []) { space in
              Toggle(space.name, isOn: membership(space.id, in: $selected))
            }
          }
        }
      } footer: {
        Spacer()
        BackButton("Cancel")
        Button("Save availability") {
          session.perform {
            let scope = SpaceTool.Availability(
              allSpaces: all,
              spaceIds: selected.isEmpty ? [session.store.currentSpace] : selected.sorted())
            try await session.store.setScope(kind: kind, id: id, scope: scope)
            if scope.includes(session.store.currentSpace) {
              session.back()
            } else {
              session.close()
            }
          }
        }.buttonStyle(.borderedProminent).disabled(!all && selected.isEmpty)
      }.onAppear {
        all = initial?.allSpaces ?? false
        selected = Set(initial?.spaceIds ?? [session.store.currentSpace])
      }
    }
  }
  func membership(_ value: String, in set: Binding<Set<String>>) -> Binding<Bool> {
    Binding(
      get: { set.wrappedValue.contains(value) },
      set: { enabled in
        if enabled { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
      })
  }
#endif
