import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Vision

@main @MainActor enum ChatInteractionSmoke {
  final class LocalPanel: NSPanel {
    var pointer = NSPoint.zero
    override var canBecomeKey: Bool { false }
    override var isKeyWindow: Bool { true }
    override var mouseLocationOutsideOfEventStream: NSPoint { pointer }

    func event(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
      pointer = point
      guard !canBecomeKey, alphaValue == 0, ignoresMouseEvents,
        !NSScreen.screens.contains(where: { $0.frame.intersects(frame) }),
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber,
          context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0),
        event.window === self else { throw Failure("Event outside isolated fixture") }
      return event
    }

    func click(_ point: NSPoint) throws {
      let down = try event(.leftMouseDown, at: point)
      NSApp.postEvent(try event(.leftMouseUp, at: point), atStart: true)
      NSApp.sendEvent(down)
      if let up = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true), up.window === self {
        NSApp.sendEvent(up)
      }
    }
  }

  final class FixtureDrag: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingLocation = NSPoint(x: 240, y: 180)
    let draggingSourceOperationMask: NSDragOperation = .copy
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?,
      classes: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
      using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
      var stop = ObjCBool(false)
      for (index, item) in (draggingPasteboard.readObjects(forClasses: classes, options: searchOptions) ?? []).enumerated() {
        guard let writer = item as? NSPasteboardWriting else { continue }
        block(NSDraggingItem(pasteboardWriter: writer), index, &stop)
        if stop.boolValue { break }
      }
    }
  }

  static func main() {
    NSApplication.shared.setActivationPolicy(.prohibited)
    var result: Result<Void, Error>?
    Task { @MainActor in
      do { try await run(); result = .success(()) } catch { result = .failure(error) }
    }
    while result == nil { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01)) }
    if case .failure(let error) = result {
      FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8)); exit(1)
    }
  }

  private static func run() async throws {
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let brief = temp.appendingPathComponent("Brief.txt"), table = temp.appendingPathComponent("Milestones.csv")
    try Data("Release review".utf8).write(to: brief)
    try Data("Name,Date\nReview,Thursday".utf8).write(to: table)
    try await checkIntake(brief, table, temp: temp)

    let store = WorkspaceStore(sample: .initial, persistent: false)
    let chat = store.navigation!.current.bots.first { $0.name == "Chief" }!
    let key = store.draftKey(chat)
    let draft = "Both files for review"
    store.drafts[key] = draft
    let before = store.sample!.transcripts[chat.id]!.count
    let host = NSHostingView(rootView: Conversation(store: store, chat: chat, onProfile: {}, compact: false)
      .environment(\.scenePhase, .active).frame(width: 720, height: 500).background(Ink.canvas))
    let rect = NSRect(x: (NSScreen.screens.map(\.frame.maxX).max() ?? 0) + 1000, y: 0, width: 720, height: 500)
    let window = LocalPanel(contentRect: rect, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    window.alphaValue = 0; window.ignoresMouseEvents = true; window.contentView = host
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    guard !NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) else { throw Failure("Window not isolated") }
    var lines: [(text: String, frame: NSRect)] = []
    func paint(_ name: String) async throws -> [String] {
      try await Task.sleep(for: .milliseconds(250)); host.layoutSubtreeIfNeeded()
      guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw Failure("No bitmap") }
      host.cacheDisplay(in: host.bounds, to: bitmap)
      try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
      let request = VNRecognizeTextRequest()
      try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
      lines = (request.results ?? []).compactMap { row in
        guard let text = row.topCandidates(1).first?.string else { return nil }
        return (text, VNImageRectForNormalizedRect(row.boundingBox, Int(host.bounds.width), Int(host.bounds.height)))
      }
      return lines.map(\.text)
    }
    let idle = try await paint("idle")
    guard idle.contains(where: { $0.contains(draft) }) else { throw Failure("Draft not in Mac chat: \(idle)") }
    let ownText = "What should we cover first?"
    guard let ownLine = lines.first(where: { $0.text.contains(ownText) }),
      let botLine = lines.first(where: { $0.text.contains("gathered the notes") }),
      let longReply = lines.first(where: { $0.text.contains("The outline is ready") }) else { throw Failure("Missing fixture messages: \(idle)") }
    typealias Region = MacChatHoverRegion.Region
    func regions(_ view: NSView) -> [Region] {
      (view as? Region).map { [$0] } ?? view.subviews.flatMap(regions)
    }
    var hovered = Set<Region>()
    func hover(_ point: NSPoint) async throws {
      window.pointer = point
      let hits = Set(regions(host).filter { $0.visibleRect.intersection($0.bounds).contains($0.convert(point, from: nil)) })
      for (views, type) in [(hovered.subtracting(hits), NSEvent.EventType.mouseExited), (hits.subtracting(hovered), .mouseEntered)] {
        guard let event = NSEvent.enterExitEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 0, userData: nil), event.window === window else { throw Failure("Invalid local tracking event") }
        for region in views {
          guard region.trackingAreas.contains(where: { $0.owner === region && $0.options.contains(.mouseEnteredAndExited) }) else { throw Failure("Missing AppKit tracking area") }
          if type == .mouseEntered { region.mouseEntered(with: event) } else { region.mouseExited(with: event) }
        }
      }
      hovered = hits
      try await Task.sleep(for: .milliseconds(160)); host.layoutSubtreeIfNeeded()
    }
    for (line, mine, capture) in [(botLine, false, "incoming-actions"), (longReply, false, "multiline-actions"),
      (ownLine, true, "outgoing-actions")] {
      let point = NSPoint(x: line.frame.midX, y: line.frame.midY)
      try await hover(point)
      let frames: [NSRect] = regions(host).map { region in region.convert(region.bounds, to: nil) }
      guard let bubble = frames.first(where: { $0.contains(point) && $0.width > 90 }),
        capture != "multiline-actions" || bubble.height > 80 else { throw Failure("Missing message surface: \(line.text)") }
      let tiles = frames.filter { abs($0.width - 28) < 1 && abs($0.height - 28) < 1 }
      let buttons = tiles.filter { abs($0.midY - bubble.midY) <= 1 }.sorted { $0.minX < $1.minX }
      guard buttons.count == 3, mine ? buttons[2].maxX <= line.frame.minX : buttons[0].minX >= line.frame.maxX else {
        throw Failure("Misplaced message actions: \(tiles), bubble \(bubble)")
      }
      let reply = NSPoint(x: buttons[1].midX, y: buttons[1].midY)
      try await hover(reply)
      _ = try await paint(capture)
      if mine { try window.click(reply) }
    }
    try await hover(.zero)
    let quoted = try await paint("reply")
    guard quoted.contains(where: { $0 == "You" }), quoted.filter({ $0.contains(ownText) }).count == 2 else { throw Failure("Reply button did not quote your message: \(quoted)") }
    guard let editor = window.firstResponder as? MacChatEditor.Editor else { throw Failure("Reply did not focus the composer") }
    let drag = FixtureDrag(); drag.draggingDestinationWindow = window
    defer { drag.draggingPasteboard.releaseGlobally() }
    drag.draggingPasteboard.writeObjects([brief as NSURL, table as NSURL])
    func destination() throws -> NSView {
      var examined = [String]()
      func search(_ candidate: NSView) -> NSView? {
        guard candidate.bounds.contains(candidate.convert(drag.draggingLocation, from: nil)) else { return nil }
        for child in candidate.subviews.reversed() { if let target = search(child) { return target } }
        if !candidate.registeredDraggedTypes.isEmpty || candidate === host {
          let operation = candidate.draggingEntered(drag)
          if operation.contains(.copy) || candidate.draggingUpdated(drag).contains(.copy) { return candidate }
          examined.append("\(type(of: candidate)): \(operation.rawValue) \(candidate.registeredDraggedTypes.map(\.rawValue))")
        } else {
          examined.append("\(type(of: candidate)): no registered types")
        }
        return nil
      }
      if let target = search(host) { return target }
      throw Failure("No native file destination at \(drag.draggingLocation); \(examined)")
    }
    let first = try destination(); _ = first.draggingUpdated(drag)
    let cue = try await paint("entered")
    guard cue.contains(where: { $0.contains("Release to attach") }) else { throw Failure("No drop cue: \(cue)") }
    first.draggingExited(drag)
    let cancelled = try await paint("cancelled")
    guard cancelled.contains(where: { $0.contains(draft) }), !cancelled.contains(where: { $0.contains("Release to attach") })
    else { throw Failure("Drag exit didn't restore the draft") }
    let input = editor.convert(editor.visibleRect, to: nil)
    drag.draggingLocation = NSPoint(x: input.midX, y: input.midY)
    let target = try destination(); _ = target.draggingUpdated(drag)
    guard target.prepareForDragOperation(drag), target.performDragOperation(drag) else { throw Failure("Drop not consumed") }
    target.concludeDragOperation(drag)
    let staged = try await paint("staged")
    guard editor.string == draft else {
      throw Failure("Dropping into the focused editor did not stage separate files: \(staged)")
    }
    for label in [brief.lastPathComponent, table.lastPathComponent, draft] {
      guard staged.contains(where: { $0.contains(label) }) else { throw Failure("Missing \(label): \(staged)") }
    }
    guard store.sample!.transcripts[chat.id]!.count == before else { throw Failure("Drop sent without confirmation") }
    let stagedFrames: [NSRect] = regions(host).map { region in region.convert(region.bounds, to: nil) }
    let removeButtons = stagedFrames.filter { abs($0.width - 24) < 1 && abs($0.height - 28) < 1 }
      .sorted { $0.minX < $1.minX }
    guard removeButtons.count == 2 else { throw Failure("Missing attachment remove buttons") }
    try window.click(NSPoint(x: removeButtons[1].midX, y: removeButtons[1].midY))
    let removed = try await paint("one-attachment")
    guard !removed.contains(where: { $0.contains(table.lastPathComponent) }),
      removed.contains(where: { $0.contains(brief.lastPathComponent) }), editor.string == draft else { throw Failure("Remove changed the wrong file or draft") }
    drag.draggingPasteboard.clearContents(); drag.draggingPasteboard.writeObjects([table as NSURL])
    let again = try destination()
    guard again.performDragOperation(drag) else { throw Failure("Could not reattach second file") }
    again.concludeDragOperation(drag)
    _ = try await paint("restaged")
    try window.click(NSPoint(x: host.bounds.maxX - 38, y: input.midY))
    _ = try await paint("sent")
    guard let sent = store.sample!.transcripts[chat.id]?.last(where: { $0.role == "user" }),
      sent.blocks.first?.text == draft else { throw Failure("Explicit Send did not deliver the draft") }
    guard sent.blocks.compactMap(\.name) == [brief.lastPathComponent, table.lastPathComponent] else { throw Failure("Explicit Send lost staged files") }
    guard let parent = sent.replyToMessageId, store.sample!.transcripts[chat.id]?.first(where: { $0.id == parent })?.text.contains(ownText) == true else { throw Failure("Explicit Send lost the reply target") }
    guard store.drafts[key] == nil else { throw Failure("Sent draft still stored") }
    func pressReturn(_ modifiers: NSEvent.ModifierFlags) throws {
      guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
        characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36), event.window === window
      else { throw Failure("Cannot address Return to fixture editor") }
      editor.keyDown(with: event)
    }
    editor.insertText("First line", replacementRange: NSRange(location: NSNotFound, length: 0))
    try pressReturn(.shift)
    editor.insertText("Second line", replacementRange: NSRange(location: NSNotFound, length: 0))
    let multiline = "First line\nSecond line"
    guard store.drafts[key] == multiline else { throw Failure("Shift-Return did not preserve both lines") }
    try pressReturn([])
    _ = try await paint("keyboard-send")
    guard store.sample!.transcripts[chat.id]?.last(where: { $0.role == "user" })?.text == multiline else { throw Failure("Return did not send both lines") }
    let longFile = temp.appendingPathComponent("Quarterly planning notes and milestones for the November launch.json")
    try Data("{}".utf8).write(to: longFile)
    drag.draggingPasteboard.clearContents(); drag.draggingPasteboard.writeObjects([longFile as NSURL])
    let singleTarget = try destination()
    guard singleTarget.performDragOperation(drag) else { throw Failure("Could not stage a file without a draft") }
    singleTarget.concludeDragOperation(drag)
    let single = try await paint("attachment-only")
    guard single.contains(where: { $0.contains("Quarterly") && $0.contains(".json") }), editor.string.isEmpty else {
      throw Failure("Long filename or extension missing from the empty draft: \(single)")
    }
    window.appearance = NSAppearance(named: .darkAqua)
    _ = try await paint("attachment-only-dark")
    print("PASS: vertically centered actions on short and tall messages, reply focus, drag enter/exit, staging and removing files, long filenames, explicit Send and multiline Return. No global input.")
  }

  private static func checkIntake(_ first: URL, _ second: URL, temp: URL) async throws {
    let intake = ChatAttachments(), limits = ChatAttachments.Limits(account: nil)
    func settle() async throws {
      let deadline = ContinuousClock.now.advanced(by: .seconds(5))
      while intake.reading {
        guard .now < deadline else { throw Failure("File intake timed out") }
        try await Task.sleep(for: .milliseconds(15))
      }
    }
    guard !MacChatFileDrop.stage([NSItemProvider(object: "not a file" as NSString)], in: intake, limits: limits) else {
      throw Failure("A text drag was accepted")
    }
    let files = [first, temp, second].map { NSItemProvider(object: $0 as NSURL) }
    guard MacChatFileDrop.stage(files, in: intake, limits: limits) else { throw Failure("File providers were rejected") }
    try await settle()
    guard intake.files.map(\.name) == [first.lastPathComponent, second.lastPathComponent],
      intake.files.first?.data == (try Data(contentsOf: first)), intake.problem?.contains("folder") == true else {
      throw Failure("Partial staging failed: \(intake.files.map(\.name)), \(intake.problem ?? "no error")")
    }
    guard !intake.stage(count: 3, limits: limits, resolve: { _ in fatalError("Read over count limit") }) else {
      throw Failure("Count limit ignored")
    }
    intake.remove(intake.files[0]); var delayed: (@MainActor ([ChatAttachments.Source]) -> Void)?
    intake.stage(count: 1, limits: limits) { delayed = $0 }; intake.cancelRead(); delayed?([.success(first)])
    guard intake.files.map(\.name) == [second.lastPathComponent] else { throw Failure("Cancelled read changed the draft") }
    print("PASS: file URL providers, byte content and order, partial failures, limits, removal and cancelled intake.")
  }
}
