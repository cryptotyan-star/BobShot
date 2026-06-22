import AppKit
import CoreGraphics

/// Разрешение TCC «Запись экрана» (Screen Recording) для ScreenCaptureKit.
enum ScreenRecordingPermission {
    /// Текущий статус без показа диалога.
    static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Запросить доступ. Системный диалог показывается только при ПЕРВОМ обращении;
    /// если ранее отказали — вернёт `false` и больше не спрашивает (нужно вести в Настройки).
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openSystemSettings() {
        let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Алерт при отсутствии разрешения с кнопкой перехода в System Settings.
    static func showDeniedAlert() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Нужно разрешение «Запись экрана»"
        alert.informativeText = """
        BobShot не может делать скриншоты без доступа к записи экрана.
        Открой System Settings → Privacy & Security → Screen Recording и включи BobShot, \
        затем перезапусти приложение.
        """
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Отмена")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openSystemSettings()
        }
    }
}
