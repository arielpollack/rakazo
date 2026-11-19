#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacChatHoverRegion: NSViewRepresentable {
  let changed: (Bool) -> Void

  final class Region: NSView {
    var changed: ((Bool) -> Void)?
    override init(frame: NSRect) {
      super.init(frame: frame)
      clipsToBounds = true
      addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
        owner: self, userInfo: nil))
      setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func mouseEntered(with event: NSEvent) { changed?(true) }
    override func mouseExited(with event: NSEvent) { changed?(false) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
  }
  func makeNSView(context: Context) -> Region { Region(frame: .zero) }
  func updateNSView(_ view: Region, context: Context) { view.changed = changed }
}

struct MacChatActionLayout: SwiftUI.Layout {
  let outgoing: Bool
  let maxContentWidth: CGFloat
  private let gap: CGFloat = 4

  private func measure(_ proposal: ProposedViewSize, _ items: Subviews) -> (CGSize, CGSize) {
    let rail = items[1].sizeThatFits(.unspecified)
    let available = max(1, min(maxContentWidth, (proposal.width ?? .infinity) - rail.width - gap))
    // Asked at the width it may take: text hugs its words, a card fills the column.
    let contentWidth = min(available, items[0].sizeThatFits(.init(width: available, height: nil)).width)
    return (items[0].sizeThatFits(.init(width: contentWidth, height: nil)), rail)
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let (content, rail) = measure(proposal, subviews)
    return CGSize(width: content.width + gap + rail.width, height: max(content.height, rail.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let (content, rail) = measure(proposal, subviews)
    subviews[0].place(at: CGPoint(x: bounds.minX + (outgoing ? rail.width + gap : 0), y: bounds.midY),
      anchor: .leading, proposal: .init(content))
    subviews[1].place(at: CGPoint(x: bounds.minX + (outgoing ? 0 : content.width + gap),
      y: bounds.midY), anchor: .leading, proposal: .init(rail))
  }
}

struct MacChatButtonStyle: ButtonStyle {
  @State private var hovered = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .foregroundStyle(hovered || configuration.isPressed ? Color.primary : .secondary)
      .background(Color.primary.opacity(configuration.isPressed ? 0.16 : hovered ? 0.08 : 0),
        in: RoundedRectangle(cornerRadius: 7))
      .contentShape(Rectangle()).background { MacChatHoverRegion { hovered = $0 } }
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
  }
}

struct MacFileDropCue: View {
  let name: String
  var body: some View {
    HStack(spacing: Layout.Space.medium) {
      Image(systemName: "tray.and.arrow.down").font(.title2.weight(.medium)).foregroundStyle(Color.accentColor)
      VStack(alignment: .leading, spacing: 2) {
        Text("Release to attach").font(.headline)
        Text("Attach to \(name)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer(minLength: 0)
    }.padding(.horizontal, Layout.Space.medium).frame(height: 54)
      .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
      .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 1.5) }
      .accessibilityElement(children: .combine).accessibilityIdentifier("file-drop-cue")
  }
}

struct MacAttachmentToken: View {
  let file: Upload
  let remove: () -> Void

  private var symbol: String {
    guard let type = UTType(mimeType: file.mime) else { return "doc" }
    switch type {
    case .commaSeparatedText: return "tablecells"
    case _ where type.conforms(to: .spreadsheet): return "tablecells"
    case _ where type.conforms(to: .image): return "photo"
    case _ where type.conforms(to: .audiovisualContent): return type.conforms(to: .audio) ? "waveform" : "film"
    case _ where type.conforms(to: .archive): return "doc.zipper"
    case _ where type.conforms(to: .text) || type == .pdf: return "doc.text"
    default: return "doc"
    }
  }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(.secondary)
        .frame(width: 18).accessibilityHidden(true)
      Text(verbatim: file.name).font(TypeRole.summary.weight(.medium)).lineLimit(1).truncationMode(.middle)
        .frame(maxWidth: 216, alignment: .leading).fixedSize(horizontal: true, vertical: false)
      Button(action: remove) {
        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 28)
      }.buttonStyle(MacChatButtonStyle()).accessibilityLabel("Remove \(file.name)").help("Remove attachment")
    }.padding(.leading, 9).padding(.trailing, 4).frame(height: 40).fixedSize()
      .background(Ink.panelSurface, in: RoundedRectangle(cornerRadius: 8))
      .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.line).allowsHitTesting(false) }
      .help("\(file.name) · \(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))")
  }
}

struct MacChatEditor: NSViewRepresentable {
  @Binding var text: String
  let label: String
  let focusRequest: Int
  let submit: () -> Void
  let canDrop: Bool
  let highlight: (Bool) -> Void
  let attach: ([URL]) -> Bool

  final class Editor: NSTextView, NSTextViewDelegate {
    var actions: MacChatEditor?

    func textDidChange(_ notification: Notification) { actions?.text = string }
    override func keyDown(with event: NSEvent) {
      let modifiers = event.modifierFlags.intersection([.shift, .option, .control, .command])
      if !hasMarkedText(), [36, 76].contains(event.keyCode), modifiers.isEmpty || modifiers == .command {
        actions?.submit(); return
      }
      if !hasMarkedText(), event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
        if modifiers.isEmpty { window?.selectNextKeyView(self) } else { window?.selectPreviousKeyView(self) }
        return
      }
      super.keyDown(with: event)
    }

    private func hasFiles(_ drag: NSDraggingInfo) -> Bool { drag.draggingPasteboard.types?.contains(.fileURL) == true }
    private func updateDrop() -> NSDragOperation {
      let allowed = actions?.canDrop == true
      actions?.highlight(allowed)
      return allowed ? .copy : []
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
      hasFiles(sender) ? updateDrop() : super.draggingEntered(sender)
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
      hasFiles(sender) ? updateDrop() : super.draggingUpdated(sender)
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
      if let sender, hasFiles(sender) { actions?.highlight(false) } else { super.draggingExited(sender) }
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
      hasFiles(sender) ? actions?.canDrop == true : super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
      guard hasFiles(sender) else { return super.performDragOperation(sender) }
      actions?.highlight(false)
      guard actions?.canDrop == true, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
      return actions?.attach(urls) == true
    }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
      if let sender, hasFiles(sender) { actions?.highlight(false) } else { super.concludeDragOperation(sender) }
    }
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView(), editor = Editor(frame: .zero)
    scroll.drawsBackground = false
    editor.drawsBackground = false; editor.isRichText = false; editor.allowsUndo = true
    editor.font = .systemFont(ofSize: 15); editor.textColor = .textColor
    editor.textContainerInset = .zero; editor.textContainer?.lineFragmentPadding = 0
    editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false
    editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
    editor.delegate = editor; editor.setAccessibilityIdentifier("composer")
    scroll.documentView = editor
    editor.registerForDraggedTypes([.fileURL])
    return scroll
  }

  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let editor = scroll.documentView as? Editor else { return }
    let request = editor.actions?.focusRequest ?? focusRequest
    editor.actions = self; editor.isEditable = context.environment.isEnabled
    editor.setAccessibilityLabel(label); editor.setAccessibilityPlaceholderValue(label)
    if editor.string != text, !editor.hasMarkedText() { editor.string = text }
    if request != focusRequest { DispatchQueue.main.async { [weak editor] in
      guard let editor else { return }; editor.window?.makeFirstResponder(editor)
    } }
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
    guard let width = proposal.width, width.isFinite else { return nil }
    let font = NSFont.systemFont(ofSize: 15), line = ceil(font.ascender - font.descender + font.leading)
    let rect = (text + "\u{200B}" as NSString).boundingRect(with: CGSize(width: max(width, 1), height: line * 6),
      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
    return CGSize(width: width, height: min(line * 6, max(line, ceil(rect.height))))
  }
}

struct MacChatFileDrop: DropDelegate {
  @Binding var targeted: Bool
  let enabled: Bool
  let receive: ([NSItemProvider]) -> Bool

  func validateDrop(info: DropInfo) -> Bool { enabled && info.hasItemsConforming(to: [.fileURL]) }
  func dropEntered(info: DropInfo) { targeted = validateDrop(info: info) }
  func dropExited(info: DropInfo) { targeted = false }
  func dropUpdated(info: DropInfo) -> DropProposal? {
    DropProposal(operation: validateDrop(info: info) ? .copy : .forbidden)
  }
  func performDrop(info: DropInfo) -> Bool {
    targeted = false
    return validateDrop(info: info) && receive(info.itemProviders(for: [.fileURL]))
  }

  @MainActor static func stage(_ providers: [NSItemProvider], in attachments: ChatAttachments,
    limits: ChatAttachments.Limits) -> Bool {
    let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
    return attachments.stage(count: files.count, limits: limits) { finish in
      let group = DispatchGroup()
      var results = Array<ChatAttachments.Source?>(repeating: nil, count: files.count)
      for (index, provider) in files.enumerated() {
        group.enter()
        provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
          let result: ChatAttachments.Source
          if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
            result = .success(url)
          } else {
            result = .failure(error ?? Failure("Couldn’t read the dropped file. Choose it again to retry."))
          }
          DispatchQueue.main.async { results[index] = result; group.leave() }
        }
      }
      group.notify(queue: .main) { finish(results.compactMap { $0 }) }
    }
  }
}
#endif
