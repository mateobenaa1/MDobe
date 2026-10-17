import AppKit
import Observation
import PDFKit
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case select, highlight, underline, strike, note, text, ink, sign, formula, whiteout, eraser
    var id: Self { self }

    var label: String {
        switch self {
        case .select: "Seleccionar"
        case .highlight: "Resaltar"
        case .underline: "Subrayar"
        case .strike: "Tachar"
        case .note: "Nota"
        case .text: "Texto"
        case .ink: "Dibujar"
        case .sign: "Firmar"
        case .formula: "Fórmula → LaTeX (recuadra una fórmula)"
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
        case .ink: "pencil.tip"
        case .sign: "signature"
        case .formula: "function"
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
    var showSignaturePad = false
    var ocrStatus: String?
    var suggestOCR = false
    /// Recibe la imagen PNG de una fórmula recuadrada y su número de página (1…).
    @ObservationIgnored var onFormula: ((Data, Int) -> Void)?

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
        suggestOCR = document.pageCount > 0 && (0..<min(3, document.pageCount)).allSatisfy(isScanned)
        NotificationCenter.default.addObserver(forName: .PDFViewAnnotationHit, object: pdfView, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.widgetHit(n) }
        }
    }

    func isScanned(_ index: Int) -> Bool {
        (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 20
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

    func addInk(_ path: NSBezierPath, on page: PDFPage, color: NSColor? = nil, width: CGFloat = 1.8) {
        let bounds = path.bounds.insetBy(dx: -width * 2, dy: -width * 2)
        let local = path.copy() as! NSBezierPath
        local.transform(using: AffineTransform(translationByX: -bounds.minX, byY: -bounds.minY))
        let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        a.add(local)
        a.color = color ?? nsColor
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

    // MARK: Firma

    func stampSignature(at point: CGPoint, on page: PDFPage) {
        guard let strokes = SignatureStore.load() else { showSignaturePad = true; return }
        let width: CGFloat = 150
        let height = (strokes.joined().map(\.y).max() ?? 0.3) * width
        // Trazos normalizados (y hacia abajo) → coordenadas de página, centrados en el clic.
        let map = { (q: CGPoint) in CGPoint(x: point.x - width / 2 + q.x * width, y: point.y + height / 2 - q.y * width) }
        let path = NSBezierPath()
        for stroke in strokes where stroke.count > 1 {
            path.move(to: map(stroke[0]))
            stroke.dropFirst().forEach { path.line(to: map($0)) }
        }
        addInk(path, on: page, color: NSColor(red: 0.05, green: 0.1, blue: 0.4, alpha: 1), width: 1.4)
        undoManager?.setActionName("Firmar")
    }

    // MARK: Fórmulas

    func captureFormula(_ rect: CGRect, on page: PDFPage) {
        let scale = min(4, 1600 / max(rect.width, rect.height))
        let img = NSImage(size: NSSize(width: rect.width * scale, height: rect.height * scale), flipped: false) { bounds in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            NSColor.white.setFill()
            bounds.fill()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            page.draw(with: .mediaBox, to: ctx)
            return true
        }
        guard let tiff = img.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        onFormula?(png, document.index(for: page) + 1)
    }

    // MARK: Formularios

    var formFields: [(page: PDFPage, field: PDFAnnotation)] {
        (0..<document.pageCount).flatMap { i -> [(page: PDFPage, field: PDFAnnotation)] in
            guard let page = document.page(at: i) else { return [] }
            return page.annotations.filter { $0.type == "Widget" }.map { (page, $0) }
        }
    }

    /// PDFKit rellena los campos por su cuenta; registramos el cambio para poder deshacerlo y que se guarde.
    private func widgetHit(_ n: Notification) {
        guard let a = n.userInfo?["PDFAnnotationHit"] as? PDFAnnotation, a.type == "Widget" else { return }
        let text = a.widgetStringValue, state = a.buttonWidgetState
        undoManager?.registerUndo(withTarget: self) { _ in
            if a.widgetFieldType == .button { a.buttonWidgetState = state } else { a.widgetStringValue = text }
        }
        undoManager?.setActionName("Rellenar campo")
    }

    func goToNextEmptyField() {
        let empty = formFields.filter { $0.field.widgetFieldType == .text && ($0.field.widgetStringValue ?? "").isEmpty }
        guard let next = empty.first(where: { document.index(for: $0.page) >= currentPageIndex }) ?? empty.first else { return }
        pdfView.go(to: next.field.bounds.insetBy(dx: -40, dy: -80), on: next.page)
    }

    func clearForm() {
        grouped("Vaciar formulario") {
            for (_, a) in formFields {
                let text = a.widgetStringValue, state = a.buttonWidgetState
                if a.widgetFieldType == .button { a.buttonWidgetState = .offState } else if a.widgetFieldType != .signature { a.widgetStringValue = "" }
                undoManager?.registerUndo(withTarget: self) { _ in
                    if a.widgetFieldType == .button { a.buttonWidgetState = state } else { a.widgetStringValue = text }
                }
            }
        }
    }

    /// Sustituye cada página `from` por `to` (llevándose las anotaciones). Deshacer invierte el cambio.
    func exchange(_ pairs: [(from: PDFPage, to: PDFPage)]) {
        for (from, to) in pairs {
            let i = document.index(for: from)
            guard i >= 0, i < document.pageCount else { continue }
            for a in from.annotations {
                from.removeAnnotation(a)
                to.addAnnotation(a)
            }
            document.removePage(at: i)
            document.insert(to, at: i)
        }
        undoManager?.registerUndo(withTarget: self) { $0.exchange(pairs.map { ($0.to, $0.from) }) }
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
