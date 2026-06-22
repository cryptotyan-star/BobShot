import AppKit
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error {
    case displayNotFound
    case cropFailed
}

/// Захват экрана через ScreenCaptureKit (macOS 14+, SCScreenshotManager).
enum ScreenCapturer {
    /// Снимок всего дисплея в заданном пиксельном размере.
    static func captureDisplay(displayID: CGDirectDisplayID, pixelWidth: Int, pixelHeight: Int) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false
        )
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = max(1, pixelWidth)
        config.height = max(1, pixelHeight)
        config.showsCursor = false
        config.captureResolution = .best

        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config
        )
    }

    /// Кроп уже снятого стоп-кадра дисплея до области выделения.
    /// `full` — снимок ВСЕГО дисплея (нативные пиксели), снятый в момент хоткея.
    /// Масштаб выводится из реального размера снимка (HiDPI-safe).
    static func cropRegion(
        full: CGImage,
        globalRect: CGRect,
        screenFrame: CGRect
    ) throws -> CGImage {
        let imageSize = CGSize(width: full.width, height: full.height)
        let crop = CoordinateMapper.cropRect(
            globalRect: globalRect, screenFrame: screenFrame, imagePixelSize: imageSize
        )
        NSLog("BobShot[crop]: snap=\(full.width)×\(full.height) frame=\(Int(screenFrame.width))×\(Int(screenFrame.height)) global=\(rectStr(globalRect)) crop=\(rectStr(crop))")

        let bounds = CGRect(x: 0, y: 0, width: full.width, height: full.height)
        let clamped = crop.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
              let cropped = full.cropping(to: clamped) else {
            throw CaptureError.cropFailed
        }
        return cropped
    }

    private static func rectStr(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width))×\(Int(r.height)))"
    }
}
