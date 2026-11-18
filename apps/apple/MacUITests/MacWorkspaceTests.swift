import AppKit
import XCTest

final class MacWorkspaceTests: XCTestCase {
  override func setUp() { continueAfterFailure = false }

  private func launch(_ mode: String = "--test-sample", arguments: [String] = []) -> XCUIApplication
  {
    let app = XCUIApplication()
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", mode] + arguments
    app.launch()
    if !app.windows["workspace"].waitForExistence(timeout: 2) {
      app.menuBars.menuBarItems["File"].click()
      app.menuItems["Show Rakazo Workspace"].click()
    }
    XCTAssertTrue(app.windows["workspace"].waitForExistence(timeout: 5))
    return app
  }

  private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
    app.descendants(matching: .any).matching(identifier: id).firstMatch
  }
  private func capture(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.windows["workspace"].screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testPaletteAndSidebarPreserveConversationDraft() throws {
    let app = launch()
    let chief = app.buttons["chat-Chief"].firstMatch
    XCTAssertTrue(chief.waitForExistence(timeout: 10))
    chief.click()
    let composer = element(app, "composer")
    capture(app, "Mac conversation")
    composer.click()
    app.typeText("Keep this Mac draft")
    app.typeKey("k", modifierFlags: .command)
    let query = app.textFields["command-query"].firstMatch
    XCTAssertTrue(query.waitForExistence(timeout: 5))
    capture(app, "Mac command menu")
    app.typeText("Scout")
    XCTAssertTrue(element(app, "command-chat/sample-scout").waitForExistence(timeout: 5))
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertEqual(composer.value as? String, "Keep this Mac draft")
    app.typeKey("b", modifierFlags: .command)
    XCTAssertTrue(composer.isHittable)
    app.typeKey("b", modifierFlags: .command)
    XCTAssertTrue(chief.waitForExistence(timeout: 5))
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(query.waitForExistence(timeout: 5))
    app.typeText("Scout")
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(app.buttons["profile"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["profile"].label.contains("Scout"))
    chief.click()
    XCTAssertEqual(composer.value as? String, "Keep this Mac draft")
    composer.click()
    app.typeKey(.return, modifierFlags: [])
    XCTAssertTrue(app.staticTexts["Keep this Mac draft"].waitForExistence(timeout: 5))
  }

  func testConversationTitleFitsSelectionAndOpensItsProfile() throws {
    let app = launch(arguments: ["-appearance", "Dark"])
    let chief = app.buttons["chat-Chief"].firstMatch
    XCTAssertTrue(chief.waitForExistence(timeout: 8))
    chief.click()
    let title = app.buttons["profile"]
    XCTAssertEqual(title.label, "Open profile for Chief")
    let shortWidth = title.frame.width
    app.buttons["chat-Agent walkthrough"].firstMatch.click()
    XCTAssertEqual(title.label, "Open profile for Agent walkthrough")
    XCTAssertGreaterThan(title.frame.width, shortWidth)
    capture(app, "Mac conversation title, dark")
    title.click()
    XCTAssertTrue(app.buttons["Close profile"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Interactive sample of agent messages"].firstMatch.exists)
  }

  func testMyMessagesUseTheSelectedBotsColor() throws {
    let app = launch(arguments: ["-appearance", "Light"])
    let chief = app.buttons["chat-Chief"].firstMatch
    XCTAssertTrue(chief.waitForExistence(timeout: 8))
    chief.click()
    let outgoing = app.staticTexts["Yes, please. What should we cover first?"].firstMatch
    XCTAssertTrue(outgoing.waitForExistence(timeout: 5))
    try assertColor(0xF16B00, covers: outgoing, minimum: 0.30)
    try assertColor(0xFFFFFF, covers: outgoing, minimum: 0.01)
    capture(app, "Floating chats and Chief accent, light")
    app.buttons["chat-Scout"].firstMatch.click()
    let composer = element(app, "composer")
    composer.click()
    app.typeText("A different conversation")
    let send = app.buttons["send"]
    try assertColor(0xFF3E51, covers: send, minimum: 0.30)
    send.click()
    let reply = app.staticTexts["A different conversation"].firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 5))
    try assertColor(0xFF3E51, covers: reply, minimum: 0.30)
    capture(app, "Scout conversation accent, light")
  }

  private func assertColor(
    _ rgb: Int, covers element: XCUIElement, minimum: Double,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let snapshot = try XCTUnwrap(
      element.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil))
    let width = snapshot.width
    let height = snapshot.height
    let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try XCTUnwrap(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          | CGBitmapInfo.byteOrder32Big.rawValue))
    context.draw(snapshot, in: CGRect(x: 0, y: 0, width: width, height: height))
    let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
    let matches = stride(from: 0, to: width * height * 4, by: 4).count { index in
      abs(Int(bytes[index]) - (rgb >> 16 & 255)) <= 4
        && abs(Int(bytes[index + 1]) - (rgb >> 8 & 255)) <= 4
        && abs(Int(bytes[index + 2]) - (rgb & 255)) <= 4
    }
    XCTAssertGreaterThan(
      Double(matches) / Double(width * height), minimum,
      "Expected rendered sRGB #\(String(rgb, radix: 16))", file: file, line: line)
  }

  func testNarrowChatsFloatOverTheDraftAndDismissOnSelection() throws {
    let app = launch(arguments: ["-appearance", "Dark"])
    let window = app.windows["workspace"]
    app.buttons["chat-Chief"].firstMatch.click()
    let composer = element(app, "composer")
    composer.click()
    app.typeText("Keep my draft under the panel")
    let shrink = window.frame.width - 760
    func resize(_ delta: CGFloat) {
      let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(
        CGVector(dx: -2, dy: -2))
      corner.click(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: delta, dy: 0)))
    }
    resize(-shrink)
    defer { resize(shrink) }
    let show = app.buttons["Show chats"]
    XCTAssertTrue(show.waitForExistence(timeout: 5))
    let before = composer.frame
    show.click()
    let panel = app.buttons["Hide chats"]
    XCTAssertTrue(panel.waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Dismiss chats"].exists)
    capture(app, "Floating chats over narrow conversation, dark")
    app.buttons["chat-Chief"].firstMatch.click()
    XCTAssertTrue(show.waitForExistence(timeout: 5))
    XCTAssertFalse(panel.exists)
    XCTAssertEqual(composer.value as? String, "Keep my draft under the panel")
    XCTAssertEqual(composer.frame.width, before.width, accuracy: 2)
    try assertColor(
      0xF16B00, covers: app.staticTexts["Yes, please. What should we cover first?"].firstMatch,
      minimum: 0.30)
  }

  func testProfileAndSelectedPassage() throws {
    let app = launch()
    let row = app.buttons["chat-Scout"].firstMatch
    XCTAssertTrue(row.waitForExistence(timeout: 10))
    row.click()
    app.buttons["profile"].click()
    let routine = app.buttons["New routine"]
    XCTAssertTrue(routine.waitForExistence(timeout: 5))
    XCTAssertTrue(routine.isHittable)
    routine.click()
    XCTAssertTrue(app.textFields["routine-name"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].click()
    app.buttons["Close profile"].click()
    let message = app.staticTexts["I found three trails worth exploring."].firstMatch
    message.hover()
    element(app, "More message actions").click()
    app.menuItems["Select text…"].click()
    let reader = element(app, "passage-reader")
    XCTAssertTrue(reader.waitForExistence(timeout: 5))
    reader.click()
    app.typeKey(.leftArrow, modifierFlags: .command)
    app.typeKey(.rightArrow, modifierFlags: [.option, .shift])
    let quote = app.buttons["Quote selection"]
    XCTAssertTrue(quote.isEnabled)
    quote.click()
    XCTAssertTrue(app.buttons["Cancel reply"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["I"].exists)
  }

  func testCancelRoutineInShortWindow() throws {
    let app = launch(arguments: ["-appearance", "Light"])
    let window = app.windows["workspace"]
    let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(
      CGVector(dx: -2, dy: -2))
    let shrink = max(0, window.frame.height - 510)
    if shrink > 0 {
      corner.click(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: 0, dy: -shrink)))
    }
    defer {
      if shrink > 0 {
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(
          CGVector(dx: -2, dy: -2))
        end.click(forDuration: 0.2, thenDragTo: end.withOffset(CGVector(dx: 0, dy: shrink)))
      }
    }
    XCTAssertLessThanOrEqual(window.frame.height, 560)
    app.buttons["chat-Chief"].firstMatch.click()
    app.buttons["profile"].click()
    app.buttons["New routine"].click()
    let name = app.textFields["routine-name"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    let cancel = app.buttons["Cancel"]
    XCTAssertTrue(cancel.isHittable)
    XCTAssertTrue(window.frame.contains(cancel.frame))
    capture(app, "New routine in light mode")
    app.typeKey(.escape, modifierFlags: [])
    XCTAssertTrue(name.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["New routine"].isHittable)
  }

  func testCreatePausedRoutine() throws {
    let app = launch(arguments: ["-appearance", "Dark"])
    let chief = app.buttons["chat-Chief"].firstMatch
    XCTAssertTrue(chief.waitForExistence(timeout: 8))
    chief.click()
    app.buttons["profile"].click()
    app.buttons["New routine"].click()
    let name = app.textFields["routine-name"]
    let instructions = element(app, "routine-prompt")
    let create = app.buttons["Create routine"]
    XCTAssertTrue(name.waitForExistence(timeout: 5))
    XCTAssertTrue(instructions.isHittable)
    XCTAssertTrue(create.isHittable)
    XCTAssertFalse(create.isEnabled)
    capture(app, "New routine in dark mode")
    name.click()
    app.typeText("Daily briefing")
    app.typeKey(.tab, modifierFlags: [])
    let prompt =
      String(repeating: "Summarize the upcoming meetings and identify what to prepare. ", count: 5)
      + "End of brief."
    app.typeText(prompt)
    XCTAssertTrue(create.isEnabled)
    XCTAssertTrue(create.isHittable)
    create.click()
    let routine = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Daily briefing"))
      .firstMatch
    XCTAssertTrue(routine.waitForExistence(timeout: 5))
    XCTAssertTrue(routine.label.contains("Paused"))
    XCTAssertTrue(routine.label.contains(prompt))
  }

  func testSettingsAndConnectionsUseDesktopCommands() throws {
    let app = launch()
    XCTAssertTrue(app.buttons["chat-Chief"].firstMatch.waitForExistence(timeout: 8))
    app.typeKey(",", modifierFlags: .command)
    let settings = app.windows["Settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    XCTAssertTrue(settings.buttons["Connect a server"].exists)
    app.typeKey("0", modifierFlags: .command)
    XCTAssertTrue(app.windows["workspace"].isHittable)
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(app.textFields["command-query"].waitForExistence(timeout: 5))
    app.typeText("Connect apps")
    app.typeKey(.return, modifierFlags: [])
    let done = app.windows["workspace"].sheets.firstMatch.buttons["Close marketplace"]
    XCTAssertTrue(done.waitForExistence(timeout: 5))
    done.click()
    XCTAssertTrue(app.buttons["chat-Chief"].firstMatch.isHittable)
  }

  func testMarketplaceQuickConnectWithoutOpeningDetails() throws {
    let app = launch()
    XCTAssertTrue(app.buttons["chat-Chief"].firstMatch.waitForExistence(timeout: 8))
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(app.textFields["command-query"].waitForExistence(timeout: 5))
    app.typeText("Connect apps"); app.typeKey(.return, modifierFlags: [])
    let connect = app.buttons["market-action-app:sample-apps/slack"].firstMatch
    let cardQuery = app.buttons.matching(identifier: "market-card-app:sample-apps/slack")
    let card = cardQuery.firstMatch
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    card.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.79)).click()
    let back = app.buttons["Discover"].firstMatch
    XCTAssertTrue(app.staticTexts["What your bot can do"].waitForExistence(timeout: 5))
    back.click()
    XCTAssertTrue(connect.waitForExistence(timeout: 5)); connect.click()
    let approve = app.buttons["Approve sample"].firstMatch
    XCTAssertTrue(approve.waitForExistence(timeout: 5)); app.buttons["Cancel"].firstMatch.click()
    XCTAssertTrue(connect.waitForExistence(timeout: 5)); connect.click()
    XCTAssertTrue(approve.waitForExistence(timeout: 5)); approve.click()
    let confirmed = NSPredicate(format: "value CONTAINS %@", "Connected · Slack")
    XCTAssertTrue(cardQuery.matching(confirmed).firstMatch.waitForExistence(timeout: 5))
    XCTAssertFalse(connect.exists)
    card.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.83)).click()
    XCTAssertTrue(app.buttons["Manage Slack"].firstMatch.waitForExistence(timeout: 5)); back.click()
    app.buttons["My integrations"].firstMatch.click()
    XCTAssertTrue(app.staticTexts["App accounts  3"].waitForExistence(timeout: 5))
  }

  func testNativeDividerAndInspectorInWideWindow() throws {
    let app = launch(arguments: ["-appearance", "Light"])
    let window = app.windows["workspace"]
    let chief = app.buttons["chat-Chief"].firstMatch
    XCTAssertTrue(chief.waitForExistence(timeout: 8))
    chief.click()
    let origin = window.coordinate(withNormalizedOffset: .zero)
    let corner = origin.withOffset(
      CGVector(dx: window.frame.width - 2, dy: window.frame.height - 2))
    let growBy = max(0, 1230 - window.frame.width)
    if growBy > 0 {
      corner.click(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: growBy, dy: 0)))
    }
    XCTAssertGreaterThanOrEqual(window.frame.width, 1180)
    defer {
      if growBy > 0 {
        let end = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(
          CGVector(dx: -2, dy: -2))
        end.click(forDuration: 0.2, thenDragTo: end.withOffset(CGVector(dx: -growBy, dy: 0)))
      }
    }
    let start = chief.frame.maxX
    let divider = try XCTUnwrap(
      window.splitters.allElementsBoundByIndex.min {
        abs($0.frame.midX - start) < abs($1.frame.midX - start)
      })
    XCTAssertLessThan(abs(divider.frame.midX - start), 55)
    let grip = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    let offset: CGFloat = chief.frame.width > 280 ? -40 : 40
    grip.click(forDuration: 0.2, thenDragTo: grip.withOffset(CGVector(dx: offset, dy: 0)))
    XCTAssertEqual(chief.frame.maxX - start, offset, accuracy: 8)
    let newGrip = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    newGrip.click(forDuration: 0.2, thenDragTo: newGrip.withOffset(CGVector(dx: -offset, dy: 0)))
    app.buttons["profile"].click()
    XCTAssertTrue(app.buttons["New routine"].waitForExistence(timeout: 5))
    XCTAssertFalse(window.sheets.firstMatch.exists)
    XCTAssertTrue(element(app, "composer").isHittable)
    capture(app, "Mac workspace and inspector")
    app.buttons["Close profile"].click()
  }

  func testServerSignInAndWorkerReply() throws {
    let environment = ProcessInfo.processInfo.environment
    guard
      let origin = environment["RAKAZO_TEST_ORIGIN"]
        ?? environment["TEST_RUNNER_RAKAZO_TEST_ORIGIN"]
    else {
      throw XCTSkip("Run with Tools/with-upstream.sh for the disposable server.")
    }
    XCTAssertTrue(origin.hasPrefix("http://127.0.0.1:"))
    let password = try XCTUnwrap(
      environment["RAKAZO_TEST_PASSWORD"] ?? environment["TEST_RUNNER_RAKAZO_TEST_PASSWORD"])
    let app = launch("--test-login")
    let server = app.textFields["server"]
    XCTAssertTrue(server.waitForExistence(timeout: 8))
    server.click()
    server.typeText(origin)
    let email = app.textFields["email"]
    email.click()
    email.typeText("native@example.test")
    let credential = app.secureTextFields["password"]
    credential.click()
    credential.typeText(password)
    app.buttons["signin"].click()
    let temporary = app.buttons["Continue for this session"]
    if temporary.waitForExistence(timeout: 4) { temporary.click() }
    app.typeKey("n", modifierFlags: .command)
    let name = app.textFields["newName"]
    XCTAssertTrue(name.waitForExistence(timeout: 8))
    name.click()
    name.typeText("Mac QA")
    app.buttons["createSubmit"].click()
    let composer = element(app, "composer")
    XCTAssertTrue(composer.waitForExistence(timeout: 10))
    composer.click()
    let message = "Hello from the Mac workspace"
    app.typeText(message)
    app.buttons["send"].click()
    let consent = app.buttons["allowConsent"]
    if consent.waitForExistence(timeout: 3) { consent.click() }
    XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 10))
    let reply = app.staticTexts.containing(
      NSPredicate(
        format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@", "i handled: " + message,
        "i handled: " + message)
    ).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 25))
  }
}
