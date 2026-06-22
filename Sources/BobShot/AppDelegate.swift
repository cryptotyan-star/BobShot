import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotKey: GlobalHotKey?
    private let overlay = OverlayController()

    /// Защита от повторного входа: пока активен захват/оверлей, новый хоткей игнорируем.
    private var isCapturing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHotKey()
        CoordinateMapper.runSelfTest()
        AnnotationGeometry.runSelfTest()
        NSLog("BobShot запущен (захват ⌃⌥S → разметка in-place).")
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "camera.viewfinder",
                accessibilityDescription: "BobShot"
            )
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: "Снять область (⌃⌥S)", action: #selector(captureArea), keyEquivalent: "")
        )
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q")
        )
        statusItem.menu = menu
    }

    private func setupHotKey() {
        hotKey = GlobalHotKey(combo: .controlOptionS) { [weak self] in
            self?.startCapture()
        }
    }

    @objc private func captureArea() {
        startCapture()
    }

    /// Точка входа в сценарий захвата. Разрешение проверяем ДО оверлея
    /// (иначе системный диалог TCC окажется под shield-окном оверлея).
    private func startCapture() {
        guard !isCapturing else {
            NSLog("BobShot: захват уже идёт — повторный хоткей игнорирую.")
            return
        }

        guard ensureScreenRecordingPermission() else { return }

        isCapturing = true
        NSLog("BobShot: снимаю стоп-кадр экрана.")
        Task { @MainActor in
            do {
                let frozen = try await self.captureFrozenScreens()
                guard !frozen.isEmpty else {
                    NSLog("BobShot: нет дисплеев для стоп-кадра.")
                    NSSound.beep()
                    self.isCapturing = false
                    return
                }
                NSLog("BobShot: показываю оверлей по стоп-кадру (\(frozen.count) дисплей(ев)).")
                self.overlay.begin(
                    frozen: frozen,
                    onExport: { [weak self] request in
                        self?.handleExport(request)
                    },
                    onCancel: { [weak self] in
                        NSLog("BobShot: выделение отменено.")
                        self?.isCapturing = false
                    }
                )
            } catch {
                NSLog("BobShot: ошибка стоп-кадра: \(error)")
                NSSound.beep()
                self.isCapturing = false
            }
        }
    }

    /// Снимает стоп-кадр КАЖДОГО дисплея в нативном разрешении в момент вызова.
    private func captureFrozenScreens() async throws -> [FrozenScreen] {
        var result: [FrozenScreen] = []
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }
            let scale = screen.backingScaleFactor
            let pw = Int((screen.frame.width * scale).rounded())
            let ph = Int((screen.frame.height * scale).rounded())
            let img = try await ScreenCapturer.captureDisplay(
                displayID: displayID, pixelWidth: pw, pixelHeight: ph
            )
            result.append(FrozenScreen(screen: screen, image: img))
        }
        return result
    }

    /// true — можно снимать; false — разрешения нет, пользователю показан путь в Настройки.
    private func ensureScreenRecordingPermission() -> Bool {
        if ScreenRecordingPermission.isGranted { return true }

        // Первый запрос покажет системный диалог; повторный отказ — нет, поэтому ведём в Настройки.
        if ScreenRecordingPermission.request(), ScreenRecordingPermission.isGranted {
            return true
        }

        ScreenRecordingPermission.showDeniedAlert()
        return false
    }

    /// Композит аннотаций поверх уже снятого стоп-кадра региона + действие (копировать/сохранить).
    private func handleExport(_ request: ExportRequest) {
        defer { isCapturing = false }
        let result = request.result
        NSLog("BobShot: стоп-кадр \(format(result.globalRect)) на «\(result.screen.localizedName)», аннотаций: \(request.annotations.count).")
        let rep = AnnotationRenderer.flatten(
            base: request.regionImage,
            annotations: request.annotations,
            selectionInView: result.rectInScreen
        )
        switch request.action {
        case .copy: copyToPasteboard(rep)
        case .save: saveToDisk(rep)
        }
    }

    private func copyToPasteboard(_ rep: NSBitmapImageRep) {
        let pb = NSPasteboard.general
        pb.clearContents()
        if let png = AnnotationRenderer.pngData(rep) { pb.setData(png, forType: .png) }
        if let tiff = AnnotationRenderer.tiffData(rep) { pb.setData(tiff, forType: .tiff) }
        NSLog("BobShot: скопировано в буфер (PNG+TIFF).")
    }

    private func saveToDisk(_ rep: NSBitmapImageRep) {
        guard let png = AnnotationRenderer.pngData(rep) else { NSSound.beep(); return }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = desktop
        // Имя по умолчанию без коллизии: BobShot.png → BobShot1.png → BobShot2.png …
        panel.nameFieldStringValue = uniqueName(base: "BobShot", ext: "png", in: desktop)
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? png.write(to: url)
            NSLog("BobShot: сохранено → \(url.path)")
        }
    }

    /// Первое свободное имя «base.ext», «base1.ext», «base2.ext» … в каталоге dir.
    private func uniqueName(base: String, ext: String, in dir: URL?) -> String {
        guard let dir else { return "\(base).\(ext)" }
        let fm = FileManager.default
        var i = 0
        while true {
            let name = i == 0 ? "\(base).\(ext)" : "\(base)\(i).\(ext)"
            if !fm.fileExists(atPath: dir.appendingPathComponent(name).path) { return name }
            i += 1
        }
    }

    private func format(_ rect: NSRect) -> String {
        "(\(Int(rect.origin.x)), \(Int(rect.origin.y)), \(Int(rect.width))×\(Int(rect.height)) pt)"
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}
