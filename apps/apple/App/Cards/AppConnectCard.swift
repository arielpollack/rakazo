import SwiftUI

/// A bot's request to connect an app, drawn as the mobile app draws it: the app's logo, name and
/// what it does, with Connect beside them until the account is connected.
struct AppConnectCard: View {
  let block: Message.Block
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var phase
  @State private var busy = false
  @State private var connectedHere = false
  @State private var problem: String?
  @State private var attempt: Task<Void, Never>?
  /// A sign-in that outlasted the wait, read again each time the person comes back to the app.
  @State private var returning: String?
  @State private var reading = false
  @State private var reviewing = false

  private struct Fields: Decodable { var logo: String? }
  private struct Started: Decodable { let connectionId: String, authorizationUrl: String? }
  private struct Connection: Decodable { let status: String }
  private enum Outcome { case connected, pending, aborted }

  private var name: String { block.name ?? block.provider ?? "" }
  private var connected: Bool { block.status == "connected" || connectedHere }
  private var bot: String? { message.botId ?? (chat.isGroup ? nil : chat.id) }
  /// The sample catalog's entry for this app, which the demo connects instead.
  private var sampleEntry: CatalogEntry? {
    guard store.demo, let library = store.sampleIntegrations,
      let seed = try? CatalogSeed.bundled.get()
    else { return nil }
    return library.catalog(seed).first {
      $0.slug == block.provider && $0.connectorId == block.connectorId
    }
  }
  private var canConnect: Bool {
    bot != nil && message.threadId != nil && block.provider != nil
      && (store.client != nil || sampleEntry != nil)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        icon
        VStack(alignment: .leading, spacing: 2) {
          Text(verbatim: name).font(CardType.title)
          Text(verbatim: block.description ?? "").font(CardType.secondary)
            .foregroundStyle(.secondary).lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
        if connected {
          Text("Connected").font(CardType.secondary.weight(.medium)).foregroundStyle(.green)
        } else if canConnect {
          Button(action: connect) {
            if busy { ProgressView().controlSize(.small).tint(Ink.canvas) } else { Text("Connect") }
          }.buttonStyle(CardButton(primary: true)).fixedSize().disabled(busy)
            .accessibilityLabel("Connect \(name)")
        }
      }
      if let problem {
        Text(problem).font(CardType.caption).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }
    }.chatCard()
      .onChange(of: phase) { _, state in if state == .active { readOnReturn() } }
      .onDisappear {
        attempt?.cancel()
        attempt = nil
        returning = nil
        busy = false
      }
      .rakazoSheet(
        isPresented: $reviewing,
        onDismiss: {
          Task { do { try await refresh() } catch { report(error.localizedDescription) } }
        }
      ) {
        if let entry = sampleEntry {
          SampleAppReview(store: store, entry: entry) {
            store.resolveSampleConnection(
              chat: chat.id, message: message.id, kind: block.kind, allow: true)
          }.integrationSheet()
        }
      }
  }

  /// The catalog's artwork, as in the integrations library, or the app's initial.
  private var icon: some View {
    let initial = Text(
      verbatim: (name.trimmingCharacters(in: .whitespaces).first.map(String.init) ?? "?")
        .uppercased()
    )
    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
    return ZStack {
      if let logo = Self.logo(block.fields(Fields.self)?.logo) {
        AsyncImage(url: logo) { phase in
          switch phase {
          case .success(let image): image.resizable().scaledToFit().frame(width: 32, height: 32)
          case .failure: initial
          default: Color.clear
          }
        }
      } else {
        initial
      }
    }.frame(width: 40, height: 40)
      .background(Ink.selection, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous)).accessibilityHidden(true)
  }

  /// A logo from the catalog hosts the integrations library loads artwork from.
  private static func logo(_ raw: String?) -> URL? {
    guard let url = MarketDirectory.secureURL(raw), let host = url.host?.lowercased(),
      [
        "cdn.jsdelivr.net", "raw.githubusercontent.com", "assets.pipedream.net",
        "logos.composio.dev", "assets.composio.dev",
      ].contains(host)
    else { return nil }
    return url
  }

  private func connect() {
    guard store.client != nil else {
      reviewing = true
      return
    }
    guard let api = store.client, let bot, let thread = message.threadId,
      let provider = block.provider
    else { return }
    attempt?.cancel()
    returning = nil
    busy = true
    problem = nil
    attempt = Task {
      do {
        var input = ["provider": provider, "displayName": name]
        input["connectorId"] = block.connectorId
        let started: Started = try await api.rpc("connections/begin", input)
        try Task.checkCancellation()
        if let raw = started.authorizationUrl {
          guard let url = MarketDirectory.secureURL(raw) else {
            throw Failure("Authorization link was not a secure web address.")
          }
          openURL(url)
        }
        switch await Self.wait(api, started.connectionId, attempts: 60) {
        case .connected: try await finish(api, bot: bot, thread: thread, provider: provider)
        case .pending:
          // Slow sign-ins are not failures: Connect can start over, and coming back reads again.
          busy = false
          returning = started.connectionId
          readOnReturn()
          return
        case .aborted: break
        }
      } catch {
        if !Task.isCancelled { problem = error.localizedDescription }
      }
      if !Task.isCancelled { busy = false }
    }
  }

  /// Reads a slow sign-in again a few times, so one failed request does not lose one that finished.
  private func readOnReturn() {
    guard let id = returning, !reading, let api = store.client, let bot,
      let thread = message.threadId, let provider = block.provider
    else { return }
    reading = true
    attempt = Task {
      defer { reading = false }
      switch await Self.wait(api, id, attempts: 3) {
      case .connected:
        returning = nil
        do {
          try await finish(api, bot: bot, thread: thread, provider: provider)
        } catch {
          if !Task.isCancelled { problem = error.localizedDescription }
        }
      case .aborted: if !Task.isCancelled { returning = nil }
      case .pending: break
      }
    }
  }

  private func finish(_ api: Client, bot: String, thread: String, provider: String) async throws {
    var input = [
      "botId": bot, "threadId": thread, "messageId": message.id, "provider": provider,
    ]
    input["connectorId"] = block.connectorId
    let _: Empty = try await api.rpc("onboarding/appConnected", input)
    try Task.checkCancellation()
    connectedHere = true
    do { try await refresh() } catch { report(error.localizedDescription) }
  }

  /// Polls the connection until it is connected. One revoked or gone was superseded by a newer
  /// attempt or a removal, so the wait stops quietly.
  private static func wait(_ api: Client, _ id: String, attempts: Int) async -> Outcome {
    for attempt in 0..<attempts {
      if Task.isCancelled { return .aborted }
      do {
        let connection: Connection = try await api.rpc(
          "connections/complete", ["connectionId": id])
        if connection.status == "connected" { return .connected }
        if connection.status == "revoked" { return .aborted }
      } catch let failure as Failure where failure.code == "NOT_FOUND" {
        return .aborted
      } catch {}
      if attempt + 1 < attempts { try? await Task.sleep(for: .seconds(2)) }
    }
    return Task.isCancelled ? .aborted : .pending
  }
}
