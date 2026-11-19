import Foundation
import JavaScriptCore

struct LiveBotTurn: Identifiable, Equatable {
  let id: String, botID: String, status: String, pose: BotPose
  let working: Bool, composing: Bool, text: String, caption: String
  var canStop: Bool { working || status == "waiting_input" || status == "waiting_takeover" }
}

@MainActor final class ChatActivity {
  private struct Entry {
    let id: String, bot: String, routine: String?, handle: JSValue
  }
  private var entries: [Entry] = []
  private var threadID: String?
  private var cursor = -1
  private let art: AvatarArtwork

  init(art: AvatarArtwork) { self.art = art }

  var turns: [LiveBotTurn] {
    entries.compactMap { entry in
      guard let state = entry.handle.invokeMethod("read", withArguments: [])?.toDictionary(),
        let status = state["status"] as? String, let value = state["pose"] as? String,
        let pose = BotPose(rawValue: value), pose != .idle
      else { return nil }
      let label = (state["label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return LiveBotTurn(
        id: entry.id, botID: entry.bot, status: status, pose: pose,
        working: state["working"] as? Bool == true, composing: state["composing"] as? Bool == true,
        text: state["text"] as? String ?? "",
        caption: label.flatMap { $0.isEmpty ? nil : $0 }
          ?? entry.routine.map { "Running \($0)…" } ?? "Working…")
    }
  }

  func sync(_ snapshot: ThreadData, chat: Chat, reconnect: Bool) {
    let reset = reconnect || threadID != snapshot.threadId
    threadID = snapshot.threadId
    if reset { cursor = snapshot.cursor ?? -1 }
    var runs = snapshot.activeRuns ?? []
    if let primary = snapshot.run, !runs.contains(where: { $0.id == primary.id }) {
      runs.append(primary)
    }
    let working = runs.filter {
      ["queued", "leased", "running"].contains($0.status) && $0.trigger != "tickets"
    }
    let running = working.filter { $0.status == "running" }
    entries = runs.compactMap { run in
      guard run.trigger != "tickets", let bot = run.botId ?? (chat.isGroup ? nil : chat.id),
        let id = run.id,
        ["queued", "leased", "running", "waiting_input", "waiting_takeover", "failed"].contains(
          run.status)
      else { return nil }
      let namedRoutine =
        run.status == "running" && run.trigger == "routine" && running.count == 1
        && working.allSatisfy { $0.botId == run.botId }
      let routine =
        namedRoutine ? run.routineName?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
      if !reset, let prior = entries.first(where: { $0.id == id && $0.bot == bot }),
        prior.handle.invokeMethod("read", withArguments: [])?.forProperty("status")?.toString()
          == run.status
      {
        return Entry(
          id: id, bot: bot, routine: routine?.isEmpty == false ? routine : nil, handle: prior.handle
        )
      }
      let live = snapshot.messages.first { $0.id == "progress:\(id)" }
      let blocks =
        live?.blocks.compactMap { block -> [String: Any]? in
          guard ["text", "progress", "steps"].contains(block.kind) else { return nil }
          if block.kind == "steps" { return ["kind": "steps", "steps": []] }
          return [
            "kind": block.kind, "text": block.text ?? "", "activity": block.activity == true,
            "pendingToolNames": block.pendingToolNames ?? [],
          ]
        } ?? []
      return make(
        id, bot: bot, status: run.status, routine: routine, blocks: blocks,
        seq: live == nil ? cursor : max(snapshot.cursor ?? -1, cursor))
    }
  }

  func receive(_ event: [String: Any], chat: Chat) {
    guard threadID != nil, event["threadId"] as? String == threadID, let seq = event["seq"] as? Int,
      seq > cursor,
      let id = event["runId"] as? String, let type = event["type"] as? String
    else { return }
    cursor = seq
    let payload = event["payload"] as? [String: Any] ?? [:]
    if type == "run.started", !entries.contains(where: { $0.id == id }),
      payload["trigger"] as? String != "tickets",
      let bot = event["botId"] as? String ?? (chat.isGroup ? nil : chat.id),
      let entry = make(
        id, bot: bot, status: "running", routine: payload["routineName"] as? String, blocks: [],
        seq: seq - 1)
    {
      entries.append(entry)
    }
    guard let entry = entries.first(where: { $0.id == id }),
      (event["botId"] as? String ?? entry.bot) == entry.bot
    else { return }
    var fields = payload.filter {
      ["name", "executionId", "trigger", "role", "activity", "delta", "text", "reset", "streaming"]
        .contains($0.key)
    }
    if type != "thread.progress" {
      fields.removeValue(forKey: "text")
      fields.removeValue(forKey: "delta")
    }
    let update: [String: Any] = [
      "type": type, "botId": entry.bot, "runId": id, "seq": seq, "payload": fields,
    ]
    entry.handle.invokeMethod("receive", withArguments: [update])
  }

  private func make(
    _ id: String, bot: String, status: String, routine: String?, blocks: [[String: Any]], seq: Int
  ) -> Entry? {
    guard
      let handle = art.api?.invokeMethod(
        "liveTurn", withArguments: [bot, id, status, false, blocks, seq]), handle.isObject
    else { return nil }
    return Entry(
      id: id, bot: bot, routine: routine?.isEmpty == false ? routine : nil, handle: handle)
  }
}
