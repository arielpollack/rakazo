import SwiftUI
import UniformTypeIdentifiers

struct MessageSelection: View {
  let text: String
  let reply: (String?) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var excerpt = ""
  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 12) {
        Text("Select a passage to copy it or quote it in your reply.").font(.callout)
          .foregroundStyle(.secondary)
        PassageReader(text: text, selection: $excerpt)
          #if os(macOS)
          .frame(minWidth: 380, idealWidth: 460, minHeight: 180, idealHeight: 260)
          #endif
        if excerpt.utf16.count > 2000 {
          Text("Select a shorter passage (up to 2,000 characters).").font(.caption).foregroundStyle(
            .secondary)
        }
      }.padding().navigationTitle("Select text").inlineMobileTitle()
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Quote selection") {
              dismiss()
              reply(excerpt)
            }.disabled(excerpt.isEmpty || excerpt.utf16.count > 2000)
          }
        }
    }
  }
}

struct MessageText: View, Equatable {
  let content: String
  private enum Section {
    case prose(String)
    case code(String, String)
  }
  private var sections: [Section] {
    guard content.contains("```"), content.utf8.count <= 100_000 else { return [.prose(content)] }
    var result = [Section]()
    var buffer = [String]()
    var language: String?
    func flush() {
      guard !buffer.isEmpty else { return }
      let text = buffer.joined(separator: "\n")
      result.append(language.map { .code($0, text) } ?? .prose(text))
      buffer = []
    }
    for line in content.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```"), language == nil || trimmed == "```" {
        flush()
        language = language == nil ? String(trimmed.dropFirst(3).prefix(32)) : nil
      } else {
        buffer.append(line)
      }
    }
    flush()
    return result
  }
  var body: some View {
    VStack(alignment: .leading, spacing: Layout.Space.small) {
      ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
        switch section {
        case .prose(let text):
          if text.utf8.count <= 32_768 {
            Text(
              (try? AttributedString(
                markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(text)
            ).lineSpacing(3).textSelection(.enabled)
          } else {
            Text(verbatim: text).textSelection(.enabled)
          }
        case .code(let language, let source):
          VStack(alignment: .leading, spacing: Layout.Space.small) {
            HStack {
              Text(language.isEmpty ? "Code" : language).font(.caption.bold())
              Spacer()
              Button {
                PlatformClipboard.copy(source)
              } label: {
                Image(systemName: "doc.on.doc")
              }.buttonStyle(.borderless).accessibilityLabel("Copy code").help("Copy code")
            }
            ScrollView(.horizontal) {
              Text(verbatim: source).font(.system(.footnote, design: .monospaced)).fixedSize(
                horizontal: true, vertical: false
              ).textSelection(.enabled)
            }
          }.padding(Layout.Space.medium).background(
            .primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Layout.Radius.control))
        }
      }
    }.environment(
      \.openURL,
      OpenURLAction { url in
        guard let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme)
        else { return .discarded }
        return .systemAction
      })
  }
}

struct AttachmentBlock: View {
  let block: Message.Block
  let chat: Chat
  let api: Client?
  @State private var export: LocalFile?
  @State private var presenting = false
  @State private var loading = false
  @State private var error: String?
  private let limit = 24_000_000
  private var filename: String {
    let last = ((block.name ?? "Attachment") as NSString).lastPathComponent
    return last.isEmpty || last.hasPrefix(".") ? "Attachment" : last
  }
  private var contentType: UTType {
    block.mimeType.flatMap { UTType(mimeType: $0) } ?? UTType(
      filenameExtension: (filename as NSString).pathExtension) ?? .data
  }
  var body: some View {
    VStack(alignment: .leading, spacing: Layout.Space.small) {
      Label(filename, systemImage: block.kind == "image" ? "photo" : "doc").font(.headline)
      if let size = block.size {
        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)).font(
          .caption)
      }
      if let api, let id = block.artifactId {
        Button {
          Task {
            loading = true
            defer { loading = false }
            do {
              guard (block.size ?? 0) <= limit else {
                throw Failure("This file is larger than the 24 MB native download limit.")
              }
              let bytes = try await api.file(id, chat: chat, limit: limit)
              export = LocalFile(bytes: bytes)
              presenting = true
            } catch { self.error = error.localizedDescription }
          }
        } label: {
          HStack {
            if loading { ProgressView().controlSize(.small) }
            Label("Save to Files…", systemImage: "square.and.arrow.down")
          }
        }.buttonStyle(.bordered).disabled(loading)
      }
    }.fileExporter(
      isPresented: $presenting, document: export, contentType: contentType,
      defaultFilename: filename
    ) { result in
      export = nil
      if case .failure(let failure) = result, (failure as NSError).code != NSUserCancelledError {
        error = failure.localizedDescription
      }
    }
    .onChange(of: presenting) { _, shown in if !shown { export = nil } }
    .alert(
      "Attachment unavailable",
      isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })
    ) {
      Button("OK") { error = nil }
    } message: {
      Text(error ?? "")
    }.allowsQuitFromDialog()
  }
  private struct LocalFile: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
      guard let bytes = configuration.file.regularFileContents else {
        throw CocoaError(.fileReadCorruptFile)
      }
      self.bytes = bytes
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
      FileWrapper(regularFileWithContents: bytes)
    }
  }
}
