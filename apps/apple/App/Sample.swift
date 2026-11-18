import Foundation

struct Sample: Codable {
  var spaces: [Workspace]
  var transcripts: [String: [Message]]
  var routines: [String: [Routine]]
  var integrations: [String: SampleIntegrations]?
  var spaceSkills: [SpaceTool]?
  var integrationRecords: IntegrationRecords?
  var computers: [String: SampleComputer]?
  var host: SampleHost?
  static let account = Account(userId: "sample", email: "", name: "Alex")
  static func message(_ seq: Int, _ role: String, _ text: String, at: Date = .now) -> Message {
    Message(
      id: UUID().uuidString, seq: seq, role: role, blocks: [.init(kind: "text", text: text)],
      createdAt: at.ISO8601Format())
  }
  static var initial: Sample {
    let names = ["Chief", "Scout", "Studio", "Atlas", "Sage"]
    let colors = ["#FF781C", "#FF3E51", "#FF5EB1::shape_2", "#A97EFE::shape_6", "#00C972"]
    let notes = [
      "Your everyday teammate", "Research and discovery", "Writing and creative projects",
      "Plans and logistics", "Notes and ideas",
    ]
    let snippets = [
      "The outline is ready. I’d start with the opening question.",
      "I found three trails worth exploring.", "Two headline options are ready for review.",
      "The itinerary now includes a free afternoon.", "I grouped your notes by topic.",
    ]
    var transcripts: [String: [Message]] = [:]
    let chats = names.indices.map { index in
      let date = Date.now.addingTimeInterval(Double(-index * 3600 - 120))
      let id = ["sample-chief", "sample-scout", "sample-studio", "sample-atlas", "sample-sage"][
        index]
      let text =
        index == 0
        ? "The outline is ready. I’d start with the opening question.\n\n**What’s in the brief**\n• The question we want to answer\n• Two examples worth presenting\n• The decision we need from the team\n\nThe examples give us a good place to start the discussion."
        : snippets[index]
      transcripts[id] =
        index == 0
        ? [
          message(
            1, "bot",
            "I’ve gathered the notes for our next team review. Would you like a short outline?",
            at: date.addingTimeInterval(-900)),
          message(
            2, "user", "Yes, please. What should we cover first?", at: date.addingTimeInterval(-60)),
          message(3, "bot", text, at: date),
        ] : [message(1, "bot", text, at: date)]
      return Chat(
        id: id, name: names[index], color: colors[index], description: notes[index],
        preview: snippets[index], updatedAt: date.ISO8601Format(), pinned: index == 0,
        unread: index == 1 || index == 4, computerMode: "shared")
    }
    var sample = Sample(
      spaces: [Workspace(id: "local", name: "Personal", bots: chats, groups: [], botSections: [])],
      transcripts: transcripts, routines: [:])
    sample.includeWalkthrough()
    return sample
  }
  mutating func includeWalkthrough() {
    if integrationRecords == nil { seedIntegrationManagement() }
    if spaceSkills == nil {
      spaceSkills = [.init(kind: "skill", id: "sample-release-notes", name: "Release notes",
        availability: .init(allSpaces: true, spaceIds: ["local"]))]
    }
    includeFeatureTours()
    let id = "sample-agent-walkthrough"
    guard let index = spaces.firstIndex(where: { $0.id == "local" }),
      !spaces[index].chats.contains(where: { $0.id == id })
    else { return }
    let date = Date.now.addingTimeInterval(-86400)
    var work = Self.message(2, "bot", "", at: date)
    work.blocks = [
      .init(
        kind: "steps", durationMs: 18000,
        steps: [
          .init(label: "Read the review notes", count: 2, outcomes: .init(succeeded: 2)),
          .init(label: "Compare the outlines", count: 1, outcomes: .init(succeeded: 1)),
        ]), .init(kind: "computer", text: "Reviewed both drafts side by side.", state: "Done"),
    ]
    var helper = Self.message(3, "bot", "", at: date)
    helper.blocks = [
      .init(
        kind: "subagent", name: "Scout", status: "completed", task: "Check the references",
        result: "Both references point to the latest draft.")
    ]
    var ask = Self.message(4, "bot", "", at: date)
    ask.runId = "sample-review"
    ask.blocks = [
      .init(
        kind: "ask", text: "What would you like to cover first?", status: "pending", input: "text")
    ]
    transcripts[id] = [
      Self.message(1, "user", "Compare the team review drafts.", at: date), work, helper, ask,
    ]
    spaces[index].bots.append(
      Chat(
        id: id, name: "Agent walkthrough", color: "#FF781C",
        description: "Interactive sample of agent messages", preview: ask.text,
        updatedAt: date.ISO8601Format()))
  }
}
