import AppKit
import SwiftUI
import Vision

@main enum MarketRenderSmoke {
  @MainActor static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    var result: Result<Void, Error>?
    Task { @MainActor in
      do {
        try await runChecks()
        result = .success(())
      } catch { result = .failure(error) }
    }
    while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }
    if case .failure(let error) = result {
      FileHandle.standardError.write(Data("\(error)\n".utf8))
      exit(1)
    }
  }

  @MainActor static func runChecks() async throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let seed = try CatalogSeed.bundled.get()
    let store = WorkspaceStore(sample: .initial, persistent: false)
    try await checkPrivateSpace(store: store, output: output)
    func directory() -> MarketDirectory { .sample(store.sampleIntegrations!, seed: seed) }
    let initial = directory()
    try await checkCompactSkills(directory: initial, output: output)
    try await checkManagement(store: store, directory: initial, output: output)
    precondition(
      initial.items.prefix(6).map(\.name) == [
        "Gmail", "Slack", "Google Drive", "Figma", "Linear", "Notion",
      ])
    precondition(Set(initial.items.map(\.id)).count == initial.items.count)
    precondition(initial.filtered(kind: .server, category: nil, search: "asana.com").count == 1)
    precondition(initial.filtered(kind: .app, category: "Design", search: "").isEmpty)
    for (scheme, width, height, file) in [
      (ColorScheme.light, 1040, 702, "light"), (.dark, 1040, 702, "dark"),
      (.light, 590, 480, "compact"),
    ] {
      try await render(
        MacMarketplace(store: store), to: output.appendingPathComponent(file + ".png"),
        scheme: scheme, width: width, height: height,
        contains: file == "compact"
          ? ["Connect Slack", "Explore integrations"]
          : ["Connect Slack", "Connect Google Drive", "Install Figma", "Configured", "2 accounts"])
    }
    let slack = initial.items[1]
    try await checkCardHits(slack)
    try await render(
      MacMarketplace(store: store, detailID: slack.id),
      to: output.appendingPathComponent("detail.png"), contains: ["Connect Slack", "Try asking"])
    try await render(
      MacMarketplace(store: store, collection: .servers),
      to: output.appendingPathComponent("servers.png"), contains: ["Add Asana server"])
    try await render(
      MarketInstallReview(store: store, item: slack, onFailure: { _ in }),
      to: output.appendingPathComponent("consent.png"), width: 460, height: 390,
      contains: ["Approve sample", "Cancel", "No provider"])

    var flow = MarketActionFlow()
    let grantsBefore = store.sampleIntegrations!.assignments
    for (name, kind) in [("Slack", MarketKind.app), ("Figma", .plugin), ("Asana", .server)] {
      let item = initial.items.first { $0.name == name && $0.kind == kind }!
      precondition(flow.begin(item))
      precondition(!flow.begin(item))
      flow.close()
      precondition(directory().items.first { $0.id == item.id }?.confirmed == nil)
      precondition(flow.begin(item))
      flow.report("Provider unavailable", for: item)
      flow.close()
      precondition(flow.failures[item.id] != nil)
      precondition(flow.begin(item))
      store.changeIntegrations { item.approveSample(in: &$0) }
      flow.report(nil, for: item)
      flow.close()
      let confirmed = directory().items.first { $0.id == item.id }!
      precondition(
        confirmed.confirmed != nil && !flow.begin(confirmed) && flow.failures[item.id] == nil)
    }
    precondition(store.sampleIntegrations!.assignments == grantsBefore)
    let restored = try JSONDecoder().decode(Sample.self, from: JSONEncoder().encode(store.sample!))
    let other = WorkspaceStore(sample: restored, persistent: false)
    try await checkCardHits(directory().items.first { $0.id == slack.id }!)
    try await render(
      MacMarketplace(store: other), to: output.appendingPathComponent("approved.png"),
      contains: ["Connected · Slack", "Installed"], omits: ["Connect Slack", "Install Figma"])
    try await render(
      MacMarketplace(store: other, collection: .manage),
      to: output.appendingPathComponent("manage.png"), scheme: .dark,
      contains: ["Team inbox", "Release watch", "Sign in again", "Not working"])
    let secondID = try await other.createPrivateSpace(name: "Second workspace")
    try await other.openPrivateSpace(secondID)
    precondition(
      other.sampleIntegrations!.accounts.isEmpty
        && other.sampleIntegrations!.installedPlugins == nil)
    print(
      "PASS: eight native offscreen renders with visible controls checked by OCR; cancel, duplicate, failure, retry, confirmation, persistence, workspace isolation and unchanged bot grants. No desktop input."
    )
  }

  private struct HitTestCard: View {
    let item: MarketItem
    let open: () -> Void, connect: () -> Void
    @FocusState var focus: MarketFocus?
    var body: some View {
      MarketCard(
        item: item, waiting: false, failure: nil, blocked: false, focus: $focus, open: open,
        act: connect
      )
      .frame(width: 268, height: 151)
    }
  }

  @MainActor private static func checkCompactSkills(directory: MarketDirectory, output: URL) async throws {
    var sample = Sample.initial
    let fixture = (1...30).map { "Step \($0). Review the proposed change." }.joined(separator: "\n\n") + "\n\nReview complete."
    let document = try CommandLine.arguments.dropFirst(2).first.map { try String(contentsOfFile: $0, encoding: .utf8) } ?? fixture
    let words = document.split(whereSeparator: \.isWhitespace)
    let opening = words.prefix(4).joined(separator: " "), ending = words.suffix(2).joined(separator: " ")
    let skill = ManagedSkill(id: "long-read", name: "Interrogate", description: "Review a change.", source: "builtin", readOnly: true, content: document)
    sample.integrationRecords?.skills = [skill]
    let store = WorkspaceStore(sample: sample, persistent: false)
    for (name, route, expected) in [
      ("library", ManageRoute.skills, ["My integrations", "Search skills", "New skill", "Done"]),
      ("reader", ManageRoute.skill(skill), ["Skills", "Interrogate", opening, "Done"]),
    ] {
      try await render(MacManagement(route, store: store, directory: directory),
        to: output.appendingPathComponent("compact-skills-\(name).png"), scheme: .dark,
        width: 680, height: 308, contains: expected)
    }
    try await render(MacManagement(.skill(skill), store: store, directory: directory),
      to: output.appendingPathComponent("compact-skills-reader-end.png"), scheme: .dark,
      width: 680, height: 308, contains: ["Interrogate", ending, "Done"], omits: [opening]
    ) { view in
      @MainActor func scrollView(in root: NSView) -> NSScrollView? {
        if let scroll = root as? NSScrollView, let document = scroll.documentView,
          document.bounds.height > scroll.contentView.bounds.height { return scroll }
        return root.subviews.lazy.compactMap { scrollView(in: $0) }.first
      }
      guard let scroll = scrollView(in: view), let document = scroll.documentView else {
        throw Failure("No scrolling skill document in the short panel.")
      }
      let bottom = document.isFlipped ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
      scroll.contentView.scroll(to: NSPoint(x: 0, y: bottom))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    print("PASS: short Skills library and reader keep navigation and actions visible; scrolled to the final paragraph.")
  }

  @MainActor private static func checkManagement(store: WorkspaceStore, directory: MarketDirectory, output: URL) async throws {
    let isolated = WorkspaceStore(sample: .initial, persistent: false)
    guard let server = try await isolated.managedServers().first(where: { $0.id == "sample-brain" }),
      let gmail = directory.items.compactMap({ if case .app(let app, _) = $0.content, app.slug == "gmail" { return app }; return nil }).first else { throw Failure("Missing management fixtures.") }
    let routes: [(String, ManageRoute, [String])] = [
      ("server", .server(server), ["Agentic Brain", "Reconnect", "Remove server", "Edit configuration"]),
      ("configuration", .configuration(server, server.transport), ["Server name", "Transport", "Server enabled", "Save changes"]),
      ("accounts", .app(gmail), ["Team inbox", "Personal inbox", "Disconnect Gmail"]),
      ("plugin", .plugin(IntegrationFixtures.repo("Linear"), IntegrationFixtures.repo("Linear"), "Linear", false), ["Connector", "2 skills", "Add skills", "Remove plugin"]),
      ("skills", .skills, ["Your library", "Weekly brief", "New skill"]),
      ("custom", .custom, ["OpenAPI document", "GraphQL endpoint", "GitHub plugin"])
    ]
    for (index, route) in routes.enumerated() {
      try await render(MacManagement(route.1, store: store, directory: directory), to: output.appendingPathComponent("management-" + route.0 + ".png"), scheme: index.isMultiple(of: 2) ? .dark : .light, width: 704, height: 650, contains: route.2)
    }
    let host = NSHostingView(rootView: MacManagement(.server(server), store: isolated, directory: directory).frame(width: 708, height: 654))
    let window = pointerWindow(host, size: host.fittingSize)
    defer { window.orderOut(nil) }
    func locate(_ label: String) async throws -> NSPoint {
      try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure("Missing Mac panel bitmap.") }
      host.cacheDisplay(in: host.bounds, to: bitmap); guard let image = bitmap.cgImage else { throw Failure("Missing Mac panel image.") }
      let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
      try VNImageRequestHandler(cgImage: image).perform([request]); let rows = request.results ?? []
      func key(_ label: String) -> String { label.lowercased().filter { $0.isLetter || $0.isNumber } }
      guard let row = rows.first(where: { key($0.topCandidates(1).first?.string ?? "") == key(label) }) else { throw Failure("Could not locate \(label) in panel: \(rows.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "; "))") }
      return NSPoint(x: row.boundingBox.midX * host.frame.width, y: row.boundingBox.midY * host.frame.height)
    }
    func press(_ label: String) async throws { let point = try await locate(label); try await click(point, in: window) }
    try await press("Edit configuration"); try await press("Advanced"); try await press("Return tool results verbatim"); try await press("Save changes")
    guard try await isolated.managedServers().first(where: { $0.id == server.id })?.verbatimResults == true else { throw Failure("Pointer edit did not persist.") }
    try await press("Remove server"); try await press("Cancel"); try await press("Remove server"); try await press("Remove server")
    guard try await !isolated.managedServers().contains(where: { $0.id == server.id }) else { throw Failure("Pointer confirmation did not remove server.") }
    print("PASS: six production management sheets rendered and OCR checked; clicked Edit → Advanced → toggle → Save → Remove → Cancel → Remove → confirm, and verified fixture state.")
  }

  private final class HitTestWindow: NSPanel {
    var localPointer = NSPoint.zero
    override var canBecomeKey: Bool { false }
    override var isKeyWindow: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { localPointer }
  }

  @MainActor private static func pointerWindow(_ host: NSView, size: CGSize) -> HitTestWindow {
    let right = NSScreen.screens.map(\.frame.maxX).max() ?? 0
    let window = HitTestWindow(
      contentRect: NSRect(origin: .init(x: right + 1000, y: 0), size: size),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.isFloatingPanel = false
    window.isExcludedFromWindowsMenu = true
    window.contentView = host
    window.orderBack(nil)
    host.layoutSubtreeIfNeeded()
    return window
  }

  @MainActor private static func click(_ point: NSPoint, in window: HitTestWindow) async throws {
    guard window.alphaValue == 0, window.ignoresMouseEvents, !window.canBecomeKey,
      !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) })
    else { throw Failure("Expected an offscreen hit-test window.") }
    window.localPointer = point
    func event(_ type: NSEvent.EventType) -> NSEvent {
      NSEvent.mouseEvent(
        with: type, location: point, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
    }
    let down = event(.leftMouseDown)
    let up = event(.leftMouseUp)
    guard down.window === window, up.window === window else {
      throw Failure("Unbound synthetic events.")
    }
    NSApp.postEvent(up, atStart: true)
    NSApp.sendEvent(down)
    if let queued = NSApp.nextEvent(
      matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true)
    {
      NSApp.sendEvent(queued)
    }
    try await Task.sleep(for: .milliseconds(45))
  }

  @MainActor private static func checkCardHits(_ item: MarketItem) async throws {
    var details = 0, actions = 0
    let host = NSHostingView(rootView: HitTestCard(item: item, open: { details += 1 }, connect: { actions += 1 }))
    let window = pointerWindow(host, size: .init(width: 268, height: 151))
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(180))
    for point in [NSPoint(x: 248, y: 15), NSPoint(x: 42, y: 82), NSPoint(x: 27, y: 116)] {
      let prior = details
      try await click(point, in: window)
      guard details == prior + 1, actions == 0 else {
        throw Failure("Card detail hit at \(point): details=\(details), actions=\(actions)")
      }
    }
    try await click(.init(x: 60, y: 26), in: window)
    let connected = item.confirmed != nil
    guard details == (connected ? 4 : 3), actions == (connected ? 0 : 1) else {
      throw Failure("Footer hit (confirmed=\(connected)): details=\(details), actions=\(actions)")
    }
    print(
      "PASS: native pointer hits open details on blank space, summary and mark; footer opens only \(connected ? "details" : "setup")."
    )
  }

  @MainActor private static func checkPrivateSpace(store: WorkspaceStore, output: URL) async throws {
    func capture(_ flow: PrivateSpaceFlow, _ label: String, _ scheme: ColorScheme,
      _ expected: [String], source: WorkspaceStore, cap: CGFloat = 240) async throws -> Int {
      let sheet = PrivateSpaceSheet(store: source, listHeightLimit: cap, close: {}, flow: flow)
        .frame(width: 408).background(Color(nsColor: .windowBackgroundColor))
      return try await render(sheet, to: output.appendingPathComponent("space-\(label).png"),
        scheme: scheme, width: 408, height: nil, contains: expected)
    }
    let flow = PrivateSpaceFlow()
    let empty = try await capture(flow, "empty", .dark, ["New private space", "Space name", "Cancel", "Create space"], source: store)
    flow.name = "Customer support"
    let ready = try await capture(flow, "ready", .light, ["Customer support", "Create space"], source: store)
    flow.name = String(repeating: "A", count: 61)
    let issue = try await capture(flow, "validation", .dark, ["Use 60 characters or fewer", "Create space"], source: store)
    var data = Sample.initial
    data.spaceSkills = (1...45).map { index in
      SpaceTool(kind: "skill", id: "skill-\(index)", name: String(format: "Daily note %02d", index),
        availability: .init(allSpaces: true, spaceIds: ["local"]))
    }
    let tallStore = WorkspaceStore(sample: data, persistent: false)
    flow.name = "Customer support"; _ = await flow.advance(using: tallStore)
    let tall = try await capture(flow, "tools", .light, ["What can this space use", "Daily note 01", "Continue"], source: tallStore)
    guard empty < 220, ready == empty, issue > empty, tall < 390 else {
      throw Failure("Private sheet did not fit: \(empty), \(ready), \(issue), \(tall)")
    }
    print("PASS: Mac fitted heights (pt) empty=\(empty), ready=\(ready), inline error=\(issue), 45+ tools=\(tall); buttons visible.")
    var pointerSample = Sample.initial
    var onlyLinear = SampleIntegrations.initial(space: "local"); onlyLinear.servers.removeAll { $0.id != "linear.app" }
    pointerSample.integrationRecords = .init(); pointerSample.spaceSkills = []; pointerSample.integrations = ["local": onlyLinear]
    let actual = WorkspaceStore(sample: pointerSample, persistent: false), interactive = PrivateSpaceFlow()
    var dismissals = 0
    interactive.name = "Pointer QA"
    let host = NSHostingView(rootView: PrivateSpaceSheet(store: actual, listHeightLimit: 240,
      close: { dismissals += 1 }, flow: interactive).frame(width: 408))
    let window = pointerWindow(host, size: host.fittingSize)
    defer { window.orderOut(nil) }
    try await Task.sleep(for: .milliseconds(180))
    try await click(.init(x: 348, y: 34), in: window)
    guard case .choosing(_, let choices) = interactive.step,
      let linear = choices.firstIndex(where: { $0.name == "Linear" }), dismissals == 0 else {
      throw Failure("Mac Create button did not present the tool picker.")
    }
    window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(120))
    let rowY = 22 + 24 + 20 + CGFloat(choices.count - 1 - linear) * 32 + 16
    try await click(.init(x: 32, y: rowY), in: window)
    guard interactive.selection.contains(choices[linear].key) else { throw Failure("Mac checkbox hit did not select Linear.") }
    try await click(.init(x: 348, y: 34), in: window)
    guard dismissals == 1, actual.navigation?.current.name == "Pointer QA",
      actual.sampleIntegrations?.servers.map(\.name) == ["Linear"] else { throw Failure("Mac Continue did not open the chosen configuration.") }
    print("PASS: Create → check Linear → Continue via native pointer handling inside the isolated Mac panel.")
  }

  @discardableResult @MainActor static func render<Content: View>(
    _ content: Content, to url: URL, scheme: ColorScheme = .light,
    width: Int = 1040, height: Int? = 702, contains: [String], omits: [String] = [],
    beforeCapture: (@MainActor (NSView) throws -> Void)? = nil
  ) async throws -> Int {
    let fitted = height ?? Int(ceil(NSHostingView(rootView: content).fittingSize.height))
    let size = CGSize(width: width, height: fitted)
    let view = NSHostingView(
      rootView: content.environment(\.colorScheme, scheme).frame(
        width: size.width, height: size.height))
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(400))
    view.layoutSubtreeIfNeeded()
    if let beforeCapture {
      try beforeCapture(view)
      try await Task.sleep(for: .milliseconds(120))
      view.layoutSubtreeIfNeeded()
    }
    guard !window.isVisible, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw Failure("Expected an offscreen view.")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]), let image = rep.cgImage
    else { throw Failure("No image data.") }
    try data.write(to: url)
    let reader = VNRecognizeTextRequest()
    reader.recognitionLevel = .accurate
    reader.recognitionLanguages = ["en-US"]
    try VNImageRequestHandler(cgImage: image).perform([reader])
    let text = (reader.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(
      separator: " ")
    func normalize(_ string: String) -> String {
      string.lowercased().filter { $0.isLetter || $0.isNumber }
    }
    let normalized = normalize(text)
    for value in contains where !normalized.contains(normalize(value)) {
      throw Failure("\(url.lastPathComponent) missing \(value): \(text)")
    }
    for value in omits where normalized.contains(normalize(value)) {
      throw Failure("\(url.lastPathComponent) unexpectedly shows \(value).")
    }
    return fitted
  }
}
