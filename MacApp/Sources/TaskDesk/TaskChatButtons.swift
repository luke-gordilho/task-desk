import SwiftUI
import TaskCore

struct TaskChatButtons: View {
    @EnvironmentObject var desk: Desk
    let task: WorkItem

    var body: some View {
        HStack(spacing: 5) {
            ForEach([ChatProvider.claude, .codex], id: \.self) { provider in
                Button { desk.open(task, provider: provider) } label: {
                    ChatLogo(provider: provider)
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Open in " + provider.rawValue)
                .accessibilityLabel("Open " + task.title + " in " + provider.rawValue)
            }
        }
    }
}

struct ChatLogo: View {
    let provider: ChatProvider
    private static let claude = NSImage(named: "ClaudeCode")
    private static let codex = NSImage(named: "ChatGPT")

    var body: some View {
        if let icon = provider == .codex ? Self.codex : Self.claude {
            Image(nsImage: icon)
                .renderingMode(provider == .codex ? .template : .original)
                .resizable().scaledToFit().frame(width: 19, height: 19)
                .foregroundStyle(Ink.text)
        } else {
            Image(systemName: provider == .codex ? "bubble.left" : "chevron.left.forwardslash.chevron.right")
        }
    }
}
