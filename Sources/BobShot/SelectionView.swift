import AppKit

protocol SelectionViewDelegate: AnyObject {
    /// Запрошен экспорт (Копировать/Сохранить) с готовыми аннотациями.
    /// rectInView — выделение в координатах вью (origin снизу-слева), как и точки аннотаций.
    func exportRequested(action: EditorAction, annotations: [Annotation], rectInView: NSRect, view: SelectionView)
    /// Отмена: Esc, правый клик, слишком маленькое выделение, «Закрыть».
    func selectionCancelled()
}

/// Вью одного экрана: затемнение с «дыркой» под выделением, рамка, размер.
/// Два режима: `.selecting` (drag выделяет область) → `.editing` (рисуем аннотации поверх + панели Lightshot).
final class SelectionView: NSView {
    weak var delegate: SelectionViewDelegate?
    let screen: NSScreen
    /// Стоп-кадр всего дисплея (нативные пиксели), снятый в момент хоткея.
    /// Рисуется фоном — выделяем по нему, а не по «живому» экрану (как Lightshot).
    let frozenImage: CGImage?

    private enum Mode { case selecting, editing }
    private var mode: Mode = .selecting

    private var startPoint: NSPoint?
    private var selectionRect: NSRect?

    // Аннотации (в координатах вью, origin снизу-слева).
    private var annotations: [Annotation] = []
    private var draft: Annotation?
    private var tool: EditorTool = .pen
    private var annotationColor: NSColor = .systemRed

    // Панели (subview'ы оверлея; видны только в editing).
    private var toolPanel: NSView?
    private var actionPanel: NSView?
    private var colorPalette: NSView?
    private var toolButtons: [EditorTool: NSButton] = [:]
    private var colorButton: NSButton?

    // Текстовый ввод (инструмент text): богатый редактор — видно ввод, перенос внутри выделения, разные цвета.
    private var activeText: EditableTextView?
    private var textClickTop: CGFloat?
    private let textFont = NSFont.boldSystemFont(ofSize: 16)

    private let minSize: CGFloat = 8

    init(frame: NSRect, screen: NSScreen, image: CGImage?) {
        self.screen = screen
        self.frozenImage = image
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Курсор
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    // MARK: - Отрисовка
    override func draw(_ dirtyRect: NSRect) {
        // Фон — стоп-кадр дисплея. CG сам разворачивает CGImage в bottom-left контексте,
        // рисуется вертикально-правильно (как в AnnotationRenderer.flatten).
        if let img = frozenImage {
            NSGraphicsContext.current?.cgContext.draw(img, in: bounds)
        }

        let dim = NSBezierPath(rect: bounds)
        if let sel = selectionRect {
            dim.append(NSBezierPath(rect: sel))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()

        guard let sel = selectionRect, sel.width > 0, sel.height > 0 else { return }

        NSColor.white.setStroke()
        let border = NSBezierPath(rect: sel)
        border.lineWidth = 1
        border.stroke()

        if mode == .editing {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: sel).addClip() // аннотации только внутри выделения
            AnnotationRenderer.drawPreview(annotations, draft: draft)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let scale = screen.backingScaleFactor
            let wPx = Int((sel.width * scale).rounded())
            let hPx = Int((sel.height * scale).rounded())
            drawSizeLabel("\(wPx) × \(hPx)", near: sel)
        }
    }

    private func drawSizeLabel(_ text: String, near sel: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let str = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pad: CGFloat = 4
        var origin = NSPoint(x: sel.minX, y: sel.maxY + pad)
        if origin.y + size.height > bounds.maxY { origin.y = sel.maxY - size.height - pad }
        let bg = NSRect(x: origin.x - pad, y: origin.y - pad / 2,
                        width: size.width + pad * 2, height: size.height + pad)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 3, yRadius: 3).fill()
        str.draw(at: origin)
    }

    // MARK: - Мышь
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .selecting:
            startPoint = p
            selectionRect = NSRect(origin: p, size: .zero)
            needsDisplay = true
        case .editing:
            hideColorPalette()
            guard let sel = selectionRect, sel.contains(p) else { commitText(); return }
            if tool == .text {
                beginText(at: clamp(p, to: sel))
                return
            }
            commitText()
            startDraft(at: clamp(p, to: sel))
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let cur = convert(event.locationInWindow, from: nil)
        switch mode {
        case .selecting:
            guard let start = startPoint else { return }
            selectionRect = rect(from: start, to: cur).intersection(bounds)
        case .editing:
            guard let sel = selectionRect, draft != nil else { return }
            updateDraft(to: clamp(cur, to: sel))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .selecting:
            guard let sel = selectionRect, sel.width >= minSize, sel.height >= minSize else {
                delegate?.selectionCancelled()
                return
            }
            mode = .editing
            buildPanels(near: sel)
            needsDisplay = true
        case .editing:
            commitDraft()
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        delegate?.selectionCancelled()
    }

    // MARK: - Черновик инструмента
    private func startDraft(at p: CGPoint) {
        switch tool {
        case .pen:    draft = .pen(PenAnnotation(points: [p], color: annotationColor))
        case .marker: draft = .marker(MarkerAnnotation(points: [p], color: annotationColor))
        case .line:   draft = .line(LineAnnotation(start: p, end: p, color: annotationColor))
        case .arrow:  draft = .arrow(ArrowAnnotation(start: p, end: p, color: annotationColor))
        case .rect:   draft = .rect(RectAnnotation(corner1: p, corner2: p, color: annotationColor))
        case .text:   break
        }
    }

    private func updateDraft(to p: CGPoint) {
        switch draft {
        case .pen(var a):    a.points.append(p); draft = .pen(a)
        case .marker(var a): a.points.append(p); draft = .marker(a)
        case .line(var a):   a.end = p; draft = .line(a)
        case .arrow(var a):  a.end = p; draft = .arrow(a)
        case .rect(var a):   a.corner2 = p; draft = .rect(a)
        default: break
        }
    }

    private func commitDraft() {
        defer { draft = nil }
        switch draft {
        case .pen(let a) where a.points.count > 1:    annotations.append(.pen(a))
        case .marker(let a) where a.points.count > 1: annotations.append(.marker(a))
        case .line(let a) where dist(a.start, a.end) >= 3:  annotations.append(.line(a))
        case .arrow(let a) where dist(a.start, a.end) >= 3: annotations.append(.arrow(a))
        case .rect(let a) where abs(a.corner1.x - a.corner2.x) >= 3 && abs(a.corner1.y - a.corner2.y) >= 3:
            annotations.append(.rect(a))
        default: break
        }
    }

    // MARK: - Текст (богатый редактор)
    private var lineHeight: CGFloat { ceil(textFont.ascender - textFont.descender + textFont.leading) + 2 }

    private func beginText(at p: CGPoint) {
        commitText()
        guard let sel = selectionRect else { return }
        // Рамка не выходит за выделение по горизонтали; перенос строк — по доступной ширине.
        let minW: CGFloat = 60
        var w = sel.maxX - p.x
        if w < minW { w = min(minW, sel.width) }
        var ox = p.x
        // У правого края рамка прижимается правым краем к sel.maxX и растёт влево (не overflow).
        if ox + w > sel.maxX { ox = sel.maxX - w }
        if ox < sel.minX { ox = sel.minX; w = min(w, sel.width) }
        let clickTop = min(p.y, sel.maxY)
        // Старт — одна строка; верх у клика, но низ не ниже выделения.
        let frame = NSRect(x: ox, y: max(clickTop - lineHeight, sel.minY), width: w, height: lineHeight)

        let tv = EditableTextView(frame: frame)
        tv.drawsBackground = false
        tv.isRichText = true
        tv.allowsUndo = true
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.size = NSSize(width: w, height: .greatestFiniteMagnitude)
        tv.font = textFont
        tv.typingAttributes = [.font: textFont, .foregroundColor: annotationColor]
        tv.insertionPointColor = annotationColor
        tv.onCommit = { [weak self] in self?.commitText() }
        tv.onCancel = { [weak self] in self?.cancelText() }
        tv.onChange = { [weak self] in self?.resizeActiveText() }
        addSubview(tv)
        window?.makeFirstResponder(tv)
        activeText = tv
        textClickTop = clickTop
    }

    /// Высота строго под весь текст (ничего не режем в экспорте). Верх держим на клике,
    /// пока влезает вниз; иначе рамка растёт ВВЕРХ. Не выше самого выделения.
    private func resizeActiveText() {
        guard let tv = activeText, let sel = selectionRect, let top = textClickTop,
              let tc = tv.textContainer else { return }
        tv.layoutManager?.ensureLayout(for: tc)
        // Та же метрика, что у рендера (NSAttributedString.draw(in:)) — иначе низ строки срежется.
        let need = tv.attributedString().boundingRect(
            with: NSSize(width: tc.size.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin]).height
        let h = max(lineHeight, min(ceil(need), sel.height))
        // Верх у клика, пока текст помещается вниз; затем поднимаем верх к sel.maxY.
        var topY = top
        if h > top - sel.minY { topY = min(sel.maxY, sel.minY + h) }
        let newY = topY - h
        var f = tv.frame
        if abs(f.height - h) > 0.5 || abs(f.origin.y - newY) > 0.5 {
            f.size.height = h
            f.origin.y = newY
            tv.frame = f
        }
        needsDisplay = true
    }

    private func commitText() {
        guard let tv = activeText else { return }
        let attr = tv.attributedString()
        let box = tv.frame
        tv.removeFromSuperview()
        activeText = nil
        textClickTop = nil
        window?.makeFirstResponder(self)
        if !attr.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            annotations.append(.text(TextAnnotation(attributed: attr, box: box)))
            needsDisplay = true
        }
    }

    private func cancelText() {
        activeText?.removeFromSuperview()
        activeText = nil
        textClickTop = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Клавиши
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { delegate?.selectionCancelled(); return } // Esc
        guard mode == .editing, let sel = selectionRect else { super.keyDown(with: event); return }
        let cmd = event.modifierFlags.contains(.command)
        let chars = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 36 || event.keyCode == 76 { // Return / keypad Enter
            export(.copy, sel: sel)
        } else if cmd && chars == "s" {
            export(.save, sel: sel)
        } else if cmd && chars == "z" {
            undo()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Панели
    private func buildPanels(near sel: NSRect) {
        // Правая вертикальная панель инструментов (8 иконок Lightshot).
        let tools: [(EditorTool?, String, Selector)] = [
            (.pen,    "pencil",    #selector(pickTool(_:))),
            (.line,   "line",      #selector(pickTool(_:))),
            (.arrow,  "arrow",     #selector(pickTool(_:))),
            (.rect,   "rectangle", #selector(pickTool(_:))),
            (.marker, "marker",    #selector(pickTool(_:))),
            (.text,   "text",      #selector(pickTool(_:))),
        ]
        var toolViews: [NSView] = []
        for (i, t) in tools.enumerated() {
            let b = iconButton(icon: t.1, action: t.2, tag: i)
            if let tool = t.0 { toolButtons[tool] = b }
            toolViews.append(b)
        }
        // Цвет (отдельная кнопка-свотч) + Undo.
        let cb = colorSwatchButton()
        colorButton = cb
        toolViews.append(cb)
        toolViews.append(iconButton(icon: "undo", action: #selector(undoTapped), tag: -1))

        let tp = panelContainer(with: toolViews, vertical: true)
        addSubview(tp)
        toolPanel = tp

        // Нижняя панель действий: копировать / сохранить / закрыть.
        let actions = [
            iconButton(icon: "copy",  action: #selector(copyTapped),  tag: -10),
            iconButton(icon: "save",  action: #selector(saveTapped),  tag: -11),
            iconButton(icon: "close", action: #selector(closeTapped), tag: -12),
        ]
        let ap = panelContainer(with: actions, vertical: false)
        addSubview(ap)
        actionPanel = ap

        highlightActiveTool()
        positionPanels(near: sel)
    }

    private func positionPanels(near sel: NSRect) {
        let gap: CGFloat = 8
        // Верхняя «безопасная» граница: вырез камеры (notch) / меню-бар. Выше неё панели не ставим,
        // иначе на MacBook Pro они уезжают под вырез. На обычных экранах inset = 0.
        let topInset = max(screen.safeAreaInsets.top, 0)
        let usableTop = bounds.maxY - topInset            // ниже этого — без выреза
        let lo = gap                                       // нижняя безопасная граница
        let hi = usableTop - gap                           // верхняя безопасная граница

        if let tp = toolPanel {
            let s = tp.fittingSize
            // Снаружи справа → снаружи слева → внутрь у правого края выделения.
            var x = sel.maxX + gap
            if x + s.width > bounds.maxX - gap {
                let left = sel.minX - gap - s.width
                x = left >= gap ? left : sel.maxX - gap - s.width
            }
            x = min(max(x, gap), bounds.maxX - s.width - gap)
            var y = sel.midY - s.height / 2
            y = min(max(y, lo), max(lo, hi - s.height))
            tp.frame = CGRect(x: x, y: y, width: s.width, height: s.height)
        }
        if let ap = actionPanel {
            let s = ap.fittingSize
            var x = sel.midX - s.width / 2
            x = min(max(x, gap), bounds.maxX - s.width - gap)
            // Снаружи снизу → снаружи сверху (если не под вырезом) → ВНУТРЬ у нижнего края.
            var y = sel.minY - gap - s.height
            if y < lo {
                let above = sel.maxY + gap
                if above + s.height <= hi {
                    y = above                              // снаружи сверху, ниже выреза
                } else {
                    y = sel.minY + gap                     // внутрь поля скриншота
                }
            }
            y = min(max(y, lo), max(lo, hi - s.height))
            ap.frame = CGRect(x: x, y: y, width: s.width, height: s.height)
        }
    }

    private func panelContainer(with views: [NSView], vertical: Bool) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.97, alpha: 1).cgColor
        container.layer?.cornerRadius = 6
        container.layer?.borderColor = NSColor(white: 0.72, alpha: 1).cgColor
        container.layer?.borderWidth = 1
        container.shadow = {
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.25)
            sh.shadowBlurRadius = 6
            sh.shadowOffset = NSSize(width: 0, height: -2)
            return sh
        }()

        let stack = NSStackView(views: views)
        stack.orientation = vertical ? .vertical : .horizontal
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 5),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -5),
        ])
        return container
    }

    private func iconButton(icon: String, action: Selector, tag: Int) -> NSButton {
        let b = NSButton()
        b.image = IconLoader.icon(icon)
        b.imagePosition = .imageOnly
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.target = self
        b.action = action
        b.tag = tag
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }

    private func colorSwatchButton() -> NSButton {
        let b = NSButton()
        b.title = ""
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.layer?.borderColor = NSColor(white: 0.5, alpha: 1).cgColor
        b.layer?.borderWidth = 1
        b.layer?.backgroundColor = annotationColor.cgColor
        b.target = self
        b.action = #selector(colorTapped)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }

    private func highlightActiveTool() {
        for (t, b) in toolButtons {
            b.layer?.backgroundColor = (t == tool)
                ? NSColor.systemBlue.withAlphaComponent(0.25).cgColor
                : NSColor.clear.cgColor
        }
    }

    // MARK: - Действия панели
    @objc private func pickTool(_ sender: NSButton) {
        commitText()
        let map: [EditorTool] = [.pen, .line, .arrow, .rect, .marker, .text]
        guard sender.tag >= 0, sender.tag < map.count else { return }
        tool = map[sender.tag]
        highlightActiveTool()
    }

    @objc private func undoTapped() { undo() }
    private func undo() {
        if activeText != nil { commitText(); return }
        if !annotations.isEmpty { annotations.removeLast(); needsDisplay = true }
    }

    @objc private func copyTapped()  { if let s = selectionRect { export(.copy, sel: s) } }
    @objc private func saveTapped()  { if let s = selectionRect { export(.save, sel: s) } }
    @objc private func closeTapped() { delegate?.selectionCancelled() }

    private func export(_ action: EditorAction, sel: NSRect) {
        commitText()
        delegate?.exportRequested(action: action, annotations: annotations, rectInView: sel, view: self)
    }

    // MARK: - Палитра цвета
    @objc private func colorTapped() {
        if colorPalette != nil { hideColorPalette(); return }
        guard let cb = colorButton else { return }
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen,
                                 .systemBlue, .systemPurple, .black, .white]
        var swatches: [NSView] = []
        for (i, c) in colors.enumerated() {
            let s = NSButton()
            s.title = ""
            s.isBordered = false
            s.wantsLayer = true
            s.layer?.cornerRadius = 3
            s.layer?.borderColor = NSColor(white: 0.5, alpha: 1).cgColor
            s.layer?.borderWidth = 1
            s.layer?.backgroundColor = c.cgColor
            s.target = self
            s.action = #selector(paletteColorPicked(_:))
            s.tag = i
            s.translatesAutoresizingMaskIntoConstraints = false
            s.widthAnchor.constraint(equalToConstant: 22).isActive = true
            s.heightAnchor.constraint(equalToConstant: 22).isActive = true
            swatches.append(s)
        }
        paletteColors = colors
        let pal = panelContainer(with: swatches, vertical: true)
        addSubview(pal)
        colorPalette = pal
        let s = pal.fittingSize
        let gap: CGFloat = 8
        // Координаты кнопки цвета в системе вью (она лежит внутри stack панели).
        let cbFrame = cb.convert(cb.bounds, to: self)
        // Справа от кнопки; если не влезает — слева от неё.
        var x = cbFrame.maxX + gap
        if x + s.width > bounds.maxX - gap { x = cbFrame.minX - gap - s.width }
        x = min(max(x, gap), bounds.maxX - s.width - gap)
        // По вертикали — по центру кнопки.
        var y = cbFrame.midY - s.height / 2
        y = min(max(y, gap), bounds.maxY - s.height - gap)
        pal.frame = CGRect(x: x, y: y, width: s.width, height: s.height)
    }

    private var paletteColors: [NSColor] = []
    @objc private func paletteColorPicked(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < paletteColors.count else { return }
        // Фиксируем в sRGB: динамические systemColor иначе резолвятся в композите под
        // дефолтной (light) темой — в dark mode цвет PNG расходится со свотчем.
        let picked = paletteColors[sender.tag]
        annotationColor = picked.usingColorSpace(.sRGB) ?? picked
        colorButton?.layer?.backgroundColor = annotationColor.cgColor
        // Цвет — только для выделенного фрагмента и дальнейшего ввода. Уже набранный текст не трогаем.
        if let tv = activeText {
            let r = tv.selectedRange()
            if r.length > 0 { tv.textStorage?.addAttribute(.foregroundColor, value: annotationColor, range: r) }
            var ta = tv.typingAttributes
            ta[.foregroundColor] = annotationColor
            tv.typingAttributes = ta
            tv.insertionPointColor = annotationColor
            window?.makeFirstResponder(tv)
        }
        hideColorPalette()
    }

    private func hideColorPalette() {
        colorPalette?.removeFromSuperview()
        colorPalette = nil
    }

    // MARK: - Геометрия
    private func rect(from a: NSPoint, to b: NSPoint) -> NSRect {
        NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
    private func clamp(_ p: NSPoint, to r: NSRect) -> NSPoint {
        NSPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }
    private func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// NSTextView ввода аннотации: Enter — зафиксировать, Esc — отменить, изменение текста — колбэк.
final class EditableTextView: NSTextView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onChange: (() -> Void)?
    override func insertNewline(_ sender: Any?) { onCommit?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func didChangeText() { super.didChangeText(); onChange?() }
}
