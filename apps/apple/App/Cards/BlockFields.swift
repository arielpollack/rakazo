import Foundation

/// Any JSON value, for the parts of a block the app passes along without reading.
enum JSONValue: Codable, Equatable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case null
  case array([JSONValue])
  case object([String: JSONValue])

  init(from decoder: Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() {
      self = .null
    } else if let bool = try? value.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? value.decode(Double.self) {
      self = .number(number)
    } else if let string = try? value.decode(String.self) {
      self = .string(string)
    } else if let array = try? value.decode([JSONValue].self) {
      self = .array(array)
    } else {
      self = .object(try value.decode([String: JSONValue].self))
    }
  }
  func encode(to encoder: Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .string(let string): try value.encode(string)
    case .number(let number): try value.encode(number)
    case .bool(let bool): try value.encode(bool)
    case .null: try value.encodeNil()
    case .array(let array): try value.encode(array)
    case .object(let object): try value.encode(object)
    }
  }
  /// As Foundation objects, for an RPC body or a web view message.
  var foundation: Any {
    switch self {
    case .string(let string): string
    case .number(let number): number
    case .bool(let bool): bool
    case .null: NSNull()
    case .array(let array): array.map(\.foundation)
    case .object(let object): object.mapValues(\.foundation)
    }
  }
}

extension Message.Block {
  /// The block as the server sent it, so each card reads the fields only it uses.
  struct Wire: Codable {
    var value: JSONValue?
    init(_ value: JSONValue?) { self.value = value }
    // Never stored or read back under its own key; the decoder fills it from the whole block.
    init(from decoder: Decoder) throws { value = nil }
    func encode(to encoder: Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encodeNil()
    }
  }

  /// This block's fields read as `type`, or nil when they don't match it.
  func fields<T: Decodable>(_ type: T.Type) -> T? {
    guard let value = wire?.value, let data = try? JSONEncoder().encode(value) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }
}
