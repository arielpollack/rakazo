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
  @StateObject private var attachments = ChatAttachments()
  @State private var fileTargeted = false
  @State private var unreadMarker: String?
  @State private var draftText = ""
  @State private var picking = false
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
  #if os(macOS)
  @State private var composerFocusRequest = 0
  private var acceptsFiles: Bool { !attachments.reading && !picking && consent == nil }
  #endif
  var draft: Binding<String> {
    Binding(
      get: { draftText },
      set: {
        draftText = $0
        store.drafts[store.draftKey(chat)] = $0.isEmpty ? nil : $0
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
                      unreadMarker: $unreadMarker,
                      reload: { _ = try await feed.refresh(store: store, chat: chat) },
                      report: { feed.problem = $0 },
                      width: min(
                        Layout.readingWidth,
                        geometry.size.width
                          * (typeSize.isAccessibilitySize ? 0.92 : compact ? 0.82 : 0.75)),
                      reply: { selection in
                        quote = message
                        excerpt = selection
                        #if os(macOS)
                        composerFocusRequest += 1
                        #else
                        focus = true
                        #endif
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
                  turns: feed.turns, chat: chat, bots: store.navigation?.current.bots ?? [])
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
        ZStack(alignment: .bottom) {
          composer(colors).opacity(fileTargeted ? 0 : 1)
          #if os(macOS)
            if fileTargeted { MacFileDropCue(name: chat.name).allowsHitTesting(false) }
          #endif
        }.frame(maxWidth: Layout.readingWidth + 204).padding(
          .horizontal, Layout.Space.medium
        ).padding(.vertical, Layout.Space.small).frame(maxWidth: .infinity)
      }
      .inlineMobileTitle().toolbar {
        #if os(iOS)
          if compact { ToolbarItem(placement: .principal) { profileButton } }
        #endif
      }
    }
    #if os(macOS)
    .contentShape(Rectangle())
    .onDrop(of: [.fileURL], delegate: MacChatFileDrop(targeted: $fileTargeted,
      enabled: acceptsFiles,
      receive: { MacChatFileDrop.stage($0, in: attachments, limits: .init(account: store.account)) }))
    #endif
    .onDisappear { fileTargeted = false; attachments.cancelRead() }
    .onAppear { draftText = store.drafts[store.draftKey(chat)] ?? "" }.task(
      id: "\(reload)-\(phase == .active)"
    ) { if phase == .active { await feed.observe(store: store, chat: chat) } }
    .onChange(of: store.sample?.computers?[chat.id]?.pendingRun) { _, _ in
      Task { _ = try? await feed.refresh(store: store, chat: chat) }
    }
    .task(id: phase) {
      if phase == .active, chat.unread == true, unreadMarker == nil { try? await store.mark(chat, unread: false) }
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
      allowedContentTypes: ChatAttachments.pickerTypes, allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let urls):
        stage(urls)
      case .failure(let error):
        if (error as NSError).code != NSUserCancelledError { attachments.problem = error.localizedDescription }
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
            Text(chat.isGroup ? "Group chat" : "Bot").font(
              .caption
            ).foregroundStyle(.secondary).lineLimit(1)
          }
        }
      }.padding(.horizontal, Layout.Space.tight).frame(minHeight: hitHeight)
        .contentShape(Capsule())
    }.buttonStyle(.plain).accessibilityLabel("Open profile for \(chat.name)")
      .accessibilityIdentifier("profile").help("Open conversation profile")
  }
  private func composer(_ colors: OutgoingColors) -> some View {
    #if os(macOS)
    let spacing: CGFloat = 12
    #else
    let spacing: CGFloat = 6
    #endif
    return VStack(alignment: .leading, spacing: spacing) {
      if let quote {
        HStack(spacing: Layout.Space.small) {
          RoundedRectangle(cornerRadius: 2).fill(chat.tint).frame(width: 3)
          VStack(alignment: .leading, spacing: 2) {
            Text(quote.role == "user" ? (quote.author?.name ?? "You")
              : (store.navigation?.current.bots.first { $0.id == quote.botId }?.name ?? chat.name))
              .font(.caption.weight(.semibold))
            Text(verbatim: excerpt ?? quote.text).font(.caption).lineLimit(1).foregroundStyle(.secondary)
          }
          Spacer()
          Glyph(icon: "xmark", label: "Cancel reply") {
            self.quote = nil
            excerpt = nil
          }
        }.fixedSize(horizontal: false, vertical: true).padding(.horizontal, 8)
      }
      if let problem = attachments.problem {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
          Text(verbatim: problem).textSelection(.enabled)
          Spacer(minLength: 0)
          Button { attachments.problem = nil } label: { Image(systemName: "xmark") }
            .buttonStyle(.plain).accessibilityLabel("Dismiss attachment error")
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6)
      }
      if !attachments.files.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: Layout.Space.small) {
            ForEach(attachments.files) { file in
              #if os(macOS)
              MacAttachmentToken(file: file) { attachments.remove(file) }
              #else
              Button {
                attachments.remove(file)
              } label: {
                Label(file.name, systemImage: "paperclip").lineLimit(1)
                Image(systemName: "xmark.circle.fill")
              }.buttonStyle(.bordered).font(.caption).accessibilityLabel("Remove \(file.name)")
              #endif
            }
          }
        }.scrollIndicators(.hidden)
      }
      HStack(alignment: .bottom, spacing: composerControlSpacing) {
        Glyph(
          icon: "paperclip", label: "Attach file", size: compact ? Layout.touch : Layout.pointer
        ) {
          picking = true
        }.disabled(attachments.reading)
        Group {
          #if os(macOS)
          MacChatEditor(text: draft, label: "Message \(chat.name)", focusRequest: composerFocusRequest,
            submit: start, canDrop: acceptsFiles, highlight: { fileTargeted = $0 }, attach: stage)
            .overlay(alignment: .topLeading) {
              if draftText.isEmpty {
                Text("Message \(chat.name)").foregroundStyle(.tertiary).allowsHitTesting(false).accessibilityHidden(true)
              }
            }
            .frame(minHeight: Layout.pointer)
          #else
          TextField("Message \(chat.name)", text: draft, axis: .vertical).textFieldStyle(.plain)
            .lineLimit(1...6).focused($focus).accessibilityIdentifier("composer")
            .padding(.vertical, Layout.Space.small).padding(.horizontal, 12)
            .frame(minHeight: compact ? Layout.touch : Layout.pointer)
            .background(Ink.fill, in: RoundedRectangle(cornerRadius: Layout.Radius.composer))
          #endif
        }.font(TypeRole.message)
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
            Group {
              if attachments.reading {
                ProgressView().controlSize(.small)
              } else {
                Image(systemName: "arrow.up").font(
                  .system(size: compact ? 19 : 16, weight: .semibold))
              }
            }.frame(
              width: compact ? Layout.touch : Layout.pointer,
              height: compact ? Layout.touch : Layout.pointer
            ).foregroundStyle(canSend ? colors.text : Color.secondary).background(
              canSend ? colors.fill : disabledSendFill, in: Circle())
          }.buttonStyle(.plain).disabled(!canSend).keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("Send").accessibilityIdentifier("send")
        }
      }
    }
    #if os(macOS)
    .padding(10)
    .background(Ink.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    #endif
  }
  #if os(macOS)
  private var composerControlSpacing: CGFloat { Layout.Space.tight }
  private var disabledSendFill: Color { Ink.selection }
  #else
  private var composerControlSpacing: CGFloat { Layout.Space.small }
  private var disabledSendFill: Color { Ink.fill }
  #endif
  var canSend: Bool {
    !attachments.reading
      && (!draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !attachments.files.isEmpty)
  }
  @discardableResult private func stage(_ urls: [URL]) -> Bool {
    attachments.stage(count: urls.count, limits: .init(account: store.account)) { finish in
      finish(urls.map { .success($0) })
    }
  }
  func start() {
    guard canSend else { return }
    let text = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.count <= 100000 else {
      feed.problem = "Message exceeds 100,000 characters."
      return
    }
    let files = attachments.files
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
    attachments.clear()
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
  @Binding var unreadMarker: String?
  let reload: () async throws -> Void, report: (String) -> Void
  let width: CGFloat
  let reply: (String?) -> Void
  @State private var hovering = false
  @State private var picker = false
  @State private var selecting = false
  @State private var reacting = false
  @State private var copied: UUID?
  #if os(macOS)
  @State private var trackingMenu: ObjectIdentifier?
  #endif
  @State private var pendingReaction: (String, String)?
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var focused: ActionFocus?
  private enum ActionFocus: Hashable { case message, react, reply, more }
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
      #if os(macOS)
        if stored {
          MacChatActionLayout(outgoing: mine, maxContentWidth: width) {
            content.focusable().focused($focused, equals: .message)
            macActions
          }.background { MacChatHoverRegion { hovering = $0 } }
        } else {
          content.frame(maxWidth: width, alignment: mine ? .trailing : .leading)
        }
      #else
        content.frame(maxWidth: width, alignment: mine ? .trailing : .leading)
      #endif
      if !reactions.isEmpty {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 4) { badges }
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 52))], alignment: .leading, spacing: 4) {
            badges
          }
        }.frame(maxWidth: width, alignment: mine ? .trailing : .leading)
      }
    }.frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
      .sheet(isPresented: $selecting) {
        MessageSelection(text: message.selectableText, reply: reply)
      }
  }
  private var content: some View {
    VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
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
            menuItems(selection: true)
            if canReact { Menu("React", systemImage: "face.smiling") { emojiButtons } }
          }
      }
    }
  }
  #if os(macOS)
  private var macActions: some View {
    let visible = hovering || picker || voiceOver || focused != nil || copied != nil || trackingMenu != nil
    return ZStack {
      if visible {
        HStack(spacing: 2) {
          if canReact {
            Button { picker.toggle() } label: { icon("face.smiling") }
              .focused($focused, equals: .react).accessibilityLabel("React").help("React")
              .popover(isPresented: $picker) {
                HStack(spacing: 2) { emojiButtons }.padding(6)
                  .onExitCommand { picker = false }
              }
          }
          Button { reply(nil) } label: { icon("arrowshape.turn.up.left") }
            .focused($focused, equals: .reply).accessibilityLabel("Reply").help("Reply")
          Menu { menuItems(selection: false) } label: {
            icon(copied == nil ? "ellipsis" : "checkmark")
          }.menuStyle(.button).menuIndicator(.hidden).focused($focused, equals: .more)
            .accessibilityLabel(copied == nil ? "More message actions" : "Copied")
            .help(copied == nil ? "More message actions" : "Copied")
        }.buttonStyle(MacChatButtonStyle()).transition(.opacity)
          .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { note in
            if (hovering || focused == .more), let menu = note.object as? NSMenu { trackingMenu = ObjectIdentifier(menu) }
          }
          .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { note in
            if let menu = note.object as? NSMenu, trackingMenu == ObjectIdentifier(menu) { trackingMenu = nil }
          }
      }
    }.frame(width: canReact ? 88 : 58, height: 28)
      .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: visible)
      .task(id: copied) {
        guard copied != nil else { return }
        do { try await Task.sleep(for: .seconds(1.2)); copied = nil } catch {}
      }
  }
  private func icon(_ name: String) -> some View {
    Image(systemName: name).font(.system(size: 14, weight: .medium))
      .frame(width: 28, height: 28).contentShape(Rectangle())
  }
  #endif
  @ViewBuilder private func menuItems(selection: Bool) -> some View {
    if stored { Button("Reply", systemImage: "arrowshape.turn.up.left") { reply(nil) } }
    if stored && message.id != unreadMarker {
      Button("Mark as unread", systemImage: "envelope.badge") {
        Task {
          do {
            try await store.mark(chat, unread: true, from: message.id)
            unreadMarker = message.id
          } catch {
            report(error.localizedDescription)
          }
        }
      }
    }
    if !message.selectableText.isEmpty {
      if stored && selection { Button("Select text…", systemImage: "selection.pin.in.out") { selecting = true } }
      Button(selection ? "Copy text" : "Copy", systemImage: "doc.on.doc") {
        if PlatformClipboard.copy(message.selectableText) { copied = UUID() }
        else { report("Couldn’t copy the message. Try again.") }
      }
    }
  }
  @ViewBuilder var emojiButtons: some View {
    ForEach(TranscriptRows.emoji, id: \.self) { emoji in
      Button {
        react(emoji)
      } label: {
        #if os(macOS)
        Text(verbatim: emoji).font(.system(size: 23)).frame(width: 34, height: 34)
        #else
        Text(verbatim: emoji).font(.title2).frame(width: 44, height: 44)
        #endif
      }
      #if os(macOS)
      .buttonStyle(MacChatButtonStyle())
      #else
      .buttonStyle(.plain)
      #endif
      .accessibilityLabel(emoji).disabled(reacting)
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
      List {
        Section("These providers may receive data for this action") {
          ForEach(status.unapproved) { item in
            VStack(alignment: .leading, spacing: 6) {
              Text(item.name).font(.headline)
              Text(item.detail).font(.callout).foregroundStyle(.secondary)
            }
          }
        }
        Section {
          Button("Allow and continue", action: allow).accessibilityIdentifier("allowConsent")
          Button("Not now", role: .cancel, action: cancel)
        }
      }.navigationTitle("Review AI data sharing")
    }
  }
}
