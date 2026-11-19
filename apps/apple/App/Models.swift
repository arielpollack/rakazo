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
  /// The paired computer the bot runs on; nil runs it on the server.
  var computerDeviceId: String?
  var modelProvider: String?
  var modelId: String?
  var isGroup: Bool { members != nil }
  var target: [String: Any] { [isGroup ? "groupId" : "botId": id] }
  struct Member: Codable, Hashable {
    var botId: String?
    var name: String?
    var color: String?
    var avatarSet: String?
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
  var isAdmin: Bool? = nil
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
  @ContentBlocks var blocks: [Block]
  var createdAt: String
  var botId: String?
  var replyPreview: Quote?
  var replyToMessageId: String?
  var replyQuote: String?
  var threadId: String?
  var runId: String?
  var author: Named?
  /// The voice call this message was spoken in.
  var callId: String?
  var appearsInTranscript: Bool {
    !blocks.contains { $0.kind == "delivery" } && blocks.contains(where: \.visible)
  }
  var text: String { blocks.filter(\.visible).map(\.label).joined(separator: "\n") }
  var selectableText: String {
    blocks.compactMap { block -> String? in
      guard block.visible, let text = block.text, !text.isEmpty else { return nil }
      switch block.kind {
      case "text", "progress", "ask": return text
      case "channel_message":
        return "\(block.fromLabel ?? "Message") (\(block.providerLabel)): \(text)"
      default: return nil
      }
    }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }
  struct Quote: Codable { var text: String }
  @propertyWrapper struct ContentBlocks: Codable {
    var wrappedValue: [Block]
    init(wrappedValue: [Block]) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
      var container = try decoder.unkeyedContainer()
      wrappedValue = []
      while !container.isAtEnd {
        let entry = try container.superDecoder()
        do {
          var block = try Block(from: entry)
          block.wire = .init(try? JSONValue(from: entry))
          wrappedValue.append(block)
        } catch is DecodingError {
          let header = try? BlockHeader(from: entry)
          let kind = header?.kind ?? ""
          wrappedValue.append(Block(kind: ["delivery", "steps"].contains(kind) ? kind : "unsupported_content"))
        }
      }
    }
    func encode(to encoder: Encoder) throws { try wrappedValue.encode(to: encoder) }
    private struct BlockHeader: Decodable { let kind: String }
  }
  struct Block: Codable {
    var kind: String
    var wire: Wire?
    var text: String?
    var name: String?
    var title: String?
    var question: Question?
    var detail: String?, detailFormat: String?, site: String?
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
    var provider: String?, transport: String?, connectorId: String?, intent: String?
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
    var activity: Bool?, undone: Bool?, dismissed: Bool?, expired: Bool?, durationMs: Int?,
      durationSeconds: Int?
    var pendingToolNames: [String]?
    var options: [Option]?, actions: [Action]?, steps: [Step]?
    var credential: Presence?, oneTimeCode: Presence?, receipt: Presence?,
      instructionUpdate: Presence?, settingsUpdate: Presence?
    struct Presence: Codable {}
    enum Question: Codable {
      case choice(String)
      case tool(Prompt)
      struct Prompt: Codable { let message: String }
      var text: String {
        switch self {
        case .choice(let text): text
        case .tool(let prompt): prompt.message
        }
      }
      init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let text = try? value.decode(String.self) {
          self = .choice(text)
        } else {
          self = .tool(try value.decode(Prompt.self))
        }
      }
      func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .choice(let text): try value.encode(text)
        case .tool(let prompt): try value.encode(prompt)
        }
      }
    }
    struct Option: Codable { let id: String, letter: String, label: String }
    struct Action: Codable {
      let id: String, label: String
      var outcome: String?
    }
    struct Step: Codable {
      let label: String, count: Int
      var outcomes: Outcomes?
    }
    struct Outcomes: Codable { var succeeded: Int?, failed: Int?, stopped: Int? }
    var visible: Bool {
      !(kind == "steps" || kind == "progress" && activity == true || kind == "import_setup" && undone == true
        || kind == "choice" && answerId == "_dismissed")
    }
    var isNarration: Bool { ["text", "meta", "progress"].contains(kind) }
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
      text ?? title ?? name ?? question?.text ?? lines?.map { "\($0.k): \($0.v)" }.joined(
        separator: "\n")
        ?? kind.replacingOccurrences(of: "_", with: " ").capitalized
    }
  }
}
struct TranscriptRows {
  static let emoji = ["👍", "👎", "❤️", "😂", "🎉", "😮"]
  var visible: [Message] = []
  var reactions: [String: [String: Int]] = [:]
  /// Each "messages with another bot" line, by the message that opens it.
  var exchanges: [String: PeerTranscript.Exchange] = [:]
  /// An emoji someone sent in reply to a message, which shows as a reaction on it.
  static func reaction(_ message: Message) -> String? {
    guard message.role == "user", message.replyToMessageId != nil, message.blocks.count == 1,
      let block = message.blocks.first, block.kind == "text", let text = block.text,
      emoji.contains(text)
    else { return nil }
    return text
  }
  init(_ messages: [Message]) {
    let folded = PeerTranscript.fold(messages.filter(\.appearsInTranscript))
    let readable = folded.messages
    let parents = Dictionary(readable.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let answers = Set(
      readable.flatMap {
        $0.blocks.compactMap {
          $0.kind == "ask" && $0.status == "answered" ? $0.answerMessageId : nil
        }
      })
    var shown: [Message] = []
    for message in readable {
      if !answers.contains(message.id), let mark = Self.reaction(message),
        let id = message.replyToMessageId,
        let parent = parents[id], id != message.id,
        Self.reaction(parent) == nil || answers.contains(id)
      {
        reactions[id, default: [:]][mark, default: 0] += 1
      } else {
        shown.append(message)
      }
    }
    let lines = PeerTranscript.exchanges(.init(messages: shown, folded: folded.folded))
    exchanges = lines.lines
    visible = shown.filter { lines.lineOf[$0.id] == nil || lines.lines[$0.id] != nil }
  }
}
struct ThreadData: Codable {
  var threadId: String
  var messages: [Message]
  var cursor: Int?
  var olderCursor: Int?
  var run: Run?
  var activeRuns: [Run]?
  struct Run: Codable {
    let status: String
    var error: String?
    var id: String?, botId: String?, trigger: String?, routineName: String?
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
  /// The server's stable code for a refusal a screen answers, such as `BOT_BUSY`.
  var code: String? = nil
  init(_ message: String, code: String? = nil) {
    self.message = message
    self.code = code
  }
  var errorDescription: String? { message }
}

enum Clock {
  static func needsSeparator(_ current: String, after previous: String?) -> Bool {
    guard let date = date(current) else { return false }
    guard let previous else { return true }
    guard let before = Self.date(previous) else { return false }
    return !Calendar.current.isDate(before, inSameDayAs: date) || date.timeIntervalSince(before) >= 15 * 60
  }
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
