import Foundation
import ServiceManagement

/// Автозапуск при входе в систему через SMAppService (пункт в «Объектах входа» Системных настроек).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "включён"
        case .notRegistered: return "выключен"
        case .requiresApproval: return "ждёт разрешения в Системных настройках → Основные → Объекты входа"
        case .notFound: return "приложение не найдено (запускайте из ~/Applications)"
        @unknown default: return "неизвестно"
        }
    }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
