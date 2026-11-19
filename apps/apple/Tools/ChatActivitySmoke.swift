import AppKit
import Combine
import SwiftUI
import Vision

@main enum ChatActivitySmoke {
  @MainActor static func main() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    if CommandLine.arguments.contains("--server") {
      try await server()
      return
    }
    let art = AvatarArtwork.shared
    guard art.api?.isObject == true else { throw Failure("Missing packaged avatar renderer") }
    let chat = Chat(id: "chief", name: "Chief", color: "#8795AA", avatarSet: "rakazo")
    let projection = ChatActivity(art: art)
    let run = ThreadData.Run(
      status: "running", id: "turn", botId: chat.id, trigger: "routine", routineName: "Daily brief")
    let snapshot = ThreadData(threadId: "test", messages: [], cursor: 0, run: run)
    projection.sync(snapshot, chat: chat, reconnect: true)
    var seq = 0
    func send(_ type: String, _ payload: [String: Any] = [:]) {
      seq += 1
      projection.receive(
        [
          "type": type, "threadId": "test", "botId": chat.id, "runId": "turn", "seq": seq,
          "payload": payload,
        ], chat: chat)
    }
    func check(_ pose: BotPose, _ caption: String? = nil) throws {
      guard projection.turns.first?.pose == pose,
        caption == nil || projection.turns.first?.caption == caption
      else { throw Failure("Expected \(pose): \(projection.turns)") }
    }
    try check(.working, "Running Daily brief…")
    send("thread.meta", ["activity": ["thinking": true]])
    try check(.thinking)
    for (name, pose) in [
      ("read_file", BotPose.reading), ("write_file", .writing), ("computer_act", .computer),
      ("other", .working),
    ] {
      send("agent.tool.called", ["name": name, "executionId": name])
      try check(pose)
      send("agent.tool.completed", ["executionId": name])
      try check(.working)
    }
    send("thread.progress", ["text": "Finding a tool", "activity": true])
    try check(.working, "Finding a tool")
    guard projection.turns.first?.text == "" else { throw Failure("Tool caption leaked into chat") }
    send("thread.progress", ["reset": true, "streaming": true, "delta": "A reply."])
    try check(.writing)
    guard projection.turns.first?.text == "A reply.", projection.turns.first?.composing == true
    else { throw Failure("Writing row lost") }
    send("agent.tool.called", ["executionId": "second", "name": "read_file"])
    try check(.reading)
    guard projection.turns.first?.text == "A reply.", projection.turns.first?.composing == false
    else { throw Failure("Tool after narration lost the prior sentence or its mark") }
    send("computer.takeover.requested")
    try check(.waiting)
    guard projection.turns.first?.working == false, projection.turns.first?.text == "",
      projection.turns.first?.canStop == true
    else { throw Failure("Waiting rendered a working footer") }
    send("computer.takeover.released")
    try check(.working)
    send("run.failed")
    try check(.error)
    projection.sync(snapshot, chat: chat, reconnect: true)
    try check(.working)
    send("run.completed")
    guard projection.turns.isEmpty else { throw Failure("Terminal activity persisted") }
    var hidden = snapshot
    hidden.run?.trigger = "tickets"
    projection.sync(hidden, chat: chat, reconnect: true)
    guard projection.turns.isEmpty else { throw Failure("Background work leaked") }
    let base = "2026-11-19T09:00:00Z"
    guard Clock.needsSeparator(base, after: nil),
      !Clock.needsSeparator("2026-11-19T09:14:59Z", after: base),
      Clock.needsSeparator("2026-11-19T09:15:00Z", after: base)
    else { throw Failure("Time grouping differs") }
    let internalBlocks = [
      Message.Block(kind: "steps"),
      Message.Block(kind: "progress", text: "Finding a tool", activity: true),
    ]
    var reply = Message(id: "reply", seq: 2, role: "bot", blocks: internalBlocks, createdAt: base)
    guard !reply.appearsInTranscript else { throw Failure("An internal-only message is visible") }
    reply.blocks.append(.init(kind: "text", text: "Hello"))
    guard reply.text == "Hello", reply.appearsInTranscript else {
      throw Failure("Settled reply lost")
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    func render(_ bot: Chat, _ pose: BotPose, _ dark: Bool = false, _ time: Double = 0.72) throws
      -> Data
    {
      guard
        let scene = art.scene(
          chat: bot, size: 28, dark: dark, pose: pose, composing: false, still: pose == .idle)
      else { throw Failure("Missing scene \(pose)") }
      let renderer = ImageRenderer(
        content: Canvas { context, size in
          scene.draw(context, in: size, elapsed: time, morph: 0, poke: nil)
        }.frame(width: 96, height: 96))
      renderer.scale = 2
      guard let cg = renderer.cgImage,
        let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
      else { throw Failure("Native image missing") }
      return data
    }
    var images = Set<Data>()
    for pose in BotPose.allCases {
      let data = try render(chat, pose)
      images.insert(data)
      try data.write(to: directory.appendingPathComponent("\(pose).png"))
    }
    guard images.count == BotPose.allCases.count,
      try render(chat, .working) != render(chat, .working, false, 1.42),
      try render(chat, .idle) != render(chat, .idle, true)
    else { throw Failure("Poses, motion or appearance rendered identically") }
    for (index, color) in ["#8795AA", "#8795AA::shape_7", "data:image/png;base64,fixture"]
      .enumerated()
    {
      let bot = Chat(id: chat.id, name: chat.name, color: color)
      let data = try render(bot, .working)
      guard !images.contains(data) else { throw Failure("Identity substituted") }
      images.insert(data)
      try data.write(to: directory.appendingPathComponent("family-\(index).png"))
    }
    print(
      "PASS: bundled native artwork for eight poses, two themes, four families, animation, events, waiting, reconnect, message filtering and time grouping."
    )
  }

  @MainActor static func server() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let raw = env["TEST_RUNNER_RAKAZO_TEST_ORIGIN"], let url = URL(string: raw),
      url.host == "127.0.0.1", let password = env["TEST_RUNNER_RAKAZO_TEST_PASSWORD"]
    else { throw Failure("Requires disposable loopback server") }
    let login = try await Client(server: url).authenticate(
      email: "native@example.test", password: password, code: false)
    let store = WorkspaceStore(login: login)
    try await store.load()
    guard let api = store.client else { throw Failure("No test server") }
    let bot: Chat = try await api.rpc(
      "bots/create", ["name": "Activity test", "avatarSet": "rakazo"])
    let consent: Consent = try await api.rpc(
      "aiConsent/status", ["botId": bot.id, "uses": ["model", "memory"]])
    if !consent.unapproved.isEmpty {
      let _: Empty = try await api.rpc(
        "aiConsent/allow",
        ["scope": consent.scope, "version": consent.version, "keys": consent.unapproved.map(\.key)])
    }
    let feed = Timeline()
    let note = "What is your name?"
    var sawMark = false
    let observation = feed.$turns.sink { if $0.contains(where: \.working) { sawMark = true } }
    let observer = Task { await feed.observe(store: store, chat: bot) }
    defer {
      observer.cancel()
      observation.cancel()
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while feed.loading {
      guard .now < deadline else { throw Failure("Snapshot timed out") }
      try await Task.sleep(for: .milliseconds(50))
    }
    let _: Empty = try await api.rpc(
      "threads/send", ["botId": bot.id, "text": note, "clientNonce": UUID().uuidString])
    while !feed.rows.visible.contains(where: { $0.role == "bot" && $0.text.contains(note) })
      || !feed.turns.isEmpty
    {
      guard .now < deadline else { throw Failure("Reply/settling timed out") }
      try await Task.sleep(for: .milliseconds(50))
    }
    guard sawMark else { throw Failure("Never observed live work on released SSE") }
    let size = CGSize(width: 760, height: 540)
    let view = NSHostingView(rootView: Conversation(store: store, chat: bot, onProfile: {}, compact: false)
      .environment(\.scenePhase, .active).frame(width: size.width, height: size.height))
    let rect = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    let paintDeadline = ContinuousClock.now.advanced(by: .seconds(8))
    while true {
      try await Task.sleep(for: .milliseconds(200))
      view.layoutSubtreeIfNeeded()
      guard !window.isVisible, let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else {
        throw Failure("Expected an offscreen native chat window")
      }
      view.cacheDisplay(in: rect, to: bitmap)
      guard let image = bitmap.cgImage else { throw Failure("No rendered Mac chat") }
      let reader = VNRecognizeTextRequest()
      reader.recognitionLanguages = ["en-US"]
      try VNImageRequestHandler(cgImage: image).perform([reader])
      let lines = (reader.results ?? []).compactMap { $0.topCandidates(1).first?.string.lowercased() }
      if lines.contains(where: { $0.contains("i handled") }),
        lines.filter({ $0.contains("what is your name") }).count >= 2,
        !lines.contains(where: { $0 == "actions" || $0.hasPrefix("working…") }) { break }
      guard .now < paintDeadline else { throw Failure("The saved turn did not paint correctly: \(lines)") }
    }
    print(
      "PASS: release server sign-in → send → native working mark → both bubbles painted in the Mac chat with no leftover activity."
    )
  }
}
