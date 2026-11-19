import Combine
import SwiftUI

/// Messages on their way to the server, as in the mobile app: each shows the moment it is sent,
/// they go out one at a time in the order sent, and one that fails stays to retry or delete.
/// App-wide, so leaving a chat never drops what it was sending.
@MainActor final class Outbox: ObservableObject {
  static let limit = 20
  enum State { case queued, sending, failed }
  struct Attempt: Identifiable {
    /// Also the client nonce, so a retry the server already saved is not saved twice.
    let id = UUID().uuidString
    let chatId: String
    let target: [String: Any]
    let api: Client
    let text: String
    let files: [Upload]
    let quote: Message?
    let excerpt: String?
    var state = State.queued
    var error: String?
    /// The transcript position the server gave it; it leaves once the chat shows that message.
    var acceptedSeq: Int?
    var artifactIds: [String] = []
  }
  struct ConsentRequest: Identifiable {
    let chatId: String
    let status: Consent
    var id: String { chatId }
  }
  @Published private(set) var attempts: [Attempt] = []
  /// A chat whose messages wait for the person to allow the providers they reach.
  @Published var consent: ConsentRequest?
  /// Chats whose server copy of a message is ready to load.
  let delivered = PassthroughSubject<String, Never>()
  private var consented = Set<String>()
  private var draining = false

  func send(
    _ text: String, files: [Upload], quote: Message?, excerpt: String?, chat: Chat, api: Client
  ) throws {
    guard attempts.filter({ $0.acceptedSeq == nil }).count < Self.limit else {
      throw Failure("Too many unsent messages.")
    }
    attempts.append(
      Attempt(
        chatId: chat.id, target: chat.target, api: api, text: text, files: files, quote: quote,
        excerpt: excerpt))
    Task { await drain() }
  }
  func retry(_ id: String) {
    guard let index = attempts.firstIndex(where: { $0.id == id }), attempts[index].state == .failed
    else { return }
    attempts[index].state = .queued
    attempts[index].error = nil
    Task { await drain() }
  }
  func discard(_ id: String) {
    attempts.removeAll { $0.id == id && $0.state != .sending }
  }
  /// The chat now shows these user messages; sends they confirm leave.
  func shown(_ seqs: Set<Int>, in chatId: String) {
    attempts.removeAll { $0.chatId == chatId && $0.acceptedSeq.map(seqs.contains) == true }
  }
  func allow(_ request: ConsentRequest) async {
    consent = nil
    guard let api = attempts.first(where: { $0.chatId == request.chatId })?.api else { return }
    do {
      let _: Consent = try await api.rpc(
        "aiConsent/allow",
        [
          "scope": request.status.scope, "version": request.status.version,
          "keys": request.status.unapproved.map(\.key),
        ])
      consented.insert(request.chatId)
    } catch {
      fail(chat: request.chatId, error.localizedDescription)
    }
    await drain()
  }
  /// Not allowed: that chat's waiting messages stay unsent until retried.
  func decline(_ request: ConsentRequest) {
    consent = nil
    fail(chat: request.chatId, nil)
    Task { await drain() }
  }
  private func fail(chat chatId: String, _ error: String?) {
    for index in attempts.indices
    where attempts[index].chatId == chatId
      && attempts[index].state == .queued
    {
      attempts[index].state = .failed
      attempts[index].error = error
    }
  }
  private func drain() async {
    guard !draining else { return }
    draining = true
    defer { draining = false }
    while consent == nil, let next = attempts.first(where: { $0.state == .queued }) {
      let id = next.id
      func update(_ change: (inout Attempt) -> Void) {
        if let index = attempts.firstIndex(where: { $0.id == id }) { change(&attempts[index]) }
      }
      update { $0.state = .sending }
      do {
        if !consented.contains(next.chatId) {
          let status: Consent = try await next.api.rpc(
            "aiConsent/status", next.target.merging(["uses": ["model", "memory"]]) { $1 })
          guard status.unapproved.isEmpty else {
            update { $0.state = .queued }
            consent = ConsentRequest(chatId: next.chatId, status: status)
            return
          }
          consented.insert(next.chatId)
        }
        var ids = next.artifactIds
        for file in next.files.dropFirst(ids.count) {
          let record: ObjectID = try await next.api.rpc(
            "artifacts/create",
            next.target.merging([
              "name": file.name, "mimeType": file.mime,
              "contentBase64": file.data.base64EncodedString(), "clientNonce": file.id,
            ]) { $1 })
          ids.append(record.id)
          update { $0.artifactIds = ids }
        }
        var input = next.target
        input["text"] = next.text
        input["artifactIds"] = ids
        input["clientNonce"] = id
        if let parent = next.quote {
          input["replyToMessageId"] = parent.id
          input["replyQuote"] = next.excerpt
        }
        let receipt: Receipt = try await next.api.rpc("threads/send", input)
        update { $0.acceptedSeq = receipt.seq }
        delivered.send(next.chatId)
      } catch {
        update {
          $0.state = .failed
          $0.error = error.localizedDescription
        }
      }
    }
  }
  private struct Receipt: Decodable { let seq: Int }
}

/// This chat's messages still on their way, after the transcript.
struct OutboxRows: View {
  @ObservedObject var outbox: Outbox
  let chat: Chat
  let colors: OutgoingColors
  let width: CGFloat
  var body: some View {
    ForEach(outbox.attempts.filter { $0.chatId == chat.id }) { attempt in
      let failed = attempt.state == .failed
      Button {
        outbox.retry(attempt.id)
      } label: {
        VStack(alignment: .trailing, spacing: 3) {
          VStack(alignment: .leading, spacing: 6) {
            if let quoted = attempt.excerpt ?? attempt.quote?.text {
              Text(verbatim: quoted).lineLimit(2).font(.caption).padding(7).background(
                .black.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            }
            if !attempt.text.isEmpty { Text(verbatim: attempt.text) }
            ForEach(attempt.files) { Label($0.name, systemImage: "paperclip").font(.callout) }
          }.font(TypeRole.message).padding(.horizontal, Layout.bubbleInsetX)
            .padding(.vertical, Layout.bubbleInsetY).foregroundStyle(colors.text).background(
              colors.fill,
              in: RoundedRectangle(cornerRadius: Layout.Radius.bubble, style: .continuous)
            ).opacity(0.8)
          Text(failed ? Self.retryCaption : "Sending…").font(.caption)
            .foregroundStyle(failed ? Color.red : Color.secondary)
        }
      }.buttonStyle(.plain).disabled(!failed).help(attempt.error ?? "")
        .frame(maxWidth: width, alignment: .trailing).frame(
          maxWidth: .infinity, alignment: .trailing
        )
        .contextMenu {
          if failed {
            Button("Try Again") { outbox.retry(attempt.id) }
            Button("Delete", role: .destructive) { outbox.discard(attempt.id) }
          }
        }
    }
  }
  #if os(macOS)
    private static let retryCaption = "Not sent. Click to retry"
  #else
    private static let retryCaption = "Not sent. Tap to retry"
  #endif
}
