import SwiftUI

/// What the chat cards don't draw: content this version can't read yet, opened on the web, and
/// the sample workspace's computer access review.
struct AgentBlock: View {
  let block: Message.Block, message: Message, chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void, report: (String) -> Void
  @State private var reviewingHost = false
  private var review: Bool { block.actions?.first?.id == "sample-host-review" }
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        Image(systemName: review ? "questionmark.bubble" : "square.on.square")
          .foregroundStyle(Ink.action).accessibilityHidden(true)
        Text(review ? "Question" : "Unsupported content").font(.subheadline.weight(.semibold))
      }
      if review {
        if let text = block.text { MessageText(content: text).equatable() }
        if block.status == "answered" {
          Label(block.answer ?? "Answered", systemImage: "checkmark.circle").font(.caption)
        } else {
          Button("Review computer access…", systemImage: "lock.shield") { reviewingHost = true }
            .buttonStyle(.bordered)
        }
      } else if let url = store.link(chat) {
        Link(destination: url) {
          Label("Open in Rakazo", systemImage: "arrow.up.right.square").font(.callout)
        }
      }
    }.padding(12).background(Ink.canvas, in: RoundedRectangle(cornerRadius: Layout.Radius.control))
      .overlay { RoundedRectangle(cornerRadius: Layout.Radius.control).strokeBorder(Ink.line) }
      .tint(Ink.action)
      .rakazoSheet(
        isPresented: $reviewingHost,
        onDismiss: {
          Task { do { try await refresh() } catch { report(error.localizedDescription) } }
        }
      ) {
        SampleHostReview(store: store, bot: chat.id, requestID: message.id)
      }
  }
}
