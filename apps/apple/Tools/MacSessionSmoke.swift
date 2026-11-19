import Foundation
import Security

@main enum MacSessionSmoke {
  @MainActor static func main() async {
    do {
      let env = ProcessInfo.processInfo.environment
      guard Bundle.main.bundleIdentifier?.hasPrefix("dev.rakazo.smoke.session.") == true,
        let host = env["TEST_RUNNER_RAKAZO_TEST_ORIGIN"], let origin = try? Client.origin(host),
        origin.host == "127.0.0.1", CommandLine.arguments.count == 2
      else { throw Failure("Run the isolated local session fixture.") }
      SecKeychainSetUserInteractionAllowed(false)
      switch CommandLine.arguments[1] {
      case "sign-in":
        let session = AppSession()
        guard session.workspace == nil, session.launchError == nil,
          let password = env["TEST_RUNNER_RAKAZO_TEST_PASSWORD"] else { throw Failure("Expected a fresh sign-in.") }
        let login = try await Client(server: origin).authenticate(email: "native@example.test", password: password, code: false)
        try session.connect(login)
      case "restore-and-sign-out":
        let session = AppSession()
        guard env["TEST_RUNNER_RAKAZO_TEST_PASSWORD"] == nil,
          let workspace = session.workspace, workspace.login?.server == origin
        else { throw Failure("Fresh process did not restore the disposable session.") }
        try await workspace.load()
        guard workspace.account?.email == "native@example.test", workspace.navigation != nil else {
          throw Failure("Restored token did not open the authenticated workspace.")
        }
        try await session.leave()
      case "verify-signed-out":
        let session = AppSession()
        guard session.workspace == nil, session.launchError == nil, try Vault.read() == nil else {
          throw Failure("Sign-out left a session behind.")
        }
      case "clean": try Vault.clear()
      default: throw Failure("Unknown fixture phase.")
      }
    } catch {
      FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
      exit(1)
    }
  }
}
