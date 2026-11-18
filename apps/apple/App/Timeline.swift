import Combine
import Foundation

@MainActor final class Timeline: ObservableObject {
  @Published var items: [Message] = [] { didSet { rows = TranscriptRows(items) } }
  private(set) var rows = TranscriptRows([])
  @Published var loading = true
  @Published var working = false
  @Published var problem: String?
  @Published var older: Int?
  @Published var run: String?
  @Published var runFailure: String?
  @Published var previews: [String: String] = [:]
  @Published var actionLabels: [String: String] = [:]
  @Published var connection: String?
  private var stamp = 0
  func refresh(store: WorkspaceStore, chat: Chat, preserve: Bool = true) async throws -> Int {
    stamp += 1
    let ticket = stamp
    let snap = try await store.snapshot(chat)
    try Task.checkCancellation()
    guard ticket == stamp else { return snap.cursor ?? -1 }
    if preserve, let first = snap.messages.first, items.first?.seq ?? Int.max < first.seq,
      snap.threadId == threadID
    {
      items = items.filter { $0.seq < first.seq } + snap.messages
    } else {
      items = snap.messages
      older = snap.olderCursor
    }
    threadID = snap.threadId
    run = snap.run?.status
    runFailure = snap.run?.status == "failed" ? snap.run?.error ?? "The run failed." : nil
    loading = false
    return snap.cursor ?? -1
  }
  private var threadID: String?
  func observe(store: WorkspaceStore, chat: Chat) async {
    var backoff: UInt64 = 1
    while !Task.isCancelled {
      do {
        let cursor = try await refresh(store: store, chat: chat)
        previews = [:]
        actionLabels = [:]
        connection = nil
        guard let api = store.client else { return }
        try await api.events(
          "threads/subscribe", input: chat.target.merging(["cursor": cursor]) { $1 }
        ) { event in
          guard let type = event["type"] as? String,
            type.hasPrefix("run.") || type.hasPrefix("thread.") || type == "effect.reconciled"
          else { return }
          backoff = 1
          let key = "progress:" + (event["runId"] as? String ?? event["id"] as? String ?? "live")
          if type == "thread.progress", let payload = event["payload"] as? [String: Any] {
            if payload["activity"] as? Bool == true {
              self.actionLabels[key] = payload["text"] as? String ?? "Running an action…"
              self.previews.removeValue(forKey: key)
              return
            }
            self.actionLabels.removeValue(forKey: key)
            let prior =
              payload["reset"] as? Bool == true
              ? "" : self.previews[key] ?? self.items.first(where: { $0.id == key })?.text ?? ""
            let current =
              (payload["delta"] as? String).map { prior + $0 } ?? payload["text"] as? String
              ?? prior
            if self.run != "running" { self.run = "running" }
            if self.previews[key] != current { self.previews[key] = current }
            return
          }
          if type == "run.checkpointed" { return }
          _ = try await self.refresh(store: store, chat: chat, preserve: type != "thread.cleared")
          if ["thread.message.created", "run.failed", "run.completed", "run.cancelled"].contains(
            type)
          {
            self.previews.removeValue(forKey: key)
            self.actionLabels.removeValue(forKey: key)
          } else if type == "thread.cleared" {
            self.previews = [:]
            self.actionLabels = [:]
          }
        }
        if !Task.isCancelled { connection = "Reconnecting…" }
      } catch {
        if Task.isCancelled { return }
        loading = false
        connection =
          items.isEmpty ? error.localizedDescription : "Live updates paused. Reconnecting…"
      }
      do { try await Task.sleep(nanoseconds: backoff * 1_000_000_000) } catch { return }
      backoff = min(30, backoff * 2)
    }
  }
  func previous(_ api: Client, chat: Chat) async {
    guard let cursor = older, !working else { return }
    working = true
    defer { working = false }
    do {
      let page: ThreadData = try await api.rpc(
        "threads/messages", chat.target.merging(["before": cursor]) { $1 })
      guard page.threadId == threadID else { return }
      let ids = Set(items.map(\.id))
      items.insert(contentsOf: page.messages.filter { !ids.contains($0.id) }, at: 0)
      older = page.olderCursor
    } catch { problem = error.localizedDescription }
  }
}
