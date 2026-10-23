import Combine
import CoreBluetooth

/// Включён ли Bluetooth телефона. Пока состояние неизвестно (или Bluetooth запрещён), считаем включённым:
/// причину проверки «Bluetooth выключен» называем, только когда система прямо так сказала.
final class PhoneBluetooth: NSObject, CBCentralManagerDelegate {
    let isOn = CurrentValueSubject<Bool, Never>(true)
    private var manager: CBCentralManager?

    /// Менеджер создаём при первой подписке: до подключения очков окно доступа к Bluetooth не показываем.
    func start() {
        guard manager == nil, CBManager.authorization == .allowedAlways else { return }
        manager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isOn.send(central.state != .poweredOff)
    }
}
