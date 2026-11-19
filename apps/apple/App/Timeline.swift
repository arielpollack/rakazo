import Combine
import Foundation

@MainActor final class Timeline: ObservableObject {
  @Published var items: [Message] = [] { didSet { rows = TranscriptRows(items) } }
  private(set) var rows = TranscriptRows([])
  @Published var loading = true
  @Published var working = false
  @Published var problem: String?
  @Published var older: Int?
  @Published var runFailure: String?
  @Published private(set) var turns: [LiveBotTurn] = []
  private let activity = ChatActivity(art: .shared)
  @Published var connection: String?
  private var stamp = 0
  func refresh(store: WorkspaceStore, chat: Chat, preserve: Bool = true, reconnect: Bool = false)
    async throws -> Int
  {
    stamp += 1
    let ticket = stamp
    let api = store.client
    var snap = try await store.snapshot(chat)
    try Task.checkCancellation()
    guard ticket == stamp else { return snap.cursor ?? -1 }
    activity.sync(snap, chat: chat, reconnect: reconnect)
    updateTurns()
    snap.messages.removeAll { $0.id.hasPrefix("progress:") }
    if preserve, let first = snap.messages.first, items.first?.seq ?? Int.max < first.seq,
      snap.threadId == threadID
    {
      items = items.filter { $0.seq < first.seq } + snap.messages
    } else {
      if let api, let cursor = snap.olderCursor,
        !snap.messages.contains(where: \.appearsInTranscript)
      {
        guard
          let page = try await earlierWindow(
            api, chat: chat, thread: snap.threadId, before: cursor,
            isCurrent: { ticket == stamp })
        else { return snap.cursor ?? -1 }
        snap.messages.insert(contentsOf: page.messages, at: 0)
        snap.olderCursor = page.olderCursor
      }
      items = snap.messages
      older = snap.olderCursor
    }
    threadID = snap.threadId
    runFailure =
      snap.run?.status == "failed" && snap.run?.trigger != "tickets"
      ? snap.run?.error ?? "The run failed." : nil
    loading = false
    return snap.cursor ?? -1
  }
  private var threadID: String?
  private func updateTurns() {
    let next = activity.turns
    if next != turns { turns = next }
  }
  func observe(store: WorkspaceStore, chat: Chat) async {
    var backoff: UInt64 = 1
    while !Task.isCancelled {
      do {
        let cursor = try await refresh(store: store, chat: chat, reconnect: true)
        connection = nil
        guard let api = store.client else { return }
        try await api.events(
          "threads/subscribe", input: chat.target.merging(["cursor": cursor]) { $1 }
        ) { event in
          guard let type = event["type"] as? String,
            event["threadId"] as? String == nil || event["threadId"] as? String == self.threadID,
            type.hasPrefix("run.") || type.hasPrefix("thread.") || type.hasPrefix("agent.tool.")
              || type.hasPrefix("computer.takeover.") || type == "effect.reconciled"
          else { return }
          backoff = 1
          if type == "run.checkpointed" { return }
          self.activity.receive(event, chat: chat)
          self.updateTurns()
          if type == "thread.progress" || type.hasPrefix("agent.tool.") { return }
          if type == "thread.meta",
            (event["payload"] as? [String: Any])?["activity"] is [String: Any]
          {
            return
          }
          _ = try await self.refresh(store: store, chat: chat, preserve: type != "thread.cleared")
        }
        if !Task.isCancelled { connection = "Reconnecting…" }
      } catch {
        if Task.isCancelled { return }
        loading = false
        connection =
          rows.visible.isEmpty ? error.localizedDescription : "Live updates paused. Reconnecting…"
      }
      do { try await Task.sleep(nanoseconds: backoff * 1_000_000_000) } catch { return }
      backoff = min(30, backoff * 2)
    }
  }
  func previous(_ api: Client, chat: Chat) async {
    guard let cursor = older, let thread = threadID, !working else { return }
    working = true
    defer { working = false }
    do {
      guard
        let page = try await earlierWindow(
          api, chat: chat, thread: thread, before: cursor,
          isCurrent: { threadID == thread && older == cursor })
      else { return }
      let ids = Set(items.map(\.id))
      items.insert(contentsOf: page.messages.filter { !ids.contains($0.id) }, at: 0)
      older = page.olderCursor
    } catch { if !Task.isCancelled { problem = error.localizedDescription } }
  }
  private func earlierWindow(
    _ api: Client, chat: Chat, thread: String, before: Int, isCurrent: () -> Bool
  ) async throws
    -> ThreadData?
  {
    var cursor = before
    while isCurrent() {
      try Task.checkCancellation()
      let page: ThreadData = try await api.rpc(
        "threads/messages",
        chat.target.merging(["before": cursor, "includePeerReceipts": true]) { $1 })
      try Task.checkCancellation()
      guard isCurrent() else { return nil }
      guard page.threadId == thread, page.olderCursor.map({ $0 < cursor }) != false else {
        throw Failure("Could not load earlier messages in this conversation.")
      }
      guard let next = page.olderCursor, !page.messages.contains(where: \.appearsInTranscript)
      else { return page }
      cursor = next
    }
    return nil
  }
}
