import SwiftUI

/// The account's paired computers, from `GET /api/devices`.
struct UserDevices: Decodable {
  struct Device: Decodable, Identifiable, Hashable {
    let deviceId: String
    let name: String
    let connected: Bool
    /// The model providers it signs in to, as it last reported.
    let modelProviders: [String]?
    var id: String { deviceId }
  }
  let devices: [Device]
}

/// A model the computer a bot runs on signs in to, from `bots/computerModels`.
struct ComputerModel: Decodable, Hashable {
  let provider: String
  let providerName: String
  let id: String
  let label: String
  var key: String { "\(provider)/\(id)" }
}
struct ComputerModels: Decodable {
  struct Current: Decodable {
    let provider: String
    let id: String
  }
  let models: [ComputerModel]
  /// The model the bot's next turn uses there.
  let current: Current?
}

/// The models a computer signs in to, a submenu per provider: one cloud alone can offer hundreds.
struct ComputerModelMenu: View {
  let models: [ComputerModel]
  /// The chosen model's `key`.
  let chosen: String?
  let pick: (ComputerModel) -> Void

  var body: some View {
    let names = providers
    Menu(models.first { $0.key == chosen }?.label ?? "Choose") {
      if names.count == 1 {
        buttons(models)
      } else {
        ForEach(names, id: \.self) { name in
          Menu(name) { buttons(models.filter { $0.providerName == name }) }
        }
      }
    }.fixedSize()
  }

  private var providers: [String] {
    var seen = Set<String>()
    return models.map(\.providerName).filter { seen.insert($0).inserted }
  }

  private func buttons(_ models: [ComputerModel]) -> some View {
    ForEach(models, id: \.key) { model in
      Button {
        pick(model)
      } label: {
        if model.key == chosen {
          Label(model.label, systemImage: "checkmark")
        } else {
          Text(model.label)
        }
      }
    }
  }
}

/// Where a bot's computer runs: the server or one of the account's paired computers.
struct RunsOnBox: View {
  @ObservedObject var store: WorkspaceStore
  let chat: Chat
  let devices: [UserDevices.Device]
  @State private var current: String?
  @State private var pending: UserDevices.Device?
  @State private var saving = false
  @State private var problem: String?
  /// Where the bot was asked to move while it was working; moving there first stops it.
  @State private var blocked: Destination?
  /// What the computer it runs on signs in to; nil until read.
  @State private var models: [ComputerModel]?
  /// The model its next turn uses there, as `provider/id`.
  @State private var chosenModel: String?
  #if os(macOS)
    @ObservedObject private var host = MacHostAccess.shared
    private static let thisMac = "this-mac"
  #endif

  init(store: WorkspaceStore, chat: Chat, devices: [UserDevices.Device]) {
    self.store = store
    self.chat = chat
    self.devices = devices
    _current = State(initialValue: chat.computerDeviceId)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Layout.Space.small) {
      VStack(spacing: 0) {
        LabeledContent("Runs on") {
          Picker("Runs on", selection: selection) {
            Text("Rakazo server").tag(String?.none)
            ForEach(devices) { Text($0.name).tag(Optional($0.deviceId)) }
            if let current, !devices.contains(where: { $0.deviceId == current }) {
              Text("Offline").tag(Optional(current))
            }
            #if os(macOS)
              if host.available, !devices.contains(where: { $0.deviceId == host.thisDevice }) {
                Text("This Mac").tag(Optional(Self.thisMac))
              }
            #endif
          }.pickerStyle(.menu).labelsHidden().fixedSize().disabled(saving)
        }.padding(.horizontal, Layout.Space.medium).padding(.vertical, Layout.Space.small)
        // Whether that computer is online shows in the conversation's header.
        if current != nil, let models {
          Divider().padding(.leading, Layout.Space.medium)
          modelRow(models).padding(.horizontal, Layout.Space.medium)
            .padding(.vertical, Layout.Space.medium)
        }
      }.background(Ink.fill, in: RoundedRectangle(cornerRadius: 12))
      if let problem { Problem(text: problem) }
    }.onChange(of: chat.computerDeviceId) { _, value in current = value }
      // Again when the computer reports what it signs in to, which it does on connecting.
      .task(id: "\(current ?? "")|\(reported)") { await loadModels() }
      .alert(
        "Run \(chat.name) on \(pending?.name ?? "")?",
        isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
        presenting: pending
      ) { device in
        Button("Run on \(device.name)") { choose(device.deviceId) }
        Button("Cancel", role: .cancel) {}
      } message: { device in
        Text("It starts with an empty workspace on \(device.name). Files on its current computer stay there.")
      }
      .alert(
        "Stop \(chat.name) to move it?",
        isPresented: Binding(get: { blocked != nil }, set: { if !$0 { blocked = nil } }),
        presenting: blocked
      ) { destination in
        Button("Stop and Move", role: .destructive) { stopAndMove(destination.deviceId) }
        Button("Cancel", role: .cancel) {}
      }
  }

  private var selection: Binding<String?> {
    Binding(
      get: { current },
      set: { next in
        guard next != current else { return }
        #if os(macOS)
          if next == Self.thisMac {
            runHere()
            return
          }
        #endif
        if current == nil, let device = devices.first(where: { $0.deviceId == next }) {
          pending = device
        } else {
          choose(next)
        }
      })
  }

  @ViewBuilder private func modelRow(_ models: [ComputerModel]) -> some View {
    if models.isEmpty {
      LabeledContent("Model", value: "None signed in")
    } else {
      LabeledContent("Model") {
        ComputerModelMenu(models: models, chosen: chosenModel, pick: pick)
          .disabled(saving).accessibilityIdentifier("computerModel")
      }
    }
  }

  private var reported: String {
    devices.first { $0.deviceId == current }?.modelProviders?.joined(separator: ",") ?? ""
  }

  private func pick(_ model: ComputerModel) {
    guard model.key != chosenModel else { return }
    saving = true
    problem = nil
    Task {
      defer { saving = false }
      do {
        try await store.setModel(chat, provider: model.provider, id: model.id)
        chosenModel = model.key
      } catch { problem = error.localizedDescription }
    }
  }

  private func loadModels() async {
    guard current != nil, let api = store.client else {
      models = nil
      return
    }
    do {
      let listed: ComputerModels = try await api.rpc("bots/computerModels", ["botId": chat.id])
      try Task.checkCancellation()
      models = listed.models
      chosenModel = listed.current.map { "\($0.provider)/\($0.id)" }
    } catch {
      if !Task.isCancelled { models = nil }
    }
  }

  #if os(macOS)
    /// Asks to let bots use this Mac, pairs it, and moves the bot onto it.
    private func runHere() {
      saving = true
      problem = nil
      Task {
        defer { saving = false }
        guard let deviceId = await host.allow() else { return }
        try? await store.load()
        await move(deviceId)
      }
    }
  #endif

  private func choose(_ deviceId: String?) {
    saving = true
    problem = nil
    Task {
      defer { saving = false }
      await move(deviceId)
    }
  }

  private func move(_ deviceId: String?) async {
    do {
      current = try await store.setComputerDevice(chat, deviceId: deviceId)
    } catch let failure as Failure where failure.code == "BOT_BUSY" {
      blocked = Destination(deviceId: deviceId)
    } catch { problem = error.localizedDescription }
  }

  private func stopAndMove(_ deviceId: String?) {
    saving = true
    problem = nil
    Task {
      defer { saving = false }
      do {
        try await store.stop(chat)
        await move(deviceId)
      } catch { problem = error.localizedDescription }
    }
  }

  struct Destination: Identifiable {
    let deviceId: String?
    var id: String { deviceId ?? "server" }
  }
}
