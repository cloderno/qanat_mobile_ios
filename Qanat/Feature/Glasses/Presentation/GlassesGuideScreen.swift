import SwiftUI

private enum GuideTab: Int, CaseIterable { case idle, video, note, talk }
private enum Mark: Hashable { case dot, bar }

private struct GuideRow {
    let gesture: String
    let action: String
    let note: String?
    let marks: [Mark]
}

/// Инструкция по кнопке камеры на очках — что она делает в каждом из состояний приложения.
struct GlassesGuideScreen: View {
    let onClose: () -> Void
    let onOpenCheck: () -> Void

    @State private var tab: GuideTab = .idle
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: L.t("glasses_guide_title"), onBack: onClose)
            // Всё, включая «Понятно», — в одной прокрутке: закреплённая внизу панель закрывала последние строки жестов.
            ScrollView {
                VStack(spacing: 14) {
                    intro
                    // Подписи не помещаются (узкий экран, крупный шрифт, «Тыныштықта») — переключатель листается вбок.
                    ViewThatFits(in: .horizontal) {
                        tabs
                        ScrollView(.horizontal, showsIndicators: false) { tabs.fixedSize() }
                    }
                    Text(L.t(whenKey)).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                    SettingsCard {
                        let rows = self.rows
                        ForEach(rows.indices, id: \.self) { index in
                            if index > 0 { Rectangle().fill(palette.outlineVariant).frame(height: 1) }
                            rowView(rows[index])
                        }
                    }
                    if let footer = footerKey {
                        Text(L.t(footer)).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
                    }
                    // Проверка начинается со связи и кнопки — жесты из этой инструкции там пробуют на настоящих очках.
                    Button(action: onOpenCheck) {
                        Text(L.t("glasses_check_title")).textStyle(Typography.bodyMedium.weight(.semibold)).foregroundStyle(palette.primary)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    PrimaryButton(text: L.t("glasses_guide_done"), action: onClose)
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 24)
                .readableWidth()
            }
        }
        .background(palette.background)
    }

    /// Рисунок дужки и пояснение: рядом, только когда тексту остаётся место; иначе рисунок над текстом.
    private var intro: some View {
        let text = Text(L.t("glasses_guide_intro")).textStyle(Typography.bodyMedium.size(14, lineHeight: 19.6)).foregroundStyle(palette.onSurfaceVariant)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.xs) {
                GlassesTempleArt().frame(width: 170, height: 80)
                text.frame(minWidth: 266, alignment: .leading)
            }
            VStack(spacing: Spacing.sm) {
                GlassesTempleArt().frame(width: 170, height: 80)
                text.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.md)
        .frame(maxWidth: .infinity)
        .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var tabs: some View {
        SegmentedPicker(
            options: ["glasses_guide_tab_idle", "glasses_guide_tab_video", "glasses_guide_tab_note", "glasses_guide_tab_talk"].map { L.t($0) },
            selectedIndex: tab.rawValue,
            segmentHeight: 40,
            trackRadius: 14,
            segmentRadius: 10,
            textStyle: Typography.labelLarge,
            onSelect: { tab = GuideTab(rawValue: $0) ?? .idle }
        )
    }

    private func rowView(_ row: GuideRow) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(row.marks.indices, id: \.self) { index in
                    switch row.marks[index] {
                    case .dot: Circle().fill(palette.primary).frame(width: 9, height: 9)
                    case .bar: RoundedRectangle(cornerRadius: 5).fill(palette.primary).frame(width: 22, height: 9)
                    }
                }
            }
            .frame(width: 56, height: 40)
            .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.gesture).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                Text(row.action).textStyle(Typography.titleSmall).foregroundStyle(palette.onSurface)
                if let note = row.note {
                    Text(note).textStyle(Typography.bodySmall.size(13, lineHeight: 17.5)).foregroundStyle(palette.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 64)
    }

    private var whenKey: String {
        switch tab {
        case .idle: "glasses_guide_when_idle"
        case .video: "glasses_guide_when_video"
        case .note: "glasses_guide_when_note"
        case .talk: "glasses_guide_when_talk"
        }
    }

    private var footerKey: String? {
        switch tab {
        case .note: "glasses_guide_note_footer"
        case .talk: "glasses_guide_talk_footer"
        default: nil
        }
    }

    private var rows: [GuideRow] {
        func row(_ gesture: String, _ action: String, _ note: String?, _ marks: [Mark]) -> GuideRow {
            GuideRow(gesture: L.t("glasses_guide_gesture_\(gesture)"), action: L.t("glasses_guide_action_\(action)"), note: note.map { L.t("glasses_guide_note_\($0)") }, marks: marks)
        }
        switch tab {
        case .idle:
            return [
                row("single", "photo", nil, [.dot]),
                row("hold", "video_start", "video_stop", [.bar]),
                row("click_hold", "note_start", "note_send", [.dot, .bar]),
                row("double", "talk_start", "talk_end", [.dot, .dot]),
                row("triple", "new_chat", "new_chat", [.dot, .dot, .dot]),
            ]
        case .video:
            return [row("single", "video_stop", "video_stop_saved", [.dot])]
        case .note:
            return [
                row("single", "photo_to_note", nil, [.dot]),
                row("hold", "video_to_note", "video_stop", [.bar]),
                row("double", "note_stop", nil, [.dot, .dot]),
            ]
        case .talk:
            return [
                row("single", "photo_to_kanat", nil, [.dot]),
                row("hold", "video_to_kanat", "video_to_kanat", [.bar]),
                row("double", "talk_end", nil, [.dot, .dot]),
            ]
        }
    }
}
