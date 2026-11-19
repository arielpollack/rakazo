import SwiftUI
import UniformTypeIdentifiers

struct Conversation: View {
  @ObservedObject var store: WorkspaceStore
  let chat: Chat
  let onProfile: () -> Void
  let compact: Bool
  var revealSidebar: (() -> Void)?
  @StateObject private var feed = Timeline()
  @Environment(\.scenePhase) var phase
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.colorSchemeContrast) private var contrast
  @State private var files: [Upload] = []
  @State private var draftText = ""
  @State private var picking = false
  @State private var reading = false
  @State private var stopping = false
  @State private var quote: Message?
  @State private var excerpt: String?
  @State private var consent: Outbox.ConsentRequest?
  /// Bumped on each send, to follow it to the end of the transcript.
  @State private var sentCount = 0
  @State private var reload = 0
  @State private var showLatest = false
  @State private var bottomVisible = true
  @FocusState private var focus: Bool
  var draft: Binding<String> {
    Binding(
      get: { draftText },
      set: {
        draftText = $0
        store.drafts[store.draftKey(chat)] = $0
      })
  }
  var body: some View {
    let colors = OutgoingColors(chat: chat, contrast: contrast)
    GeometryReader { geometry in
      VStack(spacing: 0) {
        if !compact {
          HStack(spacing: 8) {
            if let revealSidebar {
              Glyph(icon: "sidebar.left", label: "Show chats", action: revealSidebar)
            }
            profileButton
            Spacer(minLength: 0)
            #if os(macOS)
              Glyph(icon: "sidebar.right", label: "Conversation details", action: onProfile)
            #else
              Glyph(icon: "info.circle", label: "Conversation details", action: onProfile)
            #endif
          }.padding(.horizontal, Layout.Space.medium).frame(minHeight: Layout.headerHeight)
        }
        ScrollViewReader { proxy in
          ZStack(alignment: .bottomTrailing) {
            ScrollView {
              LazyVStack(spacing: 9) {
                if feed.older != nil, let api = store.client {
                  Button("Load earlier messages") { Task { await feed.previous(api, chat: chat) } }
                    .font(.caption).padding(6).disabled(feed.working)
                }
                if feed.loading {
                  ProgressView().padding()
                } else if feed.rows.visible.isEmpty && feed.older == nil && feed.connection == nil
                  && feed.turns.isEmpty && feed.runFailure == nil
                {
                  VStack(spacing: 12) {
                    Avatar(chat: chat, size: 72)
                    Text(chat.name).font(.title2.bold())
                    Text(
                      chat.description?.isEmpty == false
                        ? chat.description! : "Start a conversation"
                    ).foregroundStyle(.secondary)
                  }.padding(.top, 65)
                }
                ForEach(Array(feed.rows.visible.enumerated()), id: \.element.id) { index, message in
                  VStack(spacing: 9) {
                    if Clock.needsSeparator(
                      message.createdAt,
                      after: index == 0 ? nil : feed.rows.visible[index - 1].createdAt)
                    {
                      Text(Clock.label(message.createdAt, full: true)).font(
                        .caption.weight(.medium)
                      ).foregroundStyle(.secondary).padding(.vertical, Layout.Space.small)
                    }
                    Bubble(
                      message: message, chat: chat, store: store, outgoingColors: colors,
                      reactions: feed.rows.reactions[message.id] ?? [:],
                      waitingForUser: feed.turns.contains { $0.id == message.runId && $0.pose == .waiting },
                      reload: { _ = try await feed.refresh(store: store, chat: chat) },
                      report: { feed.problem = $0 },
                      width: min(
                        Layout.readingWidth,
                        geometry.size.width
                          * (typeSize.isAccessibilitySize ? 0.92 : compact ? 0.82 : 0.75)),
                      reply: { selection in
                        quote = message
                        excerpt = selection
                        focus = true
                      })
                  }
                }
                OutboxRows(
                  outbox: store.outbox, chat: chat, colors: colors,
                  width: min(
                    Layout.readingWidth,
                    geometry.size.width
                      * (typeSize.isAccessibilitySize ? 0.92 : compact ? 0.82 : 0.75)))
                ChatActivityRows(
                  turns: feed.turns, chat: chat, bots: store.navigation?.current.bots ?? [],
                  waiting: store.device(of: chat).flatMap { $0.connected ? nil : "Waiting for \($0.name)" })
                if let failure = feed.runFailure {
                  Problem(text: failure).frame(maxWidth: .infinity, alignment: .leading)
                }
                Color.clear.frame(height: 1).id("bottom").onAppear {
                  bottomVisible = true
                  showLatest = false
                }.onDisappear { bottomVisible = false }
              }.padding(.horizontal, compact ? Layout.Space.medium : Layout.Space.roomy).padding(
                .top, Layout.Space.small
              ).padding(.bottom, Layout.Space.small)
            }.defaultScrollAnchor(.bottom).scrollDismissesKeyboard(.interactively)
              .onChange(of: feed.turns) { _, _ in
                if bottomVisible { proxy.scrollTo("bottom", anchor: .bottom) }
              }
              .onChange(of: sentCount) { _, _ in
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
              }
              .onChange(of: feed.rows.visible.last?.id) { old, _ in
                if old == nil || bottomVisible {
                  DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
                } else {
                  showLatest = true
                }
              }
            if showLatest {
              Glyph(icon: "arrow.down", label: "Jump to latest", size: compact ? Layout.touch : 36)
              {
                withAnimation(reduceMotion ? nil : Layout.motion) {
                  proxy.scrollTo("bottom", anchor: .bottom)
                }
                showLatest = false
              }.background(.regularMaterial, in: Circle()).shadow(radius: 2).padding(
                Layout.Space.medium)
            }
          }
        }
        if let connection = feed.connection {
          HStack {
            Text(connection).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Button("Retry") { reload += 1 }.font(.caption)
          }.padding(5)
        }
        composer(colors).frame(maxWidth: Layout.readingWidth + 204).padding(
          .horizontal, Layout.Space.medium
        ).padding(.vertical, Layout.Space.small).frame(maxWidth: .infinity)
      }
      .inlineMobileTitle().toolbar {
        #if os(iOS)
          if compact { ToolbarItem(placement: .principal) { profileButton } }
        #endif
      }
    }.onAppear { draftText = store.drafts[store.draftKey(chat)] ?? "" }.task(
      id: "\(reload)-\(phase == .active)"
    ) { if phase == .active { await feed.observe(store: store, chat: chat) } }
    .onChange(of: store.sample?.computers?[chat.id]?.pendingRun) { _, _ in
      Task { _ = try? await feed.refresh(store: store, chat: chat) }
    }
    .task(id: phase) {
      if phase == .active, chat.unread == true { try? await store.mark(chat, unread: false) }
    }
    .confirmationDialog(
      "Stop the active runs in this conversation?", isPresented: $stopping,
      titleVisibility: .visible
    ) {
      Button("Stop runs", role: .destructive) {
        Task {
          do {
            guard let api = store.client else { return }
            let _: Empty = try await api.rpc("threads/stop", chat.target)
            _ = try await feed.refresh(store: store, chat: chat)
          } catch { feed.problem = error.localizedDescription }
        }
      }
    }
    .fileImporter(
      isPresented: $picking,
      allowedContentTypes: [
        .image, .pdf, .plainText, .commaSeparatedText, .json, .zip, .audio, .movie,
      ], allowsMultipleSelection: true
    ) { result in
      Task {
        reading = true
        defer { reading = false }
        do {
          let urls = try result.get()
          let staged = try await Self.readFiles(
            urls, count: files.count, bytes: files.reduce(0, { $0 + $1.data.count }),
            maxCount: min(store.account?.maxAttachmentsPerMessage ?? 5, 10),
            maxBytes: min(store.account?.maxUploadSizeBytes ?? 8_000_000, 16_000_000))
          files += staged
        } catch {
          if (error as NSError).code != NSUserCancelledError {
            feed.problem = error.localizedDescription
          }
        }
      }
    }
    .alert(
      "Conversation",
      isPresented: Binding(get: { feed.problem != nil }, set: { if !$0 { feed.problem = nil } })
    ) {
      Button("OK") { feed.problem = nil }
    } message: {
      Text(feed.problem ?? "")
    }
    .sheet(
      item: $consent,
      onDismiss: {
        if let request = store.outbox.consent, request.chatId == chat.id {
          store.outbox.decline(request)
        }
      }
    ) { request in
      ConsentView(
        status: request.status, cancel: { store.outbox.decline(request) },
        allow: { Task { await store.outbox.allow(request) } })
    }
    .onReceive(store.outbox.$consent) { consent = $0?.chatId == chat.id ? $0 : nil }
    // A sent message leaves the outbox once the transcript shows the server's copy.
    .onReceive(feed.$items) { items in
      store.outbox.shown(Set(items.filter { $0.role == "user" }.map(\.seq)), in: chat.id)
    }
    .onReceive(store.outbox.delivered.filter { [id = chat.id] in $0 == id }) { _ in
      Task { _ = try? await feed.refresh(store: store, chat: chat) }
    }
  }
  private var subtitle: String {
    if let device = store.device(of: chat) {
      return "\(device.name) · \(device.connected ? "Online" : "Offline")"
    }
    return chat.isGroup ? "Group chat" : "Bot"
  }
  private var profileButton: some View {
    #if os(macOS)
      let avatarSize: CGFloat = 28
      let hitHeight = Layout.pointer
    #else
      let avatarSize: CGFloat = 35
      let hitHeight = compact ? Layout.touch : 36
    #endif
    return Button(action: onProfile) {
      HStack(spacing: Layout.Space.small) {
        if !compact {
          Avatar(
            chat: chat, size: avatarSize,
            pose: feed.turns.first(where: { $0.botID == chat.id })?.pose ?? .idle)
        }
        VStack(alignment: compact ? .center : .leading, spacing: 1) {
          Text(chat.name).font(.headline).lineLimit(1)
          if !typeSize.isAccessibilitySize {
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }.padding(.horizontal, Layout.Space.tight).frame(minHeight: hitHeight)
        .contentShape(Capsule())
    }.buttonStyle(.plain).accessibilityLabel("Open profile for \(chat.name)")
      .accessibilityValue(subtitle)
      .accessibilityIdentifier("profile").help("Open conversation profile")
  }
  private func composer(_ colors: OutgoingColors) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if let quote {
        HStack {
          Image(systemName: "arrowshape.turn.up.left")
          Text(excerpt ?? quote.text).lineLimit(1)
          Spacer()
          Glyph(icon: "xmark", label: "Cancel reply") {
            self.quote = nil
            excerpt = nil
          }
        }.font(.caption).padding(.horizontal, 8)
      }
      if !files.isEmpty {
        ScrollView(.horizontal) {
          HStack {
            ForEach(files) { file in
              Button {
                files.removeAll { $0.id == file.id }
              } label: {
                Label(file.name, systemImage: "paperclip").lineLimit(1)
                Image(systemName: "xmark.circle.fill")
              }.buttonStyle(.bordered).font(.caption)
            }
          }
        }
      }
      HStack(alignment: .bottom, spacing: Layout.Space.small) {
        Glyph(
          icon: "paperclip", label: "Attach file", size: compact ? Layout.touch : Layout.pointer
        ) {
          picking = true
        }
        TextField("Message \(chat.name)", text: draft, axis: .vertical).textFieldStyle(.plain)
          .lineLimit(1...6).focused($focus).font(TypeRole.message).padding(
            .vertical, Layout.Space.small
          ).padding(.horizontal, 12).frame(minHeight: compact ? Layout.touch : Layout.pointer)
          .background(Ink.fill, in: RoundedRectangle(cornerRadius: Layout.Radius.composer))
          .accessibilityIdentifier(
            "composer"
          ).onKeyPress(.return, phases: .down) { press in
            #if os(macOS)
              if press.modifiers.isEmpty {
                start()
                return .handled
              }
            #endif
            return .ignored
          }
        if !canSend, feed.turns.contains(where: \.canStop) {
          Button {
            stopping = true
          } label: {
            Image(systemName: "stop.fill").font(.callout).frame(
              width: compact ? Layout.touch : Layout.pointer,
              height: compact ? Layout.touch : Layout.pointer
            )
            .foregroundStyle(colors.text).background(colors.fill, in: Circle())
          }.buttonStyle(.plain).accessibilityLabel("Stop").help("Stop active runs")
        } else {
          Button(action: start) {
            Image(systemName: "arrow.up").font(.system(size: compact ? 19 : 16, weight: .semibold))
              .frame(
                width: compact ? Layout.touch : Layout.pointer,
                height: compact ? Layout.touch : Layout.pointer
              ).foregroundStyle(canSend ? colors.text : Color.secondary).background(
                canSend ? colors.fill : Ink.fill, in: Circle())
          }.buttonStyle(.plain).disabled(!canSend).keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send").accessibilityIdentifier("send")
        }
      }
    }.disabled(reading)
  }
  var canSend: Bool {
    !reading
      && (!draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !files.isEmpty)
  }
  nonisolated static func readFiles(
    _ urls: [URL], count: Int, bytes: Int, maxCount: Int, maxBytes: Int
  ) async throws -> [Upload] {
    guard count + urls.count <= maxCount else {
      throw Failure("Too many attachments for one message.")
    }
    var staged = [Upload]()
    for url in urls {
      try Task.checkCancellation()
      let access = url.startAccessingSecurityScopedResource()
      defer { if access { url.stopAccessingSecurityScopedResource() } }
      let info = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isRegularFileKey])
      let limit = min(maxBytes, 24_000_000 - bytes - staged.reduce(0, { $0 + $1.data.count }))
      guard info.isRegularFile == true, let size = info.fileSize, size > 0, size <= limit else {
        throw Failure("The file is empty or exceeds the attachment size limit.")
      }
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      guard let data = try handle.read(upToCount: limit + 1), !data.isEmpty, data.count <= limit
      else { throw Failure("The file exceeds the attachment size limit.") }
      staged.append(
        Upload(
          name: url.lastPathComponent,
          mime: info.contentType?.preferredMIMEType ?? "application/octet-stream", data: data))
    }
    return staged
  }
  func start() {
    guard canSend else { return }
    let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count <= 100000 else {
      feed.problem = "Message exceeds 100,000 characters."
      return
    }
    if let api = store.client {
      do {
        try store.outbox.send(
          text, files: files, quote: quote, excerpt: excerpt, chat: chat, api: api)
      } catch {
        feed.problem = error.localizedDescription
        return
      }
    } else {
      store.demoSend(text, files: files, chat: chat, reply: quote, excerpt: excerpt)
      Task { _ = try? await feed.refresh(store: store, chat: chat) }
    }
    store.drafts[store.draftKey(chat)] = nil
    draftText = ""
    files = []
    quote = nil
    excerpt = nil
    sentCount += 1
  }
}

struct Bubble: View {
  let message: Message
  let chat: Chat
  @ObservedObject var store: WorkspaceStore
  let outgoingColors: OutgoingColors
  let reactions: [String: Int]
  let waitingForUser: Bool
  let reload: () async throws -> Void, report: (String) -> Void
  let width: CGFloat
  let reply: (String?) -> Void
  @State private var hovering = false
  @State private var picker = false
  @State private var selecting = false
  @State private var reacting = false
  @State private var pendingReaction: (String, String)?
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  private var stored: Bool {
    !message.id.hasPrefix("progress:") && !message.id.hasPrefix("subagent:")
  }
  private var canReact: Bool { stored && !message.blocks.contains { $0.kind == "channel_message" } }
  private var segments: [[Message.Block]] {
    message.blocks.filter(\.visible).reduce(into: []) { groups, block in
      if block.isNarration, groups.last?.last?.isNarration == true {
        groups[groups.count - 1].append(block)
      } else {
        groups.append([block])
      }
    }
  }
  var mine: Bool {
    message.role == "user" && (message.author == nil || message.author?.id == store.account?.userId)
  }
  var body: some View {
    VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
      if !mine, chat.isGroup,
        let name = store.navigation?.current.bots.first(where: { $0.id == message.botId })?.name
          ?? message.author?.name
      {
        Text(name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
      }
      ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
        let surface = mine || segment.first?.isNarration == true
        VStack(alignment: .leading, spacing: 6) {
          if index == 0, let quoted = message.replyQuote ?? message.replyPreview?.text {
            Text(verbatim: quoted).lineLimit(2).font(.caption).padding(7).background(
              .black.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
          }
          ForEach(Array(segment.enumerated()), id: \.offset) { _, block in
            if block.isNarration {
              MessageText(content: block.label).equatable()
            } else if ["file", "image"].contains(block.kind) {
              AttachmentBlock(block: block, chat: chat, api: store.client)
            } else if block.kind == "card", let pairs = block.lines {
              VStack(alignment: .leading, spacing: Layout.Space.small) {
                ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                  VStack(alignment: .leading, spacing: Layout.Space.tight) {
                    Text(pair.k).font(.caption.weight(.semibold))
                    Text(pair.v).textSelection(.enabled)
                  }.accessibilityElement(children: .combine)
                }
              }
            } else if block.kind == "ask", block.actions?.isEmpty == false {
              AskCard(
                block: block, message: message, chat: chat, store: store, refresh: reload,
                report: report)
            } else {
              AgentBlock(
                block: block, message: message, chat: chat, store: store, refresh: reload,
                report: report)
            }
          }
        }.font(TypeRole.message).padding(.horizontal, surface ? Layout.bubbleInsetX : 0).padding(
          .vertical, surface ? Layout.bubbleInsetY : 0
        ).foregroundStyle(mine ? outgoingColors.text : Color.primary)
          .tint(mine ? outgoingColors.text : nil).background(
            mine ? outgoingColors.fill : surface ? Ink.fill : .clear,
            in: RoundedRectangle(cornerRadius: Layout.Radius.bubble, style: .continuous)
          )
          #if os(iOS)
          .simultaneousGesture(TapGesture(count: 2).onEnded {
            if reactions["👍"] == nil { react("👍") }
          }, including: canReact && !waitingForUser && message.blocks.allSatisfy {
            ["text", "image", "file", "chart", "page"].contains($0.kind)
          } ? .all : .subviews)
          #endif
          .contextMenu {
            menuItems
            if canReact { Menu("React", systemImage: "face.smiling") { emojiButtons } }
          }
      }
      if !reactions.isEmpty {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 4) { badges }
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], alignment: .leading, spacing: 4) {
            badges
          }
        }
      }
    }.frame(maxWidth: width, alignment: mine ? .trailing : .leading).contentShape(Rectangle())
      .overlay(alignment: mine ? .topLeading : .topTrailing) {
        if stored && showsControls {
          HStack(spacing: 2) {
            if canReact {
              Button {
                picker.toggle()
              } label: {
                icon("face.smiling")
              }.accessibilityLabel("React").help("React")
                .popover(isPresented: $picker) {
                  HStack(spacing: 0) { emojiButtons }.padding(6).presentationCompactAdaptation(
                    .popover)
                }
            }
            Button {
              reply(nil)
            } label: {
              icon("arrowshape.turn.up.left")
            }.accessibilityLabel("Reply").help("Reply")
            Menu {
              menuItems
            } label: {
              icon("ellipsis")
            }.menuIndicator(.hidden).accessibilityLabel("More message actions")
          }.buttonStyle(.plain).padding(.horizontal, 3).background(.regularMaterial, in: Capsule())
        }
      }
      .onHover { hovering = $0 }
      .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
      .sheet(isPresented: $selecting) {
        MessageSelection(text: message.selectableText, reply: reply)
      }
  }
  var showsControls: Bool {
    #if os(macOS)
      hovering || picker || voiceOver
    #else
      false
    #endif
  }
  func icon(_ name: String) -> some View {
    #if os(macOS)
      Image(systemName: name).font(.caption).frame(width: 27, height: 24).contentShape(Rectangle())
    #else
      Image(systemName: name).font(.footnote).frame(width: 44, height: 44).contentShape(Rectangle())
    #endif
  }
  @ViewBuilder var menuItems: some View {
    if stored { Button("Reply", systemImage: "arrowshape.turn.up.left") { reply(nil) } }
    if stored {
      Button("Mark as unread", systemImage: "envelope.badge") {
        Task {
          do { try await store.mark(chat, unread: true, from: message.id) } catch {
            report(error.localizedDescription)
          }
        }
      }
    }
    if !message.selectableText.isEmpty {
      if stored { Button("Select text…", systemImage: "selection.pin.in.out") { selecting = true } }
      Button("Copy text", systemImage: "doc.on.doc") {
        PlatformClipboard.copy(message.selectableText)
      }
    }
  }
  @ViewBuilder var emojiButtons: some View {
    ForEach(TranscriptRows.emoji, id: \.self) { emoji in
      Button {
        react(emoji)
      } label: {
        Text(emoji).font(.title2).frame(width: 44, height: 44)
      }
      .buttonStyle(.plain).accessibilityLabel(emoji).disabled(reacting)
    }
  }
  @ViewBuilder var badges: some View {
    ForEach(TranscriptRows.emoji.filter { reactions[$0] != nil }, id: \.self) { emoji in
      Button {
        react(emoji)
      } label: {
        Text("\(emoji) \(reactions[emoji] ?? 0)").font(.caption.weight(.medium)).padding(
          .horizontal, 9
        ).padding(.vertical, 4).background(Ink.fill, in: Capsule())
      }
      .buttonStyle(.plain).disabled(!canReact || reacting).accessibilityLabel(
        "\(emoji), \(reactions[emoji] ?? 0) reactions")
    }
  }
  func react(_ emoji: String) {
    guard !reacting else { return }
    picker = false
    reacting = true
    let nonce = pendingReaction?.0 == emoji ? pendingReaction!.1 : UUID().uuidString
    pendingReaction = (emoji, nonce)
    Task {
      defer { reacting = false }
      do {
        try await store.react(emoji, to: message, chat: chat, nonce: nonce)
        pendingReaction = nil
        try await reload()
      } catch { report(error.localizedDescription) }
    }
  }
}

struct ConsentView: View {
  let status: Consent
  let cancel: () -> Void
  let allow: () -> Void
  var body: some View {
    NavigationStack {
      Form {
        Section("These providers may receive data for this action") {
          ForEach(status.unapproved) { item in
            VStack(alignment: .leading, spacing: 6) {
              Text(item.name).font(.headline)
              Text(item.detail).font(.callout).foregroundStyle(.secondary)
            }
          }
        }
      }.formStyle(.grouped).navigationTitle("Review AI data sharing").inlineMobileTitle()
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Not now", action: cancel) }
          ToolbarItem(placement: .confirmationAction) {
            Button("Allow and continue", action: allow).accessibilityIdentifier("allowConsent")
          }
        }
    }
    // A Mac sheet takes its content's height, and a form alone has almost none.
    #if os(macOS)
      .frame(minWidth: 400, idealWidth: 460, minHeight: 240, idealHeight: 320)
    #endif
  }
}
