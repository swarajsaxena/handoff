import Foundation

/// A dynamically-typed JSON value. Hook payloads carry per-tool, per-schema
/// shapes we don't want a struct for (`tool_input`, `requested_schema`,
/// elicitation `content`, `permission_suggestions`) — this decodes any of
/// them without guessing the shape up front.
indirect enum JSONValue: Codable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case object([String: JSONValue])
  case array([JSONValue])
  case null

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let bool = try? container.decode(Bool.self) {
      self = .bool(bool)
    } else if let number = try? container.decode(Double.self) {
      self = .number(number)
    } else if let string = try? container.decode(String.self) {
      self = .string(string)
    } else if let array = try? container.decode([JSONValue].self) {
      self = .array(array)
    } else if let object = try? container.decode([String: JSONValue].self) {
      self = .object(object)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value"
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }

  var stringValue: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var boolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  var objectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  var arrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }

  /// Best-effort single-line human text for display in the activity feed /
  /// note lines, when a specific field isn't what we're after.
  var displayText: String {
    switch self {
    case .string(let value): return value
    case .number(let value):
      return value.truncatingRemainder(dividingBy: 1) == 0
        ? String(Int(value))
        : String(value)
    case .bool(let value): return value ? "true" : "false"
    case .null: return ""
    case .array(let values): return values.map(\.displayText).joined(separator: ", ")
    case .object(let values):
      return values.keys.sorted()
        .map { "\($0): \(values[$0]!.displayText)" }
        .joined(separator: ", ")
    }
  }
}
