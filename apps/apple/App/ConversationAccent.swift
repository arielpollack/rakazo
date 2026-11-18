import Foundation

struct ConversationAccent {
  let avatar: UInt32
  let neutral: Bool

  private static let palette: [(id: String, name: String, rgb: UInt32, previous: UInt32?)] = [
    ("white", "staff white", 0xFFFFFF, nil), ("violet", "executive violet", 0xA97EFE, 0x8B5CF6),
    ("green", "emerald", 0x00C972, 0x10B981), ("orange", "forge orange", 0xFF781C, 0xF97316),
    ("cyan", "cyber cyan", 0x1CC3B0, 0x06B6D4), ("blue", "cobalt blue", 0x2A92FE, 0x3B82F6),
    ("yellow", "amber gold", 0xFFAF38, 0xEAB308), ("brown", "caramel bronze", 0xA27952, 0x8D6E63),
    ("red", "crimson red", 0xFF3E51, 0xEF4444), ("magenta", "neon pink", 0xFF5EB1, 0xEC4899),
    ("gray", "slate silver", 0x94A3B8, 0x64748B),
  ]

  init(_ chat: Chat) {
    let raw = chat.color ?? ""
    if chat.isGroup || raw.hasPrefix("data:image/") {
      avatar = 0xA97EFE
      neutral = true
      return
    }
    let shape = raw.range(of: "::shape_")
    let prefix = shape.map { String(raw[..<$0.lowerBound]) } ?? raw
    let value = shape != nil && prefix.isEmpty ? "#F97316" : prefix
    let hex = Self.parseHex(value)
    if let known = Self.palette.first(where: { entry in
      if let hex, value.count == 7 { return entry.rgb == hex || entry.previous == hex }
      return shape != nil && (entry.id == value.lowercased() || entry.name == value.lowercased())
    }) {
      avatar = known.rgb
      neutral = known.id == "white"
    } else if let hex {
      avatar = hex
      neutral = false
    } else {
      let hash = chat.id.utf16.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
      let seed = hash &+ 1_831_565_813
      var next = (seed ^ (seed >> 15)) &* (1 | seed)
      next ^= next &+ ((next ^ (next >> 7)) &* (61 | next))
      let index = (UInt64(next ^ (next >> 14)) * UInt64(Self.palette.count)) >> 32
      avatar = Self.palette[Int(index)].rgb
      neutral = avatar == 0xFFFFFF
    }
  }

  private static func parseHex(_ text: String) -> UInt32? {
    guard text.first == "#" else { return nil }
    let digits = text.dropFirst()
    guard digits.count == 3 || digits.count == 6,
      digits.utf8.allSatisfy({
        (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
      })
    else { return nil }
    return UInt32(
      digits.count == 3 ? digits.map { "\($0)\($0)" }.joined() : String(digits), radix: 16)
  }

  func bubbleRGB(increasedContrast: Bool) -> UInt32? {
    guard !neutral else { return nil }
    let minimum = increasedContrast ? 4.5 : 3.0
    func linear(_ rgb: UInt32, _ shift: Int) -> Double {
      let value = Double(rgb >> shift & 255) / 255
      return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    func contrast(_ rgb: UInt32) -> Double {
      1.05 / (0.05 + 0.2126 * linear(rgb, 16) + 0.7152 * linear(rgb, 8) + 0.0722 * linear(rgb, 0))
    }
    guard contrast(avatar) < minimum else { return avatar }
    let red = linear(avatar, 16)
    let green = linear(avatar, 8)
    let blue = linear(avatar, 0)
    let long = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
    let medium = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
    let short = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
    var lightness = 0.2104542553 * long + 0.793617785 * medium - 0.0040720468 * short
    let greenRed = 1.9779984951 * long - 2.428592205 * medium + 0.4505937099 * short
    let blueYellow = 0.0259040371 * long + 0.7827717662 * medium - 0.808675766 * short
    func channel(_ value: Double) -> UInt32 {
      let clamped = min(1, max(0, value))
      return UInt32(
        ((clamped <= 0.0031308 ? 12.92 * clamped : 1.055 * pow(clamped, 1 / 2.4) - 0.055) * 255)
          .rounded())
    }
    var background = avatar
    while contrast(background) < minimum {
      lightness -= 0.01
      let long = pow(lightness + 0.3963377774 * greenRed + 0.2158037573 * blueYellow, 3)
      let medium = pow(lightness - 0.1055613458 * greenRed - 0.0638541728 * blueYellow, 3)
      let short = pow(lightness - 0.0894841775 * greenRed - 1.291485548 * blueYellow, 3)
      background =
        channel(4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short) << 16
        | channel(-1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short) << 8
        | channel(-0.0041960863 * long - 0.7034186147 * medium + 1.707614701 * short)
    }
    return background
  }
}
