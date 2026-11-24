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
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Report preview").font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text("browse \(Updater.version) · build \(Updater.build)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.muted)
                        .monospacedDigit()
                }
                ScrollView {
                    Text(previewText)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(draft.ready ? Palette.ink.opacity(0.88) : Palette.muted)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 82)
                .padding(10)
                .background(Palette.wash.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.hairline, lineWidth: 0.75))
            }
            Text("Only this summary and browse's build details leave your Mac when you review on GitHub.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(copied ? "Copied" : "Copy report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(fullPreviewText, forType: .string)
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

    private var previewText: String {
        draft.ready ? fullPreviewText : "\(draft.title)\n\nFill in \"What happened?\" to preview the report."
    }

    private var fullPreviewText: String {
        "\(draft.title)\n\n\(draft.report)\n\n—\nbrowse \(Updater.version), build \(Updater.build)"
    }
}
