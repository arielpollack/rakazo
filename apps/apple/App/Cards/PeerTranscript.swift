import Foundation

/// Messages between bots, shown as the mobile app shows them: a bot's replies to work another
/// bot handed it fold under that message's line, and back-to-back exchanges with one bot read as
/// one "N messages with X" line. Ports `foldPeerReplies` (receipts kept) and `peerExchangeLines`.
enum PeerTranscript {
  struct Exchange {
    var peerBotId: String
    var peerBotName: String
    var count: Int
    var sent: Bool
  }
  struct Folded {
    var messages: [Message]
    /// Folded replies keyed by the id of the received message they fold under.
    var folded: [String: [Message]]
  }

  static func isReceipt(_ message: Message) -> Bool {
    message.blocks.contains { ["bot_message_sent", "bot_message_received"].contains($0.kind) }
  }

  private static func inputBlock(_ block: Message.Block) -> Bool {
    ["ask", "computer", "mcp_approval", "app_connect", "tool_question", "choice"].contains(
      block.kind)
  }

  /// Another bot handing this bot new work, rather than answering work this bot delegated.
  private static func startsPeerWork(_ message: Message) -> Bool {
    message.replyToMessageId == nil
      && message.blocks.contains {
        $0.kind == "bot_message_received"
          && ($0.intent == nil || ["request", "question"].contains($0.intent))
      }
  }

  static func fold(_ messages: [Message]) -> Folded {
    var markerByRun: [String: String] = [:]
    var relayRuns = Set<String>()
    let sentReceipts = Set(
      messages.filter { $0.blocks.contains { $0.kind == "bot_message_sent" } }.map(\.id))
    var merged = Set<String>()
    for message in messages
    where message.blocks.contains(where: { $0.kind == "bot_message_received" }) {
      let relay = !startsPeerWork(message)
      if relay, let parent = message.replyToMessageId, sentReceipts.contains(parent) {
        merged.insert(message.id)
      }
      if let run = message.runId, markerByRun[run] == nil {
        markerByRun[run] = message.id
        if relay { relayRuns.insert(run) }
      }
    }
    var folded: [String: [Message]] = [:]
    var markerOf: [String: String] = [:]
    func fold(_ marker: String, _ message: Message) -> Bool {
      folded[marker, default: []].append(message)
      markerOf[message.id] = marker
      return false
    }
    let visible = messages.filter { message in
      if message.blocks.contains(where: { $0.kind == "delivery" }) { return false }
      if isReceipt(message) { return !merged.contains(message.id) }
      if let parent = message.replyToMessageId, let marker = markerOf[parent],
        TranscriptRows.reaction(message) != nil
      {
        return fold(marker, message)
      }
      guard let run = message.runId, markerByRun[run] != nil else { return true }
      if message.blocks.contains(where: inputBlock) { return true }
      guard
        message.blocks.contains(where: {
          ["text", "file", "image", "chart", "app", "page"].contains($0.kind)
        })
      else { return false }
      if message.role != "bot" || relayRuns.contains(run) { return true }
      return fold(markerByRun[run]!, message)
    }
    return Folded(messages: visible, folded: folded)
  }

  private static func receipt(_ message: Message) -> Exchange? {
    guard
      let block = message.blocks.first(where: {
        ["bot_message_sent", "bot_message_received"].contains($0.kind)
      })
    else { return nil }
    let sent = block.kind == "bot_message_sent"
    guard let id = sent ? block.toBotId : block.fromBotId else { return nil }
    return Exchange(
      peerBotId: id, peerBotName: (sent ? block.toBotName : block.fromBotName) ?? "", count: 0,
      sent: sent)
  }

  private static func clamp(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 8_000 else { return trimmed }
    return String(trimmed.prefix(7_999)).trimmingCharacters(in: .whitespaces) + "…"
  }

  /// A folded reply the bot did not already send back as one of its "Messaged X" receipts.
  private static func unreturned(_ transcript: Folded) -> [String: Int] {
    var echoes: [String: [String: [String: Int]]] = [:]
    for message in transcript.messages {
      guard let run = message.runId else { continue }
      for block in message.blocks where block.kind == "bot_message_sent" {
        guard let peer = block.toBotId else { continue }
        echoes[run, default: [:]][peer, default: [:]][clamp(block.text ?? ""), default: 0] += 1
      }
    }
    var result: [String: Int] = [:]
    for marker in transcript.messages {
      guard let peer = receipt(marker), let replies = transcript.folded[marker.id] else { continue }
      var counts = marker.runId.flatMap { echoes[$0]?[peer.peerBotId] } ?? [:]
      result[marker.id] =
        replies.filter { reply in
          guard reply.role == "bot" else { return false }
          let content = reply.blocks.filter {
            ["text", "file", "image", "chart", "page"].contains($0.kind)
          }
          guard !content.isEmpty else { return false }
          if content.contains(where: { $0.kind != "text" }) { return true }
          let text = clamp(content.map { $0.text ?? "" }.joined(separator: "\n"))
          guard let count = counts[text], count > 0 else { return true }
          counts[text] = count - 1
          return false
        }.count
    }
    return result
  }

  /// Each exchange's line, keyed by the message that opens it, and the line each message joins.
  static func exchanges(_ transcript: Folded) -> (
    lines: [String: Exchange], lineOf: [String: String]
  ) {
    var lines: [String: Exchange] = [:]
    var lineOf: [String: String] = [:]
    let unreturned = unreturned(transcript)
    var first: String?
    for message in transcript.messages {
      guard let receipt = receipt(message) else {
        first = nil
        continue
      }
      let count =
        message.blocks.filter { ["bot_message_sent", "bot_message_received"].contains($0.kind) }
        .count + (unreturned[message.id] ?? 0)
      if let first, lines[first]?.peerBotId == receipt.peerBotId {
        lines[first]?.peerBotName = receipt.peerBotName
        lines[first]?.count += count
      } else {
        first = message.id
        lines[message.id] = Exchange(
          peerBotId: receipt.peerBotId, peerBotName: receipt.peerBotName, count: count,
          sent: receipt.sent)
      }
      lineOf[message.id] = first
    }
    return (lines, lineOf)
  }
}
