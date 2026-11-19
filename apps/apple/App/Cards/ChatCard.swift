import SwiftUI

/// The mobile app's chat card: a filled, rounded surface no wider than 576 points.
struct ChatCard: ViewModifier {
  var padded = true
  func body(content: Content) -> some View {
    content.padding(.horizontal, padded ? Layout.Space.standard : 0)
      .padding(.vertical, padded ? 14 : 0)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Ink.fill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .frame(maxWidth: 576, alignment: .leading)
  }
}

extension View {
  func chatCard(padded: Bool = true) -> some View { modifier(ChatCard(padded: padded)) }
}

/// The mobile card's text sizes, on each platform's own scale.
enum CardType {
  static let title = TypeRole.message.weight(.medium)
  static let body = TypeRole.message
  static let secondary = TypeRole.summary
  #if os(macOS)
    static let caption = Font.system(size: 12)
    static let code = Font.system(size: 12, design: .monospaced)
  #else
    static let caption = Font.footnote
    static let code = Font.system(.footnote, design: .monospaced)
  #endif
}

/// A card's action, as the mobile app's action button: ink-filled for the choice that goes
/// ahead, outlined for the others.
struct CardButton: ButtonStyle {
  var primary = true
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(TypeRole.message.weight(.medium))
      .foregroundStyle(primary ? Ink.canvas : Color.primary)
      .padding(.horizontal, 16).frame(minHeight: Layout.pointer + 4)
      .background(primary ? Color.primary : Ink.canvas, in: Capsule())
      .overlay { if !primary { Capsule().strokeBorder(Ink.line) } }
      .opacity(configuration.isPressed ? 0.75 : enabled ? 1 : 0.5).contentShape(Capsule())
  }
}
