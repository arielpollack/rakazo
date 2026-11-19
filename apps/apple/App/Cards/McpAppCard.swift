import SwiftUI
import WebKit

#if os(iOS)
  import UIKit.UIGestureRecognizerSubclass
#endif

/// An MCP server's app for one tool call, as the mobile app shows it: the shared shell runs it in
/// an opaque-origin frame inside a web view with no cookies, storage or navigation, reaching only
/// the domains it declared that this app allows. A link or a message for the composer needs a tap
/// (a click on the Mac) on the card first, which the page inside cannot fake; tool calls are
/// refused.
struct McpAppCard: View {
  let block: Message.Block
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void
  @Environment(\.colorScheme) private var scheme
  @Environment(\.openURL) private var openURL
  @State private var shell: String?
  @State private var failed = false
  @State private var started = false
  @State private var height: CGFloat = 0
  /// A link the app asked to open, waiting for the person to confirm it.
  @State private var link: URL?

  private static let minHeight: CGFloat = 80
  private static let maxHeight: CGFloat = 560
  /// An app that has not started by then is not shown; the bot's reply stands without it.
  private static let startTimeout: Duration = .seconds(15)
  /// App documents already read this session; an artifact never changes.
  private static let documents: NSCache<NSString, NSString> = {
    let cache = NSCache<NSString, NSString>()
    cache.totalCostLimit = 16 * McpApp.htmlMaxBytes
    return cache
  }()

  var body: some View {
    if let fields = block.fields(AppFields.self), !failed {
      let bordered = fields.prefersBorder != false
      let shape = RoundedRectangle(cornerRadius: 20)
      VStack(alignment: .leading, spacing: 6) {
        // 12 points on iOS, as the mobile card's server name.
        Text(verbatim: fields.server).font(TypeRole.timestamp).foregroundStyle(.secondary)
          .lineLimit(1).padding(.horizontal, 4)
        ZStack {
          if let shell {
            McpAppFrame(
              shell: shell, radius: bordered ? 19 : 20,
              input: fields.toolArguments.mapValues(\.foundation),
              result: fields.toolResult.mapValues(\.foundation), csp: csp(fields).json,
              theme: scheme == .dark ? "dark" : "light",
              locale: Bundle.main.preferredLocalizations.first ?? "en",
              started: { started = true },
              resized: { height = min(max(ceil($0), Self.minHeight), Self.maxHeight) },
              openLink: open,
              offer: { ComposerOffer.post($0, to: store.draftKey(chat)) })
          }
        }
        .padding(bordered ? 1 : 0)
        .frame(maxWidth: .infinity)
        .frame(height: started && height > 0 ? height : Self.minHeight * 2)
        .background {
          if bordered { shape.fill(Ink.fill) }
        }
        .clipShape(shape)
        .overlay {
          if bordered { shape.strokeBorder(Ink.line, lineWidth: 1) }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityIdentifier("mcp-app")
      .task(id: fields.artifactId) { await load(fields) }
      .task(id: shell != nil && !started) { await expire() }
      .alert(
        "Open external link?",
        isPresented: Binding(get: { link != nil }, set: { if !$0 { link = nil } }),
        presenting: link
      ) { url in
        Button("Cancel", role: .cancel) {}
        Button("Open") { openURL(url) }
      } message: { url in
        // Keep the actual host visible even when userinfo or the path is very long.
        Text(verbatim: "\(Self.host(url))\n\n\(url.absoluteString)")
      }
      .allowsQuitFromDialog()
    }
  }

  /// The domains the app declared, less any this host refuses, including the app's own server.
  private func csp(_ fields: AppFields) -> McpApp.Csp {
    McpApp.csp(fields.csp, excluding: [store.login?.server.host].compactMap { $0 })
  }

  /// Reads the app's document; without a server (the demo) the card stays as it is before load.
  private func load(_ fields: AppFields) async {
    guard shell == nil, let api = store.client else { return }
    let key = "\(store.id)/\(chat.id)/\(fields.artifactId)" as NSString
    do {
      let html: String
      if let cached = Self.documents.object(forKey: key) {
        html = cached as String
      } else {
        let bytes = try await api.file(fields.artifactId, chat: chat, limit: McpApp.htmlMaxBytes)
        html = String(decoding: bytes, as: UTF8.self)
        Self.documents.setObject(html as NSString, forKey: key, cost: bytes.count)
      }
      guard let document = McpApp.shellDocument(McpApp.document(html, csp: csp(fields))) else {
        failed = true
        return
      }
      shell = document
    } catch {
      if !Task.isCancelled { failed = true }
    }
  }

  private func expire() async {
    guard shell != nil, !started else { return }
    try? await Task.sleep(for: Self.startTimeout)
    if !Task.isCancelled, !started { failed = true }
  }

  /// Opens a link the way a chat link opens: through the prompt unless it stays on this server.
  private func open(_ url: URL) {
    if Self.leavesApp(url, server: store.login?.server) { link = url } else { openURL(url) }
  }

  private static func leavesApp(_ url: URL, server: URL?) -> Bool {
    guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
      return false
    }
    guard let server else { return true }
    return origin(url) != origin(server)
  }

  private static func origin(_ url: URL) -> String {
    "\(url.scheme?.lowercased() ?? "")://\(host(url))"
  }

  /// The host and any port that is not the scheme's own, as a browser's `URL.host`.
  private static func host(_ url: URL) -> String {
    let scheme = url.scheme?.lowercased()
    let port = url.port.flatMap {
      ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? nil : $0
    }
    return (url.host?.lowercased() ?? "") + (port.map { ":\($0)" } ?? "")
  }
}

/// The block's fields, as the server sends an app card.
private struct AppFields: Decodable {
  let artifactId: String
  let server: String
  let toolArguments: [String: JSONValue]
  let toolResult: [String: JSONValue]
  let csp: JSONValue?
  let prefersBorder: Bool?
}

/// Text a card in a chat hands to that chat's composer; the person still sends it. The chat's
/// conversation listens for `notification` and adds the text to its draft with `adding(_:to:)`.
enum ComposerOffer {
  static let notification = Notification.Name("ComposerOffer")

  /// `draftKey` is the chat's `WorkspaceStore.draftKey`.
  static func post(_ text: String, to draftKey: String) {
    NotificationCenter.default.post(
      name: notification, object: nil, userInfo: ["draftKey": draftKey, "text": text])
  }

  /// The draft with the text after it on the same line, as the mobile composer adds a reply; a
  /// draft of only blank space is replaced.
  static func adding(_ text: String, to draft: String) -> String {
    guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
    var end = draft.endIndex
    while end > draft.startIndex, draft[draft.index(before: end)].isWhitespace {
      end = draft.index(before: end)
    }
    return String(draft[..<end]) + " " + text
  }
}

/// The web view the app's shell runs in, and the host session that answers it.
private struct McpAppFrame {
  let shell: String
  let radius: CGFloat
  let input: [String: Any]
  let result: [String: Any]
  let csp: [String: Any]
  let theme: String
  let locale: String
  let started: () -> Void
  let resized: (Double) -> Void
  let openLink: (URL) -> Void
  let offer: (String) -> Void

  /// How long after a tap on the page it may still open a link or offer text, as a browser's
  /// activation.
  static let actionWindow: TimeInterval = 1
  /// Points a finger may drift and still tap; further is a scroll or a drag.
  static let tapSlop: CGFloat = 10

  static func isTap(_ start: CGPoint, _ end: CGPoint) -> Bool {
    hypot(end.x - start.x, end.y - start.y) <= tapSlop
  }

  var hostContext: [String: Any] {
    #if os(macOS)
      let platform = "desktop"
      let touch = false
    #else
      let platform = "mobile"
      let touch = true
    #endif
    return [
      "theme": theme,
      "displayMode": "inline",
      "availableDisplayModes": ["inline"],
      "containerDimensions": ["maxHeight": 560],
      "locale": locale,
      "timeZone": TimeZone.current.identifier,
      "platform": platform,
      "deviceCapabilities": ["touch": touch, "hover": !touch],
    ]
  }

  @MainActor func makeCoordinator() -> Coordinator { Coordinator() }

  @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// The name the shared shell posts through on phones; this web view provides it.
    private static let bridge =
      "window.ReactNativeWebView = { postMessage: (data) => "
      + "window.webkit.messageHandlers.rakazoApp.postMessage(String(data)) };"
    private static let handler = "rakazoApp"
    /// A view's message is at most 64,000 characters; this leaves room for the shell's envelope.
    private static let envelopeMaxLength = 64_256
    /// The shell's own document and its app's srcdoc frame; nothing else may load.
    private static let documents: Set<String> = ["about:blank", "about:blank/", "about:srcdoc"]

    private var frame: McpAppFrame?
    private var host: McpAppHost?
    private weak var webView: WKWebView?
    private var theme = ""
    private var locale = ""
    /// When the person last tapped the page, on the system's uptime clock.
    private var tappedAt: TimeInterval?
    #if os(macOS)
      private var monitor: Any?
      private var pressedAt: CGPoint?
    #endif

    func make(_ frame: McpAppFrame) -> WKWebView {
      self.frame = frame
      theme = frame.theme
      locale = frame.locale
      let configuration = WKWebViewConfiguration()
      // Nothing the page stores outlives it, and it shares no cookies with the app's session.
      configuration.websiteDataStore = .nonPersistent()
      configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
      configuration.mediaTypesRequiringUserActionForPlayback = .all
      configuration.userContentController.addUserScript(
        WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
      configuration.userContentController.add(self, name: Self.handler)
      #if os(macOS)
        let view = AppWebView(frame: .zero, configuration: configuration)
        if ["setDrawsBackground:", "_setDrawsBackground:"].contains(where: {
          view.responds(to: NSSelectorFromString($0))
        }) {
          view.setValue(false, forKey: "drawsBackground")
        }
        view.underPageBackgroundColor = .clear
        view.wantsLayer = true
        view.layer?.cornerRadius = frame.radius
        view.layer?.masksToBounds = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) {
          [weak self] event in
          self?.watch(event)
          return event
        }
      #else
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.layer.cornerRadius = frame.radius
        view.layer.masksToBounds = true
        view.addGestureRecognizer(TapWatch { [weak self] in self?.tapped() })
      #endif
      // A long-pressed link's preview would load it outside the navigation check below.
      view.allowsLinkPreview = false
      view.navigationDelegate = self
      webView = view
      host = McpAppHost(
        .init(
          input: frame.input, result: frame.result, hostContext: frame.hostContext,
          csp: frame.csp,
          send: { [weak self] in self?.send($0) },
          allowAction: { [weak self] in self?.allowAction() ?? false },
          openLink: { [weak self] in self?.frame?.openLink($0) },
          offerMessage: { [weak self] in self?.frame?.offer($0) },
          onHeight: { [weak self] in self?.frame?.resized($0) }))
      view.loadHTMLString(frame.shell, baseURL: URL(string: "about:blank"))
      return view
    }

    /// A running view hears about later changes instead of restarting.
    func update(_ frame: McpAppFrame) {
      self.frame = frame
      guard frame.theme != theme || frame.locale != locale else { return }
      theme = frame.theme
      locale = frame.locale
      host?.updateContext(["theme": theme, "locale": locale])
    }

    func dismantle() {
      host?.teardown()
      host = nil
      webView?.configuration.userContentController.removeAllScriptMessageHandlers()
      webView?.navigationDelegate = nil
      #if os(macOS)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
      #endif
    }

    func userContentController(
      _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
      // Only the shell, the top document, speaks for the app; the app's own frame is one down.
      guard message.frameInfo.isMainFrame, message.webView === webView,
        let text = message.body as? String, text.utf16.count <= Self.envelopeMaxLength,
        let envelope = (try? JSONSerialization.jsonObject(with: Data(text.utf8)))
          as? [String: Any],
        envelope["type"] as? String == "rakazo-app:view"
      else { return }
      if (envelope["message"] as? [String: Any])?["method"] as? String == "ui/initialize" {
        frame?.started()
      }
      host?.receive(envelope["message"])
    }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
      let url = navigationAction.request.url?.absoluteString ?? ""
      decisionHandler(Self.documents.contains(url) ? .allow : .cancel)
    }

    private func send(_ message: [String: Any]) {
      let envelope: [String: Any] = ["type": "rakazo-app:host", "message": message]
      guard let webView, JSONSerialization.isValidJSONObject(envelope),
        let data = try? JSONSerialization.data(
          withJSONObject: envelope, options: [.withoutEscapingSlashes])
      else { return }
      // Passed as an argument, so nothing in the message can break out of the call.
      webView.callAsyncJavaScript(
        "window.postMessage(JSON.parse(envelope), \"*\")",
        arguments: ["envelope": String(decoding: data, as: UTF8.self)], in: nil, in: .page)
    }

    private func tapped() { tappedAt = ProcessInfo.processInfo.systemUptime }

    /// One tap, one action.
    private func allowAction() -> Bool {
      guard let tappedAt else { return false }
      let elapsed = ProcessInfo.processInfo.systemUptime - tappedAt
      guard elapsed >= 0, elapsed <= McpAppFrame.actionWindow else { return false }
      self.tappedAt = nil
      return true
    }

    #if os(macOS)
      /// A click that ends where it began on the page counts as a tap; the page still gets it.
      private func watch(_ event: NSEvent) {
        guard let webView, let window = webView.window, event.window === window,
          let content = window.contentView
        else { return }
        let point = event.locationInWindow
        let inside =
          content.hitTest(content.superview?.convert(point, from: nil) ?? point)?
          .isDescendant(of: webView) == true
        if event.type == .leftMouseDown {
          pressedAt = inside ? point : nil
        } else if let start = pressedAt {
          pressedAt = nil
          if inside, McpAppFrame.isTap(start, point) { tapped() }
        }
      }
    #endif
  }
}

#if os(macOS)
  extension McpAppFrame: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { context.coordinator.make(self) }
    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.update(self) }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
      coordinator.dismantle()
    }
  }

  /// The page does not scroll; the chat around it does, as the mobile web view with scrolling off.
  private final class AppWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
  }
#else
  extension McpAppFrame: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { context.coordinator.make(self) }
    func updateUIView(_ view: WKWebView, context: Context) { context.coordinator.update(self) }
    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
      coordinator.dismantle()
    }
  }

  /// Watches for a tap on the page without taking part in its gestures: one finger that lifts
  /// where it went down, as the mobile card counts a tap.
  private final class TapWatch: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let tapped: () -> Void
    private var start: CGPoint?

    init(tapped: @escaping () -> Void) {
      self.tapped = tapped
      super.init(target: nil, action: nil)
      cancelsTouchesInView = false
      delaysTouchesBegan = false
      delaysTouchesEnded = false
      delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
      super.touchesBegan(touches, with: event)
      start = event.allTouches?.count == 1 ? touches.first?.location(in: nil) : nil
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
      super.touchesMoved(touches, with: event)
      if let start, let point = touches.first?.location(in: nil),
        !McpAppFrame.isTap(start, point)
      {
        self.start = nil
      }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
      super.touchesEnded(touches, with: event)
      if let start, let point = touches.first?.location(in: nil), McpAppFrame.isTap(start, point) {
        tapped()
      }
      start = nil
      state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
      super.touchesCancelled(touches, with: event)
      start = nil
      state = .failed
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
  }
#endif
