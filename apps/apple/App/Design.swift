import SwiftUI

enum Layout {
  enum Space {
    static let hair: CGFloat = 2, tight: CGFloat = 4, small: CGFloat = 8
    static let medium: CGFloat = 12, standard: CGFloat = 16, roomy: CGFloat = 24,
      large: CGFloat = 32
  }
  enum Radius {
    static let control: CGFloat = 10, row: CGFloat = 14, panel: CGFloat = 16
    static let bubble: CGFloat = 20, composer: CGFloat = 14
  }
  static let touch: CGFloat = 44, pointer: CGFloat = 32
  static let bubbleInsetX: CGFloat = 14, bubbleInsetY: CGFloat = 9
  static let sidebar: CGFloat = 304, sidebarMin: CGFloat = 238, sidebarMax: CGFloat = 420
  static let inspector: CGFloat = 328, readingWidth: CGFloat = 584
  static let profileSheetMaxHeight: CGFloat = 680
  static let rowAvatar: CGFloat = 40, headerHeight: CGFloat = 60
  static let compactWidth: CGFloat = 680, inspectorWidth: CGFloat = 1180
  static let motion: Animation = .smooth(duration: 0.22)
}

enum TypeRole {
  #if os(macOS)
    static let message = Font.system(size: 15), rowTitle = Font.system(size: 15, weight: .semibold)
    static let summary = Font.system(size: 13), timestamp = Font.system(size: 11)
  #else
    static let message = Font.body, rowTitle = Font.body.weight(.semibold)
    static let summary = Font.subheadline, timestamp = Font.caption
  #endif
}

enum Ink {
  static let neutralOutgoing = PlatformColor.pair(0x1C1C1C, 0x3E3E3E)
  static let neutralOutgoingText = PlatformColor.pair(0xFFFFFF, 0xF5F5F5)
  static let action = PlatformColor.pair(0xA3400F, 0xFF944D)
  static let canvas = PlatformColor.canvas
  static let rail = PlatformColor.rail
  static let panelSurface = PlatformColor.pair(0xFFFFFF, 0x28282A)
  static let panelField = PlatformColor.pair(0xF2F2F2, 0x323235)
  static let fill = adaptive(0.947, 0.15)
  static let selection = adaptive(0.895, 0.21)
  static let line = adaptive(0.875, 0.24)
  static let orange = Color(red: 0.88, green: 0.43, blue: 0.125)
  static func adaptive(_ light: CGFloat, _ dark: CGFloat) -> Color {
    PlatformColor.gray(light, dark)
  }
}
extension Chat {
  var seed: Int { abs(Int(id.utf16.reduce(Int32(0)) { ($0 &* 31) &+ Int32($1) })) }
  var hex: UInt32 { ConversationAccent(self).avatar }
  var tint: Color { Color(rgb: hex) }
}

extension Color {
  init(rgb hex: UInt32) {
    self.init(
      .sRGB,
      red: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255,
      blue: Double(hex & 255) / 255)
  }
}

struct OutgoingColors {
  let fill, text: Color

  init(chat: Chat, contrast: ColorSchemeContrast) {
    let rgb = ConversationAccent(chat).bubbleRGB(increasedContrast: contrast == .increased)
    fill = rgb.map(Color.init(rgb:)) ?? Ink.neutralOutgoing
    text = rgb == nil ? Ink.neutralOutgoingText : .white
  }
}

struct FloatingPanel: ViewModifier {
  let compact: Bool
  @Environment(\.colorScheme) private var scheme
  func body(content: Content) -> some View {
    let shape = RoundedRectangle(
      cornerRadius: compact ? 0 : Layout.Radius.panel, style: .continuous)
    content.background(compact ? Ink.canvas : Ink.panelSurface, in: shape).clipShape(shape)
      .overlay {
        if !compact { shape.strokeBorder(Ink.line, lineWidth: 0.75).allowsHitTesting(false) }
      }
      .shadow(color: .black.opacity(compact ? 0 : scheme == .dark ? 0.32 : 0.12), radius: 7, y: 2)
  }
}
struct Avatar: View {
  let chat: Chat
  var size: CGFloat = 36
  var pose: BotPose = .idle
  var composing = false
  var activityMark = false
  var body: some View {
    Group {
      if chat.isGroup {
        Image(systemName: "person.2.fill").resizable().scaledToFit().padding(size * 0.19)
          .foregroundStyle(.secondary).background(
            Ink.selection, in: RoundedRectangle(cornerRadius: size / 3))
      } else if !activityMark, let value = chat.color, value.hasPrefix("data:image/") {
        if let encoded = value.split(separator: ",", maxSplits: 1).last,
          let data = Data(base64Encoded: String(encoded)), let photo = Image(platformData: data)
        {
          photo.resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
        } else {
          Circle().fill(Ink.fill)
        }
      } else {
        BotCharacter(
          chat: chat, size: size, pose: pose, composing: composing,
          interactive: activityMark && chat.color?.hasPrefix("data:image/") != true)
      }
    }.frame(width: size, height: size).accessibilityHidden(!activityMark)
  }
}
struct Glyph: View {
  let icon: String
  let label: String
  var size: CGFloat = Layout.pointer
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: icon).font(.system(size: size >= Layout.touch ? 19 : 16)).frame(
        width: size, height: size
      ).contentShape(Rectangle())
    }.buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(label)
      .accessibilityShowsLargeContentViewer { Label(label, systemImage: icon) }.help(label)
  }
}
struct Notice: View {
  var symbol: String
  var title: String
  var detail: String? = nil
  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol).font(.system(size: 19)).frame(width: 38, height: 38).background(
        Ink.fill, in: RoundedRectangle(cornerRadius: 11))
      Text(title).font(.headline)
      if let detail {
        Text(detail).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
      }
    }.padding(20).frame(maxWidth: .infinity)
  }
}
struct Problem: View {
  var text: String
  var body: some View {
    Label(text, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red)
      .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
  }
}
