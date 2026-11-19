#if os(macOS)
  import Foundation

  /// Runs the device runner, the Node process that keeps this Mac's link to the server: it runs
  /// the commands bots send and the whole turn of bots that live on this Mac, model calls
  /// included, with the Mac's own sign-ins. It reads its settings on stdin and exits when stdin
  /// closes, so it never outlives the app. It restarts after a crash, never after a revoke.
  final class MacDeviceRunner: @unchecked Sendable {
    private let server: URL
    private let token: String
    private let root: String
    private let onRevoked: (String?) -> Void
    private let queue = DispatchQueue(label: "dev.rakazo.device-runner")
    private var process: Process?
    private var input: FileHandle?
    private var stopped = false
    private var revoked = false
    private var attempt = 0

    init(server: URL, token: String, root: String, onRevoked: @escaping (String?) -> Void) {
      self.server = server
      self.token = token
      self.root = root
      self.onRevoked = onRevoked
    }

    func start() { queue.async { self.launch() } }

    func close() {
      let running: Process? = queue.sync {
        stopped = true
        try? input?.close()
        input = nil
        return process
      }
      guard let running else { return }
      // Closing stdin asks it to stop; one that does not is ended.
      queue.asyncAfter(deadline: .now() + 2) { if running.isRunning { running.terminate() } }
    }

    private func launch() {
      guard !stopped, !revoked else { return }
      guard let node = Self.node(), let script = Self.script() else {
        NSLog("Rakazo: this Mac cannot run bots: Node or the device runner is missing")
        return
      }
      let child = Process()
      child.executableURL = URL(fileURLWithPath: node)
      child.arguments = ["--enable-source-maps", script]
      let stdin = Pipe()
      let stdout = Pipe()
      child.standardInput = stdin
      child.standardOutput = stdout
      child.standardError = FileHandle.standardError
      var pending = Data()
      stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else {
          handle.readabilityHandler = nil
          return
        }
        pending.append(chunk)
        while let newline = pending.firstIndex(of: 0x0A) {
          let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
          pending.removeSubrange(pending.startIndex...newline)
          self?.queue.async { self?.heard(line) }
        }
      }
      child.terminationHandler = { [weak self] ended in
        self?.queue.async { self?.exited(ended) }
      }
      do {
        try child.run()
      } catch {
        NSLog("Rakazo: could not start the device runner: \(error.localizedDescription)")
        retryLater()
        return
      }
      process = child
      input = stdin.fileHandleForWriting
      let settings: [String: String] = [
        "serverUrl": server.absoluteString, "token": token, "root": root,
      ]
      if var line = try? JSONSerialization.data(withJSONObject: settings) {
        line.append(0x0A)
        try? stdin.fileHandleForWriting.write(contentsOf: line)
      }
    }

    private func heard(_ line: String) {
      if line == "started" {
        attempt = 0
      } else if line.hasPrefix("revoked") {
        revoked = true
        let reason = line.dropFirst("revoked".count).trimmingCharacters(in: .whitespaces)
        onRevoked(reason.isEmpty ? nil : reason)
      }
    }

    private func exited(_ ended: Process) {
      guard process === ended else { return }
      process = nil
      input = nil
      retryLater()
    }

    private func retryLater() {
      guard !stopped, !revoked else { return }
      let delay = min(60, pow(2, Double(attempt)))
      attempt += 1
      queue.asyncAfter(deadline: .now() + delay) { self.launch() }
    }

    /// Node from the person's login shell, which knows where they installed it.
    static func node() -> String? {
      let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
      let lookup = Process()
      lookup.executableURL = URL(fileURLWithPath: shell)
      lookup.arguments = ["-l", "-i", "-c", "command -v node"]
      let out = Pipe()
      lookup.standardOutput = out
      lookup.standardError = FileHandle.nullDevice
      lookup.standardInput = FileHandle.nullDevice
      guard (try? lookup.run()) != nil else { return nil }
      lookup.waitUntilExit()
      let found = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
      guard let found, found.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: found)
      else { return nil }
      return found
    }

    /// The runner built in the checkout this app was built from.
    static func script() -> String? {
      let apps = URL(fileURLWithPath: #filePath)  // apps/apple/App/Platform/MacDeviceRunner.swift
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
      let path = apps.appendingPathComponent("device-runner/dist/main.js").path
      return FileManager.default.fileExists(atPath: path) ? path : nil
    }
  }
#endif
