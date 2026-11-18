import SwiftUI

struct AgentBlock: View {
  let block: Message.Block, message: Message, chat: Chat
  @ObservedObject var store: WorkspaceStore
  let refresh: () async throws -> Void, report: (String) -> Void
  @State private var expanded = false
  @State private var answer = ""
  @State private var busy = false
  @State private var connecting = false
  @State private var openingScreen = false
  @State private var reviewingServer = false
  @State private var reviewingHost = false
  @State private var nonce = UUID().uuidString
  private var heading: (String, String) {
    switch block.kind {
    case "steps": ("list.bullet.indent", "Actions")
    case "subagent": ("person.2", block.name ?? "Helper")
    case "computer": ("desktopcomputer", "Computer use")
    case "choice", "ask", "tool_question": ("questionmark.bubble", "Question")
    case "connect", "app_connect": ("puzzlepiece.extension", block.name ?? "Connect app")
    case "mcp_approval": ("lock.shield", block.name ?? "Tool connection")
    case "import_setup": ("checklist", "Import setup")
    case "page": ("doc.richtext", block.title ?? "Page")
    case "app": ("macwindow", block.tool ?? "Interactive app")
    case "chart": ("chart.xyaxis.line", block.name ?? "Chart")
    case "handoff": ("arrow.triangle.branch", "Bot handoff")
    case "child_bot": ("person.crop.circle.badge.plus", block.name ?? "Bot")
    case "bot_message_received": ("arrow.down.left", block.fromBotName ?? "From another bot")
    case "bot_message_sent": ("arrow.up.right", block.toBotName.map { "To \($0)" } ?? "Sent to bot")
    case "channel_message": ("bubble.left.and.bubble.right", block.fromLabel ?? "Channel message")
    case "voice_call", "call_request": ("phone", block.title ?? "Voice call")
    case "skill_draft": ("wand.and.stars", block.name ?? "Skill draft")
    case "cloud_agent": ("cloud", block.title ?? "Cloud agent")
    default: ("square.on.square", block.kind.replacingOccurrences(of: "_", with: " ").capitalized)
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        Image(systemName: heading.0).foregroundStyle(Ink.action).accessibilityHidden(true)
        Text(heading.1).font(.subheadline.weight(.semibold))
        Spacer(minLength: 4)
        if let status = block.state ?? block.status {
          Text(status.replacingOccurrences(of: "_", with: " ").capitalized).font(
            .caption.weight(.medium)
          ).foregroundStyle(.secondary)
        }
      }
      if block.kind == "steps" {
        let steps = block.steps ?? []
        DisclosureGroup(isExpanded: $expanded) {
          ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
            let failed = step.outcomes?.failed ?? 0
            let stopped = step.outcomes?.stopped ?? 0
            HStack {
              Label(
                step.label,
                systemImage: failed > 0
                  ? "exclamationmark.circle"
                  : stopped > 0
                    ? "stop.circle"
                    : step.outcomes?.succeeded != nil ? "checkmark.circle" : "circle.dotted")
              Spacer()
              if step.count > 1 { Text("×\(step.count)").monospacedDigit() }
            }.font(.callout).padding(.top, 4)
            if failed + stopped > 0 {
              Text("\(failed) failed · \(stopped) stopped").font(.caption).foregroundStyle(
                .secondary)
            }
          }
        } label: {
          let count = steps.reduce(0) { $0 + $1.count }
          Text(
            "\(count) \(count == 1 ? "action" : "actions")"
              + (block.durationMs.map {
                " · \(Duration.milliseconds($0).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))"
              } ?? "")
          ).font(.callout)
        }.tint(.primary)
      } else {
        if let body = block.text ?? block.question ?? block.task ?? block.description ?? block.goal
          ?? block.farewell ?? block.reason
        {
          MessageText(content: body).equatable()
        }
        if let detail = block.result ?? block.progress ?? block.subtitle {
          Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
        }
        if block.kind == "choice" {
          ForEach(block.options ?? [], id: \.id) { option in
            Button {
              perform(choice: option.id)
            } label: {
              HStack {
                Text(option.letter).font(.caption.bold())
                Text(option.label)
                Spacer()
                if block.answerId == option.id { Image(systemName: "checkmark") }
              }
            }.buttonStyle(.bordered).disabled(block.answerId != nil || busy || chat.isGroup)
          }
          if block.answerId == nil && !chat.isGroup {
            Button("Dismiss choice") { perform(choice: "_dismissed") }.font(.caption).disabled(busy)
          }
        } else if store.demo, block.actions?.first?.id == "sample-host-review", block.status == "pending" {
          Button("Review computer access…", systemImage: "lock.shield") { reviewingHost = true }.buttonStyle(.bordered)
        } else if block.plainQuestion, message.runId != nil {
          if let detail = block.detail { Text(detail).font(.callout).textSelection(.enabled) }
          TextField("Your answer", text: $answer, axis: .vertical).textFieldStyle(.roundedBorder)
            .lineLimit(1...5)
          Button("Send answer") { perform(choice: nil) }.buttonStyle(.bordered).disabled(
            answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
        } else if block.kind == "ask" && block.status == "answered" {
          Label(block.dismissed == true ? "Dismissed" : block.actions?.first?.id == "sample-host-review" ? (block.answer ?? "Answered") : "Answered", systemImage: "checkmark.circle")
            .font(.caption)
        } else if block.kind == "computer", let bot = chat.isGroup ? message.botId : chat.id {
          if block.state == "Needs you", let run = message.runId {
            ComputerRequestActions(store: store, bot: bot, run: run, chat: chat, open: { openingScreen = true }, refresh: refresh, report: report)
          } else if store.demo, !chat.isGroup {
            Button("View bot screen…", systemImage: "display") { openingScreen = true }.buttonStyle(.bordered)
          } else if let url = store.link(chat) { Link("Open in Rakazo", destination: url) }
        } else if block.kind == "mcp_approval", store.demo, block.status == "pending", let id = block.serverId,
            store.sampleIntegrations?.servers.contains(where: { $0.id == id }) == true {
          Button("Review agent access…", systemImage: "lock.shield") { reviewingServer = true }.buttonStyle(.bordered)
        } else if block.kind == "app_connect", block.status == "pending", block.provider != nil,
          message.threadId != nil, !chat.isGroup || message.botId != nil
        {
          Button("Review connection…", systemImage: "link") { connecting = true }.buttonStyle(
            .bordered)
        } else if [
          "app", "page", "chart", "computer", "ask", "tool_question", "connect", "mcp_approval",
          "import_setup", "skill_draft", "call_request", "cloud_agent",
        ].contains(block.kind),
          let url = store.link(
            chat, query: block.pageId.map { [.init(name: "page", value: $0)] } ?? [])
        {
          Link(destination: url) {
            Label(
              block.kind == "page" ? "Open page" : "Open in Rakazo",
              systemImage: "arrow.up.right.square"
            ).font(.callout)
          }
        }
      }
    }.padding(12).background(Ink.canvas, in: RoundedRectangle(cornerRadius: Layout.Radius.control))
      .overlay { RoundedRectangle(cornerRadius: Layout.Radius.control).strokeBorder(Ink.line) }
      .tint(Ink.action)
      .sheet(isPresented: $reviewingHost, onDismiss: { Task { do { try await refresh() } catch { report(error.localizedDescription) } } }) {
        SampleHostReview(store: store, bot: chat.id, requestID: message.id)
      }
      .sheet(isPresented: $openingScreen) {
        if let bot = chat.isGroup ? store.navigation?.current.bots.first(where: { $0.id == message.botId }) : chat {
          SampleScreen(store: store, chat: bot, requestedRun: block.state == "Needs you" ? message.runId : nil)
        }
      }
      .confirmationDialog("Allow \(chat.name) to use \(block.name ?? "this server")?", isPresented: $reviewingServer, titleVisibility: .visible) {
        Button("Allow access") { finishSampleConnection(true) }
        Button("Dismiss request", role: .destructive) { finishSampleConnection(false) }
        Button("Cancel", role: .cancel) {}
      } message: { Text("This permission applies only to the sample workspace.") }
      .sheet(
        isPresented: $connecting,
        onDismiss: {
          Task { do { try await refresh() } catch { report(error.localizedDescription) } }
        }
      ) {
        if let api = store.client, let provider = block.provider, let thread = message.threadId,
          let bot = chat.isGroup ? message.botId : chat.id
        {
          ConnectorAuthorization(
            api: api, provider: provider, connector: block.connectorId,
            name: block.name ?? provider,
            origin: .init(botId: bot, threadId: thread, messageId: message.id))
        } else if let library = store.sampleIntegrations, let seed = try? CatalogSeed.bundled.get(),
          let entry = library.catalog(seed).first(where: { $0.slug == block.provider && $0.connectorId == block.connectorId }) {
          SampleAppReview(store: store, entry: entry) { finishSampleConnection(true) }.integrationSheet()
        }
      }
  }
  private func finishSampleConnection(_ allow: Bool) {
    store.resolveSampleConnection(chat: chat.id, message: message.id, kind: block.kind, allow: allow)
    Task { do { try await refresh() } catch { report(error.localizedDescription) } }
  }
  private func perform(choice: String?) {
    guard !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        if let api = store.client {
          if let choice, block.kind == "choice", block.answerId == nil, !chat.isGroup {
            if choice == "_dismissed" {
              let _: Empty = try await api.rpc("onboarding/dismissFocus", chat.target)
            } else {
              let _: Empty = try await api.rpc(
                "onboarding/choose", chat.target.merging(["optionId": choice]) { $1 })
            }
          } else if block.plainQuestion, let run = message.runId {
            let _: Empty = try await api.rpc(
              "threads/answer",
              chat.target.merging([
                "messageId": message.id, "runId": run, "answer": answer, "clientNonce": nonce,
              ]) { $1 })
          } else {
            return
          }
        } else if var sample = store.sample, var items = sample.transcripts[chat.id],
          let index = items.firstIndex(where: { $0.id == message.id }),
          let slot = items[index].blocks.firstIndex(where: { $0.kind == block.kind })
        {
          if let choice {
            items[index].blocks[slot].answerId = choice
          } else {
            var response = Sample.message((items.last?.seq ?? 0) + 1, "user", answer)
            response.replyToMessageId = message.id
            response.replyPreview = .init(text: block.label)
            items[index].blocks[slot].status = "answered"
            items[index].blocks[slot].answerMessageId = response.id
            items.append(response)
          }
          sample.transcripts[chat.id] = items
          store.sample = sample
        }
        answer = ""
        nonce = UUID().uuidString
        try await refresh()
      } catch { report(error.localizedDescription) }
    }
  }
}
