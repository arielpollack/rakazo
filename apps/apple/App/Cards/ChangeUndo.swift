import SwiftUI

/// Instructions or settings a bot changed from chat, which the user can undo, as the mobile app
/// shows it: a line saying what changed and an Undo button.
struct ChangeUndo: View {
  let block: Message.Block
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void
  let report: (String) -> Void
  @State private var restored = false
  @State private var pending = false

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

  /// Instructions or settings a bot changed from chat, which the user can undo.
  static func applies(to block: Message.Block) -> Bool {
    guard block.kind == "ask" else { return false }
    if block.settingsUpdate != nil { return true }
    return block.fields(Fields.self)?.instructionUpdate?.undoVersionId?.isEmpty == false
  }

  var body: some View {
    HStack(spacing: Layout.Space.small) {
      Text(block.instructionUpdate != nil ? "Instructions updated" : "Settings updated")
        .font(CardType.secondary).foregroundStyle(.primary)
      Button(restored ? "Restored" : "Undo", action: undo).buttonStyle(PlainCompact())
        .disabled(pending || restored || store.client == nil)
    }
  }

  private func undo() {
    guard !pending, !restored, let api = store.client, let fields = block.fields(Fields.self)
    else { return }
    pending = true
    Task {
      defer { pending = false }
      do {
        if let update = fields.instructionUpdate, let version = update.undoVersionId,
          !version.isEmpty
        {
          let _: Empty = try await api.rpc(
            "bots/restoreInstructions",
            [
              "botId": update.botId, "versionId": version, "expectedInstructions": update.after,
              "undo": true,
            ])
        } else if let update = fields.settingsUpdate {
          let body: [String: Any] = ["botId": update.botId]
            .merging(update.before.mapValues(\.foundation)) { $1 }
            .merging(["expectedSettings": update.after.mapValues(\.foundation)]) { $1 }
          let _: Empty = try await api.rpc("bots/update", body)
        } else {
          return
        }
        restored = true
        try await refresh()
      } catch { report(error.localizedDescription) }
    }
  }

  private struct Fields: Decodable {
    struct InstructionUpdate: Decodable {
      let botId: String
      let after: String
      let undoVersionId: String?
    }
    /// Undo writes `before` back while `after` still holds.
    struct SettingsUpdate: Decodable {
      let botId: String
      let before: [String: JSONValue]
      let after: [String: JSONValue]
    }
    let instructionUpdate: InstructionUpdate?
    let settingsUpdate: SettingsUpdate?
  }

  /// The mobile app's plain, compact action: a label with no fill.
  private struct PlainCompact: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
      configuration.label.font(CardType.caption).foregroundStyle(.primary)
        .padding(.horizontal, 6).padding(.vertical, 6)
        .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
        .contentShape(Rectangle())
    }
  }
}
