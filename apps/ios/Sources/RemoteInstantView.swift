import SwiftUI

struct RemoteInstantView: View {
    let chats: [RemoteInstantSnapshot.Chat]
    let status: String
    let canRetry: Bool
    let handoff: Bool
    @Binding var selected: String?
    @Binding var anchor: String?
    let retry: () -> Void
    let manage: () -> Void
    @State private var atTail = true
    @State private var firstVisible: String?

    var body: some View {
        let chat = chats.first { $0.id == selected }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if chat != nil {
                    Button { selected = nil; anchor = nil } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }.accessibilityLabel("返回会话")
                }
                Text(chat?.title ?? "最近聊天").font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                if canRetry {
                    Button(action: retry) {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }.accessibilityLabel("重新连接")
                }
                Button(action: manage) {
                    Image(systemName: "ellipsis").frame(width: 44, height: 44)
                }.accessibilityLabel("连接与配对")
            }.padding(.horizontal, 12).frame(minHeight: 48)
            HStack {
                Text(status).font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).padding(.bottom, 8)
            Divider()
            if let chat { messages(chat).id(chat.id) }
            else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(chats) { chat in
                            Button {
                                atTail = true; firstVisible = nil; anchor = nil; selected = chat.id
                            } label: {
                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(chat.title).font(.body.weight(.medium)).lineLimit(1)
                                        Text(chat.rows.last?.text ?? "").font(.subheadline)
                                            .foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }.padding(.horizontal, 16).padding(.vertical, 10)
                                    .frame(minHeight: 56).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider().padding(.leading, 16)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 560, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .allowsHitTesting(!handoff)
    }

    private func messages(_ chat: RemoteInstantSnapshot.Chat) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(chat.rows) { row in
                    HStack {
                        if row.mine { Spacer(minLength: 36) }
                        Text(row.text)
                            .textSelection(.enabled)
                            .padding(.horizontal, 11).padding(.vertical, 8)
                            .background(row.mine ? Color.accentColor.opacity(0.13) : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                        if !row.mine { Spacer(minLength: 36) }
                    }.id(row.id)
                }
                Color.clear.frame(height: 1)
                    .onAppear { atTail = true; anchor = nil }
                    .onDisappear { atTail = false; anchor = firstVisible }
            }.scrollTargetLayout().padding(16)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition(id: $firstVisible)
        .onChange(of: firstVisible) { _, value in if !atTail { anchor = value } }
    }
}
