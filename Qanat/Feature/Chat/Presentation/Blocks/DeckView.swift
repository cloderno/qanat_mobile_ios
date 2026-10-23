import SwiftUI
import WebKit

/// Презентация от агента прямо в ленте: страница со слайдами 16:9 во всю ширину карточки, листается пальцем
/// влево-вправо, и кнопка «На весь экран». Страница одна на карточку: «На весь экран» переносит её на тот же слайд.
struct DeckView: View {
    let title: String
    let url: String?

    @State private var page: DeckPage?
    @State private var fullScreen = false
    @Environment(\.palette) private var palette

    var body: some View {
        if let url {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    palette.surfaceContainerHighest
                    // Пока открыт полный экран, страница там; в карточке остаётся пустая рамка того же размера.
                    if let page, !fullScreen { DeckFrame(page: page) }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Button { fullScreen = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 14, weight: .semibold))
                        Text(L.t("deck_fullscreen")).textStyle(Typography.labelLarge)
                    }
                    .foregroundStyle(palette.primary)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 40)
                    .overlay(Capsule().stroke(palette.outline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .onAppear { page = DeckPage.obtain(current: page, url: url) }
            .onChange(of: url) { _, new in page = DeckPage.obtain(current: page, url: new) }
            .fullScreenCover(isPresented: $fullScreen) {
                if let page { DeckFullScreen(page: page) { fullScreen = false } }
            }
        }
    }
}

/// Во весь экран — та же страница, закрывается крестиком. Слайд 16:9 занимает весь экран, если телефон повернуть.
private struct DeckFullScreen: View {
    let page: DeckPage
    let onClose: () -> Void

    @State private var showRotateHint = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Подсказку «Поверните телефон» показываем один раз за запуск приложения.
    private static var rotateHintShown = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            DeckFrame(page: page)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.black.opacity(0.55), in: Circle())
            }
            .accessibilityLabel(L.t("deck_close"))
            .padding(8)
            if showRotateHint {
                Text(L.t("deck_rotate_hint"))
                    .textStyle(Typography.bodyMedium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .task {
            guard verticalSizeClass == .regular, !Self.rotateHintShown else { return }
            Self.rotateHintShown = true
            withAnimation { showRotateHint = true }
            try? await Task.sleep(for: .milliseconds(2500))
            withAnimation { showRotateHint = false }
        }
    }
}

/// Страница презентации с заглушкой, пока грузится, и «Повторить», если не загрузилась.
private struct DeckFrame: View {
    let page: DeckPage
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack {
            DeckWebView(page: page)
            switch page.load {
            case .loading:
                ZStack {
                    palette.surfaceContainerHighest
                    ProgressView()
                }
            case .failed:
                VStack(spacing: 4) {
                    Text(L.t("deck_error"))
                        .textStyle(Typography.bodyMedium)
                        .foregroundStyle(palette.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                    TextLinkButton(text: L.t("common_retry"), action: page.reload)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(palette.surfaceContainerHighest)
            case .loaded:
                EmptyView()
            }
        }
    }
}

private struct DeckWebView: UIViewRepresentable {
    let page: DeckPage

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        page.attach(to: container)
        return container
    }

    func updateUIView(_ container: UIView, context: Context) {
        // Страницу могли перенести в полный экран и обратно — возвращаем её в эту рамку.
        if page.webView.superview !== container { page.attach(to: container) }
    }
}

enum DeckLoad { case loading, loaded, failed }

/// WKWebView презентации. Живёт дольше SwiftUI-представления: переносится между карточкой и полным экраном.
@Observable
final class DeckPage: NSObject, WKNavigationDelegate {
    private(set) var load: DeckLoad = .loading
    var url: String
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var retried = false
    @ObservationIgnored private var timeout: Task<Void, Never>?

    /// Столько ждём главную страницу; дольше — показываем «Повторить», а не вечную заглушку.
    private static let loadTimeout: Double = 30

    private init(url: String) {
        self.url = url
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        super.init()
        webView.navigationDelegate = self
        start()
    }

    /// Та же презентация с новой подписью `k` (сервер меняет её раз в час) — та же страница: перезагрузка оборвала бы
    /// загрузку и сбросила слайд. Новый адрес пригодится для «Повторить».
    static func obtain(current: DeckPage?, url: String) -> DeckPage {
        if let current, deckIdentity(current.url) == deckIdentity(url) {
            current.url = url
            return current
        }
        return DeckPage(url: url)
    }

    func attach(to container: UIView) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(webView)
    }

    func reload() {
        retried = false
        load = .loading
        webView.stopLoading()
        start()
    }

    private func start() {
        guard let target = URL(string: url) else {
            load = .failed
            return
        }
        timeout?.cancel()
        let started = uptimeMs()
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.loadTimeout))
            guard let self, !Task.isCancelled, self.load == .loading else { return }
            log.warning("No answer in \(Self.loadTimeout) s: \(self.url)")
            // Полминуты уже прождали — второй раз сами не ждём, сразу «Повторить».
            self.webView.stopLoading()
            self.load = .failed
        }
        log.info("Loading deck, started at \(started)")
        webView.load(URLRequest(url: target))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timeout?.cancel()
        if load == .loading { load = .loaded }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
            log.warning("HTTP \(http.statusCode): \(url)")
            decisionHandler(.cancel)
            fail(URLError(.badServerResponse))
            return
        }
        decisionHandler(.allow)
    }

    /// Прерванную или неудачную загрузку повторяем один раз сами, потом — «Не удалось открыть» и «Повторить».
    private func fail(_ error: Error) {
        if (error as? URLError)?.code == .cancelled { return }
        timeout?.cancel()
        log.warning("Deck failed: \(error)")
        if !retried {
            retried = true
            start()
        } else {
            load = .failed
        }
    }
}

/// Адрес презентации без подписи `k`: она меняется со временем, а презентация та же.
func deckIdentity(_ url: String) -> String {
    guard let query = url.firstIndex(of: "?") else { return url }
    let end = url[query...].firstIndex(of: "#") ?? url.endIndex
    let params = url[url.index(after: query)..<end].split(separator: "&").filter { $0 != "k" && !$0.hasPrefix("k=") }
    return String(url[..<query]) + (params.isEmpty ? "" : "?" + params.joined(separator: "&")) + String(url[end...])
}

private let log = Log("DeckView")
