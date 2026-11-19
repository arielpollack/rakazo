import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor final class ChatAttachments: ObservableObject {
  typealias Source = Result<URL, Error>

  struct Limits {
    let count: Int
    let bytes: Int

    init(account: Account?) {
      count = min(account?.maxAttachmentsPerMessage ?? 4, 100)
      bytes = min(account?.maxUploadSizeBytes ?? 10 * 1024 * 1024, 24_000_000)
    }
  }

  @Published private(set) var files: [Upload] = []
  @Published private(set) var reading = false
  @Published var problem: String?
  private var receipt: UUID?
  private var task: Task<Void, Never>?

  private nonisolated static let mimeTypes = [
    "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "webp": "image/webp",
    "gif": "image/gif", "heic": "image/heic", "heif": "image/heif", "pdf": "application/pdf",
    "txt": "text/plain", "md": "text/markdown", "csv": "text/csv", "html": "text/html",
    "json": "application/json", "xls": "application/vnd.ms-excel",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg", "m4a": "audio/mp4",
    "mp4": "video/mp4", "mov": "video/quicktime", "3gp": "video/3gpp",
    "zip": "application/zip", "rar": "application/vnd.rar", "7z": "application/x-7z-compressed",
  ]
  nonisolated static var pickerTypes: [UTType] {
    Array(Set(mimeTypes.keys.compactMap { UTType(filenameExtension: $0) })).sorted {
      $0.identifier < $1.identifier
    }
  }

  @discardableResult func stage(
    count: Int, limits: Limits, resolve: (@escaping @MainActor ([Source]) -> Void) -> Void
  ) -> Bool {
    guard !reading, count > 0 else { return false }
    guard count <= limits.count - files.count else {
      problem = "Attach up to \(limits.count) files per message."
      return false
    }
    let request = UUID()
    receipt = request
    reading = true
    problem = nil
    let remaining = 24_000_000 - files.reduce(0) { $0 + $1.data.count }
    resolve { [weak self] sources in
      guard let self, receipt == request else { return }
      self.task = Task {
        let batch = await Self.read(sources, limit: limits.bytes, remaining: remaining)
        guard !Task.isCancelled, self.receipt == request else { return }
        self.files += batch.files
        self.problem = batch.errors.isEmpty ? nil : batch.errors.joined(separator: "\n")
        self.receipt = nil
        self.reading = false
        self.task = nil
      }
    }
    return true
  }

  func cancelRead() {
    receipt = nil
    task?.cancel()
    task = nil
    reading = false
  }

  func remove(_ file: Upload) { files.removeAll { $0.id == file.id } }
  func clear() { files.removeAll(); problem = nil }

  private nonisolated static func read(_ sources: [Source], limit: Int, remaining: Int) async
    -> (files: [Upload], errors: [String])
  {
    var available = remaining
    var uploads: [Upload] = [], errors: [String] = []
    for source in sources {
      if Task.isCancelled { break }
      do {
        let url = try source.get()
        do {
          let upload = try readFile(url, limit: min(limit, available))
          uploads.append(upload)
          available -= upload.data.count
        } catch { errors.append("\(url.lastPathComponent): \(error.localizedDescription)") }
      } catch { errors.append(error.localizedDescription) }
    }
    return (uploads, errors)
  }

  private nonisolated static func readFile(_ url: URL, limit: Int) throws -> Upload {
    guard url.isFileURL else { throw Failure("Choose a local file.") }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
    guard info.isRegularFile == true else { throw Failure("Choose a file, not a folder.") }
    let mime = mimeTypes[url.pathExtension.lowercased()] ?? info.contentType?.preferredMIMEType
    guard let mime, mimeTypes.values.contains(mime) else { throw Failure("Unsupported file type.") }
    guard let size = info.fileSize, size > 0 else { throw Failure("This file is empty.") }
    guard size <= limit else { throw Failure("Exceeds the attachment size limit.") }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    guard let data = try handle.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit else {
      throw Failure("The file is empty or exceeds the attachment size limit.")
    }
    return Upload(name: url.lastPathComponent, mime: mime, data: data)
  }
}
