import SwiftUI

/// Строка статуса очков с цветной точкой: бирюзовая — надеты и на связи, жёлтая — сняты, серая — нет связи
/// или на связи, но надеты ли — неизвестно. Для [GlassesStatus.notConnected] ничего не рисует.
struct GlassesStatusLine: View {
    let status: GlassesStatus
    let deviceName: String?

    @Environment(\.palette) private var palette

    var body: some View {
        if let (dot, text) = content {
            HStack(spacing: 5) {
                Circle().fill(dot).frame(width: 6, height: 6)
                Text(text)
                    .textStyle(Typography.labelMedium.weight(.regular))
                    .foregroundStyle(status == .ready ? palette.onPrimaryContainer : palette.onSurfaceVariant)
                    .lineLimit(1)
            }
        }
    }

    private var content: (Color, String)? {
        switch status {
        case .notConnected: nil
        case .offline: (palette.outline, L.t("glasses_status_offline"))
        case .takenOff: (palette.tones.warning, L.t("glasses_status_taken_off"))
        case .connected: (palette.outline, L.t("glasses_drawer_connected", deviceName ?? ""))
        case .ready: (palette.tones.connected, L.t("glasses_drawer_connected", deviceName ?? ""))
        }
    }
}

/// Инициалы для аватара: первые буквы первых двух слов имени.
func initials(of displayName: String) -> String {
    displayName.split(separator: " ").prefix(2).compactMap { $0.first?.uppercased() }.joined()
}
