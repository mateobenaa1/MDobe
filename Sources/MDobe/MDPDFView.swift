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

    private var drawsShapes: Bool { tool == .ink || tool == .whiteout }

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

        switch tool {
        case .select, .highlight, .underline, .strike:
            super.mouseDown(with: event)
        case .note:
            if let text = Self.askText(title: "Nueva nota", placeholder: "Escribe la nota…") {
                editor.addNote(text, at: pagePoint, on: page)
            }
        case .text:
            if let text = Self.askText(title: "Añadir texto", placeholder: "Texto…") {
                editor.addText(text, at: pagePoint, on: page, color: editor.nsColor)
            }
        case .eraser:
            editor.eraseAnnotation(at: pagePoint, on: page)
        case .sign:
            editor.stampSignature(at: pagePoint, on: page)
        case .ink, .whiteout:
            dragPage = page
            dragStart = p
            inkPoints = [p]
            startPreview()
        }
    }

    override func mouseDragged(with event: NSEvent) {
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
            if rect.width > 2, rect.height > 2 { editor.addWhiteout(rect, on: page) }
        }
    }

    private func startPreview() {
        wantsLayer = true
        preview.path = nil
        preview.lineWidth = tool == .ink ? 2 : 1
        preview.lineCap = .round
        preview.lineJoin = .round
        preview.strokeColor = tool == .ink ? editor?.nsColor.cgColor : NSColor.systemGray.cgColor
        preview.fillColor = tool == .ink ? nil : NSColor.white.withAlphaComponent(0.9).cgColor
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

extension CGRect {
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
