import SwiftUI

/// Confirms deleting a bot, naming the group chats that go with it, then deletes it.
struct DeleteBotConfirmation: ViewModifier {
  @ObservedObject var store: WorkspaceStore
  @Binding var target: Chat?
  var deleted: () -> Void = {}
  @State private var groups: [String] = []

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        "Delete \(target?.name ?? "")?",
        isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
        titleVisibility: .visible, presenting: target
      ) { chat in
        Button("Delete", role: .destructive) {
          Task {
            do {
              try await store.delete(chat)
              deleted()
            } catch { store.error = error.localizedDescription }
          }
        }.accessibilityIdentifier("confirmDeleteBot")
      } message: { _ in
        if groups.isEmpty {
          Text("Its conversation, files and routines are permanently deleted.")
        } else {
          Text(
            "Its conversation, files and routines are permanently deleted, and so are these group chats: \(groups.joined(separator: ", "))."
          )
        }
      }
      .task(id: target?.id) {
        if let chat = target { groups = await store.removedGroups(chat) } else { groups = [] }
      }
  }
}

extension View {
  func deleteBotConfirmation(
    store: WorkspaceStore, target: Binding<Chat?>, deleted: @escaping () -> Void = {}
  ) -> some View {
    modifier(DeleteBotConfirmation(store: store, target: target, deleted: deleted))
  }
}
