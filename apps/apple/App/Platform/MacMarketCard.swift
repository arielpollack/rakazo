#if os(macOS)
  import AppKit
  import SwiftUI

  enum MarketStyle {
    static let line = Color.primary.opacity(0.14)
    static let tint = Color.primary.opacity(0.055)
    static let rail = PlatformColor.pair(0xF6F6F7, 0x252527)
    static let positive = PlatformColor.pair(0x22653C, 0x9ED9AA)
    static let canvas = Color(nsColor: .textBackgroundColor)
  }

  struct MarketMark: View {
    var brand: String, fallback = "puzzlepiece.extension", size: CGFloat = 38
    var publicLogo: URL? = nil
    @Environment(\.colorScheme) private var scheme
    private static let marks: [String: NSImage] = {
      let names = Array(MarketDirectory.brands.keys) + ["linear-white", "github-white"]
      return Dictionary(
        uniqueKeysWithValues: names.compactMap { name in
          guard
            let url = Bundle.main.url(
              forResource: name, withExtension: "png", subdirectory: "Brandmarks"),
            let image = NSImage(contentsOf: url)
          else { return nil }
          return (name, image)
        })
    }()
    var body: some View {
      let variant =
        scheme == .dark && ["linear", "github"].contains(brand) ? brand + "-white" : brand
      Group {
        if let image = Self.marks[variant] {
          Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
        } else if let publicLogo {
          AsyncImage(url: publicLogo) { phase in
            if let image = phase.image {
              image.resizable().scaledToFit()
            } else {
              Image(systemName: fallback).font(.system(size: size * 0.67)).foregroundStyle(
                .secondary)
            }
          }
        } else {
          Image(systemName: fallback).font(.system(size: size * 0.67)).foregroundStyle(.secondary)
        }
      }.frame(width: size, height: size).accessibilityHidden(true)
    }
  }

  struct MarketSpotlight: View {
    let explore: () -> Void
    @Environment(\.colorScheme) private var scheme
    var body: some View {
      HStack(spacing: 16) {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 6) {
            MarketMark(brand: "github", size: 18)
            Text("GitHub  /  Spotlight").font(.subheadline.weight(.medium))
          }
          Text("Catch up on a release").font(.system(size: 24, weight: .medium))
          Text("Ask your bot what shipped in the latest version of a repository.").foregroundStyle(
            .secondary)
          Button(action: explore) {
            HStack(spacing: 6) {
              Text("Explore GitHub").fontWeight(.semibold)
              Image(systemName: "arrow.right")
            }
          }.buttonStyle(.plain)
        }.frame(maxWidth: .infinity, alignment: .leading)
        ViewThatFits(in: .horizontal) {
          branch.frame(width: 165, height: 86)
          Color.clear.frame(width: 0, height: 1)
        }
      }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .background(
          scheme == .dark ? Color.white.opacity(0.065) : Color(red: 0.94, green: 0.94, blue: 0.95),
          in: RoundedRectangle(cornerRadius: 12))
    }
    private var branch: some View {
      Canvas { context, size in
        let base = size.height * 0.70
        let split = size.height * 0.33
        var line = Path()
        line.move(to: CGPoint(x: 2, y: base))
        line.addLine(to: CGPoint(x: 162, y: base))
        context.stroke(line, with: .color(.secondary.opacity(0.50)), lineWidth: 2)
        var fork = Path()
        fork.move(to: CGPoint(x: 33, y: base))
        fork.addCurve(
          to: CGPoint(x: 82, y: split), control1: CGPoint(x: 59, y: base),
          control2: CGPoint(x: 45, y: split))
        fork.addLine(to: CGPoint(x: 148, y: split))
        context.stroke(fork, with: .color(.secondary), lineWidth: 2)
        for (left, top) in [(12.0, base), (34, base), (86, split), (97, base), (153, base)] {
          let circle = Path(ellipseIn: CGRect(x: left - 4, y: top - 4, width: 8, height: 8))
          context.fill(circle, with: .color(MarketStyle.rail))
          context.stroke(circle, with: .color(.secondary), lineWidth: 1.5)
        }
        context.draw(
          Text("release").font(.caption2).foregroundStyle(.secondary),
          at: CGPoint(x: 80, y: split - 15))
        context.draw(
          Text("main").font(.caption2).foregroundStyle(.secondary), at: CGPoint(x: 17, y: base + 18)
        )
      }.overlay(alignment: .topTrailing) {
        Image(systemName: "tag").foregroundStyle(MarketStyle.canvas).padding(9).background(
          Color.primary, in: RoundedRectangle(cornerRadius: 8)
        ).offset(x: -8, y: 12)
      }.accessibilityHidden(true)
    }
  }

  enum MarketFocus: Hashable {
    case card(String)
    case action(String)
    case search, back
  }

  struct MarketCard: View {
    let item: MarketItem, waiting: Bool, failure: String?
    let blocked: Bool
    let focus: FocusState<MarketFocus?>.Binding
    let open: () -> Void, act: () -> Void
    @State private var hovered = false

    var body: some View {
      let showsAction = !waiting && (item.confirmed == nil || item.canResume)
      ZStack(alignment: .bottomLeading) {
        Button(action: open) {
          VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 11) {
              MarketMark(brand: item.brand, fallback: item.kind.symbol, publicLogo: item.publicLogo)
              VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                  Text(item.name).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                  Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                }
                Text(item.kind.rawValue + " · " + item.category).font(.subheadline).foregroundStyle(
                  .secondary
                ).lineLimit(1)
              }
            }
            Text(failure == nil ? item.summary : "Couldn’t finish setup. Try again.")
              .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
              .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            if showsAction {
              Color.clear.frame(height: 22)
            } else {
              MarketStatus(item: item, waiting: waiting)
            }
          }.padding(16).frame(maxWidth: .infinity, alignment: .leading).frame(height: 151)
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(
          MarketCardStyle(hovered: hovered, focused: focus.wrappedValue == .card(item.id))
        )
        .focusEffectDisabled().focused(focus, equals: .card(item.id))
        .accessibilityLabel("\(item.name), \(item.kind.rawValue), details")
        .accessibilityValue(Text(waiting ? "Waiting for \(item.name)" : item.confirmed ?? ""))
        .accessibilityIdentifier("market-card-" + item.id)
        .help(failure ?? item.summary)
        if showsAction {
          MarketAction(item: item, waiting: false, failure: failure, focus: focus, act: act)
            .disabled(blocked).padding(16)
        }
      }.onHover { hovered = $0 }.accessibilityElement(children: .contain)
    }
  }

  private struct MarketCardStyle: ButtonStyle {
    let hovered: Bool, focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
      let surface = RoundedRectangle(cornerRadius: 11)
      configuration.label.foregroundStyle(.primary)
        .background(
          surface.fill(Color.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.055 : 0))
        )
        .overlay {
          surface.strokeBorder(
            focused ? Color.accentColor : hovered ? Color.primary.opacity(0.34) : MarketStyle.line,
            lineWidth: focused ? 2 : 1
          ).allowsHitTesting(false)
        }.animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
  }

  private struct MarketStatus: View {
    let item: MarketItem, waiting: Bool
    var body: some View {
      if waiting {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text("Waiting for \(item.name)…")
        }.font(.subheadline).foregroundStyle(.secondary)
      } else if let confirmed = item.confirmed, !item.canResume {
        Label(
          confirmed,
          systemImage: item.needsAttention ? "exclamationmark.circle" : "checkmark.circle"
        )
        .font(.subheadline.weight(.medium)).foregroundStyle(
          item.needsAttention ? Color.secondary : MarketStyle.positive
        )
        .lineLimit(1)
      }
    }
  }

  struct MarketAction: View {
    let item: MarketItem, waiting: Bool, failure: String?, focus: FocusState<MarketFocus?>.Binding,
      act: () -> Void
    var body: some View {
      if waiting || (item.confirmed != nil && !item.canResume) {
        MarketStatus(item: item, waiting: waiting)
          .focusable().focused(focus, equals: .action(item.id))
          .accessibilityIdentifier("market-status-" + item.id)
      } else {
        Button(action: act) {
          Label(
            failure != nil || item.canResume ? "Retry \(item.name)" : item.actionTitle,
            systemImage: failure != nil || item.canResume
              ? "arrow.clockwise" : item.kind == .app ? "link" : "plus"
          ).font(.subheadline.weight(.semibold))
        }
        .controlSize(.regular).focused(focus, equals: .action(item.id)).help(
          failure ?? item.actionTitle
        )
        .accessibilityIdentifier("market-action-" + item.id)
      }
    }
  }
#endif
