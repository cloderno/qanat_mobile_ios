import SwiftUI

/// Бренд-значок «Q» на экранах входа/пароля — та же роль, что App Icon на вебе.
struct AuthLogoBadge: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Text(brandLetter)
            .textStyle(BrandText.avatarLarge.size(28))
            .foregroundStyle(palette.onPrimary)
            .frame(width: 64, height: 64)
            .background(palette.primary, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Поле ввода с подписью над ним и бордером — как в макете.
struct AuthField: View {
    let label: String
    @Binding var text: String
    var placeholder: String?
    var enabled = true
    var isPassword = false
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var submitLabel: SubmitLabel = .next
    var onSubmit: () -> Void = {}

    @State private var visible = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).textStyle(Typography.labelMedium).foregroundStyle(palette.onSurfaceVariant)
            HStack(spacing: 0) {
                ZStack(alignment: .leading) {
                    if text.isEmpty, let placeholder {
                        Text(placeholder).textStyle(Typography.bodyLarge).foregroundStyle(palette.onSurfaceVariant)
                    }
                    Group {
                        if isPassword && !visible {
                            SecureField("", text: $text)
                        } else {
                            TextField("", text: $text)
                        }
                    }
                    .font(Typography.bodyLarge.font)
                    .foregroundStyle(palette.onSurface)
                    .keyboardType(isPassword ? .default : keyboard)
                    .textContentType(contentType ?? (isPassword ? .password : nil))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(submitLabel)
                    .onSubmit(onSubmit)
                    .disabled(!enabled)
                }
                .frame(maxWidth: .infinity)
                if isPassword {
                    Button { visible.toggle() } label: {
                        Image(systemName: visible ? "eye.slash.fill" : "eye.fill")
                            .foregroundStyle(palette.onSurfaceVariant)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L.t("auth_toggle_password_visibility"))
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 54)
            .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: Radius.authField, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.authField, style: .continuous).stroke(palette.outline, lineWidth: 1))
        }
    }
}

/// Текстовая кнопка-ссылка — как TextButton в Material.
struct TextLinkButton: View {
    let text: String
    var color: Color?
    var style: QTextStyle = Typography.labelLarge
    let action: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Text(text)
                .textStyle(style)
                .foregroundStyle(color ?? palette.primary)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
