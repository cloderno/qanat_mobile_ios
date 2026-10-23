import SwiftUI

/// Основная кнопка экрана — во всю ширину, не ниже 56pt, с индикатором загрузки вместо текста.
/// Высота по содержимому: длинный текст при крупном шрифте переносится по центру, а не обрезается.
struct PrimaryButton: View {
    let text: String
    var enabled = true
    var loading = false
    var background: Color?
    var foreground: Color?
    var trailingIcon: String?
    let action: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        let container = background ?? palette.primary
        let content = foreground ?? palette.onPrimary
        Button(action: action) {
            HStack(spacing: 8) {
                if loading {
                    ProgressView().tint(content)
                } else {
                    Text(text)
                        .textStyle(Typography.titleMedium)
                        .multilineTextAlignment(.center)
                    if let trailingIcon {
                        Image(systemName: trailingIcon).font(.system(size: 15, weight: .semibold))
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(enabled ? content : palette.onSurface.opacity(0.38))
            .background(
                enabled ? container : palette.onSurface.opacity(0.12),
                in: RoundedRectangle(cornerRadius: Radius.authButton, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(!enabled || loading)
    }
}

/// Шапка вложенного экрана по макету: «назад», заголовок слева, действия справа.
struct ScreenTopBar<Actions: View>: View {
    let title: String
    let onBack: () -> Void
    @ViewBuilder var actions: () -> Actions

    @Environment(\.windowLayout) private var layout

    init(title: String, onBack: @escaping () -> Void, @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.title = title
        self.onBack = onBack
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 4) {
            IconButton(systemName: "arrow.left", action: onBack)
            Text(title)
                .textStyle(BrandText.screenTitle)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions()
        }
        .padding(.horizontal, 8)
        .frame(height: layout.topBarHeight)
    }
}

/// Круглая кнопка-иконка 48pt — как IconButton в Material.
struct IconButton: View {
    let systemName: String
    var size: CGFloat = 20
    var tint: Color?
    var accessibilityLabel: String?
    let action: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint ?? palette.onSurface)
                .frame(width: 48, height: 48)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel ?? "")
    }
}

/// Подпись над карточкой настроек — «Устройства», «Тема», «Аккаунт».
struct SectionHeader: View {
    let text: String
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .textStyle(Typography.bodySmall.weight(.semibold))
            .foregroundStyle(palette.onSurfaceVariant)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Карточка настроек — белая подложка со скруглением 20pt, внутри строки через [RowDivider].
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0, content: content)
            .background(palette.surfaceContainer, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }
}

/// Между строками одной карточки ([LinkRow], [ToggleRow]) — с отступом слева, как у их текста.
struct RowDivider: View {
    @Environment(\.palette) private var palette

    var body: some View {
        Rectangle()
            .fill(palette.outlineVariant)
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

/// Строка-ссылка в карточке настроек: заголовок, необязательная подпись под ним и иконка справа.
struct LinkRow: View {
    let title: String
    var subtitle: String?
    var titleColor: Color?
    var trailingIcon: String?
    var trailingIconSize: CGFloat = 15
    var minHeight: CGFloat?
    let action: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .textStyle(Typography.bodyLarge)
                        .foregroundStyle(titleColor ?? palette.onSurface)
                    if let subtitle {
                        Text(subtitle)
                            .textStyle(Typography.bodySmall)
                            .foregroundStyle(palette.onSurfaceVariant)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let trailingIcon {
                    Image(systemName: trailingIcon)
                        .font(.system(size: trailingIconSize, weight: .medium))
                        .foregroundStyle(palette.onSurfaceVariant)
                }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: minHeight ?? (subtitle != nil ? 56 : 52))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressHighlightStyle())
    }
}

/// Строка карточки настроек с переключателем — пара к [LinkRow]; переключает нажатие по всей строке.
struct ToggleRow: View {
    let title: String
    var subtitle: String?
    let isOn: Bool
    let onChange: (Bool) -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Button { onChange(!isOn) } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).textStyle(Typography.bodyLarge).foregroundStyle(palette.onSurface)
                    if let subtitle {
                        Text(subtitle).textStyle(Typography.bodySmall).foregroundStyle(palette.onSurfaceVariant)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SwitchPill(checked: isOn)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, subtitle != nil ? 8 : 0)
            .frame(minHeight: subtitle != nil ? 60 : 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressHighlightStyle())
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "1" : "0")
    }
}

/// Не системный Toggle: по макету кружок одного размера в обоих положениях и без обводки.
struct SwitchPill: View {
    let checked: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        ZStack(alignment: checked ? .trailing : .leading) {
            Capsule().fill(checked ? palette.primary : palette.tones.switchTrackOff)
            Circle()
                .fill(checked ? palette.onPrimary : palette.tones.switchThumbOff)
                .frame(width: 26, height: 26)
                .padding(3)
        }
        .frame(width: 52, height: 32)
        .animation(.easeInOut(duration: 0.18), value: checked)
    }
}

/// Сегментированный переключатель по макету: подложка — сама контейнер, выбранный сегмент лежит на ней «таблеткой».
struct SegmentedPicker: View {
    let options: [String]
    let selectedIndex: Int
    var segmentHeight: CGFloat = 44
    var trackRadius: CGFloat = 16
    var segmentRadius: CGFloat = 12
    var textStyle: QTextStyle = Typography.bodyMedium
    let onSelect: (Int) -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let selected = index == selectedIndex
                Button { onSelect(index) } label: {
                    Text(options[index])
                        .textStyle(textStyle.weight(selected ? .semibold : .regular))
                        .foregroundStyle(selected ? palette.onSurface : palette.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, minHeight: segmentHeight)
                        .background(
                            selected ? palette.tones.segmentSelected : .clear,
                            in: RoundedRectangle(cornerRadius: segmentRadius, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .padding(4)
        .background(palette.tones.segmentTrack, in: RoundedRectangle(cornerRadius: trackRadius, style: .continuous))
    }
}

/// Подсветка строки при нажатии — как ripple у clickable на Android.
struct PressHighlightStyle: ButtonStyle {
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? palette.onSurface.opacity(0.08) : .clear)
    }
}
