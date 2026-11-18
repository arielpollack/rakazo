#if os(macOS)
  import SwiftUI

  struct MacWorkspace<Sidebar: View, Detail: View, Inspector: View>: View {
    @Binding var sidebarVisible: Bool
    @Binding var inspectorVisible: Bool
    let overlaysChat: Bool
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var profile: () -> Inspector
    @SceneStorage("workspace.sidebar.width") private var savedWidth = Double(Layout.sidebar)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      GeometryReader { geometry in
        let inset = Layout.Space.medium
        let maximum = min(
          Layout.sidebarMax, geometry.size.width - (overlaysChat ? 100 : 360) - 2 * inset)
        let width = min(
          max(CGFloat(savedWidth), Layout.sidebarMin), max(Layout.sidebarMin, maximum))
        let presented = overlaysChat && sidebarVisible
        ZStack(alignment: .leading) {
          detail().frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, sidebarVisible && !overlaysChat ? width + 2 * inset : 0)
            .accessibilityHidden(presented).disabled(presented)
          if presented {
            Button {
              sidebarVisible = false
            } label: {
              Color.black.opacity(0.09).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("Dismiss chats").keyboardShortcut(
              .cancelAction)
          }
          if sidebarVisible {
            HStack(spacing: 0) {
              sidebar().frame(width: width)
              SidebarGrip(
                width: width, maximum: max(Layout.sidebarMin, maximum), saved: $savedWidth
              )
              .frame(width: inset)
            }.padding(.leading, inset).padding(.vertical, inset)
              .transition(.move(edge: .leading).combined(with: .opacity))
          }
        }.background(Ink.canvas.ignoresSafeArea())
          .animation(reduceMotion ? nil : Layout.motion, value: sidebarVisible)
      }.inspector(isPresented: $inspectorVisible) {
        profile().inspectorColumnWidth(Layout.inspector)
      }
    }
  }

  private struct SidebarGrip: NSViewRepresentable {
    let width, maximum: CGFloat
    @Binding var saved: Double
    @Environment(\.layoutDirection) private var direction

    func makeNSView(context: Context) -> Grip { Grip() }
    func updateNSView(_ view: Grip, context: Context) {
      view.width = width
      view.sign = direction == .rightToLeft ? -1 : 1
      view.setWidth = { saved = min(max($0, Layout.sidebarMin), maximum) }
      view.setAccessibilityValue(width)
      view.setAccessibilityMinValue(Layout.sidebarMin)
      view.setAccessibilityMaxValue(maximum)
    }

    final class Grip: NSView {
      var width: CGFloat = 0, sign: CGFloat = 1
      var setWidth: (CGFloat) -> Void = { _ in }
      private var start: (x: CGFloat, width: CGFloat)?
      override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.splitter)
        setAccessibilityOrientation(.vertical)
        setAccessibilityLabel("Sidebar width")
        setAccessibilityIdentifier("sidebarWidth")
        toolTip = "Drag to resize the sidebar; double-click to reset"
      }
      required init?(coder: NSCoder) { nil }
      override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
      override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
          start = nil
          setWidth(Layout.sidebar)
          return
        }
        start = (event.locationInWindow.x, width)
      }
      override func mouseDragged(with event: NSEvent) {
        if let start { setWidth(start.width + sign * (event.locationInWindow.x - start.x)) }
      }
      override func mouseUp(with event: NSEvent) { start = nil }
      override func accessibilityPerformIncrement() -> Bool {
        setWidth(width + 16)
        return true
      }
      override func accessibilityPerformDecrement() -> Bool {
        setWidth(width - 16)
        return true
      }
    }
  }
#endif
