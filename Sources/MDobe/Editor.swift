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
final class Editor: ObjectEditing {
    let document: PDFDocument
    let pdfView = MDPDFView()
    var tool: Tool = .select { didSet { pdfView.tool = tool } }
    var color: Color = .yellow
    var undoManager: UndoManager?
    var showSignaturePad = false
    var ocrStatus: String?
    var suggestOCR = false
    var showBlockEditor = false
    /// Resultado de pasar los apuntes a una nueva versión del PDF (se muestra en un aviso).
    var updateReport: String?
    /// Bloque de texto listo para colocar: el siguiente clic en el PDF decide dónde.
    var pendingBlock: (text: String, plain: Bool)?
    /// Recibe la imagen PNG de una fórmula recuadrada y su número de página (1…).
    @ObservationIgnored var onFormula: ((Data, Int) -> Void)?
    /// Capa que pinta la tinta nítida a la resolución del zoom (PDFKit la deja borrosa).
    @ObservationIgnored private let ink = InkOverlay(drawsObjects: false)
    /// Cuadro de texto o tabla que se está editando (se muestra como hoja).
    var objectEdit: ObjectEdit?
    var objectNotice: String?
    /// Añadir fila/columna: el siguiente clic dice en qué tabla.
    var pendingGrow: TableGrow?

    var searchText = "" {
        didSet { if searchText.isEmpty, !lastQuery.isEmpty { clearSearch() } }
    }
    private(set) var results: [PDFSelection] = []
    private(set) var resultIndex = 0
    private var lastQuery = ""
    /// Observadores de NotificationCenter (con bloque): se quitan al liberar el objeto.
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(document: PDFDocument) {
        self.document = document
        // La capa de tinta tiene que estar antes que el documento: si no, PDFKit no la usa.
        ink.pdfView = pdfView
        pdfView.pageOverlayViewProvider = ink
        SmoothInk.drawnElsewhere = { $0.rotation == 0 && InkOverlay.covers($0) }
        SmoothInk.adopt(in: document)
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.editor = self
        PageObjects.adopt(in: document)
        suggestOCR = document.pageCount > 0 && (0..<min(3, document.pageCount)).allSatisfy(isScanned)
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewAnnotationHit, object: pdfView, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.widgetHit(n) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ink.zoomChanged() }
        })
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    func isScanned(_ index: Int) -> Bool {
        (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).count < 20
    }

    var nsColor: NSColor { NSColor(color) }
    var currentPageIndex: Int { pdfView.currentPage.map { document.index(for: $0) } ?? 0 }
    var pageTexts: [String] { (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" } }

    var annotationSummary: String { document.annotationSummary }

    // MARK: Anotaciones

    func add(_ a: PDFAnnotation, to page: PDFPage) {
        a.shouldPrint = true
        page.addAnnotation(a)
        if a is SmoothInk { ink.render(page) }
        undoManager?.registerUndo(withTarget: self) { $0.remove(a, from: page) }
    }

    func remove(_ a: PDFAnnotation, from page: PDFPage) {
        page.removeAnnotation(a)
        if a is SmoothInk { ink.render(page) }
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

    var objectView: PDFView { pdfView }

    func refresh(_ page: PDFPage) {
        pdfView.annotationsChanged(on: page)
    }

    func insertImageFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Elige la imagen que quieres poner en esta página"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else { objectNotice = "No se pudo abrir «\(url.lastPathComponent)»."; return }
        insertImage(data)
    }

    func pasteImage() {
        let pb = NSPasteboard.general
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) { return insertImage(data) }
        if let url = pb.readObjects(forClasses: [NSURL.self])?.first as? URL, let data = try? Data(contentsOf: url) { return insertImage(data) }
        objectNotice = "No hay ninguna imagen copiada. Copia una imagen (o haz una captura con ⌘⇧⌃4) y vuelve a probar."
    }

    func addInk(_ path: NSBezierPath, on page: PDFPage, color: NSColor? = nil, width: CGFloat = 1.8) {
        let bounds = path.bounds.insetBy(dx: -width * 2, dy: -width * 2)
        let local = path.copy() as! NSBezierPath
        local.transform(using: AffineTransform(translationByX: -bounds.minX, byY: -bounds.minY))
        let a = SmoothInk(bounds: bounds, forType: .ink, withProperties: nil)
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
        ink.forgetCache()
        ink.renderAll()
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

    /// Al cerrar la búsqueda (la ✕) desaparecen los resaltados naranjas.
    private func clearSearch() {
        lastQuery = ""
        results = []
        resultIndex = 0
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
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

    func insert(_ page: PDFPage, at index: Int) {
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

    /// Cambia el PDF por su nueva versión (la que ha subido el profe) recolocando tus anotaciones y páginas.
    func updateToNewVersion() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "Elige la nueva versión de este PDF: tus apuntes se pasarán a ella"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let fresh = PDFDocument(url: url) else { updateReport = "No se pudo abrir «\(url.lastPathComponent)»."; return }
        let plan = PDFUpdate.plan(old: document, new: fresh)
        guard plan.matched > 0 else {
            updateReport = "No encuentro páginas en común: ¿es una versión de este mismo PDF? (Si está escaneado, pásale antes el OCR.)"
            return
        }
        replacePages(plan.pages, plan.moves)
        undoManager?.setActionName("Actualizar a la nueva versión")
        updateReport = plan.summary
    }

    private func replacePages(_ pages: [PDFPage], _ moves: [PDFUpdate.Move]) {
        let index = currentPageIndex
        let undo = PDFUpdate.apply(pages, moves, to: document)
        pdfView.layoutDocumentView()
        ink.forgetCache()
        ink.renderAll()
        if let page = document.page(at: min(index, document.pageCount - 1)) { pdfView.go(to: page) }
        undoManager?.registerUndo(withTarget: self) { $0.replacePages(undo.pages, undo.moves) }
    }

    func print() {
        pdfView.print(with: .shared, autoRotate: true)
    }
}
