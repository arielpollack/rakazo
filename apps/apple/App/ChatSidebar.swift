import SwiftUI

struct ChatSidebar<Title: View, Compose: View>: View {
  @ObservedObject var store: WorkspaceStore
  let compact: Bool
  @Binding var searching: Bool
  let searchRequest: Int
  let working: Bool
  let search: () -> Void, choose: (Chat) -> Void, present: (Panel) -> Void
  let refresh: () async -> Void, collapse: () -> Void
  @ViewBuilder let title: () -> Title
  @ViewBuilder let compose: () -> Compose
  @State private var folder = "all"
  @State private var query = ""
  @State private var cursor = 0
  @StateObject private var history = HistorySearch()
  @FocusState private var focused: Bool
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    let workspace = store.navigation?.current
    let chats = workspace?.chats ?? []
    let unread = chats.filter { $0.unread == true }
    let results = searching ? SearchResult.results(chats, query) + history.matches(query) : []
    VStack(spacing: 0) {
      if !compact {
        HStack(spacing: Layout.Space.tight) {
          VStack(alignment: .leading, spacing: 2) {
            Text("RAKAZO").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(.secondary)
            title()
          }
          Spacer(minLength: 0)
          Glyph(icon: "command", label: "Command menu", action: { present(.palette) }).help(
            "Command menu (⌘K)")
          Glyph(icon: "sidebar.leading", label: "Hide chats", action: collapse)
          compose().font(.body.weight(.semibold)).foregroundStyle(Ink.action)
        }.padding(.horizontal, Layout.Space.standard).frame(minHeight: Layout.headerHeight)
      }
      Group {
        if searching && !compact {
          HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query).textFieldStyle(.plain).focused($focused)
              .accessibilityIdentifier("sidebarQuery")
              .task(id: searchRequest) {
                await Task.yield()
                if !Task.isCancelled { focused = true }
              }
              .onSubmit { if results.indices.contains(cursor) { open(results[cursor]) } }
            Button {
              searching = false
            } label: {
              Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).accessibilityLabel("Close search").keyboardShortcut(.cancelAction)
          }.padding(.horizontal, 10)
        } else {
          Button(action: search) {
            HStack(spacing: Layout.Space.small) {
              Image(systemName: "magnifyingglass")
              Text("Search workspace").lineLimit(1)
              Spacer()
            }.padding(.horizontal, 10).frame(maxWidth: .infinity, maxHeight: .infinity)
              .contentShape(Rectangle())
          }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Search")
        }
      }.font(.subheadline).frame(
        minHeight: compact ? Layout.touch : Layout.pointer,
        maxHeight: typeSize.isAccessibilitySize ? 65 : compact ? Layout.touch : Layout.pointer
      ).background(compact ? Ink.fill : Ink.panelField, in: RoundedRectangle(cornerRadius: Layout.Radius.control))
        .padding(.horizontal, Layout.Space.medium).padding(.vertical, Layout.Space.tight)
      if searching && !compact {
        ScrollViewReader { proxy in
          List {
            ForEach(Array(results.enumerated()), id: \.element.id) { index, hit in
              Button {
                open(hit)
              } label: {
                SearchRow(result: hit, shortcuts: false).padding(.horizontal, 12).frame(
                  minHeight: 55)
              }
              .buttonStyle(.plain).id(hit.id).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
              .listRowBackground(index == cursor ? Ink.fill : Color.clear)
              .accessibilityIdentifier(
                (hit.messageID == nil ? "search-result-" : "message-hit-") + hit.name)
            }
          }.listStyle(.plain).scrollContentBackground(.hidden).overlay {
            if results.isEmpty {
              if history.busy {
                ProgressView()
              } else if let issue = history.issue {
                Problem(text: issue).padding()
              } else {
                ContentUnavailableView.search(text: query)
              }
            }
          }.onChange(of: cursor) { _, index in
            if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
          }
        }
      } else if let workspace {
        let visible =
          folder == "all"
          ? chats
          : folder == "unread"
            ? unread : chats.filter { "section:" + ($0.sectionId ?? "") == folder }
        HStack {
          Menu {
            filterOption("All conversations", id: "all")
            filterOption("Unread", id: "unread")
            ForEach(workspace.botSections) { section in
              filterOption(section.name, id: "section:" + section.id)
            }
          } label: {
            HStack(spacing: 5) {
              Text(
                folder == "all"
                  ? "Conversations"
                  : folder == "unread"
                    ? "Unread"
                    : workspace.botSections.first { "section:" + $0.id == folder }?.name
                      ?? "Conversations")
              Image(systemName: "chevron.down").font(.caption2)
            }.font(.subheadline.weight(.semibold)).frame(
              minHeight: compact ? Layout.touch : Layout.pointer)
          }.buttonStyle(.plain).menuIndicator(.hidden).accessibilityIdentifier("chatFilter")
          Spacer()
          Text(visible.count.formatted()).font(.caption.monospacedDigit()).foregroundStyle(
            .secondary
          ).accessibilityLabel("\(visible.count) conversations")
        }.padding(.horizontal, Layout.Space.standard).padding(.top, Layout.Space.small)
        List(visible) { chat in
          let selected = !compact && chat.id == store.selected
          Button {
            choose(chat)
          } label: {
            ChatRow(chat: chat, compact: compact, selected: selected)
          }
          .buttonStyle(.plain).accessibilityIdentifier("chat-" + chat.name)
          .accessibilityAddTraits(selected ? .isSelected : [])
          .listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets())
          .contextMenu {
            Button(
              chat.pinned == true ? "Unpin chat" : "Pin chat",
              systemImage: chat.pinned == true ? "pin.slash" : "pin"
            ) {
              Task {
                do { try await store.update(chat, pinned: chat.pinned != true) } catch {
                  store.error = error.localizedDescription
                }
              }
            }
            Button(
              chat.unread == true ? "Mark as read" : "Mark as unread",
              systemImage: chat.unread == true ? "envelope.open" : "envelope.badge"
            ) {
              Task {
                do { try await store.mark(chat, unread: chat.unread != true) } catch {
                  store.error = error.localizedDescription
                }
              }
            }
          }
        }.listStyle(.plain).scrollContentBackground(.hidden).refreshable { await refresh() }.overlay
        {
          if visible.isEmpty {
            if folder == "all" {
              ContentUnavailableView {
                Label("No chats yet", systemImage: "bubble.left")
              } actions: {
                Button("Create a bot") { present(.bot) }
              }
            } else {
              Text(folder == "unread" ? "No unread chats" : "No chats in this folder")
                .foregroundStyle(.secondary)
            }
          }
        }
      } else {
        Group {
          if working {
            ProgressView()
          } else {
            Button("Reload workspace") { Task { await refresh() } }
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      if !searching {
        Divider().padding(.horizontal, Layout.Space.medium)
        HStack(spacing: Layout.Space.tight) {
          Button {
            present(.apps)
          } label: {
            Label("Connect apps", systemImage: "square.grid.2x2").font(.subheadline).frame(
              minHeight: Layout.touch)
          }.buttonStyle(.plain)
          Spacer(minLength: 0)
          Glyph(
            icon: "waveform.path.ecg", label: "Activity",
            size: compact ? Layout.touch : Layout.pointer
          ) { present(.activity) }
          Glyph(
            icon: "person.crop.circle", label: "Account",
            size: compact ? Layout.touch : Layout.pointer
          ) { present(.account) }.accessibilityIdentifier("account")
        }.padding(.horizontal, Layout.Space.standard)
        if store.demo {
          Text("Sample workspace · On this device").font(.caption2).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(
              .horizontal, Layout.Space.standard
            ).padding(.bottom, Layout.Space.small)
        }
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity).modifier(FloatingPanel(compact: compact))
      .onKeyPress(.downArrow) {
        guard searching else { return .ignored }
        cursor = min(max(0, results.count - 1), cursor + 1)
        return .handled
      }
      .onKeyPress(.upArrow) {
        guard searching else { return .ignored }
        cursor = max(0, cursor - 1)
        return .handled
      }
      .onChange(of: searching) { _, active in
        query = ""
        cursor = 0
        if !active { focused = false }
      }
      .onChange(of: query) { _, _ in cursor = 0 }
      .onChange(of: workspace?.id) { _, _ in
        folder = "all"
        query = ""
      }
      .task(id: (workspace?.id ?? "") + "/" + query) { await history.search(query, store: store) }
  }
  private func filterOption(_ name: String, id: String) -> some View {
    Button {
      folder = id
    } label: {
      if folder == id { Label(name, systemImage: "checkmark") } else { Text(name) }
    }
  }
  private func open(_ hit: SearchResult) {
    if let chat = hit.chat {
      choose(chat)
      store.anchorMessage = hit.messageID
    } else if let panel = hit.panel {
      present(panel)
    }
  }
}

struct ChatRow: View {
  let chat: Chat, compact: Bool, selected: Bool
  @Environment(\.dynamicTypeSize) private var typeSize
  private var secondary: Color { PlatformColor.secondaryLabel }
  var body: some View {
    HStack(spacing: 10) {
      Avatar(chat: chat, size: Layout.rowAvatar)
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
          Text(chat.name).font(TypeRole.rowTitle).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
          Spacer(minLength: 3)
          if !typeSize.isAccessibilitySize { timestamp }
        }
        HStack(alignment: .top, spacing: 4) {
          Text(chat.preview?.isEmpty == false ? chat.preview ?? "" : chat.description ?? "").font(
            TypeRole.summary
          ).foregroundStyle(secondary).lineLimit(typeSize.isAccessibilitySize ? 3 : 2).frame(
            maxWidth: .infinity, alignment: .leading)
          if chat.unread == true {
            Circle().fill(Ink.action).frame(width: 7, height: 7).accessibilityLabel("Unread")
          } else if chat.pinned == true {
            Image(systemName: "pin.fill").font(.caption2).foregroundStyle(secondary)
              .accessibilityLabel("Pinned")
          }
        }
        if typeSize.isAccessibilitySize { timestamp }
      }
    }.padding(.horizontal, Layout.Space.small).padding(.vertical, Layout.Space.small).frame(
      minHeight: compact ? 70 : 62
    )
    .foregroundStyle(.primary).background(
      selected ? Ink.selection : Color.clear, in: RoundedRectangle(cornerRadius: Layout.Radius.control)
    ).contentShape(Rectangle())
    .padding(.horizontal, Layout.Space.small).padding(.vertical, 1)
    .accessibilityElement(children: .combine)
  }
  private var timestamp: some View {
    Text(Clock.label(chat.updatedAt)).font(TypeRole.timestamp).foregroundStyle(secondary)
      .fixedSize()
  }
}
