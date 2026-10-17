import AppKit
import Observation
import PDFKit
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case select, highlight, underline, strike, note, text, ink, whiteout, eraser
    var id: Self { self }

    var label: String {
        switch self {
        case .select: "Seleccionar"
        case .highlight: "Resaltar"
        case .underline: "Subrayar"
        case .strike: "Tachar"
        case .note: "Nota"
        case .text: "Texto"
        case .ink: "Dibujar / firmar"
        case .whiteout: "Tapar"
        case .eraser: "Borrar anotación"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strike: "strikethrough"
        case .note: "note.text"
        case .text: "textformat"
        case .ink: "signature"
        case .whiteout: "rectangle.fill"
        case .eraser: "eraser"
        }
    }

    var isMarkup: Bool { [.highlight, .underline, .strike].contains(self) }
}

/// Estado y operaciones de edición de un documento. Todo cambio pasa por `add`/`remove` para poder deshacerlo.
@MainActor @Observable
final class Editor {
    let document: PDFDocument
    let pdfView = MDPDFView()
    var tool: Tool = .select { didSet { pdfView.tool = tool } }
    var color: Color = .yellow
    var undoManager: UndoManager?

    var searchText = ""
    private(set) var results: [PDFSelection] = []
    private(set) var resultIndex = 0
    private var lastQuery = ""

    init(document: PDFDocument) {
        self.document = document
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.editor = self
    }

    var nsColor: NSColor { NSColor(color) }
    var currentPageIndex: Int { pdfView.currentPage.map { document.index(for: $0) } ?? 0 }
    var pageTexts: [String] { (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" } }

    /// Descripción en texto de las anotaciones del usuario, para que la IA sepa qué ha marcado.
    var annotationSummary: String {
        var lines: [String] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for a in page.annotations {
                let kind: String = switch a.type {
                case "Highlight": "resaltado"
                case "Underline": "subrayado"
                case "StrikeOut": "tachado"
                case "Ink": "trazo a mano"
                case "Text": "nota"
                case "FreeText": "texto añadido"
                case "Square": "rectángulo"
                case "Circle": "círculo"
                case "Widget", "Link", "Popup": ""
                default: "anotación"
                }
                guard !kind.isEmpty else { continue }
                var line = "- Página \(i + 1): \(kind) \(Self.colorName(a.color))"
                let covered = (page.selection(for: a.bounds)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !covered.isEmpty { line += " sobre el texto: «\(covered.prefix(400))»" }
                if let c = a.contents, !c.isEmpty, ["nota", "texto añadido"].contains(kind) { line += " que dice: «\(c.prefix(200))»" }
                lines.append(line)
            }
        }
        return lines.isEmpty ? "El usuario no ha hecho anotaciones en el PDF." : "Anotaciones del usuario en el PDF (en orden):\n" + lines.prefix(60).joined(separator: "\n")
    }

    private static func colorName(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "" }
        if c.saturationComponent < 0.2 { return c.brightnessComponent < 0.3 ? "negro" : c.brightnessComponent > 0.85 ? "blanco" : "gris" }
        switch c.hueComponent * 360 {
        case ..<15, 345...: return "rojo"
        case ..<40: return "naranja"
        case ..<70: return "amarillo"
        case ..<170: return "verde"
        case ..<260: return "azul"
        case ..<300: return "morado"
        default: return "rosa"
        }
    }

    // MARK: Anotaciones

    func add(_ a: PDFAnnotation, to page: PDFPage) {
        a.shouldPrint = true
        page.addAnnotation(a)
        undoManager?.registerUndo(withTarget: self) { $0.remove(a, from: page) }
    }

    func remove(_ a: PDFAnnotation, from page: PDFPage) {
        page.removeAnnotation(a)
        undoManager?.registerUndo(withTarget: self) { $0.add(a, to: page) }
    }

    func grouped(_ name: String, _ body: () -> Void) {
        undoManager?.beginUndoGrouping()
        body()
        undoManager?.endUndoGrouping()
        undoManager?.setActionName(name)
    }

    @discardableResult
    func markup(_ selection: PDFSelection, as tool: Tool, color: NSColor? = nil) -> Int {
        let type: PDFAnnotationSubtype = switch tool {
        case .underline: .underline
        case .strike: .strikeOut
        default: .highlight
        }
        let color = color ?? nsColor
        var count = 0
        grouped(tool.label) {
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let b = line.bounds(for: page)
                    guard b.width > 1, b.height > 1 else { continue }
                    let a = PDFAnnotation(bounds: b, forType: type, withProperties: nil)
                    a.color = type == .highlight ? color.withAlphaComponent(0.45) : color
                    a.quadrilateralPoints = [
                        NSValue(point: CGPoint(x: 0, y: b.height)), NSValue(point: CGPoint(x: b.width, y: b.height)),
                        NSValue(point: .zero), NSValue(point: CGPoint(x: b.width, y: 0)),
                    ]
                    add(a, to: page)
                    count += 1
                }
            }
        }
        return count
    }

    func addNote(_ text: String, at point: CGPoint, on page: PDFPage) {
        let a = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - 20, width: 20, height: 20), forType: .text, withProperties: nil)
        a.contents = text
        a.color = .systemYellow
        a.iconType = .comment
        add(a, to: page)
    }

    func addText(_ text: String, at point: CGPoint, on page: PDFPage, size: CGFloat = 12, color: NSColor = .black) {
        let font = NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        let measured = (text as NSString).boundingRect(with: CGSize(width: 1000, height: 10000), options: .usesLineFragmentOrigin, attributes: [.font: font])
        let size = CGSize(width: ceil(measured.width) + 12, height: ceil(measured.height) + 6)
        let a = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height), forType: .freeText, withProperties: nil)
        a.contents = text
        a.font = font
        a.fontColor = color
        a.color = .clear
        a.border = PDFBorder()
        a.border?.lineWidth = 0
        add(a, to: page)
    }

    func addInk(_ path: NSBezierPath, on page: PDFPage) {
        let width: CGFloat = 1.8
        let bounds = path.bounds.insetBy(dx: -width * 2, dy: -width * 2)
        let local = path.copy() as! NSBezierPath
        local.transform(using: AffineTransform(translationByX: -bounds.minX, byY: -bounds.minY))
        let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        a.add(local)
        a.color = nsColor
        a.border = PDFBorder()
        a.border?.lineWidth = width
        add(a, to: page)
    }

    func addWhiteout(_ rect: CGRect, on page: PDFPage) {
        let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        a.color = .white
        a.interiorColor = .white
        a.border = PDFBorder()
        a.border?.lineWidth = 0
        add(a, to: page)
    }

    func eraseAnnotation(at point: CGPoint, on page: PDFPage) {
        guard let a = page.annotation(at: point), a.type != "Widget", a.type != "Link" else { return }
        remove(a, from: page)
    }

    /// Busca `text` en el documento (con tolerancia a mayúsculas/acentos) y lo resalta. Usado por la IA.
    func highlight(text: String, note: String? = nil) -> Bool {
        guard let sel = find(text) else { return false }
        grouped("Resaltar") {
            markup(sel, as: .highlight, color: .systemYellow)
            if let note, let page = sel.pages.first {
                let b = sel.bounds(for: page)
                addNote(note, at: CGPoint(x: b.maxX + 4, y: b.maxY), on: page)
            }
        }
        return true
    }

    private func find(_ text: String) -> PDFSelection? {
        let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if let hit = document.findString(clean, withOptions: opts).first { return hit }
        // Los modelos pequeños a veces no copian la frase exacta: probamos con su comienzo.
        let words = clean.split(separator: " ")
        guard words.count > 6 else { return nil }
        return document.findString(words.prefix(6).joined(separator: " "), withOptions: opts).first
    }

    // MARK: Búsqueda

    func submitSearch() {
        if searchText == lastQuery, !results.isEmpty { return step(1) }
        lastQuery = searchText
        results = searchText.isEmpty ? [] : document.findString(searchText, withOptions: [.caseInsensitive, .diacriticInsensitive])
        results.forEach { $0.color = .systemOrange }
        pdfView.highlightedSelections = results
        resultIndex = 0
        showResult()
    }

    func step(_ delta: Int) {
        guard !results.isEmpty else { return }
        resultIndex = (resultIndex + delta + results.count) % results.count
        showResult()
    }

    private func showResult() {
        guard results.indices.contains(resultIndex) else { return }
        pdfView.setCurrentSelection(results[resultIndex], animate: true)
        pdfView.go(to: results[resultIndex])
    }

    // MARK: Páginas

    func rotateCurrentPage(by degrees: Int) {
        guard let page = pdfView.currentPage else { return }
        page.rotation += degrees
        undoManager?.registerUndo(withTarget: self) { _ in page.rotation -= degrees }
        undoManager?.setActionName("Girar página")
    }

    func deleteCurrentPage() {
        guard document.pageCount > 1, let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        document.removePage(at: index)
        undoManager?.registerUndo(withTarget: self) { $0.insert(page, at: index) }
        undoManager?.setActionName("Eliminar página")
    }

    private func insert(_ page: PDFPage, at index: Int) {
        document.insert(page, at: index)
        undoManager?.registerUndo(withTarget: self) { ed in
            ed.document.removePage(at: index)
            ed.undoManager?.registerUndo(withTarget: ed) { $0.insert(page, at: index) }
        }
    }

    func moveCurrentPage(by delta: Int) {
        let i = currentPageIndex, j = i + delta
        guard (0..<document.pageCount).contains(j) else { return }
        swapPages(i, j)
        undoManager?.setActionName("Mover página")
    }

    private func swapPages(_ i: Int, _ j: Int) {
        document.exchangePage(at: i, withPageAt: j)
        if let p = document.page(at: j) { pdfView.go(to: p) }
        undoManager?.registerUndo(withTarget: self) { $0.swapPages(i, j) }
    }

    func insertPDFs() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Elige los PDFs que quieres añadir después de la página actual"
        guard panel.runModal() == .OK else { return }
        var at = currentPageIndex + 1
        grouped("Insertar páginas") {
            for url in panel.urls {
                guard let other = PDFDocument(url: url) else { continue }
                for k in 0..<other.pageCount {
                    if let p = other.page(at: k)?.copy() as? PDFPage {
                        insert(p, at: at)
                        at += 1
                    }
                }
            }
        }
    }

    func print() {
        pdfView.print(with: .shared, autoRotate: true)
    }
}
