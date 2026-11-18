import XCTest

final class WorkspaceTests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }

  func testPrivateSpaceCancelCreateAndSelectTools() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--test-sample"]
    app.launch()
    let create = app.descendants(matching: .any).matching(identifier: "create").firstMatch
    XCTAssertTrue(create.waitForExistence(timeout: 12))
    func newSpace() {
      create.tap(); app.buttons["New private space"].firstMatch.tap()
    }
    newSpace()
    let field = app.textFields["newName"], submit = app.buttons["createSubmit"]
    XCTAssertTrue(field.waitForExistence(timeout: 5)); XCTAssertFalse(submit.isEnabled)
    app.buttons["Cancel"].tap(); XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    newSpace(); field.tap(); field.typeText("Studio QA"); submit.tap()
    let skill = app.buttons["space-tool-skill-sample-release-notes"].firstMatch
    let server = app.buttons["space-tool-mcpServer-linear.app"].firstMatch
    XCTAssertTrue(skill.waitForExistence(timeout: 5)); XCTAssertTrue(skill.isSelected)
    XCTAssertFalse(server.isSelected); server.tap(); XCTAssertTrue(server.isSelected)
    app.buttons["spaceContinue"].tap()
    XCTAssertTrue(app.buttons["Studio QA, switch workspace"].waitForExistence(timeout: 8))
  }

  func testCommandKFromComposerPreservesDraftAndNavigates() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--test-sample"]
    app.launch()
    let chief = app.buttons["chat-Chief"]
    XCTAssertTrue(chief.waitForExistence(timeout: 8))
    chief.tap()
    let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
    composer.tap()
    composer.typeText("Keep my draft")
    app.typeKey("k", modifierFlags: .command)
    let field = app.textFields["command-query"]
    XCTAssertTrue(
      field.waitForExistence(timeout: 5),
      "Command-K must open its own modal, not the sidebar filter")
    app.typeText("NoSuchChat")
    XCTAssertEqual(field.value as? String, "NoSuchChat")
    app.buttons["close-command-menu"].tap()
    XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    XCTAssertEqual(composer.value as? String, "Keep my draft")
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    app.typeText("Scout")
    app.buttons["command-chat/sample-scout"].tap()
    XCTAssertTrue(field.waitForNonExistence(timeout: 5))
    let profile = app.buttons["profile"]
    XCTAssertTrue(profile.waitForExistence(timeout: 5))
    XCTAssertTrue(profile.label.contains("Scout"), profile.label)
    app.typeKey("k", modifierFlags: .command)
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    app.typeText("Connect apps")
    app.buttons["command-panel/Connect apps"].tap()
    XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
  }

  func testSampleConnectionsAndServerAccess() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--test-sample"]
    app.launch()
    app.buttons["Connect apps"].tap()
    let mail = app.buttons["connection-sample-mail"]
    XCTAssertTrue(mail.waitForExistence(timeout: 7))
    capture(app, "Populated apps")
    mail.tap()
    XCTAssertTrue(app.staticTexts["GMAIL_FETCH_EMAILS"].waitForExistence(timeout: 5))
    app.buttons["Close"].tap()
    let calendar = app.buttons["connect-googlecalendar"]
    XCTAssertTrue(calendar.waitForExistence(timeout: 5))
    calendar.tap()
    XCTAssertTrue(
      app.staticTexts["Sample authorization. No account is contacted."].waitForExistence(timeout: 5)
    )
    app.navigationBars.buttons["Connect"].tap()
    XCTAssertTrue(calendar.waitForNonExistence(timeout: 5))
    app.buttons["MCP servers"].tap()
    let linear = app.buttons["mcp-linear.app"]
    XCTAssertTrue(linear.waitForExistence(timeout: 5))
    capture(app, "MCP server states")
    linear.tap()
    let scope = app.switches["Scout"]
    enableSwitch(scope)
    app.buttons["Save"].tap()
    linear.tap()
    XCTAssertTrue(scope.waitForExistence(timeout: 5))
    XCTAssertEqual(scope.value as? String, "1")
  }

  func testSampleComputerTakeoverAndHostConsent() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--test-sample"]
    app.launch()
    app.buttons["chat-Computer walkthrough"].tap()
    let review = app.buttons["review-bot-screen"]
    XCTAssertTrue(review.waitForExistence(timeout: 8))
    review.tap()
    let check = app.switches["sample-checklist"]
    XCTAssertTrue(check.waitForExistence(timeout: 5))
    XCTAssertFalse(check.isEnabled)
    capture(app, "Watch only")
    app.buttons["Take control"].tap()
    XCTAssertTrue(check.isEnabled)
    check.tap()
    capture(app, "In control")
    app.buttons["finish-screen-review"].tap()
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "marked reviewed"))
        .firstMatch.waitForExistence(timeout: 5))
    app.buttons["Review computer access…"].tap()
    app.buttons["Use this Mac…"].tap()
    let allow = app.buttons["Allow simulated access"]
    XCTAssertFalse(allow.isEnabled)
    enableSwitch(app.switches["Accessibility"])
    XCTAssertFalse(allow.isEnabled)
    enableSwitch(app.switches["Screen Recording"])
    XCTAssertTrue(allow.isEnabled)
    capture(app, "Simulated permission review")
    allow.tap()
    app.buttons["Allow sample read"].tap()
    XCTAssertTrue(
      app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Read Sample Notes"))
        .firstMatch.waitForExistence(timeout: 5))
  }

  func testSampleConnectionRequestsFromChat() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--test-sample"]
    app.launch()
    app.buttons["chat-Integrations walkthrough"].tap()
    let connect = app.buttons["Review connection…"]
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    connect.tap()
    app.navigationBars.buttons["Cancel"].tap()
    XCTAssertTrue(connect.waitForExistence(timeout: 5))
    connect.tap()
    app.navigationBars.buttons["Connect"].tap()
    XCTAssertTrue(connect.waitForNonExistence(timeout: 5))
    let access = app.buttons["Review agent access…"]
    access.tap()
    app.buttons["Allow access"].tap()
    XCTAssertTrue(access.waitForNonExistence(timeout: 5))
    XCTAssertEqual(
      app.staticTexts.matching(NSPredicate(format: "label == %@", "Connected")).count, 2)
  }

  private func enableSwitch(
    _ control: XCUIElement, file: StaticString = #filePath, line: UInt = #line
  ) {
    XCTAssertTrue(control.waitForExistence(timeout: 5), file: file, line: line)
    XCTAssertEqual(control.value as? String, "0", file: file, line: line)
    control.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5))
      .withOffset(CGVector(dx: -min(24, control.frame.width / 2), dy: 0)).tap()
    let changed = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == '1'"), object: control)
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 4), .completed, file: file, line: line)
  }

  func testMessageReactionsAndAgentAnswer() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--test-sample"]
    app.launch()
    let walkthrough = app.buttons["chat-Agent walkthrough"]
    XCTAssertTrue(walkthrough.waitForExistence(timeout: 10))
    walkthrough.tap()
    let answer =
      app.textFields["Your answer"].exists
      ? app.textFields["Your answer"] : app.textViews["Your answer"]
    XCTAssertTrue(answer.waitForExistence(timeout: 5))
    answer.tap()
    answer.typeText("Start with the references")
    app.buttons["Send answer"].tap()
    XCTAssertTrue(app.staticTexts["Start with the references"].waitForExistence(timeout: 5))
    let react = app.buttons.matching(identifier: "React").allElementsBoundByIndex.last!
    react.tap()
    let heart = app.buttons["❤️"]
    XCTAssertTrue(heart.waitForExistence(timeout: 5))
    heart.tap()
    let badge = app.buttons["❤️, 1 reactions"]
    XCTAssertTrue(badge.waitForExistence(timeout: 5))
    badge.tap()
    XCTAssertTrue(app.buttons["❤️, 2 reactions"].waitForExistence(timeout: 5))
  }

  func testSampleChatSearchAndProfile() throws {
    let app = XCUIApplication()
    app.launchArguments = ["--test-sample"]
    app.launch()
    let chief = app.buttons["chat-Chief"]
    XCTAssertTrue(chief.waitForExistence(timeout: 12))
    capture(app, "Inbox")
    chief.tap()
    let profile = app.buttons["profile"]
    XCTAssertTrue(profile.waitForExistence(timeout: 5))
    capture(app, "Conversation")
    profile.tap()
    XCTAssertTrue(app.staticTexts["No routines yet"].waitForExistence(timeout: 5))
    capture(app, "Profile")
    app.buttons["Close profile"].tap()
    let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
    composer.tap()
    composer.typeText("First native sample message")
    app.buttons["send"].tap()
    XCTAssertTrue(app.staticTexts["First native sample message"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts.containing(
        NSPredicate(format: "label BEGINSWITH %@", "Saved in this sample workspace")
      ).firstMatch.exists)
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.buttons["Search"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    capture(app, "Search")
    search.tap()
    search.typeText("Scout")
    app.buttons["search-result-Scout"].tap()
    XCTAssertTrue(profile.waitForExistence(timeout: 5))
    XCTAssertTrue(profile.label.contains("Scout"))
  }

  func testProfileSheetFitsTabAndPinsRoutineAction() throws {
    let isTablet = UIDevice.current.userInterfaceIdiom == .pad
    let previousOrientation = XCUIDevice.shared.orientation
    if isTablet { XCUIDevice.shared.orientation = .portrait }
    defer { if isTablet { XCUIDevice.shared.orientation = previousOrientation } }
    let app = XCUIApplication()
    app.launchArguments = ["--test-sample"]
    app.launch()
    try XCTSkipIf(app.frame.width >= 1180, "A wide workspace uses the inline inspector.")
    app.buttons["chat-Chief"].tap()
    app.buttons["profile"].tap()

    let close = app.buttons["Close profile"]
    let action = app.buttons["New routine"]
    let sections = app.scrollViews["profile-sections"]
    XCTAssertTrue(app.staticTexts["No routines yet"].waitForExistence(timeout: 5))
    XCTAssertTrue(action.isHittable)
    XCTAssertTrue(sections.exists)
    XCTAssertGreaterThanOrEqual(action.frame.minY, sections.frame.maxY - 1)
    let routineTop = close.frame.minY

    app.buttons["Pages"].tap()
    XCTAssertTrue(app.staticTexts["No pages yet"].waitForExistence(timeout: 5))
    let shrank = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in close.frame.minY > routineTop + 8 }, object: nil)
    XCTAssertEqual(
      XCTWaiter.wait(for: [shrank], timeout: 5), .completed,
      "Close button top: Routines \(routineTop), Pages \(close.frame.minY)")

    app.buttons["Routines"].tap()
    XCTAssertTrue(action.isHittable)
    action.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.textFields["Name"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
    XCTAssertTrue(action.waitForExistence(timeout: 5))
  }

  func testUpstreamSignInCreateSendAndRestore() throws {
    let env = ProcessInfo.processInfo.environment
    guard let origin = env["RAKAZO_TEST_ORIGIN"] ?? env["TEST_RUNNER_RAKAZO_TEST_ORIGIN"] else {
      throw XCTSkip("Run with Tools/with-upstream.sh for the live integration test.")
    }
    guard origin.hasPrefix("http://127.0.0.1:") else {
      XCTFail("This integration test only accepts a local throwaway server.")
      return
    }
    let password = try XCTUnwrap(
      env["RAKAZO_TEST_PASSWORD"] ?? env["TEST_RUNNER_RAKAZO_TEST_PASSWORD"])
    let app = XCUIApplication()
    app.launchArguments = ["--test-login"]
    app.launch()
    let server = app.textFields["server"]
    XCTAssertTrue(server.waitForExistence(timeout: 8))
    server.tap()
    server.typeText(origin)
    app.textFields["email"].tap()
    app.textFields["email"].typeText("native@example.test")
    app.secureTextFields["password"].tap()
    app.secureTextFields["password"].typeText(password)
    app.buttons["signin"].tap()
    let create = app.descendants(matching: .any).matching(identifier: "create").firstMatch
    XCTAssertTrue(create.waitForExistence(timeout: 15))
    create.tap()
    app.buttons["New bot"].firstMatch.tap()
    let name = "Release QA"
    let field = app.textFields["newName"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText(name)
    app.buttons["createSubmit"].tap()
    let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
    XCTAssertTrue(composer.waitForExistence(timeout: 12))
    composer.tap()
    let message = "Hello from the native client"
    composer.typeText(message)
    app.buttons["send"].tap()
    let allow = app.buttons["allowConsent"]
    if allow.waitForExistence(timeout: 3) { allow.tap() }
    XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 12))
    let reply = app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS[c] %@", "i handled: " + message)
    ).firstMatch
    XCTAssertTrue(
      reply.waitForExistence(timeout: 25),
      "A server-side reply should appear without pulling to refresh.")
    app.terminate()
    app.launchArguments = ["--test-restore"]
    app.launch()
    let row = app.buttons["chat-" + name]
    XCTAssertTrue(row.waitForExistence(timeout: 12))
    row.tap()
    XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 10))
    capture(app, "Upstream message after relaunch")
    app.navigationBars.buttons.element(boundBy: 0).tap()
    app.buttons["Search"].tap()
    let query = app.searchFields.firstMatch
    query.tap()
    query.typeText("Hello from the native client")
    let match = app.buttons.matching(identifier: "message-hit-" + name).firstMatch
    XCTAssertTrue(match.waitForExistence(timeout: 10))
    match.tap()
    let back = app.buttons["Return to latest messages"]
    XCTAssertTrue(back.waitForExistence(timeout: 8))
    XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 8))
    back.tap()
    XCTAssertTrue(app.buttons["profile"].exists)
  }

  func testAccessibleReadingSize() throws {
    let app = XCUIApplication()
    app.launchArguments = [
      "--test-sample", "-UIPreferredContentSizeCategoryName",
      "UICTContentSizeCategoryAccessibilityXXXL", "-appearance", "Dark",
    ]
    app.launch()
    app.buttons["chat-Chief"].tap()
    XCTAssertTrue(app.buttons["profile"].waitForExistence(timeout: 5))
    capture(app, "Large type conversation")
    app.buttons["profile"].tap()
    XCTAssertTrue(app.buttons["Close profile"].waitForExistence(timeout: 5))
    let newRoutine = app.buttons["New routine"]
    XCTAssertTrue(newRoutine.isHittable)
    newRoutine.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
    app.buttons["Cancel"].tap()
    app.buttons["Close profile"].tap()
    XCTAssertTrue(app.buttons["send"].exists)
  }

  func capture(_ app: XCUIApplication, _ name: String) {
    let image = XCTAttachment(screenshot: app.screenshot())
    image.name = name
    image.lifetime = .keepAlways
    add(image)
  }
}

final class TabletTests: XCTestCase {
  func testLandscapeSidebarAndInspector() throws {
    guard UIDevice.current.userInterfaceIdiom == .pad else {
      throw XCTSkip("Requires an iPad simulator.")
    }
    let original = XCUIDevice.shared.orientation
    defer { XCUIDevice.shared.orientation = original }
    XCUIDevice.shared.orientation = .landscapeLeft
    let app = XCUIApplication()
    app.launchArguments = ["--test-sample"]
    app.launch()
    let row = app.buttons["chat-Scout"]
    XCTAssertTrue(row.waitForExistence(timeout: 12))
    XCTAssertTrue(app.staticTexts["Choose a conversation"].exists)
    let chief = app.buttons["chat-Chief"]
    chief.tap()
    let composer = app.descendants(matching: .any).matching(identifier: "composer").firstMatch
    XCTAssertGreaterThan(composer.frame.minX, chief.frame.maxX)
    let divider = app.descendants(matching: .any).matching(identifier: "sidebarWidth").firstMatch
    let start = divider.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
    let beforeResize = chief.frame.maxX
    let resizeBy: CGFloat = beforeResize > 355 ? -64 : 64
    start.press(forDuration: 0.25, thenDragTo: start.withOffset(CGVector(dx: resizeBy, dy: 0)))
    XCTAssertEqual(chief.frame.maxX - beforeResize, resizeBy, accuracy: 12)
    XCTAssertGreaterThan(composer.frame.minX, chief.frame.maxX)
    composer.tap()
    composer.typeText("An unsent draft")
    app.buttons["Hide chats"].tap()
    XCTAssertFalse(chief.exists)
    XCTAssertEqual(composer.value as? String, "An unsent draft")
    app.buttons["Show chats"].tap()
    XCTAssertTrue(chief.waitForExistence(timeout: 5))
    app.buttons["chatFilter"].tap()
    app.buttons["Unread"].tap()
    XCTAssertFalse(chief.exists)
    row.tap()
    let profile = app.buttons["profile"]
    XCTAssertTrue(profile.label.contains("Scout"))
    app.buttons["chatFilter"].tap()
    app.buttons["All conversations"].tap()
    app.buttons["Search"].tap()
    let search = app.textFields["sidebarQuery"]
    XCTAssertTrue(search.waitForExistence(timeout: 5))
    search.tap()
    search.typeText("Chief")
    XCTAssertTrue(profile.exists, "Sidebar search must leave the open conversation on screen.")
    app.buttons["search-result-Chief"].tap()
    XCTAssertEqual(composer.value as? String, "An unsent draft")
    XCTAssertTrue(chief.isSelected)
    row.tap()
    profile.tap()
    XCTAssertTrue(app.staticTexts["No routines yet"].waitForExistence(timeout: 8))
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = "iPad workspace and inspector"
    attachment.lifetime = .keepAlways
    add(attachment)
    app.buttons["Close profile"].tap()
    XCTAssertTrue(app.buttons["send"].exists)
  }
}
