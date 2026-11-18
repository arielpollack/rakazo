#if os(macOS)
  import AppKit
  import SwiftUI

  struct PassageReader: NSViewRepresentable {
    let text: String
    @Binding var selection: String

    final class Coordinator: NSObject, NSTextViewDelegate {
      var selection: Binding<String>
      init(_ selection: Binding<String>) { self.selection = selection }
      func textViewDidChangeSelection(_ notification: Notification) {
        guard let reader = notification.object as? NSTextView,
          let range = Range(reader.selectedRange(), in: reader.string)
        else { return }
        selection.wrappedValue = reader.string[range].trimmingCharacters(
          in: .whitespacesAndNewlines)
      }
    }
    func makeCoordinator() -> Coordinator { Coordinator($selection) }
    func makeNSView(context: Context) -> NSScrollView {
      let scroll = NSTextView.scrollableTextView()
      guard let reader = scroll.documentView as? NSTextView else { return scroll }
      reader.isEditable = false
      reader.isSelectable = true
      reader.isRichText = false
      reader.drawsBackground = false
      scroll.drawsBackground = false
      reader.font = .preferredFont(forTextStyle: .body)
      reader.textColor = .labelColor
      reader.setAccessibilityLabel("Message text")
      reader.setAccessibilityIdentifier("passage-reader")
      reader.string = text
      reader.delegate = context.coordinator
      return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
      if let reader = scroll.documentView as? NSTextView, reader.string != text {
        reader.string = text
      }
    }
  }
#endif
