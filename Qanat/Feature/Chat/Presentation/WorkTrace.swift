import SwiftUI

/*
 * Ход работы агента, как у ассистентов: пока он отвечает — «Работаю…» и растущий список шагов, у готового ответа —
 * свёрнутая строка «Работал N с ⌄», по нажатию — те же шаги.
 */

/// Ответ ещё пишется: «Работаю…» и шаги по мере прихода.
struct WorkTraceInProgress: View {
    let trace: [TraceStep]
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L.t("chat_trace_working")).textStyle(Typography.bodyMedium).foregroundStyle(palette.onSurfaceVariant)
            if !trace.isEmpty { TraceSteps(trace: trace) }
        }
    }
}

/// Готовый ответ: «Работал N с ⌄»; [latencyMs] нет — время последнего шага.
struct WorkTraceSummary: View {
    let trace: [TraceStep]
    let latencyMs: Int64?

    @State private var expanded = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } } label: {
                HStack(spacing: 2) {
                    Text(workedSeconds(latencyMs: latencyMs, trace: trace).map { L.t("chat_trace_worked", Int($0)) } ?? L.t("chat_trace_title"))
                        .textStyle(Typography.labelMedium.weight(.regular))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(palette.onSurfaceVariant)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L.t(expanded ? "chat_trace_hide" : "chat_trace_show"))
            if expanded { TraceSteps(trace: trace).transition(.opacity) }
        }
    }
}

/// Шаги с линией слева: значок поиска у обращения к источнику, значок реплики у сказанного.
private struct TraceSteps: View {
    let trace: [TraceStep]
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(palette.outlineVariant).frame(width: 1).padding(.leading, 8)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(trace.indices, id: \.self) { index in
                    row(trace[index])
                }
            }
            .padding(.leading, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ step: TraceStep) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: { if case .tool = step { "magnifyingglass" } else { "bubble.left" } }())
                .font(.system(size: 13))
                .foregroundStyle(palette.onSurfaceVariant)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                switch step {
                case .tool(let title, let detail, _):
                    Text(title).textStyle(Typography.bodyMedium).foregroundStyle(palette.onSurface)
                    if !detail.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(palette.onSurfaceVariant)
                    }
                case .said(let text, _):
                    Text(text).textStyle(Typography.bodyMedium).foregroundStyle(palette.onSurfaceVariant)
                }
            }
        }
    }
}

/// Название — прежнее, чтобы поправить пару слов; пустое не сохраняем.
struct RenameChatAlert: ViewModifier {
    @Binding var chat: Chat?
    let onRename: (Chat, String) -> Void

    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(L.t("chat_rename_title"), isPresented: Binding(get: { chat != nil }, set: { if !$0 { chat = nil } })) {
                TextField(L.t("chat_rename_label"), text: $name)
                Button(L.t("common_cancel"), role: .cancel) { chat = nil }
                Button(L.t("chat_rename_confirm")) {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let chat, !trimmed.isEmpty { onRename(chat, trimmed) }
                    chat = nil
                }
            }
            .onChange(of: chat) { _, chat in name = chat?.title ?? "" }
    }
}

struct DeleteChatAlert: ViewModifier {
    @Binding var chat: Chat?
    let onDelete: (Chat) -> Void

    func body(content: Content) -> some View {
        content.alert(
            L.t("chat_delete_title", chat?.title ?? ""),
            isPresented: Binding(get: { chat != nil }, set: { if !$0 { chat = nil } })
        ) {
            Button(L.t("common_cancel"), role: .cancel) { chat = nil }
            Button(L.t("chat_delete_confirm"), role: .destructive) {
                if let chat { onDelete(chat) }
                chat = nil
            }
        } message: {
            Text(L.t("chat_delete_text"))
        }
    }
}
