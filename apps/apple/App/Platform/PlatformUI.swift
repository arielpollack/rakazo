import SwiftUI

#if os(macOS)
  import AppKit
  private typealias NativeColor = NSColor
#else
  import UIKit
  private typealias NativeColor = UIColor
#endif

enum PlatformColor {
  #if os(macOS)
    static let canvas = Color(nsColor: .textBackgroundColor)
    static let rail = Color(nsColor: .controlBackgroundColor)
    static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
  #else
    static let canvas = Color(uiColor: .systemBackground)
    static let rail = Color(uiColor: .secondarySystemBackground)
    static let secondaryLabel = Color(uiColor: .secondaryLabel)
  #endif

  private static func adaptive(_ light: NativeColor, _ dark: NativeColor) -> Color {
    #if os(macOS)
      Color(
        nsColor: NSColor(name: nil) { appearance in
          appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    #else
      Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    #endif
  }

  static func pair(_ light: Int, _ dark: Int) -> Color {
    func rgb(_ hex: Int) -> NativeColor {
      NativeColor(
        red: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
        blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    return adaptive(rgb(light), rgb(dark))
  }

  static func gray(_ light: CGFloat, _ dark: CGFloat) -> Color {
    adaptive(NativeColor(white: light, alpha: 1), NativeColor(white: dark, alpha: 1))
  }
}

extension Image {
  init?(platformData: Data) {
    #if os(macOS)
      guard let image = NSImage(data: platformData) else { return nil }
      self.init(nsImage: image)
    #else
      guard let image = UIImage(data: platformData) else { return nil }
      self.init(uiImage: image)
    #endif
  }
}

@MainActor enum PlatformClipboard {
  @discardableResult static func copy(_ text: String) -> Bool {
    #if os(macOS)
      NSPasteboard.general.clearContents()
      return NSPasteboard.general.setString(text, forType: .string)
    #else
      UIPasteboard.general.string = text
      return true
    #endif
  }
}

extension View {
  func rakazoSheet<Sheet: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping () -> Sheet) -> some View {
    sheet(isPresented: isPresented, onDismiss: onDismiss) { content().allowsQuitFromSheet() }
  }

  func rakazoSheet<Item: Identifiable, Sheet: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
    @ViewBuilder content: @escaping (Item) -> Sheet) -> some View {
    sheet(item: item, onDismiss: onDismiss) { content($0).allowsQuitFromSheet() }
  }

  @ViewBuilder private func allowsQuitFromSheet() -> some View {
    #if os(macOS)
      if #available(macOS 15.4, *) { presentationPreventsAppTermination(false) }
      else { background(LegacySheetQuitPolicy()) }
    #else
      self
    #endif
  }

  @ViewBuilder func allowsQuitFromDialog() -> some View {
    #if os(macOS)
      if #available(macOS 15.4, *) { dialogPreventsAppTermination(false) } else { self }
    #else
      self
    #endif
  }

  @ViewBuilder func inlineMobileTitle() -> some View {
    #if os(iOS)
      navigationBarTitleDisplayMode(.inline)
    #else
      self
    #endif
  }
  @ViewBuilder func loginKeyboard(email: Bool) -> some View {
    #if os(iOS)
      keyboardType(email ? .emailAddress : .URL).textInputAutocapitalization(.never)
    #else
      self
    #endif
  }
}

#if os(macOS)
  private struct LegacySheetQuitPolicy: NSViewRepresentable {
    final class Probe: NSView {
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.preventsApplicationTerminationWhenModal = false
      }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {}
  }
#endif
