import SwiftUI

/// A payment's order as read from the page: every value is page text, none of it checked.
struct AskReceipt: Decodable {
  struct Item: Decodable {
    let name: String
    let amount: String
  }
  /// Order lines the card leaves out; `atLeast` when the page may list even more.
  struct More: Decodable {
    let count: Int
    let atLeast: Bool
  }
  /// The pay button's label.
  var button: String?
  let items: [Item]
  var more: More?
  /// What is paid: the amount the button names, or else the page's total.
  var amount: String?
  /// `button` or `page`.
  let amountSource: String
  /// The page's total beside a button that names its own amount.
  var total: String?

  /// The receipt on an ask block, if it has one.
  static func of(_ block: Message.Block) -> AskReceipt? {
    block.fields(Holder.self)?.receipt
  }
  private struct Holder: Decodable { let receipt: AskReceipt? }

  /// The page's lines, leaving out any the page named like one of the card's own rows
  /// (`labels`), so merchant text never reads as the card's.
  static func lines(_ items: [Item], excluding labels: [String]) -> [Item] {
    let own = labels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
      .filter { !$0.isEmpty }
    return items.filter { item in
      let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      // "Total" and "Total due" pose as the card's row; "Totally Oats" doesn't.
      return !own.contains { label in
        guard name.hasPrefix(label) else { return false }
        guard let next = name.dropFirst(label.count).unicodeScalars.first else { return true }
        switch next.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
          .decimalNumber, .letterNumber, .otherNumber:
          return false
        default: return true
        }
      }
    }
  }
}

/// A payment's order as the page shows it: its lines, then what is paid, then where it came from.
struct AskReceiptView: View {
  let receipt: AskReceipt
  @Environment(\.displayScale) private var displayScale

  var body: some View {
    let items = AskReceipt.lines(receipt.items, excluding: ["Total", "On the button"])
    let lines = !items.isEmpty || receipt.more != nil || receipt.total != nil
    VStack(alignment: .leading, spacing: 10) {
      if lines {
        VStack(alignment: .leading, spacing: Layout.Space.tight) {
          // Page lines can repeat, so their place is their identity.
          ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            row(item.name, item.amount)
          }
          if let more = receipt.more {
            Text(verbatim: "\(more.count)\(more.atLeast ? "+" : "") more")
              .font(CardType.secondary).foregroundStyle(.secondary)
          }
          if let total = receipt.total { row("Total", total) }
        }.padding(.bottom, 10).frame(maxWidth: .infinity, alignment: .leading)
          .overlay(alignment: .bottom) {
            Rectangle().fill(Ink.line).frame(height: 1 / displayScale)
          }
      }
      if let amount = receipt.amount {
        row(receipt.amountSource == "button" ? "On the button" : "Total", amount, strong: true)
      }
      Text(
        receipt.button.map { "Button “\($0)” · read from the page, not checked" }
          ?? "Read from the page, not checked"
      ).font(CardType.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }.padding(.top, 10).textSelection(.enabled)
  }

  private func row(_ name: String, _ amount: String, strong: Bool = false) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(verbatim: name).fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: Layout.Space.standard)
      Text(verbatim: amount).monospacedDigit().layoutPriority(1)
    }.font(strong ? CardType.secondary.weight(.medium) : CardType.secondary)
      .foregroundStyle(.primary)
  }
}
