import Foundation
import Security

struct Login: Codable {
  let server: URL
  let token: String
}

enum Vault {
  private static var key: [String: Any] {
    var service = (Bundle.main.bundleIdentifier ?? "dev.rakazo.nativeclient") + ".session"
    #if DEBUG
      if ProcessInfo.processInfo.arguments.contains(where: {
        ["--test-login", "--test-restore"].contains($0)
      }) {
        service += ".uitest"
      }
    #endif
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: "active",
    ]
    #if os(macOS)
      query[kSecUseDataProtectionKeychain as String] = true
    #endif
    return query
  }
  static func read() throws -> Login? {
    var result: CFTypeRef?
    let status = SecItemCopyMatching(
      key.merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result)
    if status == errSecItemNotFound { return nil }
    #if os(macOS)
      if status == errSecMissingEntitlement { return nil }
    #endif
    guard status == errSecSuccess, let data = result as? Data else {
      throw Failure("Could not unlock the saved session. Unlock this device and try again.")
    }
    return try JSONDecoder().decode(Login.self, from: data)
  }
  static func save(_ login: Login) throws {
    let attributes: [String: Any] = [
      kSecValueData as String: try JSONEncoder().encode(login),
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      guard SecItemAdd(key.merging(attributes) { $1 } as CFDictionary, nil) == errSecSuccess else {
        throw Failure("Could not save your session to Keychain.")
      }
    } else if status != errSecSuccess {
      throw Failure("Could not update your session in Keychain.")
    }
  }
  static func clear() throws {
    let status = SecItemDelete(key as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw Failure("Could not remove the saved session from Keychain.")
    }
  }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
}

struct Client {
  let server: URL
  var token: String? = nil
  var space: String? = nil
  private static let transport: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.urlCache = nil
    config.timeoutIntervalForRequest = 45
    return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
  }()
  static func origin(_ input: String) throws -> URL {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let parts = URLComponents(string: trimmed.contains("://") ? trimmed : "https://" + trimmed),
      let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
      parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
      let url = parts.url
    else { throw Failure("Enter the server address only, without a path or credentials.") }
    guard
      parts.scheme?.lowercased() == "https"
        || (parts.scheme?.lowercased() == "http"
          && ["localhost", "127.0.0.1", "[::1]"].contains(host.lowercased()))
    else { throw Failure("Use HTTPS for your server, or HTTP on localhost for development.") }
    return url
  }
  func request(_ path: String, body: [String: Any]) throws -> URLRequest {
    var request = URLRequest(url: server.appendingPathComponent(path))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("rakazo://", forHTTPHeaderField: "Origin")
    request.setValue("mobile/20261118000000", forHTTPHeaderField: "x-rakazo-client-build")
    if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
    if let space { request.setValue(space, forHTTPHeaderField: "x-rakazo-space-id") }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    return request
  }
  func post(_ path: String, _ body: [String: Any]) async throws -> (Data, HTTPURLResponse) {
    let (data, raw) = try await Self.transport.data(for: request(path, body: body))
    guard let response = raw as? HTTPURLResponse else {
      throw Failure("The server returned an invalid response.")
    }
    guard (200..<300).contains(response.statusCode) else {
      let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
      let details = payload?["json"] as? [String: Any] ?? payload
      throw Failure(
        details?["message"] as? String
          ?? "Rakazo returned HTTP \(response.statusCode). Check your server and sign-in.")
    }
    return (data, response)
  }
  struct Envelope<Value: Decodable>: Decodable { let json: Value }
  func rpc<Value: Decodable>(
    _ path: String, _ input: [String: Any] = [:], as type: Value.Type = Value.self
  ) async throws -> Value {
    let (data, _) = try await post("rpc/" + path, ["json": input])
    return try JSONDecoder().decode(Envelope<Value>.self, from: data).json
  }
  func authenticate(email: String, password: String, code: Bool) async throws -> Login {
    let health: Health = try await rpc("health")
    guard health.ok else { throw Failure("This is not a Rakazo server.") }
    let (data, response) = try await post(
      "api/auth/sign-in/" + (code ? "email-otp" : "email"),
      ["email": email, code ? "otp" : "password": password])
    let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let cookies = HTTPCookie.cookies(
      withResponseHeaderFields: [
        "Set-Cookie": response.value(forHTTPHeaderField: "Set-Cookie") ?? ""
      ], for: server)
    let signed =
      response.value(forHTTPHeaderField: "set-auth-token")
      ?? cookies.first(where: {
        ["__Secure-better-auth.session_token", "better-auth.session_token"].contains($0.name)
      })?.value
    guard
      let token = signed?.removingPercentEncoding ?? body?["token"] as? String
        ?? (body?["session"] as? [String: Any])?["token"] as? String, !token.isEmpty
    else { throw Failure("Sign-in did not return a session.") }
    return Login(server: server, token: token)
  }
  func file(_ id: String, chat: Chat, limit: Int) async throws -> Data {
    let artifact: StoredArtifact = try await rpc(
      "artifacts/get", chat.target.merging(["artifactId": id]) { $1 })
    guard artifact.id == id, (0...limit).contains(artifact.size),
      artifact.contentBase64.utf8.count <= 4 * ((limit + 2) / 3),
      let bytes = Data(base64Encoded: artifact.contentBase64), bytes.count == artifact.size
    else { throw Failure("The file is incomplete or exceeds the native download limit.") }
    return bytes
  }
  func events(
    _ proc: String, input: [String: Any], receive: @escaping ([String: Any]) async throws -> Void
  ) async throws {
    var req = try request("rpc/" + proc, body: ["json": input])
    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    let (bytes, raw) = try await Self.transport.bytes(for: req)
    guard let response = raw as? HTTPURLResponse, response.statusCode == 200,
      response.mimeType == "text/event-stream"
    else { throw Failure("Live updates disconnected. Refresh to reconnect.") }
    for try await line in bytes.lines {
      try Task.checkCancellation()
      guard line.hasPrefix("data:"), line.utf8.count < 2_000_000 else { continue }
      let data = Data(line.dropFirst(5).utf8)
      if let frame = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        let event = frame["json"] as? [String: Any], let type = event["type"] as? String,
        type != "heartbeat"
      {
        try await receive(event)
      }
    }
  }
}
