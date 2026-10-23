import SwiftUI

struct LoginScreen: View {
    @State var viewModel: LoginViewModel
    let onForgotPassword: () -> Void

    @Environment(\.palette) private var palette
    @FocusState private var focus: Field?

    private enum Field { case email, password }

    var body: some View {
        let enabled = viewModel.status != .submitting
        // Прокрутка уменьшается до места над клавиатурой; на планшете форма не шире 600pt.
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xxl) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    AuthLogoBadge()
                    Text(L.t("login_title"))
                        .textStyle(BrandText.greeting.size(28, lineHeight: 32))
                        .foregroundStyle(palette.onSurface)
                }

                VStack(alignment: .leading, spacing: Spacing.md) {
                    AuthField(
                        label: L.t("login_username"),
                        text: $viewModel.email,
                        placeholder: L.t("login_email_placeholder"),
                        enabled: enabled,
                        keyboard: .emailAddress,
                        contentType: .username,
                        submitLabel: .next,
                        onSubmit: { focus = .password }
                    )
                    .focused($focus, equals: .email)
                    AuthField(
                        label: L.t("login_password"),
                        text: $viewModel.password,
                        enabled: enabled,
                        isPassword: true,
                        submitLabel: .done,
                        onSubmit: viewModel.submit
                    )
                    .focused($focus, equals: .password)
                    if case .error(let key) = viewModel.status {
                        Text(L.t(key)).textStyle(Typography.bodyMedium).foregroundStyle(palette.error)
                    }
                    Button(action: onForgotPassword) {
                        Text(L.t("login_forgot_password"))
                            .textStyle(Typography.titleSmall)
                            .foregroundStyle(palette.primary)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }

                PrimaryButton(
                    text: L.t("login_submit"),
                    enabled: viewModel.canSubmit,
                    loading: viewModel.status == .submitting,
                    action: viewModel.submit
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, Spacing.xl)
            .padding(.bottom, Spacing.lg)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
        .background(palette.background)
    }
}

struct ForgotPasswordScreen: View {
    @State var viewModel: ForgotPasswordViewModel
    let onBack: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        let sent = viewModel.status == .sent
        let submitting = viewModel.status == .submitting
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                IconButton(systemName: "arrow.left", action: onBack).padding(Spacing.xs)
                VStack(alignment: .leading, spacing: 0) {
                    if sent {
                        Image(systemName: "envelope")
                            .font(.system(size: 26))
                            .foregroundStyle(palette.onPrimaryContainer)
                            .frame(width: 64, height: 64)
                            .background(palette.primaryContainer, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        Spacer().frame(height: Spacing.md)
                        Text(L.t("forgot_password_sent_title")).textStyle(BrandText.greeting).foregroundStyle(palette.onSurface)
                        Spacer().frame(height: Spacing.sm)
                        Text(L.t("forgot_password_sent")).textStyle(Typography.bodyLarge).foregroundStyle(palette.onSurfaceVariant)
                    } else {
                        Text(L.t("forgot_password_title")).textStyle(BrandText.greeting).foregroundStyle(palette.onSurface)
                        Spacer().frame(height: Spacing.sm)
                        Text(L.t("forgot_password_hint")).textStyle(Typography.bodyLarge).foregroundStyle(palette.onSurfaceVariant)
                        Spacer().frame(height: Spacing.xl)
                        AuthField(
                            label: L.t("forgot_password_email"),
                            text: $viewModel.email,
                            placeholder: L.t("login_email_placeholder"),
                            enabled: !submitting,
                            keyboard: .emailAddress,
                            contentType: .emailAddress,
                            submitLabel: .done,
                            onSubmit: viewModel.submit
                        )
                        if case .error(let key) = viewModel.status {
                            Spacer().frame(height: Spacing.sm)
                            Text(L.t(key)).textStyle(Typography.bodyMedium).foregroundStyle(palette.error)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, Spacing.sm)
                .readableWidth()

                VStack(spacing: 6) {
                    if !sent {
                        PrimaryButton(
                            text: L.t("forgot_password_submit"),
                            enabled: viewModel.canSubmit,
                            loading: submitting,
                            action: viewModel.submit
                        )
                    }
                    Button(action: onBack) {
                        Text(L.t("forgot_password_back_to_login"))
                            .textStyle(Typography.bodyMedium)
                            .foregroundStyle(palette.onSurfaceVariant)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.top, Spacing.xl)
                .padding(.bottom, Spacing.lg)
                .readableWidth()
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(palette.background)
    }
}

struct ResetPasswordScreen: View {
    @State var viewModel: ResetPasswordViewModel
    let onDone: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch viewModel.status {
            case .checking:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .invalid:
                centered {
                    title
                    Spacer().frame(height: Spacing.sm)
                    Text(L.t("reset_password_invalid")).textStyle(Typography.bodyLarge).foregroundStyle(palette.onSurfaceVariant)
                    Spacer().frame(height: Spacing.lg)
                    TextLinkButton(text: L.t("reset_password_continue_to_login"), action: onDone)
                }
            case .error(let key):
                centered {
                    title
                    Spacer().frame(height: Spacing.sm)
                    Text(L.t(key)).textStyle(Typography.bodyLarge).foregroundStyle(palette.error)
                    Spacer().frame(height: Spacing.lg)
                    PrimaryButton(text: L.t("common_retry"), action: viewModel.retryCheck)
                    TextLinkButton(text: L.t("reset_password_continue_to_login"), action: onDone)
                }
            case .done:
                centered {
                    title
                    Spacer().frame(height: Spacing.sm)
                    Text(L.t("reset_password_done")).textStyle(Typography.bodyLarge).foregroundStyle(palette.onSurfaceVariant)
                    Spacer().frame(height: Spacing.lg)
                    PrimaryButton(text: L.t("reset_password_continue_to_login"), action: onDone)
                }
            case .valid(let email):
                form(email: email)
            }
        }
        .background(palette.background)
    }

    private var title: some View {
        Text(L.t("reset_password_title")).textStyle(BrandText.greeting).foregroundStyle(palette.onSurface)
    }

    private func form(email: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                title
                if let email {
                    Spacer().frame(height: Spacing.sm)
                    Text(L.t("reset_password_for_email", email)).textStyle(Typography.bodyLarge).foregroundStyle(palette.onSurfaceVariant)
                }
                Spacer().frame(height: Spacing.xl)
                VStack(spacing: Spacing.md) {
                    AuthField(
                        label: L.t("reset_password_field"),
                        text: $viewModel.password,
                        placeholder: L.t("reset_password_field_placeholder"),
                        enabled: !viewModel.submitting,
                        isPassword: true,
                        contentType: .newPassword
                    )
                    AuthField(
                        label: L.t("reset_password_confirm_field"),
                        text: $viewModel.confirmPassword,
                        enabled: !viewModel.submitting,
                        isPassword: true,
                        contentType: .newPassword,
                        submitLabel: .done,
                        onSubmit: viewModel.submit
                    )
                }
                if let error = viewModel.error?.text ?? viewModel.fieldErrorKey.map({ L.t($0) }) {
                    Spacer().frame(height: Spacing.sm)
                    Text(error).textStyle(Typography.bodyMedium).foregroundStyle(palette.error)
                }
                Spacer().frame(height: Spacing.md)
                Text(L.t("reset_password_hint")).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                Spacer().frame(height: Spacing.xl)
                PrimaryButton(
                    text: L.t("reset_password_submit"),
                    enabled: viewModel.canSubmit,
                    loading: viewModel.submitting,
                    action: viewModel.submit
                )
                .padding(.bottom, Spacing.lg)
            }
            .padding(.horizontal, 20)
            .padding(.top, Spacing.xxl)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Итог проверки ссылки посередине экрана; не помещается по высоте — прокручивается.
    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0, content: content)
                    .padding(.horizontal, 20)
                    .padding(.vertical, Spacing.lg)
                    .readableWidth()
                    .frame(minHeight: proxy.size.height)
            }
        }
    }
}
