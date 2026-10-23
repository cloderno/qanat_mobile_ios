import SwiftUI

/// Короткое сообщение внизу экрана — как Snackbar в Material: показывается [message], через 4 с уходит само.
private struct SnackbarModifier: ViewModifier {
    let message: String?
    var actionLabel: String?
    var action: (() -> Void)?
    let onDismiss: () -> Void

    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                HStack(spacing: 12) {
                    Text(message)
                        .textStyle(Typography.bodyMedium)
                        .foregroundStyle(palette.inverseOnSurface)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let actionLabel, let action {
                        Button {
                            action()
                            onDismiss()
                        } label: {
                            Text(actionLabel).textStyle(Typography.labelLarge).foregroundStyle(palette.inverseOnSurface.opacity(0.9))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(palette.inverseSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .task(id: message) {
                    try? await Task.sleep(for: .seconds(4))
                    if !Task.isCancelled { onDismiss() }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
    }
}

extension View {
    func snackbar(message: String?, actionLabel: String? = nil, action: (() -> Void)? = nil, onDismiss: @escaping () -> Void) -> some View {
        modifier(SnackbarModifier(message: message, actionLabel: actionLabel, action: action, onDismiss: onDismiss))
    }
}
