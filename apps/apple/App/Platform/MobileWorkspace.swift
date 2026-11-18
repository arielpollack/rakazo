#if os(iOS)
  import SwiftUI

  struct MobileWorkspace<
    Sidebar: View, Detail: View, WorkspaceMenu: View, ComposeMenu: View, Inspector: View
  >: View {
    let width: CGFloat
    let compact: Bool, inlineInspector: Bool, hasProfile: Bool, sidebarVisible: Bool
    @Binding var phoneChat: Bool
    @ViewBuilder let sidebar: (Bool) -> Sidebar
    @ViewBuilder let detail: (Bool, Bool) -> Detail
    @ViewBuilder let workspaceMenu: () -> WorkspaceMenu
    @ViewBuilder let composeMenu: () -> ComposeMenu
    @ViewBuilder let profile: () -> Inspector
    @SceneStorage("workspace.sidebar.width") private var savedWidth = Double(Layout.sidebar)
    @GestureState private var dragOffset: CGFloat = 0
    @State private var overDivider = false
    @Environment(\.layoutDirection) private var direction
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      if compact {
        NavigationStack {
          sidebar(true).navigationTitle("Chats").inlineMobileTitle()
            .toolbar {
              ToolbarItem(placement: .principal) { workspaceMenu() }
              ToolbarItem(placement: .topBarTrailing) { composeMenu() }
            }
            .navigationDestination(isPresented: $phoneChat) {
              detail(true, false)
            }
        }
      } else {
        let showProfile = inlineInspector && hasProfile
        let maximum = min(
          Layout.sidebarMax, width - (showProfile ? Layout.inspector : 0) - 370)
        let base = bounded(CGFloat(savedWidth), maximum)
        HStack(spacing: 0) {
          if sidebarVisible {
            sidebar(false)
              .frame(width: bounded(base + dragOffset, maximum))
              .padding([.leading, .vertical], Layout.Space.small)
              .transition(.move(edge: .leading).combined(with: .opacity))
            resizeHandle(base: base, maximum: maximum)
          }
          detail(false, inlineInspector)
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).clipped()
          if showProfile {
            Divider()
            profile()
              .frame(width: Layout.inspector).background(Ink.canvas).transition(
                .move(edge: .trailing))
          }
        }.animation(
          reduceMotion ? nil : Layout.motion, value: sidebarVisible
        )
        .animation(reduceMotion ? nil : Layout.motion, value: showProfile)
      }
    }

    private func bounded(_ width: CGFloat, _ maximum: CGFloat) -> CGFloat {
      min(max(Layout.sidebarMin, width), max(Layout.sidebarMin, maximum))
    }
    private func resizeHandle(base: CGFloat, maximum: CGFloat) -> some View {
      let sign: CGFloat = direction == .rightToLeft ? -1 : 1
      return ZStack {
        Color.clear
        Capsule().fill(overDivider || dragOffset != 0 ? Color.secondary : Ink.line).frame(
          width: 2, height: 24)
      }.frame(width: 14).contentShape(Rectangle()).onHover { overDivider = $0 }
        .gesture(
          DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .updating($dragOffset) { value, state, transaction in
              transaction.animation = nil
              state = sign * value.translation.width
            }
            .onEnded { savedWidth = Double(bounded(base + sign * $0.translation.width, maximum)) }
        )
        .onTapGesture(count: 2) { savedWidth = Double(Layout.sidebar) }
        .accessibilityRepresentation {
          Slider(
            value: Binding(
              get: { Double(base) }, set: { savedWidth = Double(bounded($0, maximum)) }),
            in: Double(Layout.sidebarMin)...Double(maximum), step: 1
          ) {
            Text("Sidebar width")
          }.accessibilityIdentifier("sidebarWidth")
        }.help("Drag to resize the sidebar; double-click to reset")
    }
  }
#endif
