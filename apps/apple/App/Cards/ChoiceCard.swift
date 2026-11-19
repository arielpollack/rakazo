import SwiftUI

/// A question with lettered options, as the mobile app's choice card draws it: the question and
/// its subtitle, a dismiss button, then the options; once answered, only the picked one stays.
struct ChoiceCard: View {
  static let dismissed = "_dismissed"
  let block: Message.Block
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void
  /// Shows the outcome before the thread delivers the updated block.
  @State private var localAnswerId: String?
  @State private var busy = false

  init(
    block: Message.Block, message: Message, chat: Chat, store: WorkspaceStore,
    refresh: @escaping () async throws -> Void, report: @escaping (String) -> Void
  ) {
    self.block = block
    self.message = message
    self.chat = chat
    self.store = store
    self.refresh = refresh
    self.report = report
  }

  private var answerId: String? { block.answerId ?? localAnswerId }
  private var botId: String? { message.botId ?? (chat.isGroup ? nil : chat.id) }
  private var readOnly: Bool { botId == nil }
  /// All options until answered, then only the picked one.
  private var options: [Message.Block.Option] {
    let all = block.options ?? []
    guard let answerId else { return all }
    return all.filter { $0.id == answerId }
  }

  var body: some View {
    if answerId != Self.dismissed {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .top, spacing: Layout.Space.small) {
          VStack(alignment: .leading, spacing: Layout.Space.hair) {
            Text(verbatim: block.question?.text ?? "").font(CardType.title)
              .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
              .accessibilityAddTraits(.isHeader)
            if let subtitle = block.subtitle, !subtitle.isEmpty {
              Text(verbatim: subtitle).font(CardType.secondary).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
          if !readOnly && answerId == nil { dismissButton }
        }
        VStack(spacing: Layout.Space.small) {
          ForEach(options, id: \.id) { option in optionRow(option) }
        }
      }.chatCard().frame(maxWidth: 340, alignment: .leading)
    }
  }

  private var dismissButton: some View {
    Button {
      submit(Self.dismissed)
    } label: {
      Image(systemName: "xmark").font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary).frame(width: 30, height: 30)
        .background(Ink.selection, in: Circle())
        // A small button still gets the 44-point tap target.
        .contentShape(Rectangle().inset(by: -7))
    }.buttonStyle(.plain).disabled(busy).opacity(busy ? 0.45 : 1)
      .accessibilityLabel("Dismiss")
  }

  private func optionRow(_ option: Message.Block.Option) -> some View {
    let chosen = option.id == answerId
    return Button {
      submit(option.id)
    } label: {
      HStack(spacing: Layout.Space.medium) {
        Text(verbatim: option.letter).font(CardType.caption.weight(.medium))
          .foregroundStyle(.secondary).frame(width: 24, height: 24)
          .background(Ink.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        Text(verbatim: option.label).font(CardType.secondary)
          .foregroundStyle(chosen ? .secondary : .primary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
        if chosen {
          Image(systemName: "checkmark").font(.system(size: 15)).foregroundStyle(.secondary)
        }
      }
    }.buttonStyle(OptionStyle(chosen: chosen)).disabled(readOnly || busy || chosen)
      .opacity(busy ? 0.6 : 1)
      .accessibilityLabel(option.label)
      .accessibilityAddTraits(chosen ? .isSelected : [])
  }

  private func submit(_ optionId: String) {
    guard !readOnly, answerId == nil, !busy, let botId else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        if let api = store.client {
          // Dismissing records the server's dismissed answer id, so both outcomes share this path.
          if optionId == Self.dismissed {
            let _: Empty = try await api.rpc("onboarding/dismissFocus", ["botId": botId])
          } else {
            let _: Empty = try await api.rpc(
              "onboarding/choose", ["botId": botId, "optionId": optionId])
          }
        } else if var sample = store.sample, var items = sample.transcripts[chat.id],
          let index = items.firstIndex(where: { $0.id == message.id }),
          let slot = items[index].blocks.firstIndex(where: {
            $0.kind == "choice" && $0.answerId == nil && $0.question?.text == block.question?.text
          })
        {
          items[index].blocks[slot].answerId = optionId
          sample.transcripts[chat.id] = items
          store.sample = sample
        } else {
          return
        }
        localAnswerId = optionId
        try await refresh()
      } catch { report(error.localizedDescription) }
    }
  }

  /// An option row: the page color, filled while pressed or once picked.
  private struct OptionStyle: ButtonStyle {
    let chosen: Bool
    func makeBody(configuration: Configuration) -> some View {
      configuration.label.padding(.horizontal, 14).padding(.vertical, Layout.Space.medium)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(
          configuration.isPressed || chosen ? Ink.selection : Ink.canvas,
          in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
  }
}
