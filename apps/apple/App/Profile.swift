import SwiftUI

struct Profile: View {
  struct Computer: Decodable {
    let mode: String
    let state: String
  }
  @ObservedObject var store: WorkspaceStore
  let chat: Chat
  var sheetHeightLimit: CGFloat? = nil
  let close: () -> Void
  @State private var tab = "Routines"
  @State private var routines: [Routine] = []
  @State private var pages: [PageItem] = []
  @State private var computer: Computer?
  @State private var busy = false
  @State private var problem: String?
  @State private var form = false
  @State private var selectedRoutine: Routine?
  @State private var editing = false
  @State private var screenOpen = false
  @State private var hostOpen = false
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var reload = 0
  var tabs: [String] {
    chat.isGroup ? ["Members", "Pages"] : ["Computer", "Routines", "Pages", "Advanced"]
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Profile").font(.headline)
        Spacer()
        Glyph(icon: "pencil", label: "Edit profile", size: Layout.touch) { editing = true }
        Glyph(icon: "xmark", label: "Close profile", size: Layout.touch, action: close)
      }.padding(.horizontal, Layout.Space.standard).padding(.top, Layout.Space.small)
        .profileHeightContribution()
      ScrollView {
        VStack(spacing: Layout.Space.medium) {
          Avatar(chat: chat, size: 80)
          Text(chat.name).font(.title.bold())
          if let desc = chat.description, !desc.isEmpty {
            Text(desc).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
          }
          if typeSize.isAccessibilitySize {
            tabsPicker.pickerStyle(.menu)
          } else {
            #if os(macOS)
              ViewThatFits(in: .horizontal) {
                tabsPicker.pickerStyle(.segmented).controlSize(.small).labelsHidden().fixedSize()
                tabsPicker.pickerStyle(.menu)
              }.padding(.top, Layout.Space.medium)
            #else
              tabsPicker.pickerStyle(.segmented).labelsHidden().padding(.top, Layout.Space.medium)
            #endif
          }
          if busy {
            ProgressView().padding()
          } else if let problem {
            Problem(text: problem)
            Button("Retry") { reload += 1 }
          } else {
            section
            if sheetHeightLimit == nil && tab == "Routines" { newRoutineButton }
          }
        }.padding(.horizontal, Layout.Space.standard).padding(.vertical, Layout.Space.medium).frame(
          maxWidth: .infinity
        ).profileHeightContribution()
      }.scrollBounceBehavior(.basedOnSize).accessibilityIdentifier("profile-sections")
      if sheetHeightLimit != nil && tab == "Routines" && !chat.isGroup {
        newRoutineButton.padding(.horizontal, Layout.Space.standard)
          .padding(.top, Layout.Space.small)
          .padding(.bottom, Layout.Space.standard).profileHeightContribution()
      }
    }.background(Ink.canvas).modifier(ProfileSheetSizing(limit: sheetHeightLimit))
      .onAppear { if chat.isGroup { tab = "Members" } }.task(id: "\(tab)-\(reload)") { await load() }
      .sheet(isPresented: $form) {
        RoutineForm(store: store, chat: chat) {
          form = false
          reload += 1
        }
      }.sheet(isPresented: $editing) { ProfileEditor(store: store, chat: chat) }
      .sheet(isPresented: $screenOpen) { SampleScreen(store: store, chat: chat, requestedRun: nil) }
      .sheet(isPresented: $hostOpen) { SampleHostReview(store: store, bot: chat.id) }
      .sheet(item: $selectedRoutine, onDismiss: { reload += 1 }) { routine in
        RoutineDetails(store: store, chat: chat, routine: routine)
      }
  }
  var tabsPicker: some View {
    Picker("Profile tabs", selection: $tab) { ForEach(tabs, id: \.self) { Text($0) } }
  }
  private var newRoutineButton: some View {
    Button("New routine", systemImage: "plus") { form = true }.buttonStyle(.bordered)
  }
  @ViewBuilder var section: some View {
    switch tab {
    case "Routines":
      if routines.isEmpty {
        Notice(
          symbol: "clock.arrow.circlepath", title: "No routines yet",
          detail: "Give this bot something to do on a schedule.")
      } else {
        ForEach(routines) { routine in
          Button {
            selectedRoutine = routine
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              HStack {
                Text(routine.name).fontWeight(.semibold)
                Spacer()
                Text(routine.active ? "Active" : "Paused").font(.caption)
              }
              Text(routine.prompt).font(.callout).foregroundStyle(.secondary)
              Text(routine.crons.joined(separator: ", ") + " · " + routine.timezone).font(.caption)
                .foregroundStyle(.secondary)
            }.padding(12).background(Ink.fill, in: RoundedRectangle(cornerRadius: 12))
          }.buttonStyle(.plain)
        }
      }
    case "Pages":
      if pages.isEmpty {
        Notice(
          symbol: "doc", title: "No pages yet", detail: "Pages from this conversation appear here.")
      } else {
        ForEach(pages) { item in
          if let url = store.link(chat, query: [URLQueryItem(name: "page", value: item.id)]) {
            Link(destination: url) {
              Label(item.title, systemImage: "doc.text").frame(
                maxWidth: .infinity, alignment: .leading
              ).padding(12).background(Ink.fill, in: RoundedRectangle(cornerRadius: 10))
            }
          }
        }
      }
    case "Computer":
      if store.demo {
        Button("View bot screen", systemImage: "display") { screenOpen = true }.buttonStyle(.bordered)
        #if os(macOS)
          Button("Computer access…") { hostOpen = true }
        #endif
      } else {
        if offersRunsOn { RunsOnBox(store: store, chat: chat, devices: store.devices) }
        // A bot on a paired computer has no server computer to describe.
        if chat.computerDeviceId == nil {
          Notice(symbol: "desktopcomputer", title: computer?.state.capitalized ?? "Computer", detail: (computer?.mode ?? chat.computerMode)?.capitalized)
        }
        webLink("Open computer in Rakazo ↗")
      }
    case "Members":
      ForEach(chat.members?.compactMap(\.botId) ?? [], id: \.self) { id in
        if let member = store.navigation?.current.bots.first(where: { $0.id == id }) {
          HStack {
            Avatar(chat: member, size: 32)
            Text(member.name)
            Spacer()
          }.padding(8)
        }
      }
    default:
      VStack(alignment: .leading, spacing: 12) {
        LabeledContent("Model", value: chat.modelId ?? "Server default")
        if let value = chat.instructions, !value.isEmpty {
          Text("Instructions").bold()
          Text(value).font(.callout).textSelection(.enabled)
        }
        webLink("Manage bot on the web ↗")
      }.padding(10)
    }
  }
  /// A paired computer can take the bot; on a Mac, so can this one once allowed.
  private var offersRunsOn: Bool {
    #if os(macOS)
      return store.client != nil
    #else
      return !store.devices.isEmpty
    #endif
  }
  @ViewBuilder func webLink(_ title: String) -> some View {
    if let url = store.link(chat) { Link(title, destination: url).font(.callout) }
  }
  func load() async {
    problem = nil
    busy = true
    let active = tab
    defer { if !Task.isCancelled { busy = false } }
    do {
      if let api = store.client {
        switch active {
        case "Routines":
          let value: [Routine] = try await api.rpc("routines/list", chat.target)
          try Task.checkCancellation()
          routines = value
        case "Pages":
          let value: Pages = try await api.rpc("pages/list", chat.target)
          try Task.checkCancellation()
          pages = value.items
        case "Computer":
          let value: Computer = try await api.rpc("computer/status", chat.target)
          try Task.checkCancellation()
          computer = value
        default: break
        }
      } else {
        routines = store.sample?.routines[chat.id] ?? []
      }
    } catch { if !Task.isCancelled { problem = error.localizedDescription } }
  }
}

private struct ProfileHeight: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value += nextValue() }
}

extension View {
  fileprivate func profileHeightContribution() -> some View {
    background {
      GeometryReader { geometry in
        Color.clear.preference(key: ProfileHeight.self, value: geometry.size.height)
      }
    }
  }
}

private struct ProfileSheetSizing: ViewModifier {
  let limit: CGFloat?
  @State private var contentHeight: CGFloat?

  func body(content: Content) -> some View {
    if let limit {
      let height = max(1, min(contentHeight ?? limit, limit))
      #if os(macOS)
      content.frame(height: height)
        .onPreferenceChange(ProfileHeight.self) { if $0 > 0 { contentHeight = ceil($0) } }
      #else
      sized(content, height: height).presentationDetents([.height(height)])
        .onPreferenceChange(ProfileHeight.self) { if $0 > 0 { contentHeight = ceil($0) } }
      #endif
    } else {
      content
    }
  }

  @ViewBuilder private func sized(_ content: Content, height: CGFloat) -> some View {
    let fitted = content.frame(idealHeight: height)
    if #available(iOS 18, macOS 15, *) {
      fitted.presentationSizing(.form.fitted(horizontal: false, vertical: true))
    } else {
      fitted
    }
  }
}

struct ProfileEditor: View {
  @ObservedObject var store: WorkspaceStore
  let original: Chat
  @State private var name: String
  @State private var details: String
  @State private var instructions: String
  @State private var members: [String]
  @State private var saving = false
  @State private var problem: String?
  @Environment(\.dismiss) private var dismiss
  init(store: WorkspaceStore, chat: Chat) {
    self.store = store
    original = chat
    _name = State(initialValue: chat.name)
    _details = State(initialValue: chat.description ?? "")
    _instructions = State(initialValue: chat.instructions ?? "")
    _members = State(initialValue: chat.members?.compactMap(\.botId) ?? [])
  }
  private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  var body: some View {
    NavigationStack {
      Form {
        Section("Name") { TextField("Name", text: $name) }
        if original.isGroup {
          Section("Members (\(members.count) of 10)") {
            ForEach(store.navigation?.current.bots.filter { $0.archivedAt == nil } ?? []) { bot in
              let isMember = members.contains(bot.id)
              Button {
                if isMember { members.removeAll { $0 == bot.id } } else { members.append(bot.id) }
              } label: {
                HStack {
                  Avatar(chat: bot, size: 28)
                  Text(bot.name).foregroundStyle(.primary)
                  Spacer()
                  Image(systemName: isMember ? "checkmark.circle.fill" : "circle").foregroundStyle(
                    isMember ? Ink.action : Color.secondary)
                }
              }.disabled(!isMember && members.count >= 10).accessibilityAddTraits(
                isMember ? .isSelected : [])
            }
          }
        } else {
          Section("Description") {
            TextField("What does this bot help with?", text: $details, axis: .vertical).lineLimit(
              2...6)
          }
          Section("Instructions") {
            TextField("How should this bot work?", text: $instructions, axis: .vertical).lineLimit(
              4...12)
          }
        }
        if let problem { Problem(text: problem) }
      }.disabled(saving).navigationTitle("Edit profile").inlineMobileTitle()
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }.disabled(saving)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save() }.disabled(
              saving || cleanName.isEmpty || cleanName.count > 80 || details.count > 4000
                || instructions.count > 20000
                || original.isGroup && !(2...10).contains(members.count))
          }
        }
    }.interactiveDismissDisabled(saving)
  }
  func save() {
    saving = true
    Task {
      defer { saving = false }
      do {
        try await store.update(
          original, name: cleanName == original.name ? nil : cleanName,
          description: original.isGroup || details == (original.description ?? "") ? nil : details,
          instructions: original.isGroup || instructions == (original.instructions ?? "")
            ? nil : instructions,
          members: original.isGroup && members != original.members?.compactMap(\.botId)
            ? members : nil)
        dismiss()
      } catch { problem = error.localizedDescription }
    }
  }
}

struct RoutineForm: View {
  @ObservedObject var store: WorkspaceStore
  let chat: Chat
  let finished: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var prompt = ""
  @State private var time =
    Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
  @State private var busy = false
  @State private var problem: String?
  @State private var consent: Consent?
  #if os(macOS)
    @State private var fieldsHeight: CGFloat?
  #endif
  var body: some View {
    Group {
      #if os(macOS)
        macSheet
      #else
        mobileSheet
      #endif
    }.interactiveDismissDisabled(busy).sheet(item: $consent) { status in
      ConsentView(
        status: status, cancel: { consent = nil },
        allow: {
          consent = nil
          save(status)
        })
    }
  }

  private var createDisabled: Bool {
    busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  #if os(macOS)
    private var macSheet: some View {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: Layout.Space.medium) {
          Avatar(chat: chat, size: Layout.rowAvatar)
          VStack(alignment: .leading, spacing: Layout.Space.hair) {
            Text("New routine").font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("For \(chat.name)").foregroundStyle(.secondary).lineLimit(1).help(chat.name)
          }
        }.padding(.horizontal, Layout.Space.roomy).padding(.top, Layout.Space.roomy)

        ScrollView {
          macFields.onGeometryChange(for: CGFloat.self) {
            ceil($0.size.height)
          } action: {
            fieldsHeight = $0
          }
        }.scrollBounceBehavior(.basedOnSize).frame(
          idealHeight: fieldsHeight, maxHeight: fieldsHeight)

        Divider()
        HStack(spacing: Layout.Space.small) {
          Label("Starts paused", systemImage: "pause.circle").font(.callout)
            .foregroundStyle(.secondary).help("Open the routine to activate it when you’re ready.")
          Spacer()
          Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
          Button("Create routine") { save(nil) }.keyboardShortcut(.defaultAction).disabled(
            createDisabled)
        }.padding(.horizontal, Layout.Space.roomy).padding(.vertical, Layout.Space.standard)
      }.frame(width: 440)
    }

    private var macFields: some View {
      VStack(alignment: .leading, spacing: Layout.Space.standard) {
        VStack(alignment: .leading, spacing: Layout.Space.small) {
          Text("Name").font(.headline).accessibilityHidden(true)
          TextField("Name", text: $name, prompt: Text("Morning briefing"))
            .labelsHidden().controlSize(.large).accessibilityIdentifier("routine-name")
        }
        VStack(alignment: .leading, spacing: Layout.Space.small) {
          Text("Instructions").font(.headline).accessibilityHidden(true)
          TextField(
            "Instructions", text: $prompt, prompt: Text("What should this bot do?"), axis: .vertical
          )
          .labelsHidden().controlSize(.large).lineLimit(3...6).accessibilityIdentifier(
            "routine-prompt")
        }
        Divider()
        HStack(spacing: Layout.Space.medium) {
          VStack(alignment: .leading, spacing: Layout.Space.tight) {
            Text("Daily schedule").font(.headline)
            Text(
              TimeZone.current.localizedName(for: .generic, locale: .current)
                ?? TimeZone.current.identifier
            )
            .font(.callout).foregroundStyle(.secondary).help(TimeZone.current.identifier)
          }
          Spacer()
          DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
            .labelsHidden().accessibilityIdentifier("routine-time")
        }
        if let problem { Problem(text: problem) }
      }.textFieldStyle(.roundedBorder).padding(Layout.Space.roomy)
    }
  #else
    private var mobileSheet: some View {
      NavigationStack {
        Form {
          Section("Routine") {
            TextField("Name", text: $name).accessibilityLabel("Name").accessibilityIdentifier(
              "routine-name")
            TextField("What should this bot do?", text: $prompt, axis: .vertical).lineLimit(3...7)
          }
          Section("Daily schedule") {
            DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
            Text(TimeZone.current.identifier).font(.caption)
            Text("Created paused. Open the routine to activate it when you’re ready.").font(
              .callout
            )
            .foregroundStyle(.secondary)
          }
          if let problem { Problem(text: problem) }
        }.navigationTitle("New routine").toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
          ToolbarItem(placement: .confirmationAction) {
            Button("Create") { save(nil) }.disabled(createDisabled)
          }
        }
      }
    }
  #endif

  func save(_ approved: Consent?) {
    guard !busy else { return }
    busy = true
    problem = nil
    Task {
      defer { busy = false }
      do {
        let components = Calendar.current.dateComponents([.hour, .minute], from: time)
        let cron = "\(components.minute ?? 0) \(components.hour ?? 9) * * *"
        let zone = TimeZone.current.identifier
        if let api = store.client {
          if let approved {
            let _: Consent = try await api.rpc(
              "aiConsent/allow",
              [
                "scope": approved.scope, "version": approved.version,
                "keys": approved.unapproved.map(\.key),
              ])
          }
          let status: Consent = try await api.rpc(
            "aiConsent/status", chat.target.merging(["uses": ["model", "memory"]]) { $1 })
          if !status.unapproved.isEmpty {
            consent = status
            return
          }
          let _: Routine = try await api.rpc(
            "routines/create",
            [
              "botId": chat.id, "name": name, "prompt": prompt, "crons": [cron], "active": false,
              "timezone": zone,
            ])
        } else {
          store.sample?.routines[chat.id, default: []].append(
            Routine(
              id: UUID().uuidString, name: name, prompt: prompt, crons: [cron], active: false,
              timezone: zone))
        }
        finished()
      } catch { problem = error.localizedDescription }
    }
  }
}

private struct RoutineDetails: View {
  struct History: Decodable {
    struct Run: Decodable, Identifiable {
      let id: String, status: String, createdAt: String
      var error: String?
    }
    let runs: [Run], nextCursor: [String: String]?
  }
  @ObservedObject var store: WorkspaceStore
  let chat: Chat, routine: Routine
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var prompt: String
  @State private var active: Bool
  @State private var busy = false
  @State private var confirmDelete = false
  @State private var activationConsent: Consent?
  @State private var problem: String?
  @State private var runs: [History.Run] = []
  @State private var next: [String: String]?
  @State private var loading = false
  init(store: WorkspaceStore, chat: Chat, routine: Routine) {
    self.store = store
    self.chat = chat
    self.routine = routine
    _name = State(initialValue: routine.name)
    _prompt = State(initialValue: routine.prompt)
    _active = State(initialValue: routine.active)
  }
  var body: some View {
    NavigationStack {
      Form {
        Section("Routine") {
          TextField("Name", text: $name)
          TextField("Prompt", text: $prompt, axis: .vertical).lineLimit(2...8)
        }
        Section {
          Toggle("Active", isOn: $active)
          LabeledContent("Time zone", value: routine.timezone)
          ForEach(routine.crons, id: \.self) { Text($0).monospaced() }
        } footer: {
          Text(
            "Saving an active routine allows the bot to run on its configured schedule or trigger.")
        }
        Section("Run history") {
          if loading {
            ProgressView()
          } else if runs.isEmpty && problem == nil {
            Text("No runs yet").foregroundStyle(.secondary)
          }
          ForEach(runs) { run in
            VStack(alignment: .leading) {
              LabeledContent(run.status.capitalized, value: Clock.label(run.createdAt, full: true))
              if let error = run.error { Text(error).font(.caption) }
            }
          }
          if next != nil { Button("Earlier runs") { Task { await history() } }.disabled(loading) }
        }
        if let problem { Problem(text: problem) }
        Button("Delete routine", role: .destructive) { confirmDelete = true }
      }.disabled(busy).navigationTitle("Routine details").inlineMobileTitle()
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Close") { dismiss() }.disabled(busy)
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") { save(delete: false) }.disabled(
              busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (name == routine.name && prompt == routine.prompt && active == routine.active))
          }
        }.interactiveDismissDisabled(busy).task { await history() }.confirmationDialog(
          "Delete \(routine.name)?", isPresented: $confirmDelete, titleVisibility: .visible
        ) {
          Button("Delete routine", role: .destructive) { save(delete: true) }
        }
        .sheet(item: $activationConsent) { status in
          ConsentView(
            status: status, cancel: { activationConsent = nil },
            allow: {
              activationConsent = nil
              save(delete: false, approved: status)
            })
        }
    }
  }
  private func history() async {
    guard !loading, let api = store.client else { return }
    loading = true
    defer { loading = false }
    do {
      var input: [String: Any] = ["routineId": routine.id, "limit": 10]
      input["before"] = next
      let page: History = try await api.rpc("routines/history", input)
      try Task.checkCancellation()
      runs += page.runs
      next = page.nextCursor
    } catch { if !Task.isCancelled { problem = error.localizedDescription } }
  }
  private func save(delete: Bool, approved: Consent? = nil) {
    guard !busy else { return }
    busy = true
    Task {
      defer { busy = false }
      do {
        if let api = store.client {
          if delete {
            let _: Empty = try await api.rpc("routines/remove", ["routineId": routine.id])
          } else {
            if active && (!routine.active || prompt != routine.prompt) {
              if let approved {
                let _: Consent = try await api.rpc(
                  "aiConsent/allow",
                  [
                    "scope": approved.scope, "version": approved.version,
                    "keys": approved.unapproved.map(\.key),
                  ])
              }
              let status: Consent = try await api.rpc(
                "aiConsent/status", ["routineId": routine.id, "uses": ["model", "memory"]])
              if !status.unapproved.isEmpty {
                activationConsent = status
                return
              }
            }
            var input: [String: Any] = ["routineId": routine.id]
            if active != routine.active { input["active"] = active }
            if name != routine.name { input["name"] = name }
            if prompt != routine.prompt { input["prompt"] = prompt }
            let _: Routine = try await api.rpc("routines/update", input)
          }
        } else if var sample = store.sample,
          let index = sample.routines[chat.id]?.firstIndex(where: { $0.id == routine.id })
        {
          if delete {
            sample.routines[chat.id]?.remove(at: index)
          } else {
            sample.routines[chat.id]?[index].name = name
            sample.routines[chat.id]?[index].prompt = prompt
            sample.routines[chat.id]?[index].active = active
          }
          store.sample = sample
        }
        dismiss()
      } catch { problem = error.localizedDescription }
    }
  }
}
