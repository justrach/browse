import SwiftUI

/// A small library, explicitly opened: choosing an instruction puts words
/// in the composer, where the person can change the context and send them.
struct AgentTaskLibrary: View {
    @ObservedObject var agent: Agent
    @ObservedObject var tasks: AgentTasks
    let focus: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var looking = ""
    @State private var editing = false
    @State private var editingID: UUID?
    @State private var name = ""
    @State private var instructions = ""
    @State private var removing: AgentTask?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(editing ? "Save a task" : "Task library").font(.system(size: 19, weight: .semibold))
                    Text("Keep instructions here. Review the draft before sending.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button(editing ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if editing { editor } else { library }
            if let trouble = tasks.trouble {
                Text(trouble).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .foregroundStyle(Palette.ink)
        .frame(width: 540, height: 530)
        .background(Palette.ground)
        .alert("Remove saved task?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { task in
            Button("Remove", role: .destructive) { tasks.remove(task.id); removing = nil }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { task in Text("“\(task.title)” will be removed from your library. Conversations and drafts stay as they are.") }
    }

    private var library: some View {
        VStack(spacing: 12) {
            TextField("Search tasks", text: $looking).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    let query = looking.trimmingCharacters(in: .whitespacesAndNewlines)
                    let saved = tasks.all.filter { $0.mentions(query) }
                    let examples = AgentTask.examples.filter { $0.mentions(query) }
                    if !saved.isEmpty {
                        caption("Your tasks")
                        ForEach(saved) { row($0, saved: true) }
                    } else if query.isEmpty {
                        Text("Save a question you use often, or adapt an example below.")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    if !examples.isEmpty {
                        caption("Examples")
                        ForEach(examples) { row($0, saved: false) }
                    }
                    if saved.isEmpty && examples.isEmpty {
                        Text("No tasks match your search.").font(.system(size: 13)).foregroundStyle(Palette.muted)
                            .padding(.vertical, 24)
                    }
                }.padding(.vertical, 4)
            }
            HStack {
                Button("New task") { edit(nil) }
                Button("Save current draft") {
                    edit(nil)
                    instructions = agent.draft
                    name = String(agent.draft.split(whereSeparator: \.isNewline).first?.prefix(80) ?? "")
                }.disabled(agent.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Text("Saved on this Mac").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Name").font(.system(size: 12, weight: .medium))
            TextField("For example, Weekly reading notes", text: $name).textFieldStyle(.roundedBorder)
            Text("Instructions").font(.system(size: 12, weight: .medium))
            TextEditor(text: $instructions).font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8).background(Palette.wash, in: RoundedRectangle(cornerRadius: 10))
                .accessibilityLabel("Task instructions")
            Text("Name: \(name.count)/80 · Instructions: \(instructions.count)/6,000")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            HStack {
                Button("Back") { editing = false }
                Spacer()
                Button("Save task") {
                    if tasks.save(id: editingID, title: name, prompt: instructions) { editing = false }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 80 || instructions.count > 6_000)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.muted)
    }

    private func row(_ task: AgentTask, saved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.title).font(.system(size: 13, weight: .medium))
                Spacer()
                Menu {
                    Button(saved ? "Edit…" : "Customize…") { edit(task, copy: !saved) }
                    if saved { Button("Remove…", role: .destructive) { removing = task } }
                } label: { Image(systemName: "ellipsis") }
                .menuIndicator(.hidden).menuStyle(.borderlessButton)
                .fixedSize().accessibilityLabel("Options for \(task.title)")
            }
            Text(task.prompt).font(.system(size: 12)).foregroundStyle(Palette.muted).lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Add to draft") {
                agent.prepareDraft(task.prompt)
                dismiss()
                focus()
            }
            .disabled(agent.asking?.isQuestion == true)
            .help(agent.draft.isEmpty ? "Prepare editable instructions without sending" : "Append instructions to your existing draft")
        }
        .padding(12).background(Palette.wash, in: RoundedRectangle(cornerRadius: 12))
    }

    private func edit(_ task: AgentTask?, copy: Bool = false) {
        editingID = copy ? nil : task?.id
        name = task?.title ?? ""
        instructions = task?.prompt ?? ""
        editing = true
    }
}
