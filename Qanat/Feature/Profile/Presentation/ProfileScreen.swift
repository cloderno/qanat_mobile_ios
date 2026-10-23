import PhotosUI
import SwiftUI

struct ProfileScreen: View {
    @State var viewModel: ProfileViewModel
    let email: String
    let onDone: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL
    @FocusState private var focus: Field?

    private enum Field { case lastName, firstName, middleName, birthDate }

    var body: some View {
        VStack(spacing: 0) {
            ScreenTopBar(title: L.t("profile_title"), onBack: onDone) {
                TextLinkButton(text: L.t("profile_done"), color: palette.tones.link, style: Typography.bodyMedium.weight(.semibold), action: onDone)
            }
            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
        .background(palette.background)
        .snackbar(message: viewModel.passwordResetSent ? L.t("profile_password_reset_sent") : nil) {
            viewModel.passwordResetSent = false
        }
    }

    private var form: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: Spacing.sm) {
                    ProfileAvatar(viewModel: viewModel)
                    if let error = viewModel.avatarError {
                        Text(error.text).foregroundStyle(palette.error).multilineTextAlignment(.center)
                    }
                    Text(L.t("profile_hint"))
                        .textStyle(Typography.bodyMedium.size(14))
                        .foregroundStyle(palette.onSurfaceVariant)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                SettingsCard {
                    field(L.t("profile_last_name"), $viewModel.lastName, placeholder: L.t("profile_last_name_placeholder"), .lastName, next: .firstName)
                    RowDivider()
                    field(L.t("profile_first_name"), $viewModel.firstName, .firstName, next: .middleName)
                    RowDivider()
                    field(L.t("profile_middle_name"), $viewModel.middleName, .middleName, next: .birthDate)
                    RowDivider()
                    field(L.t("profile_birth_date"), $viewModel.birthDateText, placeholder: L.t("profile_birth_date_placeholder"), .birthDate, next: nil)
                        .keyboardType(.numbersAndPunctuation)
                }

                VStack(spacing: Spacing.sm) {
                    SectionHeader(text: L.t("profile_account_section"))
                    SettingsCard {
                        labeled(L.t("profile_login_email")) {
                            Text(email).textStyle(Typography.bodyLarge).foregroundStyle(palette.secondary)
                        }
                        RowDivider()
                        LinkRow(
                            title: L.t("profile_change_password"),
                            trailingIcon: "chevron.right",
                            minHeight: 56,
                            action: { viewModel.requestPasswordReset(email: email) }
                        )
                        RowDivider()
                        // Самостоятельно удалить учётную запись нельзя: доступ выдаёт и снимает администратор организации.
                        LinkRow(
                            title: L.t("profile_account_deletion"),
                            subtitle: L.t("profile_account_deletion_hint"),
                            trailingIcon: "arrow.up.right.square",
                            action: { openURL(sitePageURL(.dataDeletion)) }
                        )
                    }
                }

                if let error = viewModel.error {
                    Text(error.text).foregroundStyle(palette.error).frame(maxWidth: .infinity, alignment: .leading)
                }
                // Последним элементом прокрутки, а не закреплённой панелью: на маленьком экране она закрывала поля.
                PrimaryButton(text: L.t("profile_save"), loading: viewModel.saving, action: viewModel.save)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.sm)
            .padding(.bottom, Spacing.xl)
            .readableWidth()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// Строка карточки: подпись над значением, как поля ввода в макете.
    private func labeled<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).textStyle(Typography.labelMedium.weight(.regular)).foregroundStyle(palette.onSurfaceVariant)
            value()
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    private func field(_ label: String, _ text: Binding<String>, placeholder: String? = nil, _ id: Field, next: Field?) -> some View {
        labeled(label) {
            TextField("", text: text, prompt: placeholder.map { Text($0).foregroundStyle(palette.onSurfaceVariant) })
                .font(Typography.bodyLarge.font)
                .foregroundStyle(palette.onSurface)
                .focused($focus, equals: id)
                .submitLabel(next == nil ? .done : .next)
                .onSubmit {
                    if let next { focus = next } else { viewModel.save() }
                }
        }
    }
}

/// Фото с инициалами; тап — меню «Выбрать фото» / «Удалить фото», выбранное сначала кадрируем под круг.
private struct ProfileAvatar: View {
    let viewModel: ProfileViewModel

    @State private var pickerShown = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var picked: IdentifiedImage?

    var body: some View {
        Menu {
            Button { pickerShown = true } label: { Label(L.t("avatar_choose"), systemImage: "photo.on.rectangle") }
            if viewModel.avatarURL != nil {
                Button(role: .destructive, action: viewModel.removeAvatar) { Label(L.t("avatar_remove"), systemImage: "trash") }
            }
        } label: {
            ZStack {
                Avatar(initials: viewModel.initials, imageURL: viewModel.avatarURL, size: 84, textStyle: Typography.headlineLarge)
                if viewModel.avatarBusy { ProgressView().controlSize(.large) }
            }
        }
        .disabled(viewModel.avatarBusy)
        .accessibilityLabel(L.t("avatar_change"))
        .photosPicker(isPresented: $pickerShown, selection: $pickedItem, matching: .images)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    viewModel.avatarUnreadable()
                    return
                }
                picked = IdentifiedImage(image: image.normalized())
            }
        }
        .fullScreenCover(item: $picked) { picked in
            AvatarCropView(
                image: picked.image,
                onCropped: { jpeg in
                    self.picked = nil
                    viewModel.avatarCropped(jpeg)
                },
                onDismiss: { self.picked = nil }
            )
        }
    }
}

struct IdentifiedImage: Identifiable {
    let id = UUID()
    let image: UIImage
}
