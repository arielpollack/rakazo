import SwiftUI

struct ChatActivityRows: View {
  let turns: [LiveBotTurn], chat: Chat, bots: [Chat]
  @Environment(\.accessibilityReduceMotion) private var reducedMotion
  @Environment(\.scenePhase) private var phase

  private func bot(for turn: LiveBotTurn) -> Chat? {
    if !chat.isGroup { return chat.id == turn.botID ? chat : nil }
    if let bot = bots.first(where: { $0.id == turn.botID }) { return bot }
    guard let member = chat.members?.first(where: { $0.botId == turn.botID }),
      let name = member.name
    else { return nil }
    return Chat(id: turn.botID, name: name, color: member.color, avatarSet: member.avatarSet)
  }

  var body: some View {
    ForEach(turns.filter { $0.working && !$0.text.isEmpty }) { turn in
      HStack(alignment: .top, spacing: Layout.Space.small) {
        if turn.composing, let bot = bot(for: turn) {
          Avatar(
            chat: bot, size: 28, pose: turn.pose, composing: true,
            activityMark: bot.color?.hasPrefix("data:image/") != true)
        }
        MessageText(content: turn.text).equatable().font(TypeRole.message)
          .padding(.horizontal, Layout.bubbleInsetX).padding(.vertical, Layout.bubbleInsetY)
          .background(Ink.fill, in: RoundedRectangle(cornerRadius: Layout.Radius.bubble))
      }.frame(maxWidth: Layout.readingWidth, alignment: .leading).frame(
        maxWidth: .infinity, alignment: .leading)
    }
    let busy = turns.filter { $0.working && !$0.composing && bot(for: $0) != nil }
    if let first = busy.first {
      if busy.count > 1, !reducedMotion, phase == .active {
        TimelineView(.periodic(from: .now, by: 2)) { tick in
          mark(busy[Int(tick.date.timeIntervalSinceReferenceDate / 2) % busy.count])
        }
      } else {
        mark(first)
      }
    }
  }

  @ViewBuilder private func mark(_ turn: LiveBotTurn) -> some View {
    if let bot = bot(for: turn) {
      HStack(spacing: Layout.Space.small) {
        Avatar(chat: bot, size: 28, pose: turn.pose, activityMark: true).id(bot.id)
        Text(turn.caption).font(.subheadline).foregroundStyle(.secondary)
      }.padding(.vertical, Layout.Space.tight).frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain).accessibilityLabel("\(bot.name), \(turn.caption)")
    }
  }
}
