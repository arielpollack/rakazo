import Foundation

struct Chat: Codable, Identifiable, Hashable {
  var id: String
  var name: String
  var color: String?
  var avatarSet: String?
  var description: String?
  var instructions: String?
  var preview: String?
  var updatedAt: String?
  var pinned: Bool?
  var unread: Bool?
  var archivedAt: String?
  var snoozedUntil: String?
  var sectionId: String?
  var members: [Member]?
  var computerMode: String?
  var modelId: String?
  var isGroup: Bool { members != nil }
  var target: [String: Any] { [isGroup ? "groupId" : "botId": id] }
  struct Member: Codable, Hashable {
    var botId: String?
    var name: String?
    var color: String?
  }
}

struct Named: Codable, Identifiable, Hashable {
  var id: String
  var name: String
}
struct Workspace: Codable {
  var id: String
  var name: String
  var bots: [Chat]
  var groups: [Chat]
  var botSections: [Named]
  var chats: [Chat] {
    (bots + groups).filter {
      $0.archivedAt == nil && (Clock.date($0.snoozedUntil) ?? .distantPast) <= .now
    }.sorted {
      if ($0.pinned == true) != ($1.pinned == true) { return $0.pinned == true }
      return ($0.updatedAt ?? "") > ($1.updatedAt ?? "")
    }
  }
}
struct NavigationData: Codable {
  var current: Workspace
  var spaces: [Named]
}
struct Account: Codable {
  var userId: String
  var email: String
  var name: String
  var maxUploadSizeBytes: Int?
  var maxAttachmentsPerMessage: Int?
}
struct Message: Codable, Identifiable {
  var id: String
  var seq: Int
  var role: String
  var blocks: [Block]
  var createdAt: String
  var botId: String?
  var replyPreview: Quote?
  var replyToMessageId: String?
  var replyQuote: String?
  var threadId: String?
  var runId: String?
  var author: Named?
  var text: String { blocks.map(\.label).joined(separator: "\n") }
  var selectableText: String {
    blocks.compactMap { block -> String? in
      guard let text = block.text, !text.isEmpty else { return nil }
      switch block.kind {
      case "text", "progress", "ask": return text
      case "channel_message":
        return "\(block.fromLabel ?? "Message") (\(block.providerLabel)): \(text)"
      default: return nil
      }
    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
  struct Quote: Codable { var text: String }
  struct Block: Codable {
    var kind: String
    var text: String?
    var name: String?
    var title: String?
    var question: String?
    var detail: String?
    var artifactId: String?
    var lines: [Pair]?
    var mimeType: String?
    var size: Int?
    var state: String?, status: String?, answerMessageId: String?, answerId: String?,
      input: String?, approvalEffectId: String?
    var answer: String?, subtitle: String?, task: String?, progress: String?, result: String?,
      pageId: String?
    var server: String?, tool: String?, goal: String?, reason: String?, farewell: String?,
      description: String?
    var fromBotName: String?, toBotName: String?, fromLabel: String?, fromBotId: String?,
      toBotId: String?, botId: String?
    var provider: String?, transport: String?, connectorId: String?
    var serverId: String?, needsOAuth: Bool?
    var providerLabel: String {
      guard let provider else { return "Chat" }
      if provider == "sendblue", let transport, ["iMessage", "SMS", "RCS"].contains(transport) {
        return transport
      }
      for (prefix, label) in [("telegram-", "Telegram"), ("photon-", "iMessage")]
      where provider.hasPrefix(prefix) && provider.count > prefix.count {
        return "\(label) (\(provider.dropFirst(prefix.count)))"
      }
      return [
        "sendblue": "iMessage", "slack": "Slack", "whatsapp": "WhatsApp", "telegram": "Telegram",
        "lark": "Feishu", "photon": "iMessage (Photon)",
      ][provider] ?? provider
    }
    var activity: Bool?, undone: Bool?, dismissed: Bool?, durationMs: Int?, durationSeconds: Int?
    var options: [Option]?, actions: [Action]?, steps: [Step]?
    var credential: Presence?, oneTimeCode: Presence?, receipt: Presence?,
      instructionUpdate: Presence?, settingsUpdate: Presence?
    struct Presence: Codable {}
    struct Option: Codable { let id: String, letter: String, label: String }
    struct Action: Codable { let id: String, label: String }
    struct Step: Codable {
      let label: String, count: Int
      var outcomes: Outcomes?
    }
    struct Outcomes: Codable { var succeeded: Int?, failed: Int?, stopped: Int? }
    var visible: Bool {
      !(kind == "progress" && activity == true || kind == "import_setup" && undone == true
        || kind == "choice" && answerId == "_dismissed")
    }
    var plainQuestion: Bool {
      kind == "ask" && status != "answered" && input != "secret" && approvalEffectId == nil
        && credential == nil && oneTimeCode == nil && receipt == nil && instructionUpdate == nil
        && settingsUpdate == nil && (actions ?? []).isEmpty
    }
    struct Pair: Codable {
      var k: String
      var v: String
    }
    var label: String {
      text ?? title ?? name ?? question ?? lines?.map { "\($0.k): \($0.v)" }.joined(separator: "\n")
        ?? kind.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }
}
struct TranscriptRows {
  static let emoji = ["👍", "👎", "❤️", "😂", "🎉", "😮"]
  var visible: [Message] = []
  var reactions: [String: [String: Int]] = [:]
  init(_ messages: [Message]) {
    let readable = messages.filter {
      !$0.blocks.contains { $0.kind == "delivery" } && $0.blocks.contains(where: \.visible)
    }
    let parents = Dictionary(readable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let answers = Set(
      readable.flatMap {
        $0.blocks.compactMap {
          $0.kind == "ask" && $0.status == "answered" ? $0.answerMessageId : nil
        }
      })
    func emoji(_ message: Message) -> String? {
      guard message.role == "user", message.replyToMessageId != nil, message.blocks.count == 1,
        let block = message.blocks.first, block.kind == "text", let text = block.text,
        Self.emoji.contains(text)
      else { return nil }
      return text
    }
    for message in readable {
      if !answers.contains(message.id), let mark = emoji(message),
        let id = message.replyToMessageId,
        let parent = parents[id], id != message.id, emoji(parent) == nil || answers.contains(id)
      {
        reactions[id, default: [:]][mark, default: 0] += 1
      } else {
        visible.append(message)
      }
    }
  }
}
struct ThreadData: Codable {
  var threadId: String
  var messages: [Message]
  var cursor: Int?
  var olderCursor: Int?
  var run: Run?
  struct Run: Codable {
    let status: String
    var error: String?
  }
}
struct Activity: Codable, Identifiable {
  var runId: String
  var botId: String
  var botName: String
  var groupId: String?
  var groupName: String?
  var status: String
  var promptSnippet: String
  var updatedAt: String
  var id: String { runId }
}
struct Activities: Codable { let runs: [Activity] }
struct Routine: Codable, Identifiable {
  var id: String
  var name: String
  var prompt: String
  var crons: [String]
  var active: Bool
  var timezone: String
}
struct PageItem: Codable, Identifiable {
  var id: String
  var title: String
  var botId: String?
  var groupId: String?
}
struct Pages: Codable {
  var items: [PageItem]
  var nextCursor: String?
}
struct Consent: Codable, Identifiable {
  var scope: String
  var version: String
  var recipients: [Recipient]
  var id: String { scope }
  struct Recipient: Codable, Identifiable {
    let key: String
    let name: String
    let detail: String
    let allowed: Bool
    var id: String { key }
  }
  var unapproved: [Recipient] { recipients.filter { !$0.allowed } }
}
struct Upload: Identifiable {
  let id = UUID().uuidString
  let name: String
  let mime: String
  let data: Data
}
struct SearchPage: Decodable {
  struct Hit: Decodable {
    let kind: String
    let title: String
    let snippet: String
    let botId: String?
    let groupId: String?
    let messageId: String?
  }
  let hits: [Hit]
}
struct StoredArtifact: Decodable {
  let id: String
  let name: String
  let mimeType: String
  let size: Int
  let contentBase64: String
}
struct ObjectID: Decodable { let id: String }
struct Empty: Decodable {}
struct Health: Decodable { let ok: Bool }
struct Failure: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

enum Clock {
  static func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    return (try? Date(value, strategy: .iso8601.time(includingFractionalSeconds: true)))
      ?? (try? Date(value, strategy: .iso8601))
  }
  static func label(_ value: String?, full: Bool = false) -> String {
    guard let date = date(value) else { return "" }
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDateInToday(date) { return full ? "Today \(time)" : time }
    if calendar.isDateInYesterday(date) { return full ? "Yesterday \(time)" : "Yesterday" }
    let day =
      date > Date.now.addingTimeInterval(-604800)
      ? date.formatted(.dateTime.weekday(full ? .wide : .abbreviated))
      : date.formatted(date: .abbreviated, time: .omitted)
    return full ? "\(day) \(time)" : day
  }
}
