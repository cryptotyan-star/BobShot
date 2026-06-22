import AppKit

// Точка входа. BobShot — фоновая утилита из меню-бара (без иконки в Dock),
// поэтому activationPolicy = .accessory (вместе с LSUIElement в Info.plist).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
