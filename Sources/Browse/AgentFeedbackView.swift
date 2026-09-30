import SwiftUI

struct AgentFeedbackView: View {
    @State var draft: AgentFeedbackDraft
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "bubble.left.and.exclamationmark.bubble.right")
                    .font(.system(size: 20))
                    .foregroundStyle(Palette.muted)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Report an agent problem")
                        .font(.system(size: 19, weight: .semibold))
                    Text("Describe what happened so we can reproduce it.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Palette.muted)
                }
            }
            Picker("Problem", selection: $draft.kind) {
                ForEach(AgentFeedbackDraft.Kind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.menu)
            VStack(alignment: .leading, spacing: 8) {
                Text("What happened?").font(.system(size: 12, weight: .medium))
                TextEditor(text: $draft.details)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(height: 140)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline, lineWidth: 1))
                    .accessibilityLabel("What happened")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("What did you expect? (optional)").font(.system(size: 12, weight: .medium))
                TextField("", text: $draft.expected, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...4)
                    .padding(10)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Expected behavior")
            }
            Text("The draft includes this description and browse's build details. Review it on GitHub before submitting.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(copied ? "Copied" : "Copy report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft.report, forType: .string)
                    copied = true
                }
                .disabled(!draft.ready)
                Button("Review on GitHub") {
                    Links.writeFeedback(title: draft.title, body: draft.report)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.ready)
            }
        }
        .foregroundStyle(Palette.ink)
        .padding(24)
        .frame(width: 480)
        .background(Palette.ground)
    }
}
