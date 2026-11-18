#if os(iOS)
  import SwiftUI
  import UIKit

  struct CommandQuery: UIViewRepresentable {
    @Binding var text: String
    let move: (Int) -> Void, accept: () -> Void, digit: (Int) -> Void, close: () -> Void
    final class Field: UITextField, UITextFieldDelegate {
      var config: CommandQuery?
      override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, !isFirstResponder else { return }
        var ancestor: UIResponder? = next
        while let responder = ancestor {
          if let owner = responder as? UIViewController,
            let transition = owner.transitionCoordinator,
            transition.animate(
              alongsideTransition: nil,
              completion: { [weak self] context in
                if !context.isCancelled, self?.window != nil { self?.becomeFirstResponder() }
              })
          {
            return
          }
          ancestor = responder.next
        }
        if !becomeFirstResponder() {
          DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder() }
        }
      }
      override var keyCommands: [UIKeyCommand]? {
        let keys =
          [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputEscape, "k"]
          + (1...9).map(String.init)
        return keys.map { input in
          let command = UIKeyCommand(
            input: input, modifierFlags: (input == "k" || Int(input) != nil) ? .command : [],
            action: #selector(handle(_:)))
          command.wantsPriorityOverSystemBehavior = true
          return command
        }
      }
      override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(handle(_:)) { return config != nil && markedTextRange == nil }
        return super.canPerformAction(action, withSender: sender)
      }
      override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard markedTextRange == nil, let key = presses.first?.key,
          key.modifierFlags.intersection([.command, .alternate, .control, .shift]).isEmpty
        else {
          super.pressesBegan(presses, with: event)
          return
        }
        switch key.keyCode {
        case .keyboardEscape: config?.close()
        case .keyboardUpArrow: config?.move(-1)
        case .keyboardDownArrow: config?.move(1)
        default: super.pressesBegan(presses, with: event)
        }
      }
      @objc private func handle(_ key: UIKeyCommand) {
        switch key.input {
        case UIKeyCommand.inputUpArrow: config?.move(-1)
        case UIKeyCommand.inputDownArrow: config?.move(1)
        case UIKeyCommand.inputEscape, "k": config?.close()
        default: if let index = Int(key.input ?? "") { config?.digit(index - 1) }
        }
      }
      override func accessibilityPerformEscape() -> Bool {
        config?.close()
        return true
      }
      @objc func edited() { config?.text = text ?? "" }
      func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        config?.accept()
        return false
      }
    }
    func makeUIView(context: Context) -> Field {
      let field = Field()
      field.placeholder = "Search chats, pages, and actions"
      field.accessibilityIdentifier = "command-query"
      field.font = .preferredFont(forTextStyle: .body)
      field.adjustsFontForContentSizeCategory = true
      field.autocapitalizationType = .none
      field.autocorrectionType = .no
      field.returnKeyType = .go
      field.clearButtonMode = .whileEditing
      field.delegate = field
      field.addTarget(field, action: #selector(Field.edited), for: .editingChanged)
      field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      return field
    }
    func updateUIView(_ field: Field, context: Context) {
      field.config = self
      if field.text != text { field.text = text }
    }
  }
#endif
