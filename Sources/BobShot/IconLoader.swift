import AppKit

/// Загрузка иконок панели из бандла (Contents/Resources/icons/<name>.png).
/// PNG кладёт build-app.sh из Resources/icons/png. NSImage не грузит произвольный SVG, потому PNG.
enum IconLoader {
    private static var cache: [String: NSImage] = [:]

    static func icon(_ name: String, size: CGFloat = 20) -> NSImage? {
        let key = "\(name)@\(size)"
        if let c = cache[key] { return c }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "icons"),
              let img = NSImage(contentsOf: url) else {
            NSLog("BobShot: иконка не найдена в бандле: icons/\(name).png")
            return nil
        }
        img.size = NSSize(width: size, height: size)
        cache[key] = img
        return img
    }
}
