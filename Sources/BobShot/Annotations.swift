import AppKit

/// Инструменты редактора (правая панель Lightshot).
enum EditorTool {
    case pen, line, arrow, rect, marker, text
}

/// Действие нижней панели.
enum EditorAction {
    case copy, save
}

// MARK: - Модели аннотаций
// Все координаты — в ТОЧКАХ вью выделения (origin снизу-слева экрана), как и selectionRect.
// В пиксели снимка переводятся только при композите (AnnotationRenderer.flatten).

struct PenAnnotation { var points: [CGPoint]; var color: NSColor; var lineWidth: CGFloat = 3 }
struct LineAnnotation { var start: CGPoint; var end: CGPoint; var color: NSColor; var lineWidth: CGFloat = 3 }
struct ArrowAnnotation { var start: CGPoint; var end: CGPoint; var color: NSColor = .systemRed; var lineWidth: CGFloat = 3 }
struct RectAnnotation { var corner1: CGPoint; var corner2: CGPoint; var color: NSColor; var lineWidth: CGFloat = 3 }
struct MarkerAnnotation { var points: [CGPoint]; var color: NSColor; var lineWidth: CGFloat = 16 }
/// Текст — богатая строка (разные цвета внутри одного блока). box — рамка в координатах вью (bottom-left).
struct TextAnnotation { var attributed: NSAttributedString; var box: CGRect }

enum Annotation {
    case pen(PenAnnotation)
    case line(LineAnnotation)
    case arrow(ArrowAnnotation)
    case rect(RectAnnotation)
    case marker(MarkerAnnotation)
    case text(TextAnnotation)
}

/// Перевод координат аннотаций: вью-точки выделения → пиксели снимка.
/// И вью, и битмап композита — bottom-left (origin снизу-слева), поэтому Y-флипа НЕТ:
/// захваченный CGImage рисуется вертикально-правильно в bottom-left контексте, а пиксель (0,0)
/// = низ-лево выделения = sel.origin. Так превью на оверлее и финальный композит совпадают,
/// и текст не зеркалится.
enum AnnotationGeometry {
    static func pointToPixel(_ p: CGPoint, selectionInView sel: CGRect, imagePixelSize: CGSize) -> CGPoint {
        guard sel.width > 0, sel.height > 0 else { return .zero }
        let sx = imagePixelSize.width / sel.width
        let sy = imagePixelSize.height / sel.height
        return CGPoint(x: (p.x - sel.minX) * sx, y: (p.y - sel.minY) * sy)
    }

    static func scale(selectionInView sel: CGRect, imagePixelSize: CGSize) -> CGFloat {
        guard sel.width > 0 else { return 1 }
        return imagePixelSize.width / sel.width
    }

    static func runSelfTest() {
        let sel = CGRect(x: 10, y: 20, width: 100, height: 50)
        let img = CGSize(width: 200, height: 100) // 2x

        // Низ-лево выделения (sel.origin) → пиксель (0,0).
        assert(pointToPixel(CGPoint(x: 10, y: 20), selectionInView: sel, imagePixelSize: img) == .zero,
               "annot origin fail")
        // Верх-право выделения (maxX,maxY) → (200,100).
        assert(pointToPixel(CGPoint(x: 110, y: 70), selectionInView: sel, imagePixelSize: img) == CGPoint(x: 200, y: 100),
               "annot topRight fail")
        // Центр → (100,50).
        assert(pointToPixel(CGPoint(x: 60, y: 45), selectionInView: sel, imagePixelSize: img) == CGPoint(x: 100, y: 50),
               "annot center fail")
        assert(scale(selectionInView: sel, imagePixelSize: img) == 2, "annot scale fail")
        NSLog("BobShot: AnnotationGeometry self-test OK")
    }
}

// MARK: - Отрисовка

/// Рисует аннотации в текущем графическом контексте — и для live-превью (во вью-координатах),
/// и для финального композита (в пиксельных координатах). Координатное пространство задаётся `Transform`.
enum AnnotationRenderer {

    /// Преобразование вью-точки в целевое пространство + масштаб толщины/шрифта.
    struct Transform {
        let map: (CGPoint) -> CGPoint
        let scale: CGFloat
        /// Идентичность — для live-превью (вью-координаты).
        static let identity = Transform(map: { $0 }, scale: 1)
        /// Для композита: вью-точки выделения → пиксели снимка.
        static func toPixels(sel: CGRect, imagePixelSize: CGSize) -> Transform {
            Transform(
                map: { AnnotationGeometry.pointToPixel($0, selectionInView: sel, imagePixelSize: imagePixelSize) },
                scale: AnnotationGeometry.scale(selectionInView: sel, imagePixelSize: imagePixelSize)
            )
        }
    }

    /// Live-превью: аннотации + черновик поверх оверлея (вью-координаты).
    static func drawPreview(_ annotations: [Annotation], draft: Annotation?) {
        for a in annotations { draw(a, t: .identity) }
        if let draft { draw(draft, t: .identity) }
    }

    /// Композит: чистый снимок региона + аннотации → битмап нативного разрешения.
    /// Без аннотаций — пиксель-в-пиксель копия. Контекст bottom-left, без глобального flip.
    static func flatten(base: CGImage, annotations: [Annotation], selectionInView sel: CGRect) -> NSBitmapImageRep {
        if annotations.isEmpty {
            return NSBitmapImageRep(cgImage: base)
        }
        let w = base.width, h = base.height
        let pixelSize = CGSize(width: w, height: h)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = pixelSize

        NSGraphicsContext.saveGraphicsState()
        let gctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = gctx

        // Снимок рисуется вертикально-правильно в bottom-left контексте (CG сам разворачивает CGImage).
        gctx.cgContext.draw(base, in: CGRect(origin: .zero, size: pixelSize))

        let t = Transform.toPixels(sel: sel, imagePixelSize: pixelSize)
        for a in annotations { draw(a, t: t) }

        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    // MARK: - Один примитив

    private static func draw(_ a: Annotation, t: Transform) {
        switch a {
        case .pen(let p):     drawPolyline(p.points, color: p.color, width: p.lineWidth, t: t, alpha: 1)
        case .marker(let m):  drawPolyline(m.points, color: m.color, width: m.lineWidth, t: t, alpha: 0.4)
        case .line(let l):    drawLine(l.start, l.end, color: l.color, width: l.lineWidth, t: t)
        case .arrow(let a):   drawArrow(a.start, a.end, color: a.color, width: a.lineWidth, t: t)
        case .rect(let r):    drawRect(r.corner1, r.corner2, color: r.color, width: r.lineWidth, t: t)
        case .text(let tx):   drawText(tx, t: t)
        }
    }

    private static func drawPolyline(_ pts: [CGPoint], color: NSColor, width: CGFloat, t: Transform, alpha: CGFloat) {
        guard pts.count > 1 else {
            // Одна точка — нарисуем кружок, чтобы клик был виден.
            if let p = pts.first {
                let m = t.map(p); let r = max(1, width * t.scale) / 2
                (alpha < 1 ? color.withAlphaComponent(alpha) : color).setFill()
                NSBezierPath(ovalIn: CGRect(x: m.x - r, y: m.y - r, width: r * 2, height: r * 2)).fill()
            }
            return
        }
        let path = NSBezierPath()
        path.lineWidth = max(1, width * t.scale)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: t.map(pts[0]))
        for p in pts.dropFirst() { path.line(to: t.map(p)) }
        (alpha < 1 ? color.withAlphaComponent(alpha) : color).setStroke()
        path.stroke()
    }

    private static func drawLine(_ a: CGPoint, _ b: CGPoint, color: NSColor, width: CGFloat, t: Transform) {
        let path = NSBezierPath()
        path.lineWidth = max(1, width * t.scale)
        path.lineCapStyle = .round
        path.move(to: t.map(a))
        path.line(to: t.map(b))
        color.setStroke()
        path.stroke()
    }

    private static func drawRect(_ c1: CGPoint, _ c2: CGPoint, color: NSColor, width: CGFloat, t: Transform) {
        let p1 = t.map(c1), p2 = t.map(c2)
        let r = CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p1.x - p2.x), height: abs(p1.y - p2.y))
        let path = NSBezierPath(rect: r)
        path.lineWidth = max(1, width * t.scale)
        path.lineJoinStyle = .miter
        color.setStroke()
        path.stroke()
    }

    private static func drawArrow(_ start: CGPoint, _ end: CGPoint, color: NSColor, width: CGFloat, t: Transform) {
        let s = t.map(start), e = t.map(end)
        let lw = max(1, width * t.scale)
        color.setStroke(); color.setFill()

        let line = NSBezierPath()
        line.lineWidth = lw
        line.lineCapStyle = .round
        line.move(to: s)
        line.line(to: e)
        line.stroke()

        let angle = atan2(e.y - s.y, e.x - s.x)
        let headLen = max(8, lw * 4)
        let spread = CGFloat.pi / 7
        let p1 = CGPoint(x: e.x - headLen * cos(angle - spread), y: e.y - headLen * sin(angle - spread))
        let p2 = CGPoint(x: e.x - headLen * cos(angle + spread), y: e.y - headLen * sin(angle + spread))
        let head = NSBezierPath()
        head.move(to: e); head.line(to: p1); head.line(to: p2); head.close()
        head.fill()
    }

    private static func drawText(_ tx: TextAnnotation, t: Transform) {
        guard tx.attributed.length > 0,
              let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Нижний-левый угол рамки в целевом пространстве — туда сдвигаем начало координат.
        let bl = t.map(CGPoint(x: tx.box.minX, y: tx.box.minY))
        ctx.saveGState()
        ctx.translateBy(x: bl.x, y: bl.y)
        ctx.scaleBy(x: t.scale, y: t.scale)
        // НЕмасштабированную строку рисуем в рамку В ТОЧКАХ → переносы и метрики строк
        // байт-в-байт как в редакторе (NSTextView). CTM лишь увеличивает растр под Retina.
        // Контекст bottom-left, scale>0 без flip → текст не зеркалится.
        tx.attributed.draw(in: CGRect(origin: .zero, size: tx.box.size))
        ctx.restoreGState()
    }

    // MARK: - Экспорт битмапа

    static func pngData(_ rep: NSBitmapImageRep) -> Data? { rep.representation(using: .png, properties: [:]) }
    static func tiffData(_ rep: NSBitmapImageRep) -> Data? { rep.tiffRepresentation }
}
