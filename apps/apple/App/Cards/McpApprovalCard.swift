import AuthenticationServices
import SwiftUI

/// A bot's request to connect an MCP server, drawn as the mobile app draws it. A server that needs
/// sign-in is authorized here, as on the web, and then approved.
struct McpApprovalCard: View {
  let block: Message.Block
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void
  @Environment(\.webAuthenticationSession) private var browser
  @Environment(\.openURL) private var openURL
  @State private var localStatus = "pending"
  @State private var running: Choice?
  /// A sign-in the server sent to the browser; the next press checks that it finished.
  @State private var browserURL: URL?

  private enum Choice { case approve, dismiss }
  private struct Fields: Decodable { var endpoint: String? }

  private var bot: String? { message.botId ?? (chat.isGroup ? nil : chat.id) }
  private var name: String { block.name ?? block.serverId ?? "" }
  private var oauth: Bool { block.needsOAuth == true }
  /// The saved answer, or the one given here while the saved block still reads pending.
  private var status: String {
    if let saved = block.status, saved != "pending" { return saved }
    return localStatus
  }
  private var canAnswer: Bool {
    bot != nil && block.serverId != nil && (store.client != nil || store.demo)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        Text(verbatim: "M").font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
          .frame(width: 28, height: 28)
          .background(Ink.selection, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text("Connect MCP server “\(name)”").font(CardType.title)
            .fixedSize(horizontal: false, vertical: true)
          Text(verbatim: block.fields(Fields.self)?.endpoint ?? "stdio (\(block.transport ?? ""))")
            .font(CardType.caption).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading)
      }
      if status != "pending" {
        Text(
          status == "connected" ? "Connected." : "Dismissed. Reconnect anytime from MCP settings."
        ).font(CardType.secondary).foregroundStyle(status == "connected" ? .green : .secondary)
      } else if canAnswer {
        Text(
          oauth
            ? "Authorize this server so agents can use its tools."
            : "Approve this server to let your agent use its tools."
        ).font(CardType.secondary).foregroundStyle(Color.primary.opacity(0.75))
          .fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
          Button(oauth ? (running == .approve ? "Connecting…" : "Authorize") : "Approve") {
            submit(.approve)
          }.buttonStyle(CardButton(primary: true))
          Button("Not now") { submit(.dismiss) }.buttonStyle(CardButton(primary: false))
        }.fixedSize().disabled(running != nil)
      }
    }.chatCard()
      .onChange(of: block.status) { _, saved in
        // A removal repaints the block to pending, so an answer given here no longer holds.
        if saved != "connected" && saved != "dismissed" { localStatus = "pending" }
      }
  }

  private func submit(_ choice: Choice) {
    guard running == nil, status == "pending", let bot, let server = block.serverId else { return }
    running = choice
    Task {
      defer { running = nil }
      do {
        guard let api = store.client else {
          store.resolveSampleConnection(
            chat: chat.id, message: message.id, kind: block.kind, allow: choice == .approve)
          try await refresh()
          return
        }
        if choice == .approve, oauth {
          if browserURL != nil {
            try await store.verifyBrowserGrant(server)
          } else if case .finishInBrowser(let url) = try await store.authorizeServer(
            server, using: { try await signIn($0) })
          {
            browserURL = url
            openURL(url)
            return
          }
        }
        var input: [String: Any] = ["botId": bot, "serverId": server]
        input["threadId"] = message.threadId
        let _: Empty = try await api.rpc(
          choice == .approve ? "mcp/assignments/approve" : "mcp/assignments/dismiss", input)
        localStatus = choice == .approve ? "connected" : "dismissed"
        browserURL = nil
        try await refresh()
      } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
        // Closing the sign-in leaves the card as it was.
      } catch { report(error.localizedDescription) }
    }
  }

  /// Signs in to the server in the system's browser sheet, which hands back the app's callback.
  private func signIn(_ url: URL) async throws -> URL {
    if #available(iOS 17.4, macOS 14.4, *) {
      return try await browser.authenticate(
        using: url, callback: .customScheme("rakazo"), preferredBrowserSession: .shared,
        additionalHeaderFields: [:])
    }
    return try await browser.authenticate(
      using: url, callbackURLScheme: "rakazo", preferredBrowserSession: .shared)
  }
}
