import SwiftUI

enum Panel: String, Identifiable {
  case bot, group, space, account, activity, apps, profile, search, palette, shortcuts
  var id: String { rawValue }
}

struct Shell: View {
  @ObservedObject var store: WorkspaceStore
  @State private var modal: Panel?
  @State private var search = false
  @State private var searchRequest = 0
  @State private var sidebarVisible = true
  @State private var overlayVisible = false
  @State private var nextPanel: Panel?
  @State private var openChatAfterDismissal = false
  @State private var phoneChat = false
  @State private var inspector = false
  @State private var working = false
  @Environment(\.scenePhase) var phase
  #if os(macOS)
    @Environment(\.openSettings) private var openSettings
  #endif
  var body: some View {
    GeometryReader { geometry in
      #if os(macOS)
        let compact = false
        let overlaysChat = geometry.size.width < Layout.sidebarMin + Layout.readingWidth
        let visibility = overlaysChat ? $overlayVisible : $sidebarVisible
      #else
        let compact = geometry.size.width < Layout.compactWidth
        let overlaysChat = false
        let visibility = $sidebarVisible
      #endif
      let inlineInspector = geometry.size.width >= Layout.inspectorWidth
      ZStack {
        Group {
          #if os(macOS)
          MacWorkspace(sidebarVisible: visibility, inspectorVisible: $inspector, overlaysChat: overlaysChat) {
            sidebar(compact: false, visibility: visibility, closeAfterSelection: overlaysChat)
          } detail: {
            detail(compact: false, inlineInspector: inlineInspector, visibility: visibility)
          } profile: {
            inlineProfile
          }
          #else
          MobileWorkspace(width: geometry.size.width, compact: compact, inlineInspector: inlineInspector,
            hasProfile: inspector && store.chat != nil, sidebarVisible: sidebarVisible, phoneChat: $phoneChat,
            sidebar: { sidebar(compact: $0, visibility: visibility) },
            detail: { detail(compact: $0, inlineInspector: $1, visibility: visibility) },
            workspaceMenu: { workspaceMenu }, composeMenu: { composeMenu }, profile: { inlineProfile })
          #endif
        }
        if working && store.navigation != nil {
          ProgressView().padding(8).background(.regularMaterial, in: Capsule()).frame(
            maxHeight: .infinity, alignment: .top
          ).allowsHitTesting(false)
        }
      }.background {
        #if os(iOS)
        Button("Command menu") { if modal == nil { modal = .palette } }.keyboardShortcut("k")
          .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        #endif
      }.focusedSceneValue(
        \.workspaceActions, actions(compact: compact, visibility: visibility, overlaysChat: overlaysChat)
      ).onChange(of: overlaysChat) { _, narrow in
        if !narrow { overlayVisible = false }
      }.onChange(of: store.selected) { _, _ in
        if overlaysChat { overlayVisible = false }
      }.onChange(of: compact) { _, narrow in
        if narrow {
          search = false
          phoneChat = store.chat != nil
        }
      }.onChange(of: inlineInspector) { _, wide in if !wide { inspector = false } }.sheet(
        item: $modal,
        onDismiss: {
          if openChatAfterDismissal {
            openChatAfterDismissal = false
            phoneChat = true
          }
          if let nextPanel {
            self.nextPanel = nil
            present(nextPanel)
          }
        }
      ) { panel in
        Group {
          switch panel {
          case .space:
            PrivateSpaceSheet(store: store, listHeightLimit: min(320, max(64, geometry.size.height - 220))) {
              phoneChat = false
              modal = nil
            }
          case .bot, .group:
            CreateForm(
              store: store, kind: panel,
              finished: {
                openChatAfterDismissal = true
                modal = nil
              })
          case .profile:
            if let chat = store.chat {
              Profile(
                store: store, chat: chat,
                sheetHeightLimit: min(Layout.profileSheetMaxHeight, geometry.size.height * 0.9),
                close: { modal = nil }
              ).id(chat.id)
            }
          case .account: AccountView(store: store)
          case .activity:
            ActivityView(
              store: store,
              open: { id in
                if let chat = store.navigation?.current.chats.first(where: { $0.id == id }) {
                  store.choose(chat)
                  openChatAfterDismissal = true
                  modal = nil
                }
              })
          case .apps:
            #if os(macOS)
            MacMarketplace(store: store).id(store.navigation?.current.id)
            #else
            ConnectionsView(store: store)
            #endif
          case .shortcuts:
            NavigationStack {
              List {
                Section("Workspace") {
                  LabeledContent("Command menu", value: "⌘K")
                  LabeledContent("Show or hide sidebar", value: "⌘B")
                  LabeledContent("New bot", value: "⌘N")
                  LabeledContent("New group chat", value: "⇧⌘N")
                  LabeledContent("Refresh workspace", value: "⌘R")
                  LabeledContent("Account settings", value: "⌘,")
                }
                Section("Command menu") {
                  LabeledContent("Move selection", value: "↑ ↓")
                  LabeledContent("Open selection", value: "Return")
                  LabeledContent("Close", value: "Esc")
                  LabeledContent("Jump to a conversation", value: "⌘1–9")
                }
              }.navigationTitle("Keyboard shortcuts").inlineMobileTitle()
                .toolbar {
                  ToolbarItem(placement: .confirmationAction) { Button("Done") { modal = nil } }
                }
            }
          case .palette:
            CommandPalette(
              store: store,
              choose: { chat in
                store.choose(chat)
                if overlaysChat { overlayVisible = false }
                openChatAfterDismissal = compact
                modal = nil
              },
              action: { panel in
                nextPanel = panel
                modal = nil
              }, close: { modal = nil })
          case .search:
            #if os(iOS)
            MobileSearch(
              store: store,
              choose: {
                store.choose($0)
                openChatAfterDismissal = true
                modal = nil
              },
              action: {
                nextPanel = $0
                modal = nil
              })
            #else
              EmptyView()
            #endif
          }
        }
        #if os(macOS)
        .formStyle(.grouped)
        .frame(width: min(panel == .space ? 408 : panel == .apps ? 1040 : panel == .palette ? 560 : 500, geometry.size.width - 32),
               height: panel == .space || panel == .profile ? nil : min(panel == .apps ? 702 : panel == .palette ? 440 : 490, geometry.size.height - 64))
        .fitPrivateSpaceSheet(panel == .space)
        #else
        .presentationDragIndicator(compact ? .visible : .automatic)
        #endif
      }
    }.task { await refresh() }
      .task(id: "\(store.navigation?.current.id ?? "")-\(phase == .active)") {
        guard phase == .active, let api = store.client, api.space != nil else { return }
        var delay = 1
        while !Task.isCancelled {
          do {
            try Task.checkCancellation()
            try await api.events("notifications/subscribe", input: [:]) { event in
              if event["type"] as? String == "roster", !Task.isCancelled {
                try await store.load(space: api.space)
                delay = 1
              }
            }
          } catch { if Task.isCancelled { return } }
          do {
            try await Task.sleep(for: .seconds(delay))
            try await store.load(space: api.space)
          } catch { if Task.isCancelled { return } }
          delay = min(delay * 2, 30)
        }
      }.alert(
        "Workspace",
        isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
      ) {
        Button("OK") { store.error = nil }
      } message: {
        Text(store.error ?? "")
      }
  }
  @ViewBuilder private var inlineProfile: some View {
    if let chat = store.chat { Profile(store: store, chat: chat, close: { inspector = false }).id(chat.id) }
  }
  private func present(_ panel: Panel) {
    #if os(macOS)
      if panel == .account { openSettings(); return }
    #endif
    modal = panel
  }
  @ViewBuilder private func detail(compact: Bool, inlineInspector: Bool, visibility: Binding<Bool>) -> some View {
    if let chat = store.chat, let space = store.navigation?.current.id {
      if let anchor = store.anchorMessage {
        SearchExcerpt(
          store: store, chat: chat, messageID: anchor,
          revealSidebar: !compact && !visibility.wrappedValue ? { visibility.wrappedValue = true } : nil
        ).id(
          space + "/" + chat.id + "/" + anchor)
      } else {
        Conversation(
          store: store, chat: chat,
          onProfile: { if inlineInspector { inspector.toggle() } else { modal = .profile } },
          compact: compact,
          revealSidebar: !compact && !visibility.wrappedValue ? { visibility.wrappedValue = true } : nil
        ).id(space + "/" + chat.id)
      }
    } else if working && store.navigation == nil {
      ProgressView("Loading conversations…")
    } else {
      VStack(spacing: Layout.Space.medium) {
        Avatar(chat: Chat(id: "welcome", name: "Rakazo", color: "#FF781C"), size: 58)
        Text("Choose a conversation").font(.title2.weight(.semibold))
        Text("Pick a bot or group from your workspace, or start a new one.").font(.body)
          .foregroundStyle(.secondary).multilineTextAlignment(.center)
        Button("New bot", systemImage: "plus") { modal = .bot }.buttonStyle(.bordered).tint(
          Ink.action)
      }.frame(maxWidth: 330).padding().frame(maxWidth: .infinity, maxHeight: .infinity).overlay(
        alignment: .topLeading
      ) {
        if !compact && !visibility.wrappedValue {
          Glyph(icon: "sidebar.leading", label: "Show chats") { visibility.wrappedValue = true }.padding(
            Layout.Space.medium)
        }
      }
    }
  }
  private var composeMenu: some View {
    Menu {
      Button("New bot", systemImage: "plus.bubble") { modal = .bot }
      Button("New group chat", systemImage: "person.2") { modal = .group }
      Button("New private space", systemImage: "folder.badge.plus") { modal = .space }
    } label: {
      Label("Create", systemImage: "plus").frame(width: Layout.pointer, height: Layout.pointer)
    }
    .buttonStyle(.plain).menuIndicator(.hidden).labelStyle(.iconOnly).accessibilityIdentifier(
      "create"
    ).help("Create a bot, group or space")
  }
  private var workspaceMenu: some View {
    Menu {
      Button("Command menu…", systemImage: "command") { modal = .palette }
      if let nav = store.navigation {
        Section("Workspaces") {
          ForEach(nav.spaces) { space in
            Button {
              Task { await refresh(space: space.id) }
            } label: {
              if space.id == nav.current.id {
                Label(space.name, systemImage: "checkmark")
              } else {
                Text(space.name)
              }
            }
          }
        }
      }
      Button("New private space", systemImage: "folder.badge.plus") { modal = .space }
    } label: {
      HStack(spacing: 5) {
        Text(store.navigation?.current.name ?? "Workspace").font(.headline).lineLimit(1)
        Image(systemName: "chevron.down").font(.caption2.bold()).foregroundStyle(.secondary)
      }
    }.buttonStyle(.plain).menuIndicator(.hidden).accessibilityLabel(
      "\(store.navigation?.current.name ?? "Workspace"), switch workspace"
    ).help("Switch workspace")
  }
  private func openSearch(_ compact: Bool, visibility: Binding<Bool>) {
    if compact {
      modal = .search
    } else {
      visibility.wrappedValue = true
      search = true
      searchRequest += 1
    }
  }
  private func sidebar(compact: Bool, visibility: Binding<Bool>, closeAfterSelection: Bool = false) -> some View {
    ChatSidebar(
      store: store, compact: compact, searching: $search, searchRequest: searchRequest,
      working: working,
      search: { openSearch(compact, visibility: visibility) },
      choose: { chat in
        store.choose(chat)
        phoneChat = true
        search = false
        if closeAfterSelection { visibility.wrappedValue = false }
      },
      present: {
        search = false
        present($0)
      }, refresh: { await refresh() },
      collapse: {
        search = false
        visibility.wrappedValue = false
      }, title: { workspaceMenu }, compose: { composeMenu })
  }
  func refresh(space: String? = nil) async {
    working = true
    defer { working = false }
    do { try await store.load(space: space) } catch {
      if !Task.isCancelled { store.error = error.localizedDescription }
    }
  }
  func actions(compact: Bool, visibility: Binding<Bool>, overlaysChat: Bool) -> WorkspaceActions {
    WorkspaceActions(
      search: { if modal == nil { modal = .palette } else if modal == .palette { modal = nil } },
      panel: { if modal == nil { present($0) } }, refresh: { Task { await refresh() } },
      sidebar: {
        if compact {
          phoneChat = false
        } else {
          search = false
          visibility.wrappedValue.toggle()
        }
      },
      chats: Array((store.navigation?.current.chats ?? []).prefix(9)),
      choose: {
        store.choose($0)
        if overlaysChat { overlayVisible = false }
        phoneChat = true
      })
  }
}
struct WorkspaceActions: FocusedValueKey {
  typealias Value = Self
  var search: () -> Void, panel: (Panel) -> Void, refresh: () -> Void, sidebar: () -> Void,
    chats: [Chat], choose: (Chat) -> Void
}
extension FocusedValues {
  var workspaceActions: WorkspaceActions? {
    get { self[WorkspaceActions.self] }
    set { self[WorkspaceActions.self] = newValue }
  }
}
struct WorkspaceCommands: Commands {
  @FocusedValue(\.workspaceActions) private var actions
  #if os(macOS)
    @Environment(\.openWindow) private var openWindow
  #endif
  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      #if os(macOS)
        Button("Show Rakazo Workspace") { openWindow(id: "workspace") }.keyboardShortcut("0")
        Divider()
      #endif
      Button("New Bot") { actions?.panel(.bot) }.keyboardShortcut("n").disabled(actions == nil)
      Button("New Group Chat") { actions?.panel(.group) }.keyboardShortcut(
        "n", modifiers: [.command, .shift]
      ).disabled(actions == nil)
    }
    CommandMenu("Workspace") {
      Button("Command Menu…") { actions?.search() }.keyboardShortcut("k").disabled(actions == nil)
      Button("Show or Hide Sidebar") { actions?.sidebar() }.keyboardShortcut("b").disabled(actions == nil)
      Button("Refresh Workspace") { actions?.refresh() }.keyboardShortcut("r").disabled(actions == nil)
      #if os(iOS)
        Button("Account Settings…") { actions?.panel(.account) }.keyboardShortcut(",")
      #endif
      Divider()
      ForEach(Array((actions?.chats ?? []).enumerated()), id: \.element.id) { index, chat in
        Button(chat.name) { actions?.choose(chat) }.keyboardShortcut(
          KeyEquivalent(Character(String(index + 1))))
      }
    }
  }
}
struct SearchResult: Identifiable {
  var name: String, description: String
  var chat: Chat?, panel: Panel?, shortcut: Int?
  var messageID: String?
  var id: String {
    if let messageID, let chat { return "message/" + chat.id + "/" + messageID }
    return chat.map { "chat/" + $0.id } ?? "panel/" + name
  }
  static func results(_ chats: [Chat], _ query: String) -> [Self] {
    let conversations = chats.enumerated().map { index, chat in
      Self(
        name: chat.name, description: chat.description ?? chat.preview ?? "", chat: chat,
        shortcut: index < 9 ? index + 1 : nil)
    }
    let actions: [(String, Panel)] = [
      ("New bot", .bot), ("New group chat", .group), ("New private space", .space),
      ("Connect apps", .apps), ("Activity", .activity), ("Settings", .account),
    ]
    return (conversations + actions.map { Self(name: $0.0, description: "Action", panel: $0.1) })
      .filter {
        query.isEmpty
          || [$0.name, $0.description, $0.chat?.preview ?? ""].contains {
            $0.localizedCaseInsensitiveContains(query)
          }
      }
  }
}
struct SearchRow: View {
  let result: SearchResult, shortcuts: Bool
  var body: some View {
    HStack(spacing: Layout.Space.medium) {
      if let chat = result.chat {
        Avatar(chat: chat, size: 32)
      } else {
        Image(systemName: "command").frame(width: 32).foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: Layout.Space.tight) {
        Text(result.name).font(TypeRole.rowTitle)
        if !result.description.isEmpty {
          Text(result.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer()
      if shortcuts, let number = result.shortcut {
        Text("⌘\(number)").font(.caption).foregroundStyle(.secondary)
      }
    }.contentShape(Rectangle())
  }
}
#if os(iOS)
struct MobileSearch: View {
  @ObservedObject var store: WorkspaceStore
  let choose: (Chat) -> Void
  let action: (Panel) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""
  @State private var searching = true
  @StateObject private var history = HistorySearch()
  var body: some View {
    let results =
      SearchResult.results(store.navigation?.current.chats ?? [], query) + history.matches(query)
    NavigationStack {
      List(results) { result in
        Button {
          open(result)
        } label: {
          SearchRow(result: result, shortcuts: false)
        }.buttonStyle(.plain).accessibilityIdentifier(
          (result.messageID == nil ? "search-result-" : "message-hit-") + result.name)
      }.listStyle(.plain)
        .overlay {
          if results.isEmpty {
            if history.busy {
              ProgressView("Searching messages…")
            } else if let issue = history.issue {
              Problem(text: issue)
            } else {
              ContentUnavailableView.search(text: query)
            }
          }
        }
        .task(id: query) { await history.search(query, store: store) }
        .navigationTitle("Search").inlineMobileTitle()
        .searchable(
          text: $query, isPresented: $searching,
          placement: .navigationBarDrawer(displayMode: .always), prompt: "Search"
        ).onSubmit(of: .search) { if let first = results.first { open(first) } }
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
    }
  }
  func open(_ result: SearchResult) {
    if let chat = result.chat {
      choose(chat)
      store.anchorMessage = result.messageID
    } else if let panel = result.panel {
      action(panel)
    }
  }
}
#endif
