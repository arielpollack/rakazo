#if os(iOS)
  import SwiftUI

  struct PassageReader: UIViewRepresentable {
    let text: String
    @Binding var selection: String
    final class Coordinator: NSObject, UITextViewDelegate {
      var selection: Binding<String>
      init(_ selection: Binding<String>) { self.selection = selection }
      func textViewDidChangeSelection(_ textView: UITextView) {
        let range = textView.selectedTextRange
        selection.wrappedValue = (range.flatMap { textView.text(in: $0) } ?? "").trimmingCharacters(
          in: .whitespacesAndNewlines)
      }
    }
    func makeCoordinator() -> Coordinator { Coordinator($selection) }
    func makeUIView(context: Context) -> UITextView {
      let reader = UITextView()
      reader.isEditable = false
      reader.isSelectable = true
      reader.delegate = context.coordinator
      reader.textContainerInset = .zero
      reader.textContainer.lineFragmentPadding = 0
      reader.font = .preferredFont(forTextStyle: .body)
      reader.adjustsFontForContentSizeCategory = true
      reader.textColor = .label
      reader.backgroundColor = .clear
      reader.accessibilityLabel = "Message text"
      return reader
    }
    func updateUIView(_ reader: UITextView, context: Context) {
      if reader.text != text { reader.text = text }
    }
  }
#endif
