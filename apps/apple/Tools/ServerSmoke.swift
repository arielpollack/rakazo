import Foundation

@main struct ServerSmoke {
  static func main() async {
    do { try await verify() } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      exit(1)
    }
  }
  static func verify() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let raw = env["TEST_RUNNER_RAKAZO_TEST_ORIGIN"],
      let password = env["TEST_RUNNER_RAKAZO_TEST_PASSWORD"], let server = try? Client.origin(raw),
      server.host == "127.0.0.1"
    else { throw Failure("Use the isolated upstream fixture.") }
    let auth = Client(server: server)
    let login = try await auth.authenticate(
      email: "native@example.test", password: password, code: false)
    var api = Client(server: server, token: login.token)
    let account: Account = try await api.rpc("me")
    guard account.email == "native@example.test" else { throw Failure("Fixture account mismatch.") }
    let roster: NavigationData = try await api.rpc("spaces/list")
    api.space = roster.current.id
    let bot: ObjectID = try await api.rpc(
      "bots/create", ["name": "API smoke", "description": "Throwaway upstream smoke test"])
    let target = ["botId": bot.id]
    let thread: ThreadData = try await api.rpc("threads/get", target)
    let status: Consent = try await api.rpc(
      "aiConsent/status", ["botId": bot.id, "uses": ["model", "memory"]])
    if !status.unapproved.isEmpty {
      let _: Consent = try await api.rpc(
        "aiConsent/allow",
        ["scope": status.scope, "version": status.version, "keys": status.unapproved.map(\.key)])
    }
    let message = "Isolated native transport check"
    let file = Data("Native fixture file".utf8)
    let artifact: ObjectID = try await api.rpc(
      "artifacts/create",
      [
        "botId": bot.id, "name": "native.txt", "mimeType": "text/plain",
        "contentBase64": file.base64EncodedString(), "clientNonce": UUID().uuidString,
      ])
    let downloaded = try await api.file(
      artifact.id, chat: Chat(id: bot.id, name: "API smoke"), limit: 1024)
    guard downloaded == file else {
      throw Failure("Downloaded bytes do not match the uploaded file.")
    }
    let _: Empty = try await api.rpc(
      "threads/send",
      [
        "botId": bot.id, "text": message, "artifactIds": [artifact.id],
        "clientNonce": UUID().uuidString,
      ])
    let saved: ThreadData = try await api.rpc("threads/get", target)
    guard saved.threadId == thread.threadId,
      saved.messages.contains(where: {
        $0.text.contains(message) && $0.role == "user"
          && $0.blocks.contains(where: { $0.artifactId == artifact.id })
      })
    else { throw Failure("Stored message or attachment missing from upstream thread.") }
    print(
      "Verified sign-in, scoped roster, bot creation, consent, send, attachment bytes, and message readback against the release API."
    )
    let scoped = api
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        do {
          try await scoped.events(
            "threads/subscribe", input: ["botId": bot.id, "cursor": thread.cursor ?? -1]
          ) { event in
            if event["type"] as? String == "thread.message.created",
              let payload = event["payload"] as? [String: Any], payload["role"] as? String == "bot"
            {
              throw ReplyReceived()
            }
          }
          throw Failure("Thread stream closed before a worker reply.")
        } catch is ReplyReceived { return }
      }
      group.addTask {
        try await Task.sleep(for: .seconds(18))
        let last: ThreadData = try await scoped.rpc("threads/get", target)
        throw Failure(
          "No worker reply: run \(last.run?.status ?? "none"), \(last.run?.error ?? "no failure detail"), messages \(last.messages.map(\.role))."
        )
      }
      defer { group.cancelAll() }
      _ = try await group.next()
    }
    let complete: ThreadData = try await scoped.rpc("threads/get", target)
    guard complete.messages.contains(where: { $0.role == "bot" && $0.text.contains(message) })
    else { throw Failure("Worker reply was not persisted.") }
    print(
      "Verified a persisted reply from Rakazo’s scripted worker over the native event stream (no live model)."
    )
    guard
      let parent = complete.messages.first(where: { $0.role == "bot" && $0.text.contains(message) })
    else { throw Failure("No reaction target") }
    let first = UUID().uuidString
    for nonce in [first, first, UUID().uuidString] {
      let _: Empty = try await api.rpc(
        "threads/react",
        ["botId": bot.id, "messageId": parent.id, "reaction": "❤️", "clientNonce": nonce])
    }
    let reacted: ThreadData = try await api.rpc("threads/get", target)
    let projection = TranscriptRows(reacted.messages)
    guard projection.reactions[parent.id]?["❤️"] == 2 else {
      throw Failure("Reactions did not round-trip as two distinct reply messages")
    }
    let _: Empty = try await api.rpc(
      "threads/markUnread", ["botId": bot.id, "messageId": parent.id])
    let excerpt = "native transport"
    let _: Empty = try await api.rpc(
      "threads/send",
      [
        "botId": bot.id, "replyToMessageId": parent.id, "replyQuote": excerpt,
        "text": "Quoted excerpt", "clientNonce": UUID().uuidString,
      ])
    let quoted: ThreadData = try await api.rpc("threads/get", target)
    guard
      quoted.messages.contains(where: {
        $0.replyToMessageId == parent.id && $0.replyQuote == excerpt
      })
    else { throw Failure("Selected text quote missing from stored reply") }
    let scout: ObjectID = try await api.rpc("bots/create", ["name": "Group fixture Scout"])
    let studio: ObjectID = try await api.rpc("bots/create", ["name": "Group fixture Studio"])
    let group: Chat = try await api.rpc(
      "groups/create", ["name": "Group fixture", "botIds": [bot.id, scout.id]])
    let changed: Chat = try await api.rpc(
      "groups/update",
      ["groupId": group.id, "botIds": [bot.id, studio.id], "expectedBotIds": [bot.id, scout.id]])
    guard Set(changed.members?.compactMap(\.botId) ?? []) == [bot.id, studio.id] else {
      throw Failure("Group member replacement did not round-trip")
    }
    let _: Pages = try await api.rpc("pages/list", ["query": "review", "limit": 5])
    let _: [ObjectID] = try await api.rpc("connections/list")
    let routine: Routine = try await api.rpc(
      "routines/create",
      [
        "botId": bot.id, "name": "Fixture", "prompt": "Summarize the notes", "crons": ["0 8 * * *"],
        "active": false, "timezone": "UTC",
      ])
    let edited: Routine = try await api.rpc(
      "routines/update", ["routineId": routine.id, "name": "Edited fixture"])
    guard edited.name == "Edited fixture", !edited.active, edited.crons == routine.crons else {
      throw Failure("Routine changed unrelated schedule fields")
    }
    let _: Empty = try await api.rpc("routines/history", ["routineId": routine.id, "limit": 10])
    let _: Empty = try await api.rpc("routines/remove", ["routineId": routine.id])
    let remaining: [Routine] = try await api.rpc("routines/list", target)
    guard !remaining.contains(where: { $0.id == routine.id }) else {
      throw Failure("Routine still exists after deletion")
    }
    print(
      "Verified reaction retry and counts, selected-text quote, group roster change, mark from message, page search, connection listing, and routine creation, update, history and deletion against v0.12.0."
    )
  }
  struct ReplyReceived: Error {}
}
