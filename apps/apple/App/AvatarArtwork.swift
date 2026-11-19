import JavaScriptCore
import SwiftUI

enum BotPose: String, CaseIterable {
  case idle, working, thinking, reading, writing, computer, waiting, error
}

@MainActor final class AvatarArtwork {
  static let shared = AvatarArtwork(source: NSDataAsset(name: "AvatarEngine")?.data)
  let api: JSValue?
  private let cache = NSCache<NSString, AvatarScene>()

  init(source: Data?) {
    let context = JSContext()
    if let source, let script = String(data: source, encoding: .utf8) {
      context?.evaluateScript(script)
    }
    api = context?.objectForKeyedSubscript("RakazoAvatars")
    cache.countLimit = 96
  }

  func scene(chat: Chat, size: CGFloat, dark: Bool, pose: BotPose, composing: Bool, still: Bool)
    -> AvatarScene?
  {
    let raw = chat.color ?? String(format: "#%06X", chat.hex)
    let color = raw.hasPrefix("data:image/") ? "data:image/" : raw
    let args: [Any] = [
      chat.id, color, chat.avatarSet ?? "", size, dark, pose.rawValue, composing, still,
    ]
    let key = (args as NSArray).description as NSString
    if let scene = cache.object(forKey: key) { return scene }
    guard let handle = api?.invokeMethod("create", withArguments: args), !handle.isUndefined,
      let scene = AvatarScene(handle)
    else { return nil }
    cache.setObject(scene, forKey: key)
    return scene
  }
}

@MainActor final class AvatarScene {
  private typealias Properties = [String: Any]
  private struct Layer {
    var sample: Int?, image: Image?, mask: Image?, clip: Path?, offset: CGSize?, tilt: CGFloat?
    var eye: CGFloat?, bar: CGFloat?, dot: Bool, ink: Color, children: [Layer]

    init(_ value: Properties) {
      sample = value["sample"] as? Int
      func image(_ key: String) -> Image? {
        (value[key] as? String).flatMap { Image(platformData: Data($0.utf8)) }
      }
      self.image = image("image")
      mask = image("mask")
      if let rect = value["clip"] as? [CGFloat], rect.count == 5 {
        clip = Path(
          roundedRect: CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]),
          cornerRadius: rect[4], style: .circular)
      }
      if let pair = value["offset"] as? [CGFloat], pair.count == 2 {
        offset = CGSize(width: pair[0], height: pair[1])
      }
      tilt = value["tilt"] as? CGFloat
      eye = value["eye"] as? CGFloat
      bar = value["bar"] as? CGFloat
      dot = value["dot"] as? Bool == true
      let hex = (value["ink"] as? String ?? "#000000").dropFirst()
      ink = Color(rgb: UInt32(hex.prefix(6), radix: 16) ?? 0).opacity(
        hex.count == 8 ? Double(UInt8(hex.suffix(2), radix: 16) ?? 255) / 255 : 1)
      children = (value["children"] as? [Properties] ?? []).map(Layer.init)
    }

    func draw(_ original: GraphicsContext, _ samples: [Properties]) {
      var context = original
      let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
      let props = sample.flatMap { samples.indices.contains($0) ? samples[$0] : nil } ?? [:]
      if let opacity = props["opacity"] as? Double {
        if opacity <= 0 { return }
        context.opacity *= opacity
      }
      if let clip { context.clip(to: clip) }
      if let mask { context.clipToLayer { $0.draw(mask, in: rect) } }
      if let offset { context.translateBy(x: offset.width, y: offset.height) }
      if let tilt, tilt != 0 {
        context.translateBy(x: 50, y: 50)
        context.rotate(by: .degrees(tilt))
        context.translateBy(x: -50, y: -50)
      }
      if let matrix = props["matrix"] as? [CGFloat] { AvatarScene.apply(matrix, to: &context) }
      if let image { context.draw(image, in: rect) }
      if let cx = props["cx"] as? CGFloat, let cy = props["cy"] as? CGFloat,
        let ry = props["ry"] as? CGFloat, ry > 0
      {
        let rx = eye ?? bar.map { $0 / 2 } ?? (dot ? ry : 0)
        let bounds = CGRect(x: cx - rx, y: cy - ry, width: 2 * rx, height: 2 * ry)
        context.fill(
          bar == nil
            ? Path(ellipseIn: bounds)
            : Path(roundedRect: bounds, cornerRadius: min(rx, ry), style: .circular),
          with: .color(ink))
      }
      for layer in children { layer.draw(context, samples) }
    }
  }

  private let handle: JSValue, layers: [Layer]
  private let rest: [Properties]
  init?(_ handle: JSValue) {
    guard let nodes = handle.forProperty("nodes")?.toArray() as? [Properties], !nodes.isEmpty else {
      return nil
    }
    self.handle = handle
    layers = nodes.map(Layer.init)
    rest = handle.invokeMethod("sample", withArguments: [0, 0])?.toArray() as? [Properties] ?? []
  }

  nonisolated static func apply(_ matrix: [CGFloat], to context: inout GraphicsContext) {
    guard matrix.count == 6 else { return }
    context.concatenate(
      CGAffineTransform(
        a: matrix[0], b: matrix[1], c: matrix[2], d: matrix[3], tx: matrix[4], ty: matrix[5]))
  }

  func draw(
    _ original: GraphicsContext, in size: CGSize, elapsed: Double, morph: Double,
    poke: (Int, Double)?
  ) {
    var context = original
    context.scaleBy(x: size.width / 100, y: size.height / 100)
    if let (index, time) = poke,
      let matrix = AvatarArtwork.shared.api?.invokeMethod("poke", withArguments: [index, time])?
        .toArray() as? [CGFloat]
    {
      Self.apply(matrix, to: &context)
    }
    let samples =
      elapsed == 0 && morph == 0
      ? rest
      : handle.invokeMethod("sample", withArguments: [elapsed * 1000, morph])?.toArray()
        as? [Properties] ?? rest
    for layer in layers { layer.draw(context, samples) }
  }
}

struct BotCharacter: View {
  let chat: Chat, size: CGFloat, pose: BotPose, composing: Bool, interactive: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var phase
  @Environment(\.colorScheme) private var scheme
  @State private var start = Date.now
  @State private var pokeStart: Date?
  @State private var pokeIndex = 0

  var body: some View {
    let still = reduceMotion || size < 24 || phase != .active || pose == .idle
    let scene = AvatarArtwork.shared.scene(
      chat: chat, size: size, dark: scheme == .dark, pose: pose, composing: composing, still: still)
    let picture = TimelineView(.animation(minimumInterval: 1 / 30, paused: still)) { time in
      let elapsed = still ? 0 : max(0, time.date.timeIntervalSince(start))
      Canvas { context, bounds in
        let sincePoke = pokeStart.map { time.date.timeIntervalSince($0) }
        scene?.draw(
          context, in: bounds, elapsed: elapsed,
          morph: composing && !still ? min(1, elapsed / 0.52) : 0,
          poke: sincePoke.flatMap { !still && (0...1.5).contains($0) ? (pokeIndex, $0) : nil })
      }
    }.frame(width: size, height: size)
    if interactive && !still {
      Button {
        pokeIndex = (pokeIndex + 1) % 3
        pokeStart = .now
      } label: {
        picture.contentShape(Rectangle())
      }
      .buttonStyle(.plain).accessibilityLabel("Animate \(chat.name)")
    } else {
      picture.accessibilityHidden(true)
    }
  }
}
