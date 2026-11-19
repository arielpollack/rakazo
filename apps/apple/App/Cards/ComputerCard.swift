import ImageIO
import SwiftUI

/// A bot's request to use its computer, drawn as the mobile app draws it. While it waits it shows
/// the screen and the answers; once settled it folds to one line that opens to show what was asked.
struct ComputerCard: View {
  let block: Message.Block
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var phase
  @Environment(\.displayScale) private var displayScale
  @State private var expanded = false
  @State private var preview: CGImage?
  @State private var previewShown: String?
  @State private var previewReads = 0
  /// An answer that went through stays busy until the card settles, so it cannot be sent twice.
  @State private var releasing = false
  @State private var showingScreen = false

  private struct Preview: Decodable { let image: String? }

  private var pending: Bool { block.state == "Needs you" }
  private var label: String { block.state ?? "" }
  private var open: Bool { pending || expanded }
  private var bot: String? { message.botId ?? (chat.isGroup ? nil : chat.id) }
  private var botChat: Chat? {
    chat.isGroup ? store.navigation?.current.bots.first { $0.id == message.botId } : chat
  }
  /// The demo opens its sample screen; a workspace opens the bot in Rakazo.
  private var canOpen: Bool {
    store.demo ? botChat != nil : botChat.flatMap { store.link($0) } != nil
  }
  /// The demo answers only the request its sample computer is still waiting on.
  private var answerable: Bool {
    guard store.demo else { return true }
    guard let bot, let run = message.runId else { return false }
    return store.sample?.computers?[bot]?.pendingRun == run && store.sampleLeases[bot] == nil
  }
  private var previewKey: String? {
    guard pending, store.client != nil, let bot, let run = message.runId else { return nil }
    return bot + "/" + run
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if pending {
        header
      } else {
        Button {
          expanded.toggle()
        } label: {
          header.contentShape(Rectangle())
        }.buttonStyle(.plain)
      }
      if open {
        Text(verbatim: label).font(CardType.title).padding(.top, 12)
        if let text = block.text, !text.isEmpty {
          MessageText(content: text).equatable().font(CardType.body).padding(.top, 2)
        }
        if pending, let preview { screen(preview) }
        if bot != nil { actions.padding(.top, 12) }
      }
    }.chatCard()
      .task(id: "\(previewKey ?? "")#\(previewReads)") { await loadPreview() }
      .onChange(of: phase) { _, state in if state == .active { previewReads += 1 } }
      .onChange(of: block.state) { releasing = false }
      .sheet(isPresented: $showingScreen) {
        if let botChat {
          SampleScreen(store: store, chat: botChat, requestedRun: pending ? message.runId : nil)
        }
      }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Image(systemName: "laptopcomputer").font(.system(size: 16)).foregroundStyle(.secondary)
        .frame(width: 28, height: 28)
        .background(Ink.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
      Text("Computer").font(CardType.title).fixedSize()
      if !open {
        Text(verbatim: "\(label) · \(block.text ?? "")").font(CardType.caption)
          .foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
    }
  }

  /// A still of the bot's screen while the card waits.
  private func screen(_ image: CGImage) -> some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    return Color.clear.aspectRatio(16 / 10, contentMode: .fit).frame(maxWidth: .infinity)
      .overlay { Image(decorative: image, scale: 1).resizable().scaledToFit() }
      .background(Ink.canvas).clipShape(shape)
      .overlay { shape.strokeBorder(Ink.line, lineWidth: 1 / displayScale) }
      .contentShape(shape).onTapGesture { if canOpen { openScreen() } }
      .accessibilityHidden(true).padding(.top, 12)
  }

  /// The answers, right-aligned, wrapping onto a second line when they don't fit one.
  private var actions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        Spacer(minLength: 0)
        answers
        openButton
      }
      VStack(alignment: .trailing, spacing: 8) {
        HStack(spacing: 8) { answers }
        openButton
      }.frame(maxWidth: .infinity, alignment: .trailing)
    }
  }

  @ViewBuilder private var answers: some View {
    if pending, message.runId != nil {
      answer("Skip", .skipped)
      answer("I’m done", .done)
    }
  }

  @ViewBuilder private var openButton: some View {
    if canOpen {
      Button("Open computer", action: openScreen).buttonStyle(CardButton(primary: pending))
        .fixedSize().disabled(pending && releasing)
    }
  }

  private func answer(_ title: LocalizedStringKey, _ reason: TakeoverAnswer) -> some View {
    Button {
      release(reason)
    } label: {
      if releasing {
        ProgressView().controlSize(.small).accessibilityLabel(Text(title))
      } else {
        Text(title)
      }
    }.buttonStyle(CardButton(primary: false)).fixedSize().disabled(releasing || !answerable)
  }

  private func openScreen() {
    if store.demo {
      showingScreen = true
    } else if let link = botChat.flatMap({ store.link($0) }) {
      openURL(link)
    }
  }

  private func release(_ reason: TakeoverAnswer) {
    guard !releasing, answerable, let bot, let run = message.runId else { return }
    releasing = true
    Task {
      do {
        if let api = store.client {
          let _: Empty = try await api.rpc(
            "computer/release",
            ["botId": bot, "runId": run, "reason": reason.rawValue.lowercased()])
        } else if !store.answerScreenRequest(bot: bot, run: run, answer: reason) {
          throw Failure("This request is no longer waiting.")
        }
      } catch {
        releasing = false
        report(error.localizedDescription)
        return
      }
      do { try await refresh() } catch { report(error.localizedDescription) }
    }
  }

  /// Reads the still again when the app comes back; a card that moves to another run or stops
  /// waiting never keeps the earlier screen.
  private func loadPreview() async {
    let key = previewKey
    if previewShown != key {
      preview = nil
      previewShown = key
    }
    guard key != nil, let api = store.client, let bot, let run = message.runId,
      let reply: Preview = try? await api.rpc("computer/preview", ["botId": bot, "runId": run]),
      !Task.isCancelled
    else { return }
    preview = Self.decode(reply.image)
  }

  private static func decode(_ value: String?) -> CGImage? {
    guard let value, value.utf8.count <= 4_000_000, let split = value.firstIndex(of: ","),
      ["data:image/png;base64", "data:image/jpeg;base64", "data:image/webp;base64"].contains(
        String(value[..<split])),
      let bytes = Data(base64Encoded: String(value[value.index(after: split)...])),
      let source = CGImageSourceCreateWithData(bytes as CFData, nil)
    else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(
      source, 0,
      [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: 1280,
      ] as CFDictionary)
  }
}
