import SwiftUI
#if os(macOS)
  import AppKit
#endif

struct PrivateSpaceSheet: View {
  let store: PrivateSpaceOperations
  let listHeightLimit: CGFloat
  let close: () -> Void
  @StateObject var flow = PrivateSpaceFlow()
  @Environment(\.dismiss) private var dismiss
  @FocusState private var editingName: Bool
  @State private var submitting = false

  private var showingName: Bool {
    if case .loadingTools = flow.step { return flow.busy }
    return flow.enteringName
  }

  private var title: String {
    if showingName { return "New private space" }
    return switch flow.step {
    case .name: "New private space"
    case .choosing, .loadingTools: "What can this space use?"
    case .opening, .done: "Open space"
    }
  }
  private var actionTitle: String {
    switch flow.step {
    case .name: flow.busy ? "Creating…" : "Create space"
    case .loadingTools: flow.busy ? "Creating…" : "Retry"
    case .choosing: flow.busy ? "Saving…" : "Continue"
    case .opening, .done: flow.busy ? "Opening…" : "Open space"
    }
  }
  private var canClose: Bool { !flow.busy && (flow.enteringName || flow.issue != nil) }
  private var errorText: String? {
    if flow.enteringName, flow.nameTooLong { return "Use 60 characters or fewer." }
    return flow.issue
  }

  var body: some View {
    Group {
      #if os(macOS)
        VStack(alignment: .leading, spacing: 20) {
          HStack(spacing: Layout.Space.small) {
            if showingName {
              Image(systemName: "folder").overlay(alignment: .bottomTrailing) {
                Image(systemName: "lock.fill").font(.system(size: 9))
                  .background(.background, in: RoundedRectangle(cornerRadius: 2)).offset(x: 2, y: 2)
              }.foregroundStyle(.secondary).accessibilityHidden(true)
            }
            Text(title).accessibilityAddTraits(.isHeader)
          }.font(.system(size: 17, weight: .semibold))
          VStack(alignment: .leading, spacing: 6) {
            if showingName { nameField }
            if case .choosing(_, let items) = flow.step { macTools(items) }
            issue
          }
          HStack(spacing: Layout.Space.small) {
            Spacer()
            if showingName || canClose { cancelButton.keyboardShortcut(.cancelAction) }
            submitButton.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
          }.controlSize(.regular)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      #else
        NavigationStack {
          Form {
            if showingName { Section { nameField } }
            if case .choosing(_, let items) = flow.step {
              ForEach(items, id: \.key) { item in tool(item) }
            }
            if errorText != nil { Section { issue } }
          }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
              ToolbarItem(placement: .cancellationAction) {
                if showingName || canClose { cancelButton }
              }
              ToolbarItem(placement: .confirmationAction) { submitButton }
            }
        }
      #endif
    }.interactiveDismissDisabled(!canClose)
  }

  private var nameField: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Space name").font(.subheadline.weight(.medium)).accessibilityHidden(true)
      TextField("Space name", text: $flow.name, prompt: Text("e.g. Customer support"))
        .accessibilityIdentifier("newName").focused($editingName).disabled(flow.busy)
        .onAppear { editingName = true }
        .submitLabel(.done).onSubmit(submit)
        #if os(macOS)
          .textFieldStyle(.roundedBorder).controlSize(.large)
        #endif
    }
  }

  @ViewBuilder private var issue: some View {
    if let errorText {
      Label(errorText, systemImage: "exclamationmark.circle").font(.callout)
        .foregroundStyle(.red)
        #if os(macOS)
          .lineLimit(3).help(errorText)
        #endif
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("spaceIssue")
    }
  }

  private var cancelButton: some View {
    Button(showingName ? "Cancel" : "Close") { dismiss() }.disabled(!canClose)
  }
  private var submitButton: some View {
    Button(action: submit) {
      HStack(spacing: 6) {
        if flow.busy { ProgressView().controlSize(.small).accessibilityHidden(true) }
        Text(actionTitle)
      }
    }.disabled(flow.busy || (flow.enteringName && !flow.validName))
      .accessibilityIdentifier(flow.enteringName ? "createSubmit" : "spaceContinue")
  }

  private func submit() {
    guard !submitting, !flow.busy else { return }
    #if os(macOS)
      if editingName, let editor = NSApp.keyWindow?.firstResponder as? NSTextView,
        editor.hasMarkedText() { return }
    #endif
    submitting = true
    Task {
      let finished = await flow.advance(using: store)
      submitting = false
      if finished { close() }
    }
  }

  private func tool(_ item: SpaceTool) -> some View {
    let checked = Binding(get: { flow.selection.contains(item.key) }, set: { selected in
      if selected { flow.selection.insert(item.key) } else { flow.selection.remove(item.key) }
    })
    return Group {
      #if os(macOS)
        Toggle(isOn: checked) {
          Text(item.name).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
      #else
        Button { checked.wrappedValue.toggle() } label: {
          HStack {
            Text(item.name).foregroundStyle(.primary)
            Spacer()
            if checked.wrappedValue { Image(systemName: "checkmark").foregroundStyle(.tint) }
          }.frame(maxWidth: .infinity, minHeight: Layout.touch).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(checked.wrappedValue ? .isSelected : [])
      #endif
    }.disabled(flow.busy).accessibilityIdentifier("space-tool-\(item.kind)-\(item.id)")
  }

  #if os(macOS)
    @ViewBuilder private func macTools(_ items: [SpaceTool]) -> some View {
      let rowHeight: CGFloat = 32
      let content = LazyVStack(spacing: 0) {
        ForEach(items, id: \.key) { item in
          tool(item).toggleStyle(.checkbox).lineLimit(1).help(item.name).frame(height: rowHeight)
        }
      }.padding(.horizontal, 2)
      let height = CGFloat(items.count) * rowHeight
      if height > listHeightLimit {
        ScrollView { content }.frame(height: listHeightLimit)
      } else { content.frame(height: height) }
    }
  #endif
}

#if os(macOS)
  extension View {
    @ViewBuilder func fitPrivateSpaceSheet(_ enabled: Bool) -> some View {
      if #available(macOS 15, *), enabled { presentationSizing(.fitted) } else { self }
    }
  }
#endif
