import AppKit
import PDFKit
import QuartzCore

/// PDFView que interpreta el ratón/trackpad según la herramienta activa.
final class MDPDFView: PDFView {
    weak var editor: Editor?
    var tool: Tool = .select {
        didSet {
            clearSelection()
            window?.invalidateCursorRects(for: self)
        }
    }

    private var dragPage: PDFPage?
    private var dragStart: CGPoint = .zero // en coordenadas de la vista
    private var inkPoints: [CGPoint] = []
    private let preview = CAShapeLayer()
    /// Cuadro de texto, imagen o tabla que se está arrastrando.
    private var objectDrag: ObjectDrag?

    private var drawsShapes: Bool { [.ink, .whiteout, .formula].contains(tool) }

    override func resetCursorRects() {
        super.resetCursorRects()
        switch tool {
        case .select, .highlight, .underline, .strike: break
        case .eraser: addCursorRect(bounds, cursor: .disappearingItem)
        default: addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let editor, let page = page(for: p, nearest: false) else { return super.mouseDown(with: event) }
        let pagePoint = convert(p, to: page)
        if let block = editor.pendingBlock {
            return editor.placeBlock(block.text, plain: block.plain, at: pagePoint, on: page)
        }
        if let grow = editor.pendingGrow {
            editor.pendingGrow = nil
            return editor.growTable(grow, at: pagePoint, on: page)
        }
        // Con Seleccionar o Texto, los objetos se arrastran; doble clic para editarlos.
        if tool == .select || tool == .text, let drag = ObjectDrag(at: pagePoint, on: page, scale: scaleFactor) {
            if event.clickCount == 2 { return editor.edit(drag.object, on: page) }
            objectDrag = drag
            NSCursor.closedHand.push()
            return
        }

        switch tool {
        case .select, .highlight, .underline, .strike:
            super.mouseDown(with: event)
        case .note:
            if let text = Self.askText(title: "Nueva nota", placeholder: "Escribe la nota…") {
                editor.addNote(text, at: pagePoint, on: page)
            }
        case .text:
            editor.beginText(at: pagePoint, on: page)
        case .eraser:
            editor.eraseAnnotation(at: pagePoint, on: page)
        case .sign:
            editor.stampSignature(at: pagePoint, on: page)
        case .ink, .whiteout, .formula:
            dragPage = page
            dragStart = p
            inkPoints = [p]
            startPreview()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, editor?.pendingBlock != nil { editor?.pendingBlock = nil } else { super.keyDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if let drag = objectDrag, let editor {
            drag.update(to: convert(convert(event.locationInWindow, from: nil), to: drag.page))
            editor.refresh(drag.page)
            return
        }
        guard drawsShapes, dragPage != nil else { return super.mouseDragged(with: event) }
        let p = convert(event.locationInWindow, from: nil)
        let path = CGMutablePath()
        if tool == .ink {
            inkPoints.append(p)
            path.addLines(between: inkPoints)
        } else {
            path.addRect(CGRect(from: dragStart, to: p))
        }
        preview.path = path
    }

    override func mouseUp(with event: NSEvent) {
        guard let editor else { return super.mouseUp(with: event) }
        if let drag = objectDrag {
            objectDrag = nil
            NSCursor.pop()
            editor.finishDrag(drag)
            // Con la herramienta Texto, un clic sin arrastrar edita el cuadro.
            if !drag.moved, tool == .text { editor.edit(drag.object, on: drag.page) }
            return
        }
        if tool.isMarkup {
            super.mouseUp(with: event)
            if let sel = currentSelection, !(sel.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                editor.markup(sel, as: tool)
                clearSelection()
            }
            return
        }
        guard drawsShapes, let page = dragPage else { return super.mouseUp(with: event) }
        defer { dragPage = nil; preview.removeFromSuperlayer() }
        let end = convert(event.locationInWindow, from: nil)

        if tool == .ink {
            let pts = inkPoints.map { convert($0, to: page) }
            guard pts.count > 1 else { return }
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: pts[0])
            pts.dropFirst().forEach { path.line(to: $0) }
            editor.addInk(path, on: page)
        } else {
            let a = convert(dragStart, to: page), b = convert(end, to: page)
            let rect = CGRect(from: a, to: b)
            guard rect.width > 2, rect.height > 2 else { return }
            if tool == .formula { editor.captureFormula(rect, on: page) } else { editor.addWhiteout(rect, on: page) }
        }
    }

    /// Clic derecho: editar/borrar objetos y ampliar tablas, además del menú normal del PDF.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let p = convert(event.locationInWindow, from: nil)
        guard let editor, let page = page(for: p, nearest: false) else { return menu }
        let point = convert(p, to: page)
        var items: [NSMenuItem] = []
        let object = PageObjects.object(at: point, on: page, tolerance: 4 / max(scaleFactor, 0.1))
        if let object, object is TextBox || object is TableBox {
            items.append(ActionItem(object is TextBox ? "Editar texto…" : "Editar tabla…") { editor.edit(object, on: page) })
        }
        if object == nil || object is TableBox {
            items.append(ActionItem("Añadir fila a esta tabla") { editor.growTable(.row, at: point, on: page) })
            items.append(ActionItem("Añadir columna a esta tabla") { editor.growTable(.column, at: point, on: page) })
        }
        if let object {
            items.append(ActionItem("Eliminar") {
                editor.remove(object, from: page)
                editor.undoManager?.setActionName("Eliminar")
            })
        }
        items.append(.separator())
        for (i, item) in items.enumerated() { menu.insertItem(item, at: i) }
        return menu
    }

    private func startPreview() {
        wantsLayer = true
        preview.path = nil
        preview.lineWidth = tool == .ink ? 2 : 1
        preview.lineCap = .round
        preview.lineJoin = .round
        preview.strokeColor = tool == .ink ? editor?.nsColor.cgColor : tool == .formula ? NSColor.systemBlue.cgColor : NSColor.systemGray.cgColor
        preview.fillColor = tool == .ink ? nil : tool == .formula ? NSColor.systemBlue.withAlphaComponent(0.08).cgColor : NSColor.white.withAlphaComponent(0.9).cgColor
        preview.zPosition = 1000
        layer?.addSublayer(preview)
    }

    static func askText(title: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Añadir")
        alert.addButton(withTitle: "Cancelar")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 80))
        field.placeholderString = placeholder
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

/// Opción de menú que ejecuta un bloque.
private final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
