#if os(macOS)
  import AppKit
  import Combine
  import Security
  import SystemConfiguration

  /// A pairing with one server: the device token, shown once by the server, and whose it is.
  struct MacHostDevice: Codable {
    let token: String
    let deviceId: String
    let userId: String
  }

  /// Device tokens live in the device-only Keychain beside the session, one per server origin.
  enum MacHostVault {
    enum Saved { case keychain, unavailable }

    private static func key(_ origin: String) -> [String: Any] {
      [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "dev.rakazo.nativeclient")
          + ".device",
        kSecAttrAccount as String: origin, kSecUseDataProtectionKeychain as String: true,
      ]
    }
    static func read(_ origin: String) -> MacHostDevice? {
      var result: CFTypeRef?
      let status = SecItemCopyMatching(
        key(origin).merging([kSecReturnData as String: true]) { $1 } as CFDictionary, &result)
      guard status == errSecSuccess, let data = result as? Data else { return nil }
      return try? JSONDecoder().decode(MacHostDevice.self, from: data)
    }
    static func save(_ device: MacHostDevice, _ origin: String) throws -> Saved {
      let attributes: [String: Any] = [
        kSecValueData as String: try JSONEncoder().encode(device),
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ]
      var status = SecItemUpdate(key(origin) as CFDictionary, attributes as CFDictionary)
      if status == errSecItemNotFound {
        status = SecItemAdd(key(origin).merging(attributes) { $1 } as CFDictionary, nil)
      }
      if status == errSecMissingEntitlement { return .unavailable }
      guard status == errSecSuccess else { throw Failure("Could not save this Mac’s pairing.") }
      return .keychain
    }
    static func clear(_ origin: String) {
      SecItemDelete(key(origin) as CFDictionary)
    }
  }

  /// Lets the signed-in account's bots use this Mac: consent, pairing, the device runner and
  /// turning it off. Consent belongs to one server and account, and is kept only while the
  /// pairing can be kept too, so a session-only build never pairs again unasked at launch.
  @MainActor final class MacHostAccess: ObservableObject {
    static let shared = MacHostAccess()

    struct SignedIn: Equatable {
      let server: URL
      let token: String
      let userId: String
      var origin: String { server.absoluteString.trimmingCharacters(in: ["/"]) }
      static func == (a: Self, b: Self) -> Bool {
        a.origin == b.origin && a.token == b.token && a.userId == b.userId
      }
    }

    @Published private(set) var signedIn: SignedIn?
    @Published private(set) var enabled = false
    private var memoryDevices: [String: MacHostDevice] = [:]
    private var memoryConsent: [String: String] = [:]
    private var connection: MacDeviceRunner?
    private var following: AnyCancellable?
    private var terminating: NSObjectProtocol?
    private var generation = 0
    private var busy = false
    private static let consentKey = "macHost.consent"

    var available: Bool { signedIn != nil }
    /// This Mac's device for the signed-in account, while bots may use it. Kept here because views
    /// read it on every redraw and the pairing it comes from is in the Keychain.
    @Published private(set) var thisDevice: String?

    /// Follows the app's sign-in for as long as the app runs.
    func follow(_ session: AppSession) {
      following = session.$workspace.map { store -> AnyPublisher<SignedIn?, Never> in
        guard let store, let login = store.login else { return Just(nil).eraseToAnyPublisher() }
        return store.$account.map { account in
          account.map { SignedIn(server: login.server, token: login.token, userId: $0.userId) }
        }.eraseToAnyPublisher()
      }.switchToLatest().removeDuplicates().sink { [weak self] in self?.use($0) }
      terminating = NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification, object: nil, queue: .main
      ) { [weak self] _ in MainActor.assumeIsolated { self?.revokeSessionOnly() } }
    }

    /// Connects when this account allowed it here; disconnects on sign-out.
    func use(_ next: SignedIn?) {
      generation += 1
      disconnect()
      signedIn = next
      defer { noteDevice() }
      guard let next else {
        enabled = false
        return
      }
      enabled = consent(next.origin) == next.userId
      guard enabled else { return }
      let ticket = generation
      Task {
        // Problems here stay quiet: the person did not just ask for anything.
        if let device = try? await pairing(next), ticket == generation {
          connect(device, next)
        }
      }
    }

    /// Asks, then pairs and connects this Mac. Its device id, or nil when not allowed or it failed.
    @discardableResult func allow() async -> String? {
      guard let account = signedIn, !busy else { return nil }
      if let paired = thisDevice { return paired }
      let alert = NSAlert()
      alert.messageText = "Allow bots to use this Mac?"
      alert.informativeText = "Bots you run on this Mac can run commands and change files as you."
      alert.addButton(withTitle: "Allow")
      alert.addButton(withTitle: "Don't Allow")
      guard alert.runModal() == .alertFirstButtonReturn else { return nil }
      busy = true
      defer { busy = false }
      let ticket = generation
      do {
        let device = try await pairing(account)
        guard ticket == generation else { return nil }
        saveConsent(account, kept: memoryDevices[account.origin] == nil)
        enabled = true
        connect(device, account)
        return device.deviceId
      } catch {
        guard ticket == generation else { return nil }
        let problem = NSAlert()
        problem.messageText = error.localizedDescription
        problem.runModal()
        return nil
      }
    }

    /// Disconnects, revokes this device on the server and forgets the pairing and the consent.
    func stop() {
      guard let account = signedIn else { return }
      disconnect()
      let device = device(account.origin)
      forgetDevice(account.origin)
      clearConsent(account.origin)
      enabled = false
      if let device { Task { await Self.revoke(device, server: account.server) } }
    }

    private func connect(_ device: MacHostDevice, _ account: SignedIn) {
      disconnect()
      noteDevice()
      let origin = account.origin
      let link = MacDeviceRunner(server: account.server, token: device.token, root: Self.root()) {
        [weak self] reason in
        DispatchQueue.main.async { self?.revoked(reason, origin: origin) }
      }
      connection = link
      link.start()
    }

    private func disconnect() {
      connection?.close()
      connection = nil
    }

    private func revoked(_ reason: String?, origin: String) {
      connection = nil
      forgetDevice(origin)
      guard let account = signedIn, account.origin == origin else { return }
      // A sign-out ends the pairing but keeps the answer for this account's next sign-in.
      guard reason == "session-ended" else {
        clearConsent(origin)
        enabled = false
        return
      }
      if enabled { use(account) }
    }

    /// This account's pairing with the server, pairing now when there is none.
    private func pairing(_ account: SignedIn) async throws -> MacHostDevice {
      if let device = device(account.origin) {
        if device.userId == account.userId { return device }
        // Another account's pairing: it cannot be used for this one.
        forgetDevice(account.origin)
        Task { await Self.revoke(device, server: account.server) }
      }
      let api = Client(server: account.server, token: account.token)
      let (data, _) = try await api.send(
        "POST", "api/devices/pair", ["name": Self.deviceName(), "platform": "darwin"])
      struct Paired: Decodable {
        let deviceId: String
        let userId: String?
        let token: String
      }
      guard let paired = try? JSONDecoder().decode(Paired.self, from: data),
        !paired.token.isEmpty, paired.token.count <= 1024
      else { throw Failure("The server returned an invalid response.") }
      let device = MacHostDevice(
        token: paired.token, deviceId: paired.deviceId, userId: paired.userId ?? account.userId)
      do {
        if try MacHostVault.save(device, account.origin) == .unavailable {
          memoryDevices[account.origin] = device
        }
      } catch {
        // A token that cannot be kept must not stay valid on the server.
        await Self.revoke(device, server: account.server)
        throw error
      }
      return device
    }

    private func device(_ origin: String) -> MacHostDevice? {
      memoryDevices[origin] ?? MacHostVault.read(origin)
    }

    private func forgetDevice(_ origin: String) {
      memoryDevices[origin] = nil
      MacHostVault.clear(origin)
      noteDevice()
    }

    private func noteDevice() {
      let next = enabled ? signedIn.flatMap { device($0.origin)?.deviceId } : nil
      if thisDevice != next { thisDevice = next }
    }

    private func consent(_ origin: String) -> String? {
      memoryConsent[origin]
        ?? (UserDefaults.standard.dictionary(forKey: Self.consentKey)?[origin] as? String)
    }

    private func saveConsent(_ account: SignedIn, kept: Bool) {
      guard kept else {
        memoryConsent[account.origin] = account.userId
        return
      }
      var saved = UserDefaults.standard.dictionary(forKey: Self.consentKey) ?? [:]
      saved[account.origin] = account.userId
      UserDefaults.standard.set(saved, forKey: Self.consentKey)
    }

    private func clearConsent(_ origin: String) {
      memoryConsent[origin] = nil
      var saved = UserDefaults.standard.dictionary(forKey: Self.consentKey) ?? [:]
      saved[origin] = nil
      UserDefaults.standard.set(saved, forKey: Self.consentKey)
    }

    /// A pairing kept only in memory would linger on the server after quitting.
    private func revokeSessionOnly() {
      disconnect()
      guard let account = signedIn, let device = memoryDevices[account.origin] else { return }
      let done = DispatchSemaphore(value: 0)
      Task.detached {
        await Self.revoke(device, server: account.server)
        done.signal()
      }
      _ = done.wait(timeout: .now() + 2)
    }

    private nonisolated static func revoke(_ device: MacHostDevice, server: URL) async {
      _ = try? await Client(server: server, token: device.token).send(
        "DELETE", "api/devices/self")
    }

    /// The Mac's own name from Sharing settings, like `scutil --get ComputerName`.
    static func deviceName() -> String {
      var name = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? ""
      if name.trimmingCharacters(in: .whitespaces).isEmpty {
        name = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
      }
      if name.isEmpty { name = "Computer" }
      while name.utf16.count > 128 { name.removeLast() }
      return name
    }

    /// The desktop app's layout: `<app data>/computers/desktop-computers/<sha256(botId)>`.
    static func root() -> String {
      let support =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
      return support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Rakazo Mac")
        .appendingPathComponent("computers").path
    }
  }
#endif
