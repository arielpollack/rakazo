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
    func directory() -> MarketDirectory { .sample(store.sampleIntegrations!, seed: seed) }
    let initial = directory()
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
          : ["Connect Slack", "Connect Google Drive", "Install Figma", "Configured", "Team inbox"])
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
    try await other.create(
      name: "Second workspace", description: "", members: nil, privateSpace: true)
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

  private final class HitTestWindow: NSPanel {
    var localPointer = NSPoint.zero
    override var canBecomeKey: Bool { false }
    override var isKeyWindow: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { localPointer }
  }

  @MainActor private static func checkCardHits(_ item: MarketItem) async throws {
    var details = 0
    var actions = 0
    let host = NSHostingView(
      rootView: HitTestCard(item: item, open: { details += 1 }, connect: { actions += 1 }))
    let right = NSScreen.screens.map(\.frame.maxX).max() ?? 0
    let window = HitTestWindow(
      contentRect: NSRect(x: right + 1000, y: 0, width: 268, height: 151),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    window.alphaValue = 0
    window.ignoresMouseEvents = true
    window.isFloatingPanel = false
    window.isExcludedFromWindowsMenu = true
    window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(180))
    func click(_ x: CGFloat, _ y: CGFloat) async throws {
      guard window.alphaValue == 0, !window.canBecomeKey,
        !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) })
      else { throw Failure("Expected an offscreen hit-test window.") }
      let point = NSPoint(x: x, y: y)
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
    for point in [NSPoint(x: 248, y: 15), NSPoint(x: 42, y: 82), NSPoint(x: 27, y: 116)] {
      let prior = details
      try await click(point.x, point.y)
      guard details == prior + 1, actions == 0 else {
        throw Failure("Card detail hit at \(point): details=\(details), actions=\(actions)")
      }
    }
    try await click(60, 26)
    let connected = item.confirmed != nil
    guard details == (connected ? 4 : 3), actions == (connected ? 0 : 1) else {
      throw Failure("Footer hit (confirmed=\(connected)): details=\(details), actions=\(actions)")
    }
    print(
      "PASS: native pointer hits open details on blank space, summary and mark; footer opens only \(connected ? "details" : "setup")."
    )
  }

  @MainActor static func render<Content: View>(
    _ content: Content, to url: URL, scheme: ColorScheme = .light,
    width: Int = 1040, height: Int = 702, contains: [String], omits: [String] = []
  ) async throws {
    let size = CGSize(width: width, height: height)
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
  }
}
