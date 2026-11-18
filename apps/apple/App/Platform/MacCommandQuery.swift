#if os(macOS)
  import AppKit
  import SwiftUI

  struct CommandQuery: NSViewRepresentable {
    @Binding var text: String
    let move: (Int) -> Void, accept: () -> Void, digit: (Int) -> Void, close: () -> Void

    final class Field: NSTextField, NSTextFieldDelegate {
      var actions: CommandQuery?
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
          guard let self, let window, self.window === window else { return }
          window.makeFirstResponder(self)
        }
      }
      func controlTextDidChange(_ notification: Notification) { actions?.text = stringValue }
      func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector)
        -> Bool
      {
        guard !textView.hasMarkedText(), let actions else { return false }
        switch command {
        case #selector(NSResponder.moveUp(_:)): actions.move(-1)
        case #selector(NSResponder.moveDown(_:)): actions.move(1)
        case #selector(NSResponder.insertNewline(_:)): actions.accept()
        case #selector(NSResponder.cancelOperation(_:)): actions.close()
        default: return false
        }
        return true
      }
      override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
          let editor = currentEditor() as? NSTextView, !editor.hasMarkedText(), let actions
        {
          if event.charactersIgnoringModifiers == "k" {
            actions.close()
            return true
          }
          if let digit = Int(event.charactersIgnoringModifiers ?? ""), (1...9).contains(digit) {
            actions.digit(digit - 1)
            return true
          }
        }
        return super.performKeyEquivalent(with: event)
      }
    }
    func makeNSView(context: Context) -> Field {
      let field = Field()
      field.placeholderString = "Search chats, pages, and actions"
      field.isBordered = false
      field.drawsBackground = false
      field.focusRingType = .none
      field.font = .preferredFont(forTextStyle: .body)
      field.delegate = field
      field.setAccessibilityIdentifier("command-query")
      field.setAccessibilityLabel("Search chats, pages, and actions")
      field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      return field
    }
    func updateNSView(_ field: Field, context: Context) {
      field.actions = self
      if field.stringValue != text { field.stringValue = text }
    }
  }
#endif
