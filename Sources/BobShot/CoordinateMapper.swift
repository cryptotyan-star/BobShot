import AppKit
import CoreGraphics

extension NSScreen {
    /// CGDirectDisplayID этого экрана (через deviceDescription[NSScreenNumber]).
    var displayID: CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? NSNumber)?.uint32Value
    }
}

/// Перевод координат: глобальный прямоугольник AppKit → пиксели снимка дисплея (origin сверху-слева).
/// Масштаб ВЫВОДИТСЯ из реального размера снимка (а не из backingScaleFactor) —
/// иначе на масштабированных HiDPI-режимах кроп уезжает. Изолировано + самотест.
enum CoordinateMapper {
    /// - globalRect: AppKit-глобальные координаты (origin снизу-слева главного экрана, ось Y вверх).
    /// - screenFrame: frame нужного экрана в той же системе (в точках).
    /// - imagePixelSize: размер снимка ВСЕГО дисплея в пикселях (из захваченного CGImage).
    /// - returns: прямоугольник кропа в пикселях снимка, origin сверху-слева (как у CGImage).
    static func cropRect(globalRect: CGRect, screenFrame: CGRect, imagePixelSize: CGSize) -> CGRect {
        guard screenFrame.width > 0, screenFrame.height > 0 else { return .zero }
        let sx = imagePixelSize.width / screenFrame.width
        let sy = imagePixelSize.height / screenFrame.height

        let localX = globalRect.minX - screenFrame.minX
        // Низ-лево AppKit → верх-лево: высота экрана минус верхняя грань выделения.
        let localYTop = screenFrame.height - (globalRect.maxY - screenFrame.minY)

        return CGRect(
            x: localX * sx,
            y: localYTop * sy,
            width: globalRect.width * sx,
            height: globalRect.height * sy
        ).integral
    }

    /// Самопроверка ключевых случаев (вызывается на старте в debug).
    static func runSelfTest() {
        // Главный экран 1440×900 pt, снимок 2880×1800 px (2x). Выделение global (10,20) 100×50.
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let img2x = CGSize(width: 2880, height: 1800)
        let sel = CGRect(x: 10, y: 20, width: 100, height: 50)
        let r = cropRect(globalRect: sel, screenFrame: main, imagePixelSize: img2x)
        // sx=sy=2; localX=10, localYTop=900-(20+50)=830 → (20,1660,200,100)
        assert(r == CGRect(x: 20, y: 1660, width: 200, height: 100), "mapper main fail: \(r)")

        // Масштабированный режим: 1800 pt логических, снимок 3600 px → sx=2 (выводится из снимка).
        let scaled = CGRect(x: 0, y: 0, width: 1800, height: 1169)
        let imgScaled = CGSize(width: 3600, height: 2338)
        let selS = CGRect(x: 100, y: 169, width: 200, height: 100)
        let rS = cropRect(globalRect: selS, screenFrame: scaled, imagePixelSize: imgScaled)
        // sx=sy=2; localX=100, localYTop=1169-(169+100)=900 → (200,1800,400,200)
        assert(rS == CGRect(x: 200, y: 1800, width: 400, height: 200), "mapper scaled fail: \(rS)")

        // Второй экран слева (origin.x = -1440), снимок 1440×900 (1x).
        let left = CGRect(x: -1440, y: 0, width: 1440, height: 900)
        let img1x = CGSize(width: 1440, height: 900)
        let sel2 = CGRect(x: -1410, y: 100, width: 200, height: 100)
        let r2 = cropRect(globalRect: sel2, screenFrame: left, imagePixelSize: img1x)
        // sx=sy=1; localX=30, localYTop=900-(100+100)=700 → (30,700,200,100)
        assert(r2 == CGRect(x: 30, y: 700, width: 200, height: 100), "mapper left fail: \(r2)")

        NSLog("BobShot: CoordinateMapper self-test OK")
    }
}
