import SwiftUI

@MainActor final class HistorySearch: ObservableObject {
  @Published private var result: (query: String, items: [SearchResult]) = ("", [])
  @Published private(set) var busy = false
  @Published private(set) var issue: String?
  func matches(_ query: String) -> [SearchResult] { query == result.query ? result.items : [] }
  func search(_ query: String, store: WorkspaceStore) async {
    let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
    busy = false
    issue = nil
    result = (query, [])
    guard term.count >= 2, term.count <= 200, let workspace = store.navigation?.current else {
      return
    }
    busy = true
    defer { if !Task.isCancelled { busy = false } }
    do {
      try await Task.sleep(for: .milliseconds(220))
      var items = [SearchResult]()
      if let api = store.client {
        let page: SearchPage = try await api.rpc("search/query", ["q": term])
        try Task.checkCancellation()
        var seen = Set<String>()
        let chats = Dictionary(
          workspace.chats.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for hit in page.hits {
          guard let id = hit.messageId, let target = hit.groupId ?? hit.botId,
            let chat = chats[target], seen.insert(target + "/" + id).inserted
          else { continue }
          items.append(
            SearchResult(
              name: chat.name, description: hit.snippet.isEmpty ? hit.title : hit.snippet,
              chat: chat, messageID: id))
        }
      } else if let sample = store.sample {
        for chat in workspace.chats {
          for message in (sample.transcripts[chat.id] ?? []).reversed()
          where message.text.localizedCaseInsensitiveContains(term) && items.count < 25 {
            items.append(
              SearchResult(
                name: chat.name, description: String(message.text.prefix(180)), chat: chat,
                messageID: message.id))
          }
        }
      }
      try Task.checkCancellation()
      guard store.navigation?.current.id == workspace.id else { return }
      result = (query, items)
    } catch { if !Task.isCancelled { issue = "Message history couldn’t be searched. Try again." } }
  }
}

struct SearchExcerpt: View {
  @ObservedObject var store: WorkspaceStore
  let chat: Chat
  let messageID: String
  var revealSidebar: (() -> Void)?
  @State private var rows = [Message]()
  @State private var busy = true
  @State private var problem: String?
  @State private var retry = 0
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: Layout.Space.small) {
        if let revealSidebar {
          Glyph(icon: "sidebar.left", label: "Show chats", action: revealSidebar)
        }
        Avatar(chat: chat, size: 32)
        VStack(alignment: .leading) {
          Text(chat.name).font(.headline)
          Text("Search result in conversation").font(.caption).foregroundStyle(.secondary)
        }
      }.padding(Layout.Space.standard)
      Divider()
      if busy {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let problem {
        ContentUnavailableView {
          Label("Message unavailable", systemImage: "text.magnifyingglass")
        } description: {
          Text(problem)
        } actions: {
          Button("Retry") { retry += 1 }
        }
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: Layout.Space.standard) {
              ForEach(rows) { message in
                VStack(alignment: .leading, spacing: Layout.Space.small) {
                  HStack {
                    Text(message.role == "user" ? (message.author?.name ?? "You") : chat.name)
                      .fontWeight(.semibold)
                    Text(Clock.label(message.createdAt, full: true)).foregroundStyle(.secondary)
                  }.font(.caption)
                  MessageText(content: message.text).equatable().font(TypeRole.message)
                }.padding(Layout.Space.medium).frame(maxWidth: .infinity, alignment: .leading)
                  .background(
                    message.id == messageID ? chat.tint.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: Layout.Radius.panel)
                  ).accessibilityIdentifier(
                    message.id == messageID ? "matched-message" : "context-message"
                  ).id(message.id)
              }
            }.frame(maxWidth: Layout.readingWidth).padding(Layout.Space.standard)
          }.frame(maxWidth: .infinity).onAppear { proxy.scrollTo(messageID, anchor: .center) }
        }
      }
      Divider()
      Button("Return to latest messages", systemImage: "arrow.down") { store.anchorMessage = nil }
        .buttonStyle(.bordered).frame(maxWidth: .infinity).padding(Layout.Space.medium)
    }.background(Ink.canvas).task(id: retry) {
      busy = true
      problem = nil
      defer { if !Task.isCancelled { busy = false } }
      do {
        let messages: [Message]
        if let api = store.client {
          let page: ThreadData = try await api.rpc(
            "threads/messages", chat.target.merging(["around": ["messageId": messageID]]) { $1 })
          messages = page.messages
        } else {
          messages = store.sample?.transcripts[chat.id] ?? []
        }
        try Task.checkCancellation()
        guard messages.contains(where: { $0.id == messageID }) else {
          throw Failure("The matching message is no longer available in this conversation.")
        }
        rows = messages
      } catch { if !Task.isCancelled { problem = error.localizedDescription } }
    }
  }
}
