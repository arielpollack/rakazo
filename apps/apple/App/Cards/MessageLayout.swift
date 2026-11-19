import SwiftUI

/// Which card draws each part of a message, in the mobile app's order (`MessageBubbleBody` and
/// `MessageBubbleContent`).
extension Bubble {
  /// Blocks drawn as their own card between the message's text pieces.
  static func ownCard(_ block: Message.Block) -> Bool {
    ["subagent", "child_bot", "cloud_agent", "page", "app", "tool_question"].contains(block.kind)
  }
  /// An ask answered in its own card: a question or secret with no answers to pick.
  static func askInput(_ block: Message.Block) -> Bool {
    block.kind == "ask" && !AskCard.isApproval(block) && (block.actions ?? []).isEmpty
      && !ChangeUndo.applies(to: block)
  }
  /// Blocks the text bubble shows.
  static func inBubble(_ block: Message.Block) -> Bool {
    block.isNarration || ["image", "file", "card", "chart"].contains(block.kind)
  }

  /// The message split around its own cards, as the mobile app splits it.
  var pieces: [[Message.Block]] {
    message.blocks.filter(\.visible).reduce(into: []) { pieces, block in
      if Self.ownCard(block) || pieces.last.map({ Self.ownCard($0[0]) }) ?? true {
        pieces.append([block])
      } else {
        pieces[pieces.count - 1].append(block)
      }
    }
  }

  /// A line across the chat instead of a bubble: a handoff, a message to or from another bot,
  /// or a message from a connected channel.
  var centered: Bool {
    let blocks = message.blocks
    return !blocks.contains(where: ChangeUndo.applies) && !blocks.contains(where: Self.askInput)
      && blocks.contains {
        ["handoff", "bot_message_sent", "bot_message_received", "channel_message"].contains($0.kind)
      }
  }

  @ViewBuilder func piece(_ blocks: [Message.Block], first: Bool) -> some View {
    let block = blocks[0]
    switch block.kind {
    case "subagent", "child_bot", "cloud_agent":
      SpecialMessageCard(
        block: block, message: message, chat: chat, store: store, refresh: reload, report: report)
    case "page":
      PageCard(
        block: block, message: message, chat: chat, store: store, refresh: reload, report: report,
        newest: newestPages)
    case "tool_question":
      ToolQuestionCard(
        block: block, message: message, chat: chat, store: store, refresh: reload, report: report)
    case "app":
      McpAppCard(
        block: block, message: message, chat: chat, store: store, refresh: reload, report: report)
    default:
      content(blocks, first: first)
    }
  }

  @ViewBuilder func content(_ blocks: [Message.Block], first: Bool) -> some View {
    let connects = blocks.filter { $0.kind == "app_connect" }
    let approvals = blocks.filter { $0.kind == "mcp_approval" }
    if let undo = blocks.first(where: ChangeUndo.applies) {
      ChangeUndo(
        block: undo, message: message, chat: chat, store: store, refresh: reload, report: report)
    } else if let ask = blocks.first(where: Self.askInput) {
      VStack(alignment: .leading, spacing: Layout.Space.small) {
        AskInputCard(
          block: ask, message: message, chat: chat, store: store, refresh: reload, report: report)
        inlineCards(connects + approvals)
      }
    } else if !connects.isEmpty || !approvals.isEmpty,
      connects.count + approvals.count == blocks.count
    {
      inlineCards(connects + approvals)
    } else if let ask = blocks.first(where: { $0.kind == "ask" && $0.actions?.isEmpty == false }) {
      VStack(alignment: .leading, spacing: Layout.Space.small) {
        if store.demo, ask.actions?.first?.id == "sample-host-review" {
          AgentBlock(
            block: ask, message: message, chat: chat, store: store, refresh: reload,
            report: report)
        } else if ask.fields(OutgoingDraftMarker.self) != nil {
          OutgoingDraftCard(
            block: ask, message: message, chat: chat, store: store, refresh: reload,
            report: report)
        } else {
          AskCard(
            block: ask, message: message, chat: chat, store: store, refresh: reload,
            report: report)
        }
        inlineCards(connects + approvals)
      }.contextMenu { menuItems }
    } else if blocks.contains(where: { ["image", "file"].contains($0.kind) }) {
      VStack(alignment: mine ? .trailing : .leading, spacing: Layout.Space.small) {
        surfaces(blocks.filter(Self.inBubble), first: first)
        inlineCards(connects + approvals)
      }
    } else {
      VStack(alignment: mine ? .trailing : .leading, spacing: Layout.Space.small) {
        surfaces(blocks.filter(Self.inBubble), first: first)
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
          switch block.kind {
          case "choice":
            ChoiceCard(
              block: block, message: message, chat: chat, store: store, refresh: reload,
              report: report)
          case "computer":
            ComputerCard(
              block: block, message: message, chat: chat, store: store, refresh: reload,
              report: report)
          case "import_setup":
            ImportSetupCard(
              block: block, message: message, chat: chat, store: store, refresh: reload,
              report: report)
          case "app_connect", "mcp_approval":
            inlineCards([block])
          case "unsupported_content":
            // Content this version can't read yet: say so and open it on the web.
            AgentBlock(
              block: block, message: message, chat: chat, store: store, refresh: reload,
              report: report)
          default:
            EmptyView()
          }
        }
      }
    }
  }

  @ViewBuilder func inlineCards(_ blocks: [Message.Block]) -> some View {
    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
      if block.kind == "app_connect" {
        AppConnectCard(
          block: block, message: message, chat: chat, store: store, refresh: reload,
          report: report)
      } else {
        McpApprovalCard(
          block: block, message: message, chat: chat, store: store, refresh: reload,
          report: report)
      }
    }
  }

  /// The message's text and attachments, in bubbles: neighboring text shares one.
  @ViewBuilder func surfaces(_ blocks: [Message.Block], first: Bool) -> some View {
    let groups = blocks.reduce(into: [[Message.Block]]()) { groups, block in
      if block.isNarration || block.kind == "chart", groups.last?.last.map(Self.joinsText) == true {
        groups[groups.count - 1].append(block)
      } else {
        groups.append([block])
      }
    }
    ForEach(Array(groups.enumerated()), id: \.offset) { index, segment in
      surface(segment, quoting: first && index == 0)
    }
  }
  private static func joinsText(_ block: Message.Block) -> Bool {
    block.isNarration || block.kind == "chart"
  }

  @ViewBuilder func surface(_ segment: [Message.Block], quoting: Bool) -> some View {
    let surface = mine || segment.first.map(Self.joinsText) == true
    VStack(alignment: .leading, spacing: 6) {
      if quoting, let quoted = message.replyQuote ?? message.replyPreview?.text {
        Text(verbatim: quoted).lineLimit(2).font(.caption).padding(7).background(
          .black.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
      }
      ForEach(Array(segment.enumerated()), id: \.offset) { _, block in
        if block.isNarration {
          MessageText(content: block.label).equatable()
        } else if block.kind == "chart" {
          Text(verbatim: "[chart: \(block.name ?? "chart")]")
        } else if ["file", "image"].contains(block.kind) {
          AttachmentBlock(block: block, chat: chat, api: store.client)
        } else if block.kind == "card", let pairs = block.lines {
          VStack(alignment: .leading, spacing: Layout.Space.small) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
              VStack(alignment: .leading, spacing: Layout.Space.tight) {
                Text(pair.k).font(.caption.weight(.semibold))
                Text(pair.v).textSelection(.enabled)
              }.accessibilityElement(children: .combine)
            }
          }
        }
      }
    }.font(TypeRole.message).padding(.horizontal, surface ? Layout.bubbleInsetX : 0).padding(
      .vertical, surface ? Layout.bubbleInsetY : 0
    ).foregroundStyle(mine ? outgoingColors.text : Color.primary)
      .tint(mine ? outgoingColors.text : nil).background(
        mine ? outgoingColors.fill : surface ? Ink.fill : .clear,
        in: RoundedRectangle(cornerRadius: Layout.Radius.bubble, style: .continuous)
      )
      #if os(iOS)
        .simultaneousGesture(
          TapGesture(count: 2).onEnded {
            if reactions["👍"] == nil { react("👍") }
          },
          including: canReact && !waitingForUser
            && message.blocks.allSatisfy {
              ["text", "image", "file", "chart", "page"].contains($0.kind)
            } ? .all : .subviews)
      #endif
      .contextMenu {
        menuItems
        if canReact { Menu("React", systemImage: "face.smiling") { emojiButtons } }
      }
  }

  /// The handoff, peer or channel line.
  @ViewBuilder var centeredLine: some View {
    let blocks = message.blocks
    Group {
      if let handoff = blocks.first(where: { $0.kind == "handoff" }) {
        AgentEventLabel(
          label:
            "\(botName(handoff.fromBotId) ?? "bot") messaged \(botName(handoff.toBotId) ?? "bot")",
          detail: handoff.text)
      } else if let peer = blocks.first(where: {
        $0.kind == "bot_message_sent" || $0.kind == "bot_message_received"
      }) {
        let sent = peer.kind == "bot_message_sent"
        let id = sent ? peer.toBotId : peer.fromBotId
        PeerReceiptLine(
          peer: id.flatMap(botChat),
          name: peerExchange?.peerBotName ?? (sent ? peer.toBotName : peer.fromBotName) ?? "Bot",
          count: peerExchange?.count ?? 1, sent: sent)
      } else if let channel = blocks.first(where: { $0.kind == "channel_message" }) {
        VStack(spacing: 2) {
          Text(channel.providerLabel).font(.system(size: 12))
          Text(verbatim: "\(channel.fromLabel ?? ""): \(channel.text ?? "")").font(
            .system(size: 13.5))
        }.foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.vertical, 4)
      }
    }.frame(maxWidth: .infinity).contentShape(Rectangle()).contextMenu { menuItems }
  }

  /// A bot's name as the workspace or a group lists it.
  func botName(_ id: String?) -> String? { id.flatMap(botChat)?.name }
  func botChat(_ id: String) -> Chat? {
    if let bot = store.navigation?.current.bots.first(where: { $0.id == id }) { return bot }
    for group in store.navigation?.current.groups ?? [] {
      if let member = group.members?.first(where: { $0.botId == id }) {
        return Chat(
          id: id, name: member.name ?? id, color: member.color, avatarSet: member.avatarSet)
      }
    }
    return nil
  }
}

/// Present only on an ask that carries an outgoing draft.
private struct OutgoingDraftMarker: Decodable { let outgoingDraft: JSONValue }

/// "Alex messaged Sam", with what was said behind a tap.
struct AgentEventLabel: View {
  let label: String
  let detail: String?
  @State private var expanded = false
  var body: some View {
    Button {
      expanded.toggle()
    } label: {
      VStack(spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: "arrow.left.arrow.right").font(.system(size: 12))
          Text(label).font(.system(size: 13.5))
        }.foregroundStyle(.secondary)
        if expanded, let detail {
          MessageText(content: detail).equatable().frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Ink.fill, in: RoundedRectangle(cornerRadius: 14))
        }
      }.padding(.vertical, 4).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel(expanded ? "Hide \(label)" : "Show \(label)")
  }
}

/// "Messaged Sam", "Message from Sam" or "3 messages with Sam", with Sam's avatar before the
/// name.
struct PeerReceiptLine: View {
  let peer: Chat?
  let name: String
  let count: Int
  let sent: Bool
  private var label: String {
    count > 1
      ? "\(count) messages with \(name)" : sent ? "Messaged \(name)" : "Message from \(name)"
  }
  var body: some View {
    let split = label.range(of: name, options: .backwards)
    HStack(spacing: 4) {
      if let split, split.lowerBound > label.startIndex {
        Text(label[..<split.lowerBound].trimmingCharacters(in: .whitespaces))
      }
      if let peer {
        Avatar(chat: peer, size: 16)
      } else {
        Image(systemName: "person.crop.circle").font(.system(size: 14))
      }
      if split != nil { Text(verbatim: name).fontWeight(.medium).lineLimit(1) }
      if let split, split.upperBound < label.endIndex {
        Text(label[split.upperBound...].trimmingCharacters(in: .whitespaces))
      }
      if split == nil { Text(label) }
    }.font(.system(size: 13)).foregroundStyle(.secondary).padding(.vertical, 4)
      .accessibilityElement(children: .ignore).accessibilityLabel(label)
  }
}
