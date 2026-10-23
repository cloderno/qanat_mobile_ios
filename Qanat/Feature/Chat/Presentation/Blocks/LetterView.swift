import SwiftUI

/// Письмо от агента: кому, тема, начало текста, скачивание DOCX и «Сохранить как шаблон». Кнопок нет, если файла нет.
/// [onSaveTemplate] — nil: у письма нет кнопки «Сохранить как шаблон».
struct LetterView: View {
    let letter: LetterBlock
    let downloading: Bool
    let onDownload: () -> Void
    var onSaveTemplate: ((String) -> Void)?

    @State private var namingTemplate = false
    @State private var templateName = ""
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !letter.preview.isEmpty { LetterPreview(text: letter.preview) }
            if letter.needsFilling { needsFillingNote }
            if letter.documentId != nil {
                FlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    downloadButton
                    if onSaveTemplate != nil { saveTemplateButton }
                }
            }
        }
        // Название шаблона — сразу тема письма: чаще всего её и оставляют. Пустое не сохраняем.
        .alert(L.t("letter_templates_save"), isPresented: $namingTemplate) {
            TextField(L.t("letter_templates_name"), text: $templateName)
            Button(L.t("common_cancel"), role: .cancel) {}
            Button(L.t("letter_templates_save_confirm")) {
                let name = templateName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { onSaveTemplate?(name) }
            }
        } message: {
            Text(L.t("letter_templates_save_text"))
        }
    }

    /// Конверт, «Текстовый файл · DOCX», «Кому: …» и тема письма.
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope")
                .font(.system(size: 18))
                .foregroundStyle(palette.onPrimaryContainer)
                .frame(width: 40, height: 40)
                .background(palette.primaryContainer, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(L.t("chat_letter_kind")).textStyle(Typography.labelSmall).foregroundStyle(palette.primary).lineLimit(1)
                if !letter.addressee.isEmpty {
                    Text(L.t("chat_letter_to", letter.addressee))
                        .textStyle(Typography.labelMedium.weight(.regular))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .lineLimit(2)
                }
                if !letter.subject.isEmpty {
                    Text(letter.subject).textStyle(Typography.titleSmall.weight(.bold)).foregroundStyle(palette.onSurface).lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Номер, дату или подписанта агент оставил человеку — без них письмо не отправить.
    private var needsFillingNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil").font(.system(size: 13)).foregroundStyle(palette.tones.warning)
            Text(L.t("chat_letter_needs_filling")).textStyle(Typography.labelMedium).foregroundStyle(palette.tones.warning)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(palette.tones.warningContainer, in: RoundedRectangle(cornerRadius: Radius.extraSmall, style: .continuous))
    }

    /// Пока файл скачивается — индикатор и «Скачивается…»; повторно кнопка не нажимается.
    private var downloadButton: some View {
        Button(action: onDownload) {
            HStack(spacing: 8) {
                if downloading {
                    ProgressView().controlSize(.small).tint(palette.onPrimaryContainer)
                } else {
                    Image(systemName: "arrow.down.to.line").font(.system(size: 14, weight: .semibold))
                }
                Text(L.t(downloading ? "chat_letter_downloading" : "chat_letter_download")).textStyle(Typography.labelLarge)
            }
            .foregroundStyle(palette.onPrimaryContainer)
            .padding(.leading, 16)
            .padding(.trailing, 24)
            .frame(minHeight: 40)
            .background(palette.primaryContainer, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(downloading)
    }

    private var saveTemplateButton: some View {
        Button {
            templateName = letter.subject.isEmpty ? letter.title : letter.subject
            namingTemplate = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "bookmark").font(.system(size: 14, weight: .semibold))
                Text(L.t("letter_templates_save")).textStyle(Typography.labelLarge)
            }
            .foregroundStyle(palette.primary)
            .padding(.leading, 16)
            .padding(.trailing, 24)
            .frame(minHeight: 40)
            .overlay(Capsule().stroke(palette.outline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Начало письма на «листе»: длинный текст к низу растворяется — видно, что он продолжается в файле.
private struct LetterPreview: View {
    let text: String
    @State private var shownHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0
    @Environment(\.palette) private var palette

    var body: some View {
        let clipped = fullHeight > shownHeight + 1
        Text(text)
            .textStyle(Typography.bodySmall)
            .foregroundStyle(palette.onSurfaceVariant)
            .lineLimit(5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { proxy in Color.clear.onAppear { shownHeight = proxy.size.height } })
            // Полный текст — невидимо, только чтобы понять, обрезан ли показанный.
            .background(alignment: .top) {
                Text(text)
                    .textStyle(Typography.bodySmall)
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .background(GeometryReader { proxy in Color.clear.onAppear { fullHeight = proxy.size.height } })
            }
            // Растворяется только текст, а не «лист» под ним.
            .mask(LinearGradient(
                stops: [.init(color: .black, location: 0.5), .init(color: clipped ? .clear : .black, location: 1)],
                startPoint: .top, endPoint: .bottom
            ))
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(palette.surfaceVariant, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
    }
}
