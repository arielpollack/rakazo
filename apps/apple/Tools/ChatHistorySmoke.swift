import AppKit
import SwiftUI
import Vision

@main enum ChatHistorySmoke {
  @MainActor static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    var result: Result<Void, Error>?
    Task { @MainActor in
      do {
        if CommandLine.arguments.contains("--release-server") {
          try await checkServer()
        } else {
          try checkWireHistory()
          try await checkLongHistory()
        }
        result = .success(())
      } catch { result = .failure(error) }
    }
    while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
    if case .failure(let error) = result {
      FileHandle.standardError.write(Data("\(error)\n".utf8))
      exit(1)
    }
  }

  static func checkWireHistory() throws {
    let data = Data(
      #"""
      {"json":{"threadId":"scout-thread","cursor":72,"olderCursor":18,"run":null,"messages":[
        {"id":"request","seq":18,"role":"user","createdAt":"2026-05-01T10:00:00Z","blocks":[{"kind":"text","text":"Review the draft"}]},
        {"id":"prompt","seq":19,"role":"bot","createdAt":"2026-05-01T10:01:00Z","blocks":[{"kind":"tool_question","question":{"source":"Review","message":"Which draft?","fields":[{"name":"draft","type":"text","label":"Draft","required":true}]},"status":"pending","expiresAt":"2026-05-01T10:10:00Z","publicKey":"fixture"}]},
        {"id":"choice","seq":20,"role":"bot","createdAt":"2026-05-01T10:02:00Z","blocks":[{"kind":"choice","question":"Which day?","options":[{"id":"today","letter":"A","label":"Today"}]}]},
        {"id":"mixed","seq":21,"role":"bot","createdAt":"2026-05-01T10:03:00Z","blocks":[{"kind":"future_card","steps":["richer metadata"]},{"kind":"text","text":"Draft received"}]},
        {"id":"protected","seq":22,"role":"bot","createdAt":"2026-05-01T10:04:00Z","blocks":[{"kind":"ask","text":"Confirm","actions":[{"unsupported":"shape"}]}]},
        {"id":"hidden","seq":23,"role":"user","createdAt":"2026-05-01T10:05:00Z","blocks":[{"kind":"delivery","result":{}},{"kind":"text","text":"Internal fixture input"}]}
      ]}}
      """#.utf8)
    let thread = try JSONDecoder().decode(Client.Envelope<ThreadData>.self, from: data).json
    let rows = TranscriptRows(thread.messages).visible
    guard thread.olderCursor == 18, thread.cursor == 72,
      rows.map(\.id) == ["request", "prompt", "choice", "mixed", "protected"],
      rows[1].text == "Which draft?", rows[2].text == "Which day?",
      rows[2].blocks.first?.options?.first?.id == "today",
      rows[3].blocks.count == 2, rows[3].blocks.last?.text == "Draft received",
      rows[4].blocks.first?.kind == "unsupported_content",
      rows[4].blocks.first?.plainQuestion == false
    else { throw Failure("Mixed transcript lost a row, prompt, cursor, or an action boundary.") }
    print(
      "Passed: mixed history, structured tool prompts, choices, unsupported content and fail-closed actions."
    )
  }

  @MainActor static func checkLongHistory() async throws {
    var sample = Sample.initial
    let bots = Array(sample.spaces[0].bots.prefix(3))
    let endings = ["Blue lantern", "Green orchard", "Silver harbor"]
    for (index, bot) in bots.enumerated() {
      var messages = (1...(index == 0 ? 2 : 38)).map { sequence in
        Sample.message(sequence, sequence.isMultiple(of: 3) ? "user" : "bot",
          String(repeating: "Notes for the next meeting.\n\n", count: sequence % 7 + 1))
      }
      messages.append(Sample.message(messages.count + 1, "bot", endings[index]))
      sample.transcripts[bot.id] = messages
    }
    let store = WorkspaceStore(sample: sample, persistent: false)
    try await checkSelections(store: store, bots: bots, expected: endings, order: [0, 1, 2, 1, 0])
    print("Passed: latest messages paint across short and multi-screen Mac transcripts.")
  }

  @MainActor static func checkSelections(
    store: WorkspaceStore, bots: [Chat], expected: [String], order: [Int]
  ) async throws {
    let size = CGSize(width: 1160, height: 760)
    let host = NSHostingView(rootView: Shell(store: store).environment(\.scenePhase, .active)
      .frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
      backing: .buffered, defer: false)
    window.contentView = host
    for index in order {
      store.choose(bots[index])
      let deadline = ContinuousClock.now.advanced(by: .seconds(8))
      var matched = false
      repeat {
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let leading = Layout.sidebar + 2 * Layout.Space.medium
        let rect = CGRect(x: leading, y: 0, width: size.width - leading, height: size.height)
        guard !window.isVisible, let rep = host.bitmapImageRepForCachingDisplay(in: rect) else {
          throw Failure("Expected an offscreen transcript.")
        }
        host.cacheDisplay(in: rect, to: rep)
        guard let image = rep.cgImage else { throw Failure("No transcript render.") }
        let reader = VNRecognizeTextRequest()
        reader.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([reader])
        let text = (reader.results ?? []).compactMap { $0.topCandidates(1).first?.string }
          .joined(separator: " ").lowercased()
        matched = text.contains(expected[index].lowercased()) && !text.contains("internal fixture input")
          && !expected.enumerated().contains { $0.offset != index && text.contains($0.element.lowercased()) }
      } while !matched && ContinuousClock.now < deadline
      guard matched else { throw Failure("Fixture \(index) did not paint its own latest history.") }
    }
  }

  @MainActor static func checkServer() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let origin = env["TEST_RUNNER_RAKAZO_TEST_ORIGIN"],
      let server = try? Client.origin(origin),
      server.host == "127.0.0.1", let password = env["TEST_RUNNER_RAKAZO_TEST_PASSWORD"]
    else { throw Failure("Use the isolated upstream fixture.") }
    let login = try await Client(server: server).authenticate(
      email: "native@example.test", password: password, code: false)
    let store = WorkspaceStore(login: login)
    try await store.load()
    guard let api = store.client, store.account?.email == "native@example.test" else {
      throw Failure("Fixture account mismatch.")
    }
    var bots: [Chat] = []
    let notes = ["Orchard inventory", "Mountain forecast", "Harbor schedule"]
    let seed = CommandLine.arguments.contains("--seed")
    for (index, name) in ["Chief", "Scout", "Atlas", "Empty fixture"].enumerated() {
      let bot: Chat
      if let existing = store.navigation?.current.bots.first(where: { $0.name == name }) {
        bot = existing
      } else {
        guard seed else { throw Failure("Missing seeded bot: \(name)") }
        try await store.create(name: name, description: "", members: nil)
        guard let created = store.chat else { throw Failure("Missing fixture bot") }
        bot = created
      }
      if seed, index < notes.count {
        let consent: Consent = try await api.rpc(
          "aiConsent/status", ["botId": bot.id, "uses": ["model", "memory"]])
        if !consent.unapproved.isEmpty {
          let _: Empty = try await api.rpc(
            "aiConsent/allow",
            [
              "scope": consent.scope, "version": consent.version,
              "keys": consent.unapproved.map(\.key),
            ])
        }
        let _: Empty = try await api.rpc(
          "threads/send", ["botId": bot.id, "text": notes[index], "clientNonce": UUID().uuidString])
      }
      bots.append(bot)
    }
    if seed {
      for (bot, note) in zip(bots, notes) {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while true {
          let saved = try await store.snapshot(bot)
          if saved.messages.contains(where: { $0.role == "bot" && $0.text.contains(note) }) {
            break
          }
          guard ContinuousClock.now < deadline else {
            throw Failure("Fixture worker did not reply to \(bot.name).")
          }
          try await Task.sleep(for: .milliseconds(200))
        }
      }
      return
    }
    let latest = try await store.snapshot(bots[1])
    guard latest.olderCursor != nil, !latest.messages.isEmpty,
      TranscriptRows(latest.messages).visible.isEmpty
    else {
      throw Failure("The fixture did not exercise a fully hidden newest page.")
    }
    let empty = try await store.snapshot(bots[3])
    guard empty.messages.isEmpty, empty.olderCursor == nil else {
      throw Failure("Expected a genuinely empty bot.")
    }
    try await checkSelections(store: store, bots: bots,
      expected: notes.map { "I handled: \($0)" } + ["Start a conversation"],
      order: [0, 1, 2, 3, 0, 2, 1, 0, 1])
    print(
      "Passed: nine native Mac chat selections, including persisted history behind 510 hidden messages and a genuinely empty conversation."
    )
  }
}
