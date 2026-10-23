import QuickLook
import SwiftUI

/// Документ убирается из «Документов»: done — убран, экран закрывается.
enum Deletion { case none, inProgress, done }

/// Экран одного документа.
@MainActor
@Observable
final class DocumentViewModel {
    enum Phase {
        case loading
        case failed(messageKey: String)
        case loaded(AgentDocument)
    }

    private(set) var phase: Phase = .loading
    /// Формат, файл которого скачивается; nil — ничего не скачивается.
    private(set) var downloading: DocumentFormat?
    /// Скачанный файл: экран открывает его один раз; nil — открывать нечего.
    var fileToOpen: URL?
    private(set) var deletion: Deletion = .none
    /// Не скачалось или не убралось — сообщение показывается один раз.
    var messageKey: String?

    private let documents: DocumentRepository
    let documentId: String

    init(documents: DocumentRepository, documentId: String) {
        self.documents = documents
        self.documentId = documentId
        load()
    }

    var document: AgentDocument? {
        if case .loaded(let document) = phase { return document }
        return nil
    }

    func retry() { load() }

    /// Скачивает файл, затем экран его откроет. Пока качается один формат, нажатия не считаются.
    func download(_ format: DocumentFormat) {
        guard let document, downloading == nil, document.formats.contains(format) else { return }
        downloading = format
        messageKey = nil
        Task {
            do {
                fileToOpen = try await documents.download(id: document.id, format: format).url
            } catch {
                log.warning("Файл документа \(document.id) (\(format)) не скачался: \(error)")
                messageKey = "chat_document_download_failed"
            }
            downloading = nil
        }
    }

    /// Подтверждение спрашивает экран; убранный документ пропадает и из списка «Документов».
    func delete() {
        guard document != nil, deletion == .none else { return }
        deletion = .inProgress
        messageKey = nil
        Task {
            do {
                try await documents.delete(id: documentId)
                deletion = .done
            } catch {
                log.warning("Документ \(documentId) не убран: \(error)")
                deletion = .none
                messageKey = "documents_delete_failed"
            }
        }
    }

    private func load() {
        phase = .loading
        Task {
            do {
                phase = .loaded(try await documents.document(id: documentId))
            } catch {
                phase = .failed(messageKey: documentsMessageKey(error))
            }
        }
    }
}

/// Документ во весь экран: откуда он, сам блок — как в ответе агента, скачивание файлов и «Убрать».
/// [onBack] вызывается и после того, как документ убран; [onOpenChat] — открыть чат, где агент его сделал.
struct DocumentScreen: View {
    @State var viewModel: DocumentViewModel
    let onBack: () -> Void
    let onOpenChat: (String) -> Void

    @State private var confirmDelete = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: viewModel.document?.kind.label ?? L.t("documents_kind_other"), onBack: onBack) {
                if viewModel.document != nil {
                    Button { confirmDelete = true } label: {
                        Group {
                            if viewModel.deletion != .none { ProgressView().controlSize(.small) } else {
                                Image(systemName: "trash").font(.system(size: 18)).foregroundStyle(palette.onSurface)
                            }
                        }
                        .frame(width: 48, height: 48)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.deletion != .none)
                    .accessibilityLabel(L.t("documents_delete"))
                }
            }
            switch viewModel.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let key):
                DocumentsNotice(icon: "exclamationmark.circle", text: L.t(key), onRetry: viewModel.retry)
                    .frame(maxHeight: .infinity)
            case .loaded(let document):
                content(document)
            }
        }
        .background(palette.background)
        .snackbar(message: viewModel.messageKey.map { L.t($0) }) { viewModel.messageKey = nil }
        .quickLookPreview($viewModel.fileToOpen)
        // Документ убран — назад, к списку, где его уже нет.
        .onChange(of: viewModel.deletion) { _, deletion in if deletion == .done { onBack() } }
        .alert(L.t("documents_delete_confirm_title"), isPresented: $confirmDelete) {
            Button(L.t("common_cancel"), role: .cancel) {}
            Button(L.t("documents_delete_confirm"), role: .destructive, action: viewModel.delete)
        } message: {
            Text(L.t("documents_delete_confirm_text"))
        }
    }

    private func content(_ document: AgentDocument) -> some View {
        // Файл письма скачивают кнопки форматов ниже — своя кнопка письма их бы задвоила.
        let block: ChatBlock = if case .letter(let letter) = document.block {
            .letter(LetterBlock(title: letter.title, addressee: letter.addressee, subject: letter.subject, preview: letter.preview, documentId: nil, needsFilling: letter.needsFilling))
        } else {
            document.block
        }
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header(document)
                // Чат удалён — переходить некуда.
                if let chatId = document.chatId { chatSource(document.chatTitle) { onOpenChat(chatId) } }
                BlockView(block: block, actions: MessageActions(
                    playing: nil, onTogglePlayback: { _ in }, loadPhoto: { _, _ in nil }, onOpenPhoto: { _ in },
                    downloadingDocument: nil, onDownloadDocument: { _ in }, onSaveTemplate: { _, _ in }
                ))
                if !document.formats.isEmpty { downloads(document.formats) }
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.xs)
            .padding(.bottom, Spacing.xl)
            .readableWidth()
        }
    }

    /// Значок вида, название и подпись с тем, когда документ сделан.
    private func header(_ document: AgentDocument) -> some View {
        HStack(spacing: Spacing.md) {
            DocumentKindIcon(kind: document.kind, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title.isEmpty ? document.kind.label : document.title).textStyle(Typography.titleMedium).foregroundStyle(palette.onSurface)
                Text([document.subtitle, fullCreatedLabel(document.createdAt)].filter { !$0.isEmpty }.joined(separator: " · "))
                    .textStyle(Typography.bodySmall)
                    .foregroundStyle(palette.onSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// «Из чата «…»» — открывает чат, где агент сделал документ.
    private func chatSource(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left").font(.system(size: 15)).foregroundStyle(palette.onSurfaceVariant)
                Text(L.t("documents_from_chat", title.isEmpty ? L.t("chat_untitled") : title))
                    .textStyle(Typography.bodyMedium)
                    .foregroundStyle(palette.onSurface)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.onSurfaceVariant)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).stroke(palette.outline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// «Скачать»: кнопка на каждый формат, который отдаёт сервер. Пока качается один, остальные не нажимаются.
    private func downloads(_ formats: [DocumentFormat]) -> some View {
        VStack(spacing: Spacing.sm) {
            SectionHeader(text: L.t("documents_download_section"))
            ForEach(formats, id: \.self) { format in
                let inProgress = viewModel.downloading == format
                Button { viewModel.download(format) } label: {
                    HStack(spacing: 8) {
                        if inProgress {
                            ProgressView().controlSize(.small).tint(palette.onPrimaryContainer)
                        } else {
                            Image(systemName: "arrow.down.to.line").font(.system(size: 14, weight: .semibold))
                        }
                        Text(inProgress ? L.t("chat_letter_downloading") : L.t("documents_format_\(format.rawValue)"))
                            .textStyle(Typography.labelLarge)
                    }
                    .foregroundStyle(palette.onPrimaryContainer)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(palette.primaryContainer, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.downloading != nil)
                .opacity(viewModel.downloading != nil && !inProgress ? 0.5 : 1)
            }
        }
    }
}

private let log = Log("DocumentScreen")
