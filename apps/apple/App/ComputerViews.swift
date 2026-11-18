import ImageIO
import SwiftUI

struct ComputerRequestActions: View {
  private struct Preview: Decodable { let image: String? }
  @ObservedObject var store: WorkspaceStore
  let bot: String, run: String, chat: Chat
  let open: () -> Void, refresh: () async throws -> Void, report: (String) -> Void
  @State private var preview: CGImage?
  @State private var submitted = false
  private var available: Bool {
    !store.demo
      || (store.sample?.computers?[bot]?.pendingRun == run && store.sampleLeases[bot] == nil)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: Layout.Space.small) {
      if let preview {
        Image(decorative: preview, scale: 1).resizable().scaledToFit().frame(maxHeight: 144)
          .accessibilityLabel("Bot screen preview")
      }
      if store.demo {
        Button(action: open) {
          HStack {
            Image(systemName: "display")
            VStack(alignment: .leading) {
              Text("Review bot screen…")
              Text(store.sample?.computers?[bot]?.document ?? "Release review").font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }.buttonStyle(.bordered).accessibilityIdentifier("review-bot-screen")
      } else if let url = store.link(chat) {
        Link("Open computer in Rakazo ↗", destination: url)
      }
      HStack {
        Button("Skip") { submit(.skipped) }
        Button("I’m done") { submit(.done) }
      }.buttonStyle(.bordered).disabled(submitted || !available)
    }.task(id: run) {
      preview = nil
      guard let api = store.client else { return }
      guard
        let response: Preview = try? await api.rpc(
          "computer/preview", ["botId": bot, "runId": run]),
        !Task.isCancelled, let value = response.image, value.utf8.count <= 4_000_000,
        let split = value.firstIndex(of: ","),
        ["data:image/png;base64", "data:image/jpeg;base64", "data:image/webp;base64"].contains(
          String(value[..<split])),
        let bytes = Data(base64Encoded: String(value[value.index(after: split)...])),
        let source = CGImageSourceCreateWithData(bytes as CFData, nil)
      else { return }
      preview = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 640,
        ] as CFDictionary)
    }
  }
  private func submit(_ answer: TakeoverAnswer) {
    guard !submitted, available else { return }
    submitted = true
    Task {
      do {
        if let api = store.client {
          let _: Empty = try await api.rpc(
            "computer/release",
            ["botId": bot, "runId": run, "reason": answer.rawValue.lowercased()])
        } else if !store.answerScreenRequest(bot: bot, run: run, answer: answer) {
          throw Failure("This request is no longer waiting.")
        }
      } catch {
        submitted = false
        report(error.localizedDescription)
        return
      }
      do { try await refresh() } catch { report(error.localizedDescription) }
    }
  }
}

struct SampleScreen: View {
  @ObservedObject var store: WorkspaceStore
  let chat: Chat
  let requestedRun: String?
  @Environment(\.dismiss) private var dismiss
  @State private var viewer = UUID()
  private var computer: SampleComputer { store.sample?.computers?[chat.id] ?? SampleComputer() }
  private var ownsControl: Bool { store.sampleLeases[chat.id] == viewer }
  private var occupied: Bool { store.sampleLeases[chat.id] != nil && !ownsControl }
  private var stale: Bool { requestedRun != nil && requestedRun != computer.pendingRun }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Avatar(chat: chat, size: 28)
        VStack(alignment: .leading, spacing: 2) {
          Text("Bot computer").font(.headline)
          Text(chat.name).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Glyph(icon: "xmark", label: "Close computer", size: Layout.pointer) { dismiss() }
      }.padding(Layout.Space.standard)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: Layout.Space.standard) {
          HStack {
            Label("Sample screen", systemImage: "display")
            Spacer()
            Text(
              ownsControl ? "You have control" : occupied ? "In use by another viewer" : "View only"
            )
          }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: Layout.Space.standard) {
            Label("Team notes", systemImage: "note.text").font(.subheadline).foregroundStyle(
              .secondary)
            if ownsControl {
              TextField(
                "Document title",
                text: Binding(
                  get: { computer.document },
                  set: { title in
                    store.editScreen(bot: chat.id, viewer: viewer) {
                      $0.document = String(title.prefix(120))
                    }
                  })
              ).font(.title2.bold()).textFieldStyle(.roundedBorder)
            } else {
              Text(computer.document.isEmpty ? "Untitled" : computer.document).font(.title2.bold())
            }
            Divider()
            Label("Draft prepared", systemImage: "checkmark.circle.fill").foregroundStyle(
              .secondary)
            Toggle(
              "Checklist reviewed",
              isOn: Binding(
                get: { computer.reviewed },
                set: { value in
                  store.editScreen(bot: chat.id, viewer: viewer) { $0.reviewed = value }
                })
            ).disabled(!ownsControl).accessibilityIdentifier("sample-checklist")
          }.padding(Layout.Space.roomy).frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.canvas, in: RoundedRectangle(cornerRadius: Layout.Radius.control))
            .overlay {
              RoundedRectangle(cornerRadius: Layout.Radius.control).strokeBorder(Ink.line)
            }
          if stale {
            Text("This request is closed.").font(.callout)
          } else if let response = computer.response {
            Text(response).font(.callout).foregroundStyle(.secondary)
          }
        }.padding(Layout.Space.standard)
      }.background(Ink.fill)
      Divider()
      HStack {
        if !stale {
          if ownsControl {
            if let run = computer.pendingRun {
              Button("Skip") { finish(run, .skipped) }
              Spacer()
              Button("I’m done") { finish(run, .done) }.buttonStyle(.borderedProminent)
                .accessibilityIdentifier("finish-screen-review")
            } else {
              Spacer()
              Button("Hand back control") {
                store.handBack(bot: chat.id, viewer: viewer)
                dismiss()
              }
            }
          } else {
            if computer.pendingRun == nil && !occupied {
              Button("Request another review") { store.requestSampleReview(bot: chat.id) }
            }
            Spacer()
            Button("Take control") {
              _ = store.sampleTakeover(bot: chat.id, viewer: viewer, run: requestedRun)
            }
            .buttonStyle(.borderedProminent).disabled(occupied)
          }
        } else {
          Spacer()
          Button("Close") { dismiss() }
        }
      }.padding(Layout.Space.standard)
    }.tint(Ink.action).background(Ink.canvas)
      .onDisappear { store.handBack(bot: chat.id, viewer: viewer) }
      #if os(macOS)
        .frame(minWidth: 420, idealWidth: 540, minHeight: 350, idealHeight: 425)
      #endif
  }
  private func finish(_ run: String, _ answer: TakeoverAnswer) {
    if store.handBack(bot: chat.id, viewer: viewer, run: run, answer: answer) { dismiss() }
  }
}

struct SampleHostReview: View {
  @ObservedObject var store: WorkspaceStore
  let bot: String?
  var requestID: String? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var reviewing = false
  @State private var accessibility = false
  @State private var screenRecording = false
  var body: some View {
    NavigationStack {
      Form {
        Section("Where should bots run?") {
          LabeledContent(
            "Current choice",
            value: store.sample?.host == .thisMac ? "This Mac (simulated)" : "Isolated computer")
          Text("This is a simulation. No access to your Mac, files, or screen is requested.").font(
            .callout
          ).foregroundStyle(.secondary)
        }
        if store.sample?.host == .thisMac {
          Section {
            if let bot, let requestID {
              Button("Allow sample read") {
                store.answerHostRequest(bot: bot, message: requestID, allowed: true)
                dismiss()
              }
            } else if let bot {
              Button("Read sample note") { store.runSampleHostTask(bot: bot) }
              if let result = store.sample?.computers?[bot]?.localResult {
                Label(result, systemImage: "checkmark.circle")
              }
            }
            Button("Revoke simulated access", role: .destructive) {
              store.sample?.host = .sandbox
              reviewing = false
            }
          }
        } else if reviewing {
          Section("Simulated Mac permissions") {
            Toggle("Accessibility", isOn: $accessibility)
            Toggle("Screen Recording", isOn: $screenRecording)
            Button("Allow simulated access") {
              if store.chooseSampleMac(
                accessibility: accessibility, screenRecording: screenRecording)
              {
                accessibility = false
                screenRecording = false
                reviewing = false
              }
            }.disabled(!accessibility || !screenRecording)
            Button("Keep isolated") {
              reviewing = false
              accessibility = false
              screenRecording = false
            }
          }
        } else {
          Section { Button("Use this Mac…") { reviewing = true } }
        }
        if let bot, let requestID {
          Section {
            Button("Decline request") {
              store.answerHostRequest(bot: bot, message: requestID, allowed: false)
              dismiss()
            }
          }
        }
      }.formStyle(.grouped).navigationTitle("Computer access").inlineMobileTitle().toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
    }.integrationSheet()
  }
}
