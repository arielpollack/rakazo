import SwiftUI

@main struct RakazoApp: App {
  @StateObject private var session: AppSession
  @AppStorage("appearance") private var appearance = "System"
  init() {
    let session = AppSession()
    _session = StateObject(wrappedValue: session)
    #if os(macOS)
      MacHostAccess.shared.follow(session)
    #endif
  }
  private var colorScheme: ColorScheme? {
    appearance == "Light" ? .light : appearance == "Dark" ? .dark : nil
  }
  var body: some Scene {
    #if os(macOS)
      Window("Rakazo", id: "workspace") { workspace.frame(minWidth: 720, minHeight: 480) }
        .defaultSize(width: 1160, height: 760).windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false)).commands { WorkspaceCommands() }
      Settings {
        Group {
          if let store = session.workspace { AccountView(store: store) }
          else { ContentUnavailableView("Not signed in", systemImage: "person.crop.circle", description: Text("Connect a server or open the sample in the Rakazo window.")) }
        }.formStyle(.grouped).frame(width: 460, height: 330)
          .environmentObject(session).preferredColorScheme(colorScheme)
      }
    #else
      WindowGroup { workspace }.commands { WorkspaceCommands() }
    #endif
  }
  private var workspace: some View {
    Group {
      if let workspace = session.workspace { Shell(store: workspace).id(workspace.id) }
      else { SignIn() }
    }.environmentObject(session).background(Ink.canvas.ignoresSafeArea()).preferredColorScheme(colorScheme)
  }
}
struct SignIn: View {
  @EnvironmentObject var session: AppSession
  @AppStorage("lastServer") private var recent = ""
  @State private var server = ""
  @State private var email = ""
  @State private var password = ""
  @State private var otp = false
  @State private var codeSent = false
  @State private var busy = false
  @State private var problem: String?
  @State private var unsaved: Login?
  @State private var promptForSession = false
  @FocusState private var focused: Field?
  enum Field { case server, email, credential }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Avatar(chat: Chat(id: "welcome", name: "Rakazo", color: "#FF781C"), size: 64)
        Text("Sign in to Rakazo").font(.largeTitle.bold())
        Text("Connect to the server where your bots live.").foregroundStyle(.secondary)
        field("Server") {
          TextField("https://your-rakazo-server", text: $server).textContentType(.URL).loginKeyboard(email: false)
            .accessibilityIdentifier("server").focused($focused, equals: .server).submitLabel(.next)
            .onSubmit { focused = .email }
        }
        field("Email") {
          TextField("you@example.com", text: $email).textContentType(.username).loginKeyboard(email: true)
            .accessibilityIdentifier("email").focused($focused, equals: .email).submitLabel(
            otp && !codeSent ? .go : .next
          ).onSubmit { if otp && !codeSent { submit() } else { focused = .credential } }
        }
        if !otp || codeSent {
          field(otp ? "Email code" : "Password") {
            SecureField(otp ? "Code" : "Password", text: $password).textContentType(
              otp ? .oneTimeCode : .password
            ).accessibilityIdentifier("password").focused($focused, equals: .credential)
              .submitLabel(.go).onSubmit { submit() }
          }
        }
        if let text = problem ?? session.launchError { Problem(text: text) }
        if codeSent {
          Text("Enter the code sent to your email.").font(.callout).foregroundStyle(.secondary)
        }
        Button {
          submit()
        } label: {
          HStack {
            if busy { ProgressView() }
            Text(otp && !codeSent ? "Send email code" : "Sign in").fontWeight(.semibold)
          }.frame(maxWidth: .infinity)
        }.buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("signin")
          .disabled(
            busy || email.isEmpty || server.isEmpty || ((!otp || codeSent) && password.isEmpty))
        Button(otp ? "Use a password instead" : "Use an email code instead") {
          otp.toggle()
          codeSent = false
          password = ""
          problem = nil
        }.frame(maxWidth: .infinity)
        Divider().padding(.vertical, 5)
        Button("Explore a sample workspace") { session.enterSample() }.frame(maxWidth: .infinity)
          .accessibilityIdentifier("sample")
        Text("Sample chats stay on this device. Signing in never imports your desktop session.")
          .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(
            maxWidth: .infinity)
      }.autocorrectionDisabled().frame(maxWidth: 360).padding(
        28
      ).disabled(busy).frame(maxWidth: .infinity)
    }.defaultScrollAnchor(.center).background(Ink.canvas).onAppear {
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--test-login") {
          server = ""
          return
        }
      #endif
      server =
        recent.isEmpty ? UserDefaults.standard.string(forKey: "suggestedServer") ?? "" : recent
    }.onChange(of: server) { _, _ in
      codeSent = false
      password = ""
    }.onChange(of: email) { _, _ in
      if otp {
        codeSent = false
        password = ""
      }
    }
    .alert("Continue without saving this session?", isPresented: $promptForSession) {
      Button("Continue for this session") {
        if let login = unsaved { finish(login, remember: false) }
        unsaved = nil
      }
      Button("Cancel", role: .cancel) {
        if let login = unsaved {
          Task {
            _ = try? await Client(server: login.server, token: login.token).post(
              "api/auth/sign-out", [:])
          }
        }
        unsaved = nil
      }
    } message: {
      Text(
        "Sign-in succeeded, but Keychain is unavailable. You can use Rakazo now and sign in again after quitting. Your password and session will not be written to disk."
      )
    }
  }
  func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.subheadline.weight(.medium))
      content().textFieldStyle(.plain).padding(11).background(
        Ink.fill, in: RoundedRectangle(cornerRadius: 10))
    }
  }
  func submit() {
    guard !busy else { return }
    busy = true
    problem = nil
    Task {
      defer { busy = false }
      do {
        let api = Client(server: try Client.origin(server))
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if otp && !codeSent {
          let health: Health = try await api.rpc("health")
          guard health.ok else { throw Failure("Not a Rakazo server.") }
          _ = try await api.post(
            "api/auth/email-otp/send-verification-otp", ["email": address, "type": "sign-in"])
          codeSent = true
          return
        }
        let login = try await api.authenticate(email: address, password: password, code: otp)
        password = ""
        focused = nil
        finish(login, remember: true)
      } catch { problem = error.localizedDescription }
    }
  }
  func finish(_ login: Login, remember: Bool) {
    do {
      try session.connect(login, remember: remember)
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--test-login") { return }
      #endif
      recent = login.server.absoluteString
    } catch {
      unsaved = login
      promptForSession = true
    }
  }
}
