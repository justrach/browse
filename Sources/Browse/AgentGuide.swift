import SwiftUI

/// The two places to work, and the controls that matter once work starts.
struct AgentGuide: View {
    var body: some View {
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            Text("A research companion")
                .font(.system(size: 17, weight: .semibold))
            step("doc.text", "Choose the context", "Press . while reading. The page title and domain above the input show what will be included. Use × to exclude it, + to include it, or the pin to keep that page attached as you change tabs.")
            step("text.quote", "Ask about a passage", "Enable “Ask about selected text” in Settings › Agent. Right-click a passage, review the selected-text preview and its source, then send. Remove the page context to send just the excerpt.")
            step("arrow.up.right.square", "Follow the activity", "The status row shows when Codegraff is working, needs an answer, or has finished. Choose “Details” for all activity and a tool's “Result” for its output. Expand “Agent pages” to inspect pages it has open.")
            step("bubble.left.and.bubble.right", "Follow the thread", "Ask a follow-up, or type while it works to queue a message. Stop pauses queued messages too.")
            Divider()
            step("arrow.up.left.and.arrow.down.right", "Room for a bigger task", "Expand the conversation for research across sources. The side column includes the page in front; the expanded view sends your words alone. Pinned pages stay attached in either view.")
            Text("Interrupted work offers Reconnect. Continue prepares a follow-up for you to send. Conversation options has Report a problem; you can also type /feedback followed by a description.")
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
          }
          .foregroundStyle(Palette.ink)
          .padding(22)
        }
        .frame(width: 350, height: 540)
        .background(Palette.ground)
    }

    private func step(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Palette.muted)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
