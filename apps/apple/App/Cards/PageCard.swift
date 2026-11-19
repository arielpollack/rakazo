import SwiftUI
import WebKit

/// A page in the chat, as the mobile app draws it: its live top half and a footer naming it.
/// Opens the latest version.
struct PageCard: View {
  let block: Message.Block
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void
  /// The thread's newest card for each page, from `PageCard.newest`.
  let newest: [String: String]
  @State private var detail: PageState = .loading
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var phase

  init(
    block: Message.Block, message: Message, chat: Chat, store: WorkspaceStore,
    refresh: @escaping () async throws -> Void, report: @escaping (String) -> Void,
    newest: [String: String] = [:]
  ) {
    self.block = block
    self.message = message
    self.chat = chat
    self.store = store
    self.refresh = refresh
    self.report = report
    self.newest = newest
  }

  /// Each page's newest card in a thread, as `messageId:version`.
  static func newest(_ messages: [Message]) -> [String: String] {
    var newest: [String: String] = [:]
    for message in messages {
      for block in message.blocks where block.kind == "page" {
        let page = PageFields(block)
        newest[page.pageId] = "\(message.id):\(page.version)"
      }
    }
    return newest
  }

  private var page: PageFields { PageFields(block) }
  private var title: String {
    if case .ready(let detail) = detail { return detail.title }
    return page.title
  }
  private var deleted: Bool {
    if case .deleted = detail { return true }
    return false
  }
  /// A later card in the same thread shows this page. A newer version saved with no card here,
  /// such as a routine's refresh, does not count.
  private var updatedBelow: Bool {
    guard case .ready = detail, let latest = newest[page.pageId] else { return false }
    return latest != "\(message.id):\(page.version)"
  }
  private var destination: URL? {
    store.link(chat, query: [URLQueryItem(name: "page", value: page.pageId)])
  }

  var body: some View {
    Button {
      if let destination { openURL(destination) }
    } label: {
      VStack(spacing: 0) {
        if !deleted { PagePreview(state: detail, server: store.login?.server) }
        footer
      }.background(Ink.fill)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }.buttonStyle(PressedPage()).disabled(deleted || destination == nil)
      .frame(maxWidth: 576, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Open \(title)")
      .accessibilityAddTraits(.isButton)
      .task(id: "\(page.pageId):\(page.version)") { await load() }
      .onChange(of: phase) { _, now in
        if now == .active {
          PageReads.cameBack()
          Task { await load() }
        }
      }
  }

  private var footer: some View {
    HStack(spacing: 14.5) {
      PageIcon().offset(y: -3)
      VStack(alignment: .leading, spacing: 4) {
        Text(verbatim: title).font(CardType.body).foregroundStyle(.primary).lineLimit(1)
        Text(deleted ? "Deleted" : updatedBelow ? "Updated below" : "Page")
          .font(CardType.secondary).foregroundStyle(.secondary).lineLimit(1)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.padding(.leading, 15.5).padding(.trailing, 20).frame(minHeight: 72)
      .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.04)).frame(height: 1) }
  }

  /// The page from the cache unless a newer version is known or the app came back.
  private func load() async {
    guard let api = store.client else { return }
    do {
      let read = try await PageReads.latest(
        api, scope: store.id, pageId: page.pageId, atLeast: page.version)
      detail = .ready(read)
    } catch is CancellationError {
    } catch let failure as Failure where failure.code == "NOT_FOUND" {
      detail = .deleted
    } catch {
      detail = .failed
    }
  }
}

private struct PageFields: Decodable {
  let pageId: String
  let version: Int
  let title: String

  init(_ block: Message.Block) {
    self =
      block.fields(PageFields.self)
      ?? PageFields(pageId: block.pageId ?? "", version: 1, title: block.title ?? "")
  }
  init(pageId: String, version: Int, title: String) {
    self.pageId = pageId
    self.version = version
    self.title = title
  }
}

/// What `pages/get` returns that the card reads.
private struct PageDetail: Decodable {
  let title: String
  let code: String
  let currentVersion: Int
}

private enum PageState {
  case loading, failed, deleted
  case ready(PageDetail)
}

/// Page reads shared by every card, until the app comes back or a card knows a newer version.
@MainActor private enum PageReads {
  private static var reads: [String: (read: Task<PageDetail, Error>, at: Date)] = [:]
  private static var onScreen = Date.distantPast

  /// Every card hears the app come back at once; the first marks it for all of them.
  static func cameBack() {
    if Date.now.timeIntervalSince(onScreen) > 2 { onScreen = .now }
  }

  static func latest(_ api: Client, scope: UUID, pageId: String, atLeast version: Int)
    async throws -> PageDetail
  {
    let key = "\(scope.uuidString)|\(pageId)"
    if let cached = reads[key], cached.at >= onScreen, let page = try? await cached.read.value,
      page.currentVersion >= version
    {
      return page
    }
    let read = Task { () async throws -> PageDetail in
      try await api.rpc("pages/get", ["pageId": pageId])
    }
    reads[key] = (read, .now)
    do {
      return try await read.value
    } catch {
      if reads[key]?.read == read { reads[key] = nil }
      throw error
    }
  }
}

/// The page runtime from the user's own server; the page document inlines it because the
/// viewer's policy loads nothing. Each use asks again with the last copy's tag, so a page never
/// runs on a kit older than the server that checked it.
@MainActor private enum PageRuntime {
  private static var copies: [URL: (text: String, etag: String?)] = [:]
  private static var pending: [URL: Task<String, Error>] = [:]
  private static let transport: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.timeoutIntervalForRequest = 45
    return URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
  }()

  static func load(server: URL) async throws -> String {
    let url = server.appendingPathComponent("api/v1/assets/page-runtime.js")
    if let running = pending[url] { return try await running.value }
    let cached = copies[url]
    let running = Task { () async throws -> String in
      var request = URLRequest(url: url)
      if let etag = cached?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
      let (data, raw) = try await transport.data(for: request)
      guard let response = raw as? HTTPURLResponse else {
        throw Failure("The page runtime returned an invalid response.")
      }
      if response.statusCode == 304, let cached { return cached.text }
      guard (200..<300).contains(response.statusCode),
        let text = String(data: data, encoding: .utf8)
      else { throw Failure("Page runtime returned \(response.statusCode)") }
      copies[url] = (text, response.value(forHTTPHeaderField: "ETag"))
      return text
    }
    pending[url] = running
    defer { pending[url] = nil }
    return try await running.value
  }

  private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) { completionHandler(nil) }
  }
}

/// A page as one self-contained document for the sandboxed viewer: the runtime and a boot script
/// carrying the page's compiled code, under the same content policy as the web viewer.
private enum PageDocument {
  static let policy =
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; media-src data: blob:; font-src data:; form-action 'none'; base-uri 'none'"

  static func html(runtime: String, code: String, dark: Bool) -> String? {
    let boot: [String: Any] = [
      "code": code, "theme": dark ? "dark" : "light", "errorTitle": "This page couldn't be shown.",
      "lang": "en",
    ]
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: boot, options: .withoutEscapingSlashes),
      let json = String(data: data, encoding: .utf8)
    else { return nil }
    // No page text can close the script element.
    let safe = json.replacingOccurrences(of: "<", with: "\\u003c")
    #if os(iOS)
      let touch = " data-touch"
    #else
      let touch = ""
    #endif
    return "<!DOCTYPE html><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
      + "<html\(touch)><head><meta charset=\"utf-8\">"
      + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
      + "<script>\(runtime)</script></head>"
      + "<body><div id=\"root\"></div><script>RakazoPage.mount(\(safe))</script></body></html>"
  }
}

/// Pages draw at desktop width and shrink into the card, so a preview reads like the page.
private let previewScale: CGFloat = 0.6
private let previewAspect: CGFloat = 1200 / 630

/// The page's top, drawn live and scaled into the card. A page or viewer that could not load
/// says so in its place; the card still opens the page, which can try again.
private struct PagePreview: View {
  let state: PageState
  let server: URL?
  @Environment(\.colorScheme) private var scheme
  @State private var document: String?
  @State private var documentFailed = false
  @State private var shown = false

  private var detail: PageDetail? {
    if case .ready(let detail) = state { return detail }
    return nil
  }
  private var failed: Bool {
    if case .failed = state { return true }
    return false
  }
  /// A newer version keeps the older preview while it builds, but never past a failure.
  private var unavailable: Bool { failed || documentFailed }

  var body: some View {
    Color.clear.aspectRatio(previewAspect, contentMode: .fit)
      .overlay(alignment: .top) {
        if unavailable {
          Text("This page couldn't load").font(CardType.secondary).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
            .padding(.top, 40).padding(.horizontal, 20)
        } else if let document {
          PageFrame(html: document) { shown = true }.opacity(shown ? 1 : 0)
        }
      }
      .overlay(alignment: .bottom) {
        LinearGradient(
          colors: [Ink.fill.opacity(0), Ink.fill], startPoint: .top, endPoint: .bottom
        ).frame(height: 100)
      }
      .clipped().allowsHitTesting(false).accessibilityHidden(true)
      .task(id: Key(code: detail?.code, dark: scheme == .dark)) { await build() }
  }

  private struct Key: Equatable {
    let code: String?
    let dark: Bool
  }

  private func build() async {
    guard let detail, let server else { return }
    do {
      let runtime = try await PageRuntime.load(server: server)
      guard let html = PageDocument.html(runtime: runtime, code: detail.code, dark: scheme == .dark)
      else { throw Failure("This page couldn't be shown.") }
      document = html
      documentFailed = false
    } catch is CancellationError {
    } catch {
      document = nil
      documentFailed = true
    }
  }
}

/// Bot-authored HTML in a web view that cannot reach the app's session: a fresh, non-persistent
/// store with no cookies or storage, no new windows or link previews, and navigation limited to
/// the document itself. The content policy in the document blocks outbound requests.
private struct PageFrame {
  let html: String
  let loaded: () -> Void

  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    var html: String?
    var loaded: () -> Void
    init(loaded: @escaping () -> Void) { self.loaded = loaded }

    func webView(
      _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      let url = navigationAction.request.url?.absoluteString ?? ""
      decisionHandler(url == "about:blank" || url == "about:blank/" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded() }
    func webView(
      _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }
  }

  func makeCoordinator() -> Coordinator { Coordinator(loaded: loaded) }

  private func make(_ coordinator: Coordinator) -> PreviewWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    let view = PreviewWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = coordinator
    view.uiDelegate = coordinator
    view.allowsLinkPreview = false
    view.pageZoom = previewScale
    #if os(iOS)
      view.isUserInteractionEnabled = false
      view.isOpaque = false
      view.backgroundColor = .clear
      view.scrollView.backgroundColor = .clear
      view.scrollView.isScrollEnabled = false
      view.scrollView.contentInsetAdjustmentBehavior = .never
    #endif
    load(view, coordinator)
    return view
  }

  private func load(_ view: WKWebView, _ coordinator: Coordinator) {
    coordinator.loaded = loaded
    guard coordinator.html != html else { return }
    coordinator.html = html
    view.loadHTMLString(html, baseURL: nil)
  }
}

#if os(macOS)
  extension PageFrame: NSViewRepresentable {
    func makeNSView(context: Context) -> PreviewWebView { make(context.coordinator) }
    func updateNSView(_ view: PreviewWebView, context: Context) { load(view, context.coordinator) }
  }
#else
  extension PageFrame: UIViewRepresentable {
    func makeUIView(context: Context) -> PreviewWebView { make(context.coordinator) }
    func updateUIView(_ view: PreviewWebView, context: Context) { load(view, context.coordinator) }
  }
#endif

/// A preview only: clicks and scrolls pass through to the card and the chat.
private final class PreviewWebView: WKWebView {
  #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  #endif
}

private struct PressedPage: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.opacity(configuration.isPressed ? 0.85 : 1)
  }
}

/// The page icon in a 33 x 41 box: a sheet with a folded top-right corner, two lines and four
/// rising bars.
private struct PageIcon: View {
  private static let width: CGFloat = 33, height: CGFloat = 41, radius: CGFloat = 5.5
  private static let foldX: CGFloat = 20.5, foldY: CGFloat = 12, barWidth: CGFloat = 3.5
  private static let sheet = PlatformColor.pair(0xE8E8EA, 0x2C2C2E)
  private static let fold = PlatformColor.pair(0xD0D0D4, 0x3C3C3E)
  private static let lines: [(x: CGFloat, y: CGFloat, width: CGFloat, color: Color)] = [
    (5.5, 7.5, 12, PlatformColor.pair(0x8E8E93, 0x6F6F71)),
    (5.5, 14, 14.5, PlatformColor.pair(0xA1A1A6, 0x616163)),
  ]
  private static let bars: [(x: CGFloat, y: CGFloat, height: CGFloat, color: Color)] = [
    (5.5, 27.5, 7.5, Color(rgb: 0x489D61)), (11.5, 25.5, 9.5, Color(rgb: 0xE7712E)),
    (18, 22.5, 12, Color(rgb: 0xBC3B3D)), (24, 20, 15, Color(rgb: 0x3E82F3)),
  ]

  var body: some View {
    ZStack(alignment: .topLeading) {
      UnevenRoundedRectangle(topLeadingRadius: Self.radius, bottomLeadingRadius: Self.radius)
        .fill(Self.sheet).frame(width: Self.foldX, height: Self.height)
      UnevenRoundedRectangle(bottomTrailingRadius: Self.radius).fill(Self.sheet)
        .frame(width: Self.width - Self.foldX + 0.5, height: Self.height - Self.foldY)
        .offset(x: Self.foldX - 0.5, y: Self.foldY)
      Path { path in
        path.move(to: CGPoint(x: Self.foldX, y: 0))
        path.addLine(to: CGPoint(x: Self.foldX, y: Self.foldY))
        path.addLine(to: CGPoint(x: Self.width, y: Self.foldY))
        path.closeSubpath()
      }.fill(Self.fold)
      ForEach(Self.lines.indices, id: \.self) { index in
        let line = Self.lines[index]
        Capsule().fill(line.color).frame(width: line.width, height: 2.5)
          .offset(x: line.x, y: line.y)
      }
      ForEach(Self.bars.indices, id: \.self) { index in
        let bar = Self.bars[index]
        Capsule().fill(bar.color).frame(width: Self.barWidth, height: bar.height)
          .offset(x: bar.x, y: bar.y)
      }
    }.frame(width: Self.width, height: Self.height, alignment: .topLeading)
      .accessibilityHidden(true)
  }
}
