import AppKit

/// Результат выделения области.
struct SelectionResult {
    let screen: NSScreen
    /// Прямоугольник в глобальных координатах AppKit (origin снизу-слева главного экрана).
    let globalRect: NSRect
    /// Прямоугольник в координатах вью своего экрана (origin снизу-слева этого экрана).
    let rectInScreen: NSRect
}

/// Запрос экспорта из in-place редактора: что снимать, какие аннотации поверх, что делать.
struct ExportRequest {
    let result: SelectionResult
    /// Аннотации в координатах вью экрана выделения (origin снизу-слева), как и result.rectInScreen.
    let annotations: [Annotation]
    let action: EditorAction
    /// Готовый кроп региона из стоп-кадра (нативные пиксели). Композит аннотаций — поверх него.
    let regionImage: CGImage
}

/// Стоп-кадр одного дисплея: экран + снимок всего дисплея (нативные пиксели).
struct FrozenScreen {
    let screen: NSScreen
    let image: CGImage
}

/// Borderless-окно поверх всего для одного экрана.
final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Создаёт оверлеи на всех экранах и сообщает о выборе/отмене.
final class OverlayController: NSObject, SelectionViewDelegate {
    private var windows: [OverlayWindow] = []
    private var onExport: ((ExportRequest) -> Void)?
    private var onCancel: (() -> Void)?
    private(set) var isActive = false

    func begin(frozen: [FrozenScreen],
               onExport: @escaping (ExportRequest) -> Void,
               onCancel: @escaping () -> Void) {
        guard !isActive else { return }
        isActive = true
        self.onExport = onExport
        self.onCancel = onCancel

        for f in frozen {
            let screen = f.screen
            let window = OverlayWindow(screen: screen)
            let view = SelectionView(
                frame: NSRect(origin: .zero, size: screen.frame.size),
                screen: screen,
                image: f.image
            )
            view.delegate = self
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view) // чтобы Esc ловился сразу
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - SelectionViewDelegate

    func exportRequested(action: EditorAction, annotations: [Annotation], rectInView: NSRect, view: SelectionView) {
        let screen = view.screen
        let globalRect = NSRect(
            x: screen.frame.origin.x + rectInView.origin.x,
            y: screen.frame.origin.y + rectInView.origin.y,
            width: rectInView.width,
            height: rectInView.height
        )
        let result = SelectionResult(screen: screen, globalRect: globalRect, rectInScreen: rectInView)

        // Кроп берём из стоп-кадра (снят в момент хоткея), а не из «живого» экрана.
        guard let full = view.frozenImage,
              let region = try? ScreenCapturer.cropRegion(
                  full: full, globalRect: globalRect, screenFrame: screen.frame) else {
            NSLog("BobShot: не удалось вырезать регион из стоп-кадра.")
            tearDown()
            onCancel?()
            cleanup()
            return
        }
        let request = ExportRequest(result: result, annotations: annotations,
                                    action: action, regionImage: region)
        tearDown()
        onExport?(request)
        cleanup()
    }

    func selectionCancelled() {
        tearDown()
        onCancel?()
        cleanup()
    }

    // MARK: - Lifecycle

    /// Скрыть и убрать все окна оверлея (важно: до захвата экрана в Фазе 4).
    private func tearDown() {
        NSCursor.arrow.set()
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
    }

    private func cleanup() {
        onExport = nil
        onCancel = nil
        isActive = false
    }
}
