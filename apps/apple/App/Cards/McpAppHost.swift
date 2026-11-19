import Foundation

/// MCP Apps (SEP-1865) on the host side, as the shared core module web, Electron and the mobile
/// app use: the content policy an app runs under, the document the sandbox shows, and the
/// view-to-host protocol.
///
/// The boundary is the same opaque-origin sandbox bot-made HTML runs in: no cookies, storage or
/// app DOM. This host shows an app; it does not let it act. A view can ask to open a link and to
/// put text in the composer, each only right after the person used it. Tool calls, resource reads
/// and model-context updates from a view are refused.
enum McpApp {
  static let protocolVersion = "2026-01-26"
  /// Larger app documents are not shown; the tool's result still reaches the bot.
  static let htmlMaxBytes = 2_000_000
  static let domainsMax = 32
  static let messageMaxLength = 2_000

  enum DomainKind { case connect, resource }

  /// Origins the app declared it needs, already narrowed to the ones this host allows.
  struct Csp {
    var connectDomains: [String] = []
    var resourceDomains: [String] = []
    /// As the protocol sends it: a list appears only when it holds a domain.
    var json: [String: Any] {
      var json: [String: Any] = [:]
      if !connectDomains.isEmpty { json["connectDomains"] = connectDomains }
      if !resourceDomains.isEmpty { json["resourceDomains"] = resourceDomains }
      return json
    }
  }

  /// The declared origins an app may reach, as CSP sources. Only public names over https (or wss
  /// for connections): no IP literals, local or internal names, single-label hosts, bare
  /// wildcards, or any host in `excludeHosts` (the app's own), so a declaration cannot point the
  /// view at the person's network or at Rakazo itself.
  static func domains(
    _ values: JSONValue?, _ kind: DomainKind, excluding excludeHosts: [String] = []
  ) -> [String] {
    guard case .array(let values) = values else { return [] }
    let excluded = excludeHosts.map { $0.lowercased() }
    var sources: [String] = []
    for case .string(let value) in values where value.utf16.count <= 256 {
      guard let source = Source(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
      else { continue }
      if source.scheme == "wss" && kind != .connect { continue }
      if let port = source.port, !(1...65535).contains(Int(port) ?? 0) { continue }
      let labels = source.host.split(separator: ".", omittingEmptySubsequences: false)
      guard labels.count >= 2, labels.allSatisfy(isLabel) else { continue }
      // The source's shape already rules out IPv6 literals; only dotted IPv4 can get this far.
      if isIPv4(source.host) || isInternal(source.host) || isCloudMetadata(source.host) {
        continue
      }
      let covers = { (other: String) in
        other == source.host || (source.wildcard && other.hasSuffix("." + source.host))
      }
      if excluded.contains(where: covers) { continue }
      let entry =
        "\(source.scheme)://\(source.wildcard ? "*." : "")\(source.host)"
        + (source.port.map { ":" + $0 } ?? "")
      if !sources.contains(entry) { sources.append(entry) }
      if sources.count >= domainsMax { break }
    }
    return sources
  }

  /// The `_meta.ui.csp` an app resource declared, narrowed to what this host allows.
  static func csp(_ declared: JSONValue?, excluding excludeHosts: [String] = []) -> Csp {
    guard case .object(let csp) = declared else { return Csp() }
    return Csp(
      connectDomains: domains(csp["connectDomains"], .connect, excluding: excludeHosts),
      resourceDomains: domains(csp["resourceDomains"], .resource, excluding: excludeHosts))
  }

  /// The policy an app document runs under: inline code, its declared origins, nothing else.
  /// Nested frames, forms that navigate, plugins and base changes stay off whatever it declared.
  /// `csp` comes from `csp(_:excluding:)`, so it is already narrowed.
  static func contentSecurityPolicy(_ csp: Csp) -> String {
    let resources = csp.resourceDomains.joined(separator: " ")
    let connect = csp.connectDomains.isEmpty ? "'none'" : csp.connectDomains.joined(separator: " ")
    let withResources = { (base: String) in resources.isEmpty ? base : "\(base) \(resources)" }
    return [
      "default-src 'none'",
      "script-src \(withResources("'unsafe-inline'"))",
      "style-src \(withResources("'unsafe-inline'"))",
      "img-src \(withResources("data: blob:"))",
      "font-src \(withResources("data:"))",
      "media-src \(withResources("data: blob:"))",
      "connect-src \(connect)",
      "frame-src 'none'",
      "object-src 'none'",
      "form-action 'none'",
      "base-uri 'none'",
    ].joined(separator: "; ")
  }

  /// An app's HTML split for the viewer shell, which puts its gesture guard between the two: the
  /// head carries the policy first, so nothing in the app's own markup runs before it applies.
  static func document(_ html: String, csp: Csp) -> (head: String, body: String) {
    let policy = contentSecurityPolicy(csp)
    return (
      head:
        "<!DOCTYPE html><meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
        + "<meta name=\"referrer\" content=\"no-referrer\">",
      body: withoutLeadingDoctype(html)
    )
  }

  /// The shell with the app already in it, for a web view that loads one document.
  static func shellDocument(_ app: (head: String, body: String)) -> String? {
    let object = ["head": app.head, "body": app.body]
    guard
      let data = try? JSONSerialization.data(
        withJSONObject: object, options: [.withoutEscapingSlashes])
    else { return nil }
    // Escaped scalar by scalar, so no `</script>` or line separator in the app ends the script.
    var boot = String.UnicodeScalarView()
    for scalar in String(decoding: data, as: UTF8.self).unicodeScalars {
      switch scalar {
      case "<": boot.append(contentsOf: "\\u003c".unicodeScalars)
      case "\u{2028}": boot.append(contentsOf: "\\u2028".unicodeScalars)
      case "\u{2029}": boot.append(contentsOf: "\\u2029".unicodeScalars)
      default: boot.append(scalar)
      }
    }
    guard let marker = shellHTML.range(of: "<!--rakazo-app-boot-->", options: .literal) else {
      return nil
    }
    return shellHTML.replacingCharacters(
      in: marker, with: "<script>window.__rakazoApp=\(String(boot));</script>")
  }

  /// Text a view asked to put in the composer, on one line; nil when unusable.
  static func messageText(_ params: Any?) -> String? {
    guard let params = params as? [String: Any], params["role"] as? String == "user" else {
      return nil
    }
    let content = params["content"]
    let blocks = content as? [Any] ?? content.map { [$0] } ?? []
    let joined = blocks.compactMap { block -> String? in
      guard let block = block as? [String: Any], block["type"] as? String == "text" else {
        return nil
      }
      return block["text"] as? String
    }.joined(separator: " ")
    var text = String.UnicodeScalarView()
    var space = false
    for scalar in joined.unicodeScalars {
      if isSpace(scalar) {
        space = true
      } else {
        if space && !text.isEmpty { text.append(" ") }
        space = false
        text.append(scalar)
      }
    }
    let result = String(text)
    return !result.isEmpty && result.utf16.count <= messageMaxLength ? result : nil
  }

  /// A web or mail link a view asked to open; anything else stays inside the view.
  static func link(_ params: Any?) -> URL? {
    guard let raw = (params as? [String: Any])?["url"] as? String, raw.utf16.count <= 4096,
      let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
      ["http", "https", "mailto"].contains(scheme)
    else { return nil }
    guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    // Normalized as a browser's `href`: lowercase scheme and host, and a path of at least `/`.
    parts.scheme = scheme
    if scheme != "mailto" {
      guard let host = parts.percentEncodedHost, !host.isEmpty else { return nil }
      parts.percentEncodedHost = host.lowercased()
      if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
    }
    return parts.url
  }

  // MARK: Parsing

  /// `(https|wss)://(*.)?host(:port)?/?`, the only source shape a declaration may use.
  private struct Source {
    let scheme: String
    let wildcard: Bool
    let host: String
    let port: String?

    init?(_ value: String) {
      var rest: Substring
      if value.hasPrefix("https://") {
        scheme = "https"
        rest = value.dropFirst(8)
      } else if value.hasPrefix("wss://") {
        scheme = "wss"
        rest = value.dropFirst(6)
      } else {
        return nil
      }
      wildcard = rest.hasPrefix("*.")
      if wildcard { rest = rest.dropFirst(2) }
      let host = rest.prefix { $0 != "/" && $0 != ":" }
      guard !host.isEmpty else { return nil }
      rest = rest.dropFirst(host.count)
      var port: Substring?
      if rest.first == ":" {
        let digits = rest.dropFirst().prefix { ("0"..."9").contains($0) }
        guard (1...5).contains(digits.count) else { return nil }
        port = digits
        rest = rest.dropFirst(1 + digits.count)
      }
      if rest == "/" { rest = "" }
      guard rest.isEmpty else { return nil }
      self.host = String(host)
      self.port = port.map(String.init)
    }
  }

  /// A DNS label: letters, digits and inner hyphens, 1 to 63 characters.
  private static func isLabel(_ label: Substring) -> Bool {
    let bytes = Array(label.utf8)
    func alphanumeric(_ byte: UInt8) -> Bool {
      (97...122).contains(byte) || (48...57).contains(byte)
    }
    guard (1...63).contains(bytes.count), let first = bytes.first, let last = bytes.last,
      alphanumeric(first), alphanumeric(last)
    else { return false }
    return bytes.allSatisfy { alphanumeric($0) || $0 == 45 }
  }

  /// Four decimal octets, without the leading zeros some parsers read as octal.
  private static func isIPv4(_ host: String) -> Bool {
    let octets = host.split(separator: ".", omittingEmptySubsequences: false)
    return octets.count == 4
      && octets.allSatisfy { octet in
        (1...3).contains(octet.count) && octet.allSatisfy { ("0"..."9").contains($0) }
          && !(octet.count > 1 && octet.hasPrefix("0")) && (Int(octet) ?? 256) <= 255
      }
  }

  /// Names reserved for local or internal use.
  private static func isInternal(_ host: String) -> Bool {
    host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
      || host.hasSuffix(".internal")
  }

  private static func isCloudMetadata(_ host: String) -> Bool {
    ["metadata.google.internal", "metadata.goog"].contains(host)
  }

  /// JavaScript's `\s`.
  private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
    scalar.properties.isWhitespace || scalar == "\u{FEFF}"
  }

  /// The app's HTML without a leading `<!doctype …>`; the head brings its own.
  private static func withoutLeadingDoctype(_ html: String) -> String {
    let scalars = html.unicodeScalars
    var index = scalars.startIndex
    if index < scalars.endIndex, scalars[index] == "\u{FEFF}" {
      index = scalars.index(after: index)
    }
    while index < scalars.endIndex, isSpace(scalars[index]) { index = scalars.index(after: index) }
    for expected in "<!doctype".unicodeScalars {
      guard index < scalars.endIndex,
        String(scalars[index]).lowercased() == String(expected), scalars[index].isASCII
      else { return html }
      index = scalars.index(after: index)
    }
    guard let close = scalars[index...].firstIndex(of: ">") else { return html }
    return String(String.UnicodeScalarView(scalars[scalars.index(after: close)...]))
  }
}

/// The host half of one view's session. It answers `ui/initialize`, sends the call's input and
/// result once the view says it is ready, and never before, as the protocol requires.
final class McpAppHost {
  struct Options {
    var input: [String: Any]
    var result: [String: Any]
    /// The `hostContext` a view gets at initialize: theme, locale, sizes.
    var hostContext: [String: Any]
    /// The domains this host let the app reach, echoed to it as granted.
    var csp: [String: Any]
    /// Posts a JSON-RPC message down to the view.
    var send: ([String: Any]) -> Void
    /// Whether a fresh gesture covers the view's request. Called only for one that acts.
    var allowAction: () -> Bool
    var openLink: (URL) -> Void
    /// Puts text in the composer; the person still sends it.
    var offerMessage: (String) -> Void
    var onHeight: (Double) -> Void
  }

  private static let denied = -32000
  private static let methodNotFound = -32601
  private static let maxViewMessageLength = 64_000

  private let options: Options
  private var initialized = false
  private var teardowns = 0

  init(_ options: Options) { self.options = options }

  /// A JSON-RPC message the view sent, as the shell passed it up.
  func receive(_ data: Any?) {
    guard let message = data as? [String: Any], JSONSerialization.isValidJSONObject(message),
      let json = try? JSONSerialization.data(
        withJSONObject: message, options: [.withoutEscapingSlashes]),
      String(decoding: json, as: UTF8.self).utf16.count <= Self.maxViewMessageLength
    else { return }
    // A response to our teardown, or noise.
    guard let method = message["method"] as? String else { return }
    if let id = Self.requestId(message["id"]) {
      request(id, method, message["params"])
    } else {
      notification(method, message["params"])
    }
  }

  /// Host context that changed, such as the theme.
  func updateContext(_ context: [String: Any]) {
    if initialized { notify("ui/notifications/host-context-changed", context) }
  }

  /// Tells the view it is going away; nothing waits for its answer.
  func teardown() {
    guard initialized else { return }
    teardowns += 1
    options.send([
      "jsonrpc": "2.0", "id": "rakazo-teardown-\(teardowns)", "method": "ui/resource-teardown",
      "params": [String: Any](),
    ])
  }

  private func request(_ id: Any, _ method: String, _ params: Any?) {
    switch method {
    case "ui/initialize":
      reply(
        id,
        [
          "protocolVersion": McpApp.protocolVersion,
          "hostInfo": ["name": "rakazo", "version": "1.0.0"],
          "hostCapabilities": [
            "openLinks": [String: Any](),
            "message": ["text": [String: Any]()],
            "sandbox": ["csp": options.csp],
          ],
          "hostContext": options.hostContext,
        ])
    case "ping":
      reply(id, [:])
    case "ui/request-display-mode":
      reply(id, ["mode": "inline"])
    case "ui/open-link":
      guard let url = McpApp.link(params) else { return refuse(id, Self.denied, "Invalid URL") }
      guard options.allowAction() else { return refuse(id, Self.denied, "Link opening denied") }
      options.openLink(url)
      reply(id, [:])
    case "ui/message":
      guard let text = McpApp.messageText(params) else {
        return refuse(id, Self.denied, "Invalid message format")
      }
      guard options.allowAction() else {
        return refuse(id, Self.denied, "Message sending denied")
      }
      options.offerMessage(text)
      reply(id, [:])
    default:
      // tools/call, resources/read, ui/update-model-context, sampling and anything newer.
      refuse(id, Self.methodNotFound, "Method not found")
    }
  }

  private func notification(_ method: String, _ params: Any?) {
    if method == "ui/notifications/initialized" {
      if initialized { return }
      initialized = true
      notify("ui/notifications/tool-input", ["arguments": options.input])
      notify("ui/notifications/tool-result", options.result)
      return
    }
    if method == "ui/notifications/size-changed",
      let number = (params as? [String: Any])?["height"] as? NSNumber, !Self.isBool(number),
      number.doubleValue.isFinite, number.doubleValue >= 0
    {
      options.onHeight(number.doubleValue)
    }
  }

  private func reply(_ id: Any, _ result: [String: Any]) {
    options.send(["jsonrpc": "2.0", "id": id, "result": result])
  }
  private func refuse(_ id: Any, _ code: Int, _ message: String) {
    options.send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
  }
  private func notify(_ method: String, _ params: [String: Any]) {
    options.send(["jsonrpc": "2.0", "method": method, "params": params])
  }

  /// A string or number id makes a request; anything else is a notification.
  private static func requestId(_ value: Any?) -> Any? {
    if let id = value as? String { return id }
    if let id = value as? NSNumber, !isBool(id) { return id }
    return nil
  }
  private static func isBool(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
  }
}

/// The shell between the host and an app: the web view's document. The app runs one frame down,
/// in an opaque-origin srcdoc frame, and has a real parent to talk to. Each document gets a fresh
/// key that only the guard placed first in it knows. The shell passes JSON-RPC both ways; it
/// reaches the host through `window.ReactNativeWebView`, the bridge name the shared shell expects
/// on phones, which the card's web view provides. Kept byte for byte as the shared core module's.
private let shellHTML = #"""
  <!DOCTYPE html><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' https:; style-src 'unsafe-inline' https:; img-src data: blob: https:; font-src data: https:; media-src data: blob: https:; connect-src https: wss:; frame-src about:; child-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"><meta name="referrer" content="no-referrer"><meta name="viewport" content="width=device-width, initial-scale=1"><style>html,body{margin:0;background:transparent}iframe{display:block;width:100%;height:100%;border:0;background:transparent}html,body{height:100%}</style><iframe id="app" title="App" sandbox="allow-scripts allow-forms" referrerpolicy="no-referrer"></iframe><!--rakazo-app-boot--><script>
  (() => {
    const frame = document.getElementById("app");
    const native = Boolean(window.ReactNativeWebView);
    const up = (message) => native ? window.ReactNativeWebView.postMessage(JSON.stringify(message)) : parent.postMessage(message, "*");
    const GESTURE_WINDOW_MS = 1000;
    let key = "", gesture = 0, gestureAt = 0;
    const guard = () => {
      key = Array.from(crypto.getRandomValues(new Uint32Array(4)), (n) => n.toString(36)).join("");
      return `<script>(() => { const up = parent, key = "${key}"; document.currentScript.remove(); const apply = Reflect.apply, repeat = Object.getOwnPropertyDescriptor(KeyboardEvent.prototype, "repeat").get; const tell = () => up.postMessage({ type: "rakazo-app:gesture", key }, "*"); addEventListener("pointerup", (event) => { if (event.isTrusted) tell(); }, true); addEventListener("keydown", (event) => { if (event.isTrusted && !apply(repeat, event, [])) tell(); }, true); })();</${"script"}>`;
    };
    const load = (app) => {
      if (!app || typeof app.head !== "string" || typeof app.body !== "string") return;
      gesture = 0;
      frame.srcdoc = app.head + guard() + app.body;
    };
    const rpc = (data) => Boolean(data) && typeof data === "object" && data.jsonrpc === "2.0";
    addEventListener("message", (event) => {
      const data = event.data;
      if (event.source === frame.contentWindow) {
        const active = navigator.userActivation ? navigator.userActivation.isActive : false;
        if (data && data.type === "rakazo-app:gesture") {
          if (key && data.key === key && active) { gesture += 1; gestureAt = Date.now(); }
          return;
        }
        if (!rpc(data)) return;
        const fresh = active && gesture > 0 && Date.now() - gestureAt <= GESTURE_WINDOW_MS ? key + ":" + gesture : null;
        up({ type: "rakazo-app:view", message: data, gesture: fresh });
        return;
      }
      const fromHost = native ? event.source === window : event.source === parent && parent !== window;
      if (!fromHost || !data || typeof data !== "object") return;
      if (data.type === "rakazo-app:load") load(data);
      else if (data.type === "rakazo-app:host" && rpc(data.message)) frame.contentWindow.postMessage(data.message, "*");
    });
    if (window.__rakazoApp) load(window.__rakazoApp);
  })();
  </script>
  """#
