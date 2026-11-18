#if os(macOS)
import SwiftUI

struct SkillsLibraryPage: View {
  @EnvironmentObject var session: ManagementSession
  @State private var query = ""
  @State private var filter = "all"
  @State private var skills: [ManagedSkill] = []
  @State private var installs: [ManagedInstall] = []
  @State private var loading = true
  @State private var retry = 0
  var body: some View {
    let matches = skills.filter { (filter == "all" || $0.source == filter) && (query.isEmpty || ($0.name + " " + $0.description).localizedCaseInsensitiveContains(query)) }
    let packs = installs.filter { $0.parts.contains("skills") && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
    ManagePage("My integrations  /  Skills", "Skills", "Instructions your bots can use across conversations.", width: 680) {
      TextField("Search skills and packs", text: $query).textFieldStyle(.roundedBorder).controlSize(.large)
      Picker("Filter skills", selection: $filter) { Text("All skills").tag("all"); Text("My skills").tag("user"); Text("Built-in").tag("builtin"); Text("From plugins").tag("plugin") }.pickerStyle(.segmented).labelsHidden()
      if loading { ProgressView() } else if session.issue != nil { Button("Retry") { retry += 1 } }
      else {
        ManageGroup("Your library") { if matches.isEmpty { ManageRow("No matching skills", query.isEmpty ? "No skills in this collection." : "Try a different name.") { if !query.isEmpty { Button("Clear search") { query = "" } } } }
          ForEach(matches) { skill in ManageRow(skill.name, skill.source == "builtin" ? "Built-in" : skill.source == "plugin" ? "Plugin skill" : "Your skill") { Button(skill.editable ? "Edit…" : "Read") { session.open(.skill(skill)) }.accessibilityLabel("\(skill.editable ? "Edit" : "Read") \(skill.name)") } }
        }
        if filter == "all" || filter == "plugin" { ManageGroup("Skill packs") { ForEach(packs) { pack in ManageRow(pack.name, "\(pack.config.manifest?.skills.count ?? 0) installed skills") { Button("Open pack") { session.open(.plugin(pack.source, pack.source, pack.name, false)) } } }; Button("Browse packs…") { session.open(.packs) } } }
      }
    } footer: { Button("Import from GitHub…") { session.open(.repository) }; Spacer(); BackButton(); Button("New skill…") { session.open(.skill(nil)) }.buttonStyle(.borderedProminent) }.task(id: retry) { do { loading = true; session.issue = nil; skills = try await session.store.managementSkills(); installs = try await session.store.managementInstalls() } catch { session.issue = error.localizedDescription }; loading = false }
  }
}
struct SkillPacksPage: View {
  @EnvironmentObject var session: ManagementSession
  var body: some View {
    let packs = session.directory.items.compactMap { if case .plugin(let entry, _) = $0.content, entry.hasConnector == false, entry.skillCount ?? 0 > 0 { return entry }; return nil }
    ManagePage("Skills  /  Discover", "Skill packs") { ManageGroup { if packs.isEmpty { Text("No packs in the current catalog.") }; ForEach(packs, id: \.id) { pack in ManageRow(pack.displayName, pack.description) { Button("Open pack") { session.open(.plugin(pack.source, pack.installedSource, pack.displayName, false)) } } } } } footer: { Button("Import from GitHub…") { session.open(.repository) }; Spacer(); BackButton() }
  }
}
struct SkillEditorPage: View {
  @EnvironmentObject var session: ManagementSession
  let original: ManagedSkill?
  @State private var name = ""
  @State private var description = ""
  @State private var content = ""
  @State private var prior = ""
  @State private var mode = "Write"
  @State private var ready = false
  @State private var pack: ManagedInstall?
  @State private var scope: SpaceTool.Availability?
  @State private var retry = 0
  private var editable: Bool { original?.editable ?? true }
  var body: some View {
    ManagePage("Skills  /  " + (original == nil ? "New skill" : editable ? "Edit" : "Read"), original?.name ?? "New skill", original == nil ? "Describe a repeatable task in Markdown." : editable ? "Your skill · Changes apply the next time a bot uses it." : original?.source == "builtin" ? "Built-in skill · Read only" : "Plugin skill · Read only") {
      if !ready { if session.issue != nil { Button("Retry") { retry += 1 } } else { ProgressView() } }
      else {
        if original == nil { ManageField("Name") { TextField("Weekly brief", text: $name) }; ManageField("Description") { TextField("Prepare a concise team update", text: $description) } }
        if editable { Picker("Editor", selection: $mode) { Text("Write").tag("Write"); Text("Preview").tag("Preview") }.pickerStyle(.segmented).labelsHidden() }
        ManageGroup(original == nil ? "Instructions" : "SKILL.md") { if editable && mode == "Write" { TextEditor(text: $content).font(.system(.body, design: .monospaced)).scrollContentBackground(.hidden).frame(minHeight: 136).accessibilityLabel("Skill instructions") } else { Text(.init(markdownBody)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) } }
        if let original, editable { ManageRow("Available in", scope?.allSpaces == true ? "All spaces" : session.store.navigation?.spaces.filter { scope?.spaceIds.contains($0.id) == true }.map(\.name).joined(separator: ", ") ?? "This space") { Button("Change…") { session.open(.scope("skill", original.id, original.name, scope)) }.disabled(content != prior) } }
        if original == nil { ManageRow("Available in", "All spaces") }
        if let pack { ManageRow("Managed by \(pack.name)", "Change installed skills in the parent plugin.") { Button("Open plugin") { session.open(.plugin(pack.source, pack.source, pack.name, false)) } } }
      }
    } footer: {
      if let original, editable { Button("Delete skill…", role: .destructive) { session.open(.confirm("Delete \(original.name)?", "Bots lose this skill in every space where it is available. Existing conversations stay intact.", [original.name], "Delete skill", { try await session.store.deleteSkill(original); session.back(2) })) } }
      Spacer(); BackButton(editable ? "Cancel" : "Done"); if editable { Button(original == nil ? "Create skill" : "Save changes") { session.perform {
        if let original { try await session.store.writeSkillDocument(original, document: content) }
        else { _ = try await session.store.writeSkill(nil, name: name, description: description, body: content) }; session.back()
      } }.buttonStyle(.borderedProminent).disabled(!ready || (original == nil ? name.isEmpty || description.isEmpty : content == prior || content.isEmpty)) }
    }.task(id: retry) { do {
      ready = false; session.issue = nil
      if let original { let skill = try await session.store.readSkill(original); content = skill.content ?? ""; scope = skill.availability; prior = content
        if !editable && skill.source == "plugin" { pack = try await session.store.managementInstalls().first { item in item.kind == "plugin" && item.parts.contains("skills") && (item.id == skill.parentID || item.config.manifest?.skills.contains(where: { $0.name == skill.name }) == true) } }
      }; ready = true
    } catch { session.issue = error.localizedDescription } }
  }
  private var markdownBody: String {
    if content.hasPrefix("---\n"), let end = content.range(of: "\n---\n", range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex) { return String(content[end.upperBound...]) }; return content
  }
}
#endif
