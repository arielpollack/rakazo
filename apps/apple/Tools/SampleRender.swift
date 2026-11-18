import AppKit
import SwiftUI

@main enum SampleRender {
  @MainActor static func main() async throws {
    NSApplication.shared.setActivationPolicy(.prohibited)
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let store = WorkspaceStore(sample: .initial, persistent: false)
    let chat = store.navigation!.current.bots.first { $0.id == Sample.computerTour }!
    try await render(
      ConnectionsView(store: store), to: directory.appendingPathComponent("apps.png"))
    try await render(
      ToolServersView(store: store, search: ""), to: directory.appendingPathComponent("servers.png")
    )
    try await render(
      SampleScreen(store: store, chat: chat, requestedRun: nil),
      to: directory.appendingPathComponent("screen.png"))
    try await render(
      SampleHostReview(store: store, bot: chat.id), to: directory.appendingPathComponent("host.png")
    )
  }
  @MainActor static func render<Content: View>(_ content: Content, to url: URL) async throws {
    let size = CGSize(width: 510, height: 490)
    let hosting = NSHostingView(
      rootView: content.formStyle(.grouped).frame(width: size.width, height: size.height))
    let window = NSWindow(
      contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
      defer: false)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(450))
    hosting.layoutSubtreeIfNeeded()
    guard !window.isVisible, let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
    else { throw Failure("Offscreen capture unavailable") }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else {
      throw Failure("No PNG")
    }
    try png.write(to: url)
  }
}
