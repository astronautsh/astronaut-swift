#if canImport(SwiftUI)
import SwiftUI

/// The support conversation, ready to present.
///
/// Deliberately plain: it inherits the host app's font and background, and
/// takes a single tint so it can be made to belong without a styling API. An
/// app that wants something else can drive `Astronaut.shared.support` directly
/// and build its own.
///
/// ```swift
/// .sheet(isPresented: $showingHelp) {
///     Astronaut.shared.supportView()
/// }
/// ```
@available(iOS 16.0, *)
public struct SupportChatView: View {
    @ObservedObject private var chat: SupportChat
    @State private var draft: String = ""
    @FocusState private var inputFocused: Bool

    private let tint: Color
    private let placeholder: String
    private let responder: SupportResponder?
    private let showsResponderHeader: Bool
    private let source: String?

    /// - Parameters:
    ///   - showsResponderHeader: Draws the name and role above the
    ///     conversation. Turn it off when the host puts a
    ///     ``SupportResponderLabel`` in its navigation bar instead, so the
    ///     identity appears once rather than twice.
    ///   - source: Where this was opened from, e.g. "paywall". Recorded on the
    ///     `support_opened` event, so the journey shows which screen sent
    ///     someone looking for help.
    public init(
        chat: SupportChat,
        tint: Color = .accentColor,
        placeholder: String = "Ask us anything…",
        responder: SupportResponder? = nil,
        showsResponderHeader: Bool = true,
        source: String? = nil
    ) {
        self.chat = chat
        self.tint = tint
        self.placeholder = placeholder
        self.responder = responder
        self.showsResponderHeader = showsResponderHeader
        self.source = source
    }

    public var body: some View {
        VStack(spacing: 0) {
            responderHeader
            conversation
            Divider()
            composer
        }
        .onAppear {
            chat.screenAppeared()
            chat.refresh()
            chat.markRead()
            // Recorded where the conversation opens rather than on the button,
            // so a tap on a reply notification counts too — and so an app with
            // its own entry points does not have to remember to send it.
            Astronaut.shared.send(
                eventType: "support_opened",
                metadata: source.map { ["source": $0] } ?? [:]
            )
        }
        .onDisappear { chat.screenDisappeared() }
        // Polling, not a socket: support is not a chat room, and a few seconds
        // of latency costs nothing next to a connection held open per screen.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                chat.refresh()
            }
        }
        .onChange(of: chat.unreadCount) { unread in
            // A reply that lands while the screen is open has been seen.
            if unread > 0 { chat.markRead() }
        }
    }

    @ViewBuilder
    private var responderHeader: some View {
        if let responder, showsResponderHeader {
            HStack(spacing: 10) {
                SupportResponderLabel(responder: responder, tint: tint, size: 36)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
        }
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        emptyState
                    }
                    ForEach(chat.messages) { message in
                        bubble(for: message).id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: chat.messages.count) { _ in
                guard let last = chat.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(responder.map { "Questions come straight to \($0.name)" } ?? "Questions come straight to us")
                .font(.headline)
            Text(
                responder.map {
                    "Write below and \($0.name) will reply here. You'll get a notification then."
                } ?? "Write below and we'll reply here. You'll get a notification when we do."
            )
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 24)
    }

    @ViewBuilder
    private func bubble(for message: SupportMessage) -> some View {
        let isUser = message.sender == .user
        HStack {
            if isUser { Spacer(minLength: 40) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 3) {
                Text(message.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isUser ? tint : Color.secondary.opacity(0.14))
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    // A message still on its way reads as provisional rather
                    // than looking identical to one that arrived.
                    .opacity(message.state == .sending ? 0.6 : 1)

                switch message.state {
                case .sending:
                    Text("Sending…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .failed:
                    Button {
                        chat.retry(message)
                    } label: {
                        Text("Not sent · tap to retry")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                case .sent:
                    EmptyView()
                }
            }

            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .focused($inputFocused)

            Button {
                chat.send(draft)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(canSend ? tint : Color.secondary.opacity(0.4))
            }
            .disabled(!canSend)
            .accessibilityLabel("Send message")
        }
        .padding(12)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
#endif
