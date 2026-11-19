import SwiftUI

/// One call's exchange in a chat: the messages a run of consecutive call turns collapses to.
struct VoiceChatGroup: Identifiable {
  /// `call:<callId>` for a call's first group, `call:<callId>:<n>` for the later segments a
  /// typed message split it into, so the row keeps its identity when older messages load.
  let key: String
  let callId: String
  var messages: [Message]
  /// The `voice_call` message the bot left when it hung up; it closes the group.
  var marker: Message?
  var id: String { key }

  /// Whether a message inside the card starts the unread part, so the divider goes above it.
  func holds(_ messageId: String?) -> Bool {
    guard let messageId else { return false }
    return messages.contains { $0.id == messageId }
  }

  /// The title the bot hung up with, else the first sentence of its first spoken reply.
  var summary: String {
    if let marker = marker?.blocks.first, marker.kind == "voice_call",
      let title = marker.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
    {
      return title
    }
    var spoken = ""
    for message in messages where message.role == "bot" && message.id != marker?.id {
      spoken = VoiceChatCard.speech(message.blocks).trimmingCharacters(in: .whitespacesAndNewlines)
      if !spoken.isEmpty { break }
    }
    guard !spoken.isEmpty else { return "" }
    let sentence: String
    if let end = spoken.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
      sentence = String(spoken[..<spoken.index(after: end.lowerBound)])
    } else {
      sentence = spoken
    }
    let limit = 120
    guard sentence.count > limit else { return sentence }
    let cut = String(sentence.prefix(limit - 1))
    return cut.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) + "…"
  }

  /// The connected time the caller recorded, else whole seconds between the first and last
  /// message.
  var duration: Int {
    if let marker = marker?.blocks.first, marker.kind == "voice_call",
      let seconds = marker.durationSeconds
    {
      return seconds
    }
    if let request = messages.first?.blocks.first, request.kind == "call_request",
      let seconds = request.durationSeconds
    {
      return seconds
    }
    guard let first = Clock.date(messages.first?.createdAt),
      let last = Clock.date(messages.last?.createdAt)
    else { return 0 }
    return max(0, Int(last.timeIntervalSince(first).rounded(.down)))
  }
}

/// A transcript row: a message on its own, or a voice chat's card.
enum VoiceChatRowItem: Identifiable {
  case message(Message)
  case voiceChat(VoiceChatGroup)
  var id: String {
    switch self {
    case .message(let message): message.id
    case .voiceChat(let group): group.key
    }
  }
  /// The row's first message, which the time separator above it reads.
  var first: Message? {
    switch self {
    case .message(let message): message
    case .voiceChat(let group): group.messages.first
    }
  }
}

/// One call's exchange, collapsed to a card; expanding it shows the transcript.
struct VoiceChatCard: View {
  let group: VoiceChatGroup
  @State private var open = false

  init(group: VoiceChatGroup) { self.group = group }

  var body: some View {
    HuggingColumn {
      Button {
        open.toggle()
      } label: {
        HStack(spacing: Layout.Space.small) {
          Image(systemName: "waveform").font(.system(size: 16)).foregroundStyle(.primary)
            .accessibilityHidden(true)
          Text("Voice chat").font(CardType.title).foregroundStyle(.primary)
          Text(Self.clock(group.duration)).font(CardType.caption).monospacedDigit()
            .foregroundStyle(.secondary)
          Spacer(minLength: 0)
          Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 16))
            .foregroundStyle(.secondary).padding(.leading, Layout.Space.small)
            .accessibilityHidden(true)
        }.padding(.horizontal, Layout.Space.medium).padding(.vertical, 9)
          .frame(minHeight: 40).contentShape(Rectangle())
      }.buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(open ? "Hide transcript" : "Show transcript")
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
      if open {
        transcript
      } else if !group.summary.isEmpty {
        Text(verbatim: group.summary).font(CardType.secondary).foregroundStyle(.secondary)
          .lineLimit(1).padding(.horizontal, Layout.Space.medium).padding(.bottom, 10)
      }
    }.background(Ink.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .frame(maxWidth: 576, alignment: .leading)
  }

  private var transcript: some View {
    VStack(alignment: .leading, spacing: 6) {
      // The marker is the card's summary line, never a transcript turn.
      ForEach(group.messages.filter { $0.id != group.marker?.id }) { message in
        let text = Self.speech(message.blocks).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
          if message.role == "user" {
            Text(verbatim: text).font(CardType.secondary).foregroundStyle(.secondary)
              .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .trailing)
          } else {
            Text(verbatim: text).font(CardType.secondary).foregroundStyle(.primary)
              .fixedSize(horizontal: false, vertical: true)
              .padding(.horizontal, 10).padding(.vertical, 7)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background(Ink.selection, in: RoundedRectangle(cornerRadius: 12))
          }
        }
      }
    }.padding(.horizontal, Layout.Space.medium).padding(.bottom, Layout.Space.medium)
  }

  static func clock(_ seconds: Int) -> String {
    "\(seconds / 60):" + String(format: "%02d", seconds % 60)
  }

  /// Collapses each run of consecutive call messages into one group: a user message carrying the
  /// call's id, or a bot reply to a run already in the group. Anything else ends the run, so a
  /// typed user message breaks the group even when it reuses the run of a call turn. The bot's
  /// `voice_call` marker closes the group, so the work it does after hanging up reads as chat.
  /// `callId` reads the message's call id (`Message.callId` from the server).
  static func groups(_ messages: [Message], callId: (Message) -> String?) -> [VoiceChatRowItem] {
    var items: [VoiceChatRowItem] = []
    var open: Int?
    var openRuns = Set<String>()
    var segments: [String: Int] = [:]
    func marks(_ message: Message) -> Bool {
      message.role == "bot" && message.blocks.first?.kind == "voice_call"
    }
    for message in messages {
      let call = callId(message)
      if let index = open, case .voiceChat(var group) = items[index] {
        let joinsByRun =
          message.role == "bot" && message.runId.map { openRuns.contains($0) } == true
        if call == group.callId || joinsByRun {
          group.messages.append(message)
          if marks(message) {
            group.marker = message
            items[index] = .voiceChat(group)
            open = nil
            continue
          }
          if call == group.callId, let run = message.runId,
            message.blocks.first?.kind != "call_request"
          {
            openRuns.insert(run)
          }
          items[index] = .voiceChat(group)
          continue
        }
        open = nil
      }
      if let call {
        let segment = (segments[call] ?? 0) + 1
        segments[call] = segment
        var group = VoiceChatGroup(
          key: segment == 1 ? "call:\(call)" : "call:\(call):\(segment)", callId: call,
          messages: [message])
        // A request belongs to the calling run, not to a spoken turn.
        openRuns = []
        if let run = message.runId, message.blocks.first?.kind != "call_request" {
          openRuns.insert(run)
        }
        if marks(message) {
          group.marker = message
          open = nil
        } else {
          open = items.count
        }
        items.append(.voiceChat(group))
        continue
      }
      items.append(.message(message))
    }
    return items
  }

  /// What a voice reads from a message: the bot's own words, never its tool activity.
  static func speech(_ blocks: [Message.Block]) -> String {
    blocks.map { block -> String in
      switch block.kind {
      case "steps": return ""
      case "progress": return block.activity == true ? "" : block.text ?? ""
      case "text", "meta", "ask", "computer": return block.text ?? ""
      case "cloud_agent":
        let prUrl = block.fields(CloudAgentSpeech.self)?.prUrl
        return "\(block.title ?? ""): \(block.status ?? "")" + (prUrl.map { " \($0)" } ?? "")
      case "subagent":
        let name = block.name ?? ""
        if block.status == "running" { return "\(name) is working on \(block.task ?? "")" }
        if block.status == "failed" { return "\(name) failed" }
        if let result = block.result, !result.isEmpty { return result }
        return "\(name) finished"
      case "card":
        return (block.lines ?? []).map { "\($0.k): \($0.v)" }.joined(separator: ". ")
      default: return ""
      }
    }.filter { !$0.isEmpty }.joined(separator: "\n")
  }
}

private struct CloudAgentSpeech: Decodable {
  var prUrl: String?
}

/// A column as wide as its widest row wants, up to the width it is offered, so the card hugs a
/// short exchange and its header's trailing chevron sits at the card's edge.
private struct HuggingColumn: SwiftUI.Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = width(proposal, subviews)
    let height = subviews.reduce(0) {
      $0 + $1.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    var y = bounds.minY
    for subview in subviews {
      let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
      subview.place(
        at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: height))
      y += height
    }
  }

  private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
    let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
    guard let limit = proposal.width else { return ideal }
    return min(limit, ideal)
  }
}
