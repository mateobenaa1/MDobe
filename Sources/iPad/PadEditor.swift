import Observation
import PDFKit
import PencilKit
import SwiftUI

enum PadMode: String, CaseIterable, Identifiable {
    case read, pencil, text, erase
    var id: Self { self }
    var label: String {
        switch self {
        case .read: "Leer"
        case .pencil: "Escribir"
        case .text: "Texto"
        case .erase: "Borrar"
        }
    }
    var symbol: String {
        switch self {
        case .read: "hand.point.up.left"
        case .pencil: "pencil.tip"
        case .text: "textformat"
        case .erase: "eraser"
        }
    }
}

/// Estado y edición de un PDF en el iPad. Igual que en el Mac, todo cambio pasa por el UndoManager
/// (así se puede deshacer y el documento se marca como modificado y se guarda).
@MainActor @Observable
final class PadEditor {
    let document: PDFDocument
    let pdfView = PDFView()
    @ObservationIgnored private let pencil = PencilLayer()
    @ObservationIgnored private let ink = InkOverlay()
    @ObservationIgnored private var tap: UITapGestureRecognizer?
    @ObservationIgnored private var tapHandler: TapHandler?
    @ObservationIgnored private var eraserPan: UIPanGestureRecognizer?
    @ObservationIgnored private var erased: [(PDFAnnotation, PDFPage)] = []
    var undoManager: UndoManager?

    var mode: PadMode = .read { didSet { applyMode() } }
    /// Pantalla completa: solo el PDF, sin barras (se alterna tocando con un dedo).
    var immersive = false
    @ObservationIgnored private var chromeTap: UITapGestureRecognizer?
    private(set) var hasSelection = false
    var showTextPrompt = false
    @ObservationIgnored private var textTarget: (point: CGPoint, page: PDFPage)?

    var searchText = ""
    private(set) var results: [PDFSelection] = []
    private(set) var resultIndex = 0
    @ObservationIgnored private var lastQuery = ""

    init(document: PDFDocument) {
        self.document = document
        pencil.editor = self
        // Las capas de tinta tienen que configurarse ANTES de cargar el documento.
        ink.pdfView = pdfView
        pdfView.pageOverlayViewProvider = ink
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.document = document
        SmoothInk.adopt(in: document)
        #if DEBUG
        if ProcessInfo.processInfo.environment["MDOBE_TEST_INK"] != nil, let page = document.page(at: 0) {
            let pts = (0..<200).map { i in CGPoint(x: 150 + Double(i) * 1.2, y: 650 + 25 * sin(Double(i) / 12)) }
            addInk(pts, widths: pts.indices.map { 0.8 + 1.2 * abs(sin(Double($0) / 20)) }, color: .black, on: page)
        }
        #endif

        let handler = TapHandler { [weak self] g in self?.tapped(g) }
        let tap = UITapGestureRecognizer(target: handler, action: #selector(TapHandler.fire(_:)))
        tap.isEnabled = false
        pdfView.addGestureRecognizer(tap)
        self.tap = tap
        tapHandler = handler
        // Borrador arrastrando con el Pencil (el dedo sigue desplazando el PDF).
        let pan = UIPanGestureRecognizer(target: handler, action: #selector(TapHandler.pan(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pan.isEnabled = false
        pdfView.addGestureRecognizer(pan)
        eraserPan = pan
        handler.onPan = { [weak self] g in self?.eraseDrag(g) }
        // Un toque con el dedo muestra/oculta las barras (esperando a que no sea un doble toque de zoom).
        let chrome = UITapGestureRecognizer(target: handler, action: #selector(TapHandler.chrome(_:)))
        chrome.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pdfView.addGestureRecognizer(chrome)
        chromeTap = chrome
        handler.onChrome = { [weak self] in
            guard let self, !hasSelection else { return }
            immersive.toggle()
        }
        applyMode()

        NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ink.zoomChanged() }
        }
        NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hasSelection = !(self.pdfView.currentSelection?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
    }

    private func applyMode() {
        pencil.setActive(mode == .pencil, over: pdfView)
        tap?.isEnabled = mode == .text || mode == .erase
        eraserPan?.isEnabled = mode == .erase
        chromeTap?.isEnabled = mode == .read || mode == .pencil
        if let chromeTap { for g in Self.doubleTaps(in: pdfView) { chromeTap.require(toFail: g) } }
        // Doble toque = zoom solo en Leer; escribiendo o borrando molesta.
        for g in Self.doubleTaps(in: pdfView) where g !== tap { g.isEnabled = mode == .read }
        // Al borrar, el Pencil no desplaza el PDF (lo hace el dedo).
        if let sv = Self.scrollView(in: pdfView) {
            sv.panGestureRecognizer.allowedTouchTypes = mode == .erase
                ? [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                : [UITouch.TouchType.direct, .pencil, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        }
    }

    private static func doubleTaps(in view: UIView) -> [UITapGestureRecognizer] {
        let own = (view.gestureRecognizers ?? []).compactMap { $0 as? UITapGestureRecognizer }.filter { $0.numberOfTapsRequired == 2 }
        return own + view.subviews.flatMap { doubleTaps(in: $0) }
    }

    private static func scrollView(in view: UIView) -> UIScrollView? {
        for sub in view.subviews {
            if let sv = sub as? UIScrollView { return sv }
            if let sv = scrollView(in: sub) { return sv }
        }
        return nil
    }

    // MARK: Borrador

    private func eraseDrag(_ g: UIPanGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            let loc = g.location(in: pdfView)
            guard let page = pdfView.page(for: loc, nearest: false) else { return }
            let point = pdfView.convert(loc, to: page)
            let tolerance = 6 / max(pdfView.scaleFactor, 0.1)
            for a in page.annotations where Self.isErasable(a) && Self.hits(a, point, tolerance) {
                page.removeAnnotation(a)
                if a is SmoothInk { ink.render(page) }
                erased.append((a, page))
            }
        default:
            guard !erased.isEmpty else { return }
            registerRestore(erased)
            undoManager?.setActionName("Borrar")
            erased = []
        }
    }

    private func registerRestore(_ items: [(PDFAnnotation, PDFPage)]) {
        undoManager?.registerUndo(withTarget: self) { ed in
            for (a, page) in items {
                page.addAnnotation(a)
                if a is SmoothInk { ed.ink.render(page) }
            }
            ed.undoManager?.registerUndo(withTarget: ed) { ed2 in
                for (a, page) in items {
                    page.removeAnnotation(a)
                    if a is SmoothInk { ed2.ink.render(page) }
                }
                ed2.registerRestore(items)
            }
        }
    }

    private static func isErasable(_ a: PDFAnnotation) -> Bool { a.type != "Widget" && a.type != "Link" && a.type != "Popup" }

    /// Para la tinta mira la distancia a la línea, no a su rectángulo (si no, borra trazos cercanos).
    private static func hits(_ a: PDFAnnotation, _ p: CGPoint, _ tolerance: CGFloat) -> Bool {
        guard a.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p) else { return false }
        guard a.type == "Ink", let paths = a.paths else { return true }
        let local = CGPoint(x: p.x - a.bounds.minX, y: p.y - a.bounds.minY)
        let reach = tolerance + (a.border?.lineWidth ?? 1)
        for path in paths {
            var prev: CGPoint?, hit = false
            path.cgPath.applyWithBlock { el in
                let e = el.pointee
                let q: CGPoint
                switch e.type {
                case .moveToPoint, .addLineToPoint: q = e.points[0]
                case .addQuadCurveToPoint: q = e.points[1]
                case .addCurveToPoint: q = e.points[2]
                default: return
                }
                if let a0 = prev, distance(local, a0, q) <= reach { hit = true }
                if prev == nil, hypot(local.x - q.x, local.y - q.y) <= reach { hit = true }
                prev = q
            }
            if hit { return true }
        }
        return false
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, len = dx * dx + dy * dy
        let t = len == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    var currentPageIndex: Int { pdfView.currentPage.map { document.index(for: $0) } ?? 0 }
    var pageTexts: [String] { (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" } }

    func goToPage(_ n: Int) {
        if let page = document.page(at: n - 1) { pdfView.go(to: page) }
    }

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

    /// Convierte los trazos del Apple Pencil en anotaciones del PDF (visibles también en el Mac).
    func commit(_ strokes: [PKStroke], from canvas: UIView) {
        let unit = 1 / max(pdfView.scaleFactor, 0.01) // pt de página por pt de pantalla
        grouped("Escribir") {
            for stroke in strokes {
                // Cada trazo va a la página donde empieza.
                guard let start = stroke.path.first?.location.applying(stroke.transform),
                      let page = pdfView.page(for: pdfView.convert(start, from: canvas), nearest: true) else { continue }
                let toPage = { (p: CGPoint) in self.pdfView.convert(self.pdfView.convert(p, from: canvas), to: page) }
                let marker = stroke.ink.inkType == .marker
                let samples = Array(stroke.path.interpolatedPoints(by: .distance(marker ? 3 : 1)))
                let points = samples.map { toPage($0.location.applying(stroke.transform)) }
                let widths = samples.map { max(0.3, $0.size.width * unit) } // grosor real de cada punto (presión)
                let color = stroke.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
                if marker {
                    addMarker(points, width: widths.reduce(0, +) / CGFloat(max(widths.count, 1)), color: color, on: page)
                } else {
                    addInk(points, widths: widths, color: color, on: page)
                }
            }
        }
    }

    private func addInk(_ pts: [CGPoint], widths: [CGFloat], color: UIColor, on page: PDFPage) {
        guard var first = pts.first else { return }
        let points = pts.count > 1 ? pts : [first, CGPoint(x: first.x + 0.3, y: first.y)] // un toque = un punto
        let widths = pts.count > 1 ? widths : [widths.first ?? 1, widths.first ?? 1]
        let width = widths.reduce(0, +) / CGFloat(max(widths.count, 1))
        first = points[0]
        let path = UIBezierPath()
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        let bounds = path.bounds.insetBy(dx: -(widths.max() ?? width) * 2, dy: -(widths.max() ?? width) * 2)
        path.apply(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let a = SmoothInk(bounds: bounds, forType: .ink, withProperties: nil)
        a.add(path)
        a.color = color
        a.border = PDFBorder()
        a.border?.lineWidth = width
        a.setValue(widths.map { String(format: "%.2f", $0) }.joined(separator: ","), forAnnotationKey: InkOverlay.widthsKey)
        add(a, to: page)
    }

    /// El rotulador se guarda como resaltado que sigue el trazo: la tinta semitransparente se vuelve opaca al guardar.
    private func addMarker(_ pts: [CGPoint], width: CGFloat, color: UIColor, on page: PDFPage) {
        guard pts.count > 1 else { return }
        let xs = pts.map(\.x), ys = pts.map(\.y)
        let bounds = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            .insetBy(dx: -width, dy: -width)
        var quads: [NSValue] = []
        for (p0, p1) in zip(pts, pts.dropFirst()) {
            let d = hypot(p1.x - p0.x, p1.y - p0.y)
            guard d > 0.3 else { continue }
            let n = CGPoint(x: -(p1.y - p0.y) / d * width / 2, y: (p1.x - p0.x) / d * width / 2)
            for p in [CGPoint(x: p0.x + n.x, y: p0.y + n.y), CGPoint(x: p1.x + n.x, y: p1.y + n.y),
                      CGPoint(x: p0.x - n.x, y: p0.y - n.y), CGPoint(x: p1.x - n.x, y: p1.y - n.y)] {
                quads.append(NSValue(cgPoint: CGPoint(x: p.x - bounds.minX, y: p.y - bounds.minY)))
            }
        }
        guard !quads.isEmpty else { return }
        let a = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        a.quadrilateralPoints = quads
        a.color = color.withAlphaComponent(0.5)
        add(a, to: page)
    }

    func highlightSelection() {
        guard let sel = pdfView.currentSelection else { return }
        markup(sel, color: .systemYellow)
        pdfView.clearSelection()
    }

    private func markup(_ selection: PDFSelection, color: UIColor) {
        grouped("Resaltar") {
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let b = line.bounds(for: page)
                    guard b.width > 1, b.height > 1 else { continue }
                    let a = PDFAnnotation(bounds: b, forType: .highlight, withProperties: nil)
                    a.color = color.withAlphaComponent(0.45)
                    a.quadrilateralPoints = [
                        NSValue(cgPoint: CGPoint(x: 0, y: b.height)), NSValue(cgPoint: CGPoint(x: b.width, y: b.height)),
                        NSValue(cgPoint: .zero), NSValue(cgPoint: CGPoint(x: b.width, y: 0)),
                    ]
                    add(a, to: page)
                }
            }
        }
    }

    /// Usado por la IA: busca la frase y la resalta (con nota opcional).
    func highlight(text: String, note: String?) -> Bool {
        let opts: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        var sel = document.findString(clean, withOptions: opts).first
        let words = clean.split(separator: " ")
        if sel == nil, words.count > 6 { sel = document.findString(words.prefix(6).joined(separator: " "), withOptions: opts).first }
        guard let sel else { return false }
        grouped("Resaltar") {
            markup(sel, color: .systemYellow)
            if let note, let page = sel.pages.first {
                let b = sel.bounds(for: page)
                let a = PDFAnnotation(bounds: CGRect(x: b.maxX + 4, y: b.maxY - 20, width: 20, height: 20), forType: .text, withProperties: nil)
                a.contents = note
                a.color = .systemYellow
                add(a, to: page)
            }
        }
        return true
    }

    // MARK: Toques (texto / borrar)

    private func tapped(_ g: UITapGestureRecognizer) {
        let loc = g.location(in: pdfView)
        guard let page = pdfView.page(for: loc, nearest: false) else { return }
        let point = pdfView.convert(loc, to: page)
        switch mode {
        case .erase:
            let tolerance = 8 / max(pdfView.scaleFactor, 0.1)
            if let a = page.annotations.last(where: { Self.isErasable($0) && Self.hits($0, point, tolerance) }) { remove(a, from: page) }
        case .text:
            textTarget = (point, page)
            showTextPrompt = true
        default: break
        }
    }

    func addPendingText(_ text: String) {
        guard let (point, page) = textTarget, !text.isEmpty else { return }
        textTarget = nil
        let font = UIFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
        let measured = (text as NSString).boundingRect(with: CGSize(width: 1000, height: 10000), options: .usesLineFragmentOrigin, attributes: [.font: font], context: nil)
        let size = CGSize(width: ceil(measured.width) + 12, height: ceil(measured.height) + 6)
        let a = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height), forType: .freeText, withProperties: nil)
        a.contents = text
        a.font = font
        a.fontColor = .black
        a.color = .clear
        a.border = PDFBorder()
        a.border?.lineWidth = 0
        add(a, to: page)
    }

    // MARK: Páginas

    func insertBlankPage(_ paper: PageFactory.Paper) {
        let box = pdfView.currentPage?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let page = PageFactory.blank(paper, box: box) else { return }
        insert(page, at: currentPageIndex + 1)
        undoManager?.setActionName("Insertar página")
        pdfView.go(to: page)
    }

    private func insert(_ page: PDFPage, at index: Int) {
        document.insert(page, at: index)
        undoManager?.registerUndo(withTarget: self) { ed in
            ed.document.removePage(at: index)
            ed.undoManager?.registerUndo(withTarget: ed) { $0.insert(page, at: index) }
        }
    }

    /// Amplía la página actual (o todas) con un margen a la derecha para apuntes.
    func addNotesMargin(_ paper: PageFactory.Paper, allPages: Bool) {
        let pages = allPages ? (0..<document.pageCount).compactMap { document.page(at: $0) } : [pdfView.currentPage].compactMap { $0 }
        let pairs = pages.compactMap { p in PageFactory.withMargin(p, paper: paper).map { (from: p, to: $0) } }
        guard !pairs.isEmpty else { return }
        exchange(pairs)
        undoManager?.setActionName("Margen para apuntes")
    }

    /// Sustituye cada página `from` por `to` llevándose las anotaciones. Deshacer invierte el cambio.
    private func exchange(_ pairs: [(from: PDFPage, to: PDFPage)]) {
        let current = pdfView.currentPage
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
        if let target = pairs.first(where: { $0.from === current })?.to { pdfView.go(to: target) }
        undoManager?.registerUndo(withTarget: self) { $0.exchange(pairs.map { ($0.to, $0.from) }) }
    }

    /// Cambia el PDF por su nueva versión recolocando tus anotaciones y páginas. Devuelve el resumen para el usuario.
    func updateToNewVersion(_ fresh: PDFDocument) -> String {
        let plan = PDFUpdate.plan(old: document, new: fresh)
        guard plan.matched > 0 else {
            return "No encuentro páginas en común: ¿es una versión de este mismo PDF?"
        }
        replacePages(plan.pages, plan.moves)
        undoManager?.setActionName("Actualizar a la nueva versión")
        return plan.summary
    }

    private func replacePages(_ pages: [PDFPage], _ moves: [PDFUpdate.Move]) {
        let index = currentPageIndex
        let undo = PDFUpdate.apply(pages, moves, to: document)
        ink.forgetCache() // la tinta puede haber cambiado de página
        pdfView.layoutDocumentView()
        if let page = document.page(at: min(index, document.pageCount - 1)) { pdfView.go(to: page) }
        undoManager?.registerUndo(withTarget: self) { $0.replacePages(undo.pages, undo.moves) }
    }

    func deleteCurrentPage() {
        guard document.pageCount > 1, let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        document.removePage(at: index)
        undoManager?.registerUndo(withTarget: self) { $0.insert(page, at: index) }
        undoManager?.setActionName("Eliminar página")
    }

    func rotateCurrentPage(by degrees: Int) {
        guard let page = pdfView.currentPage else { return }
        page.rotation += degrees
        undoManager?.registerUndo(withTarget: self) { _ in page.rotation -= degrees }
    }

    // MARK: Búsqueda

    func submitSearch() {
        if searchText == lastQuery, !results.isEmpty { return step(1) }
        lastQuery = searchText
        results = searchText.isEmpty ? [] : document.findString(searchText, withOptions: [.caseInsensitive, .diacriticInsensitive])
        results.forEach { $0.color = .systemOrange }
        pdfView.highlightedSelections = results
        resultIndex = 0
        step(0)
    }

    func step(_ delta: Int) {
        guard !results.isEmpty else { return }
        resultIndex = (resultIndex + delta + results.count) % results.count
        pdfView.go(to: results[resultIndex])
        pdfView.setCurrentSelection(results[resultIndex], animate: true)
    }
}

private final class TapHandler: NSObject {
    let action: (UITapGestureRecognizer) -> Void
    var onPan: ((UIPanGestureRecognizer) -> Void)?
    var onChrome: (() -> Void)?
    @objc func chrome(_ g: UITapGestureRecognizer) { onChrome?() }
    init(_ action: @escaping (UITapGestureRecognizer) -> Void) { self.action = action }
    @objc func fire(_ g: UITapGestureRecognizer) { action(g) }
    @objc func pan(_ g: UIPanGestureRecognizer) { onPan?(g) }
}

/// Lienzo de PencilKit encima de todo el visor, a la resolución de la pantalla (nítido con cualquier zoom).
/// El Pencil dibuja; el dedo sigue moviendo y ampliando el PDF porque le prestamos al lienzo los gestos del scroll.
/// Al terminar cada trazo se pasa al PDF como anotación y el lienzo se vacía.
final class PencilLayer: NSObject, PKCanvasViewDelegate {
    weak var editor: PadEditor?
    private let toolPicker = PKToolPicker(toolItems: [
        PKToolPickerInkingItem(type: .pen), PKToolPickerInkingItem(type: .pencil),
        PKToolPickerInkingItem(type: .marker), PKToolPickerRulerItem(),
    ])
    private var canvas: PKCanvasView?
    private weak var scrollView: UIScrollView?

    @MainActor
    func setActive(_ on: Bool, over pdfView: PDFView) {
        if on, canvas == nil {
            let c = PKCanvasView(frame: pdfView.bounds)
            c.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            c.backgroundColor = .clear
            c.isOpaque = false
            c.drawingPolicy = .pencilOnly
            c.isScrollEnabled = false
            c.delegate = self
            pdfView.addSubview(c)
            canvas = c
            // Los gestos del scroll del PDF pasan al lienzo, solo para el dedo.
            if let sv = Self.findScrollView(in: pdfView) {
                scrollView = sv
                sv.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                c.addGestureRecognizer(sv.panGestureRecognizer)
                if let pinch = sv.pinchGestureRecognizer { c.addGestureRecognizer(pinch) }
            }
            toolPicker.addObserver(c)
            toolPicker.setVisible(true, forFirstResponder: c)
            c.becomeFirstResponder()
        } else if !on, let c = canvas {
            toolPicker.setVisible(false, forFirstResponder: c)
            toolPicker.removeObserver(c)
            c.resignFirstResponder()
            if let sv = scrollView {
                sv.addGestureRecognizer(sv.panGestureRecognizer)
                if let pinch = sv.pinchGestureRecognizer { sv.addGestureRecognizer(pinch) }
            }
            c.removeFromSuperview()
            canvas = nil
        }
    }

    private static func findScrollView(in view: UIView) -> UIScrollView? {
        for sub in view.subviews {
            if let sv = sub as? UIScrollView { return sv }
            if let sv = findScrollView(in: sub) { return sv }
        }
        return nil
    }

    func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
        guard !canvas.drawing.strokes.isEmpty else { return }
        let strokes = canvas.drawing.strokes
        canvas.drawing = PKDrawing()
        MainActor.assumeIsolated { editor?.commit(strokes, from: canvas) }
    }
}

/// Tinta dibujada por nosotros: PDFKit en iPad pinta las anotaciones de tinta sin suavizar (se ven pixeladas).
/// En el archivo se guarda como una anotación de tinta normal.
final class SmoothInk: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        if page?.rotation == 0 { return } // la dibuja InkOverlay con PencilKit
        guard let paths, !paths.isEmpty else { return super.draw(with: box, in: context) }
        UIGraphicsPushContext(context)
        context.saveGState()
        context.setShouldAntialias(true)
        context.translateBy(x: bounds.minX, y: bounds.minY) // los trazos van relativos al origen de la anotación
        color.setStroke()
        for path in paths {
            let p = path.copy() as! UIBezierPath
            p.lineWidth = border?.lineWidth ?? 1
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        }
        context.restoreGState()
        UIGraphicsPopContext()
    }

    /// Sustituye la tinta existente del documento por SmoothInk (sin pasar por deshacer).
    static func adopt(in document: PDFDocument) {
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for old in page.annotations where old.type == "Ink" && !(old is SmoothInk) {
                guard let paths = old.paths else { continue }
                let new = SmoothInk(bounds: old.bounds, forType: .ink, withProperties: nil)
                paths.forEach { new.add($0) }
                new.color = old.color
                new.border = old.border
                new.contents = old.contents
                new.shouldPrint = old.shouldPrint
                if let w = old.value(forAnnotationKey: InkOverlay.widthsKey) { new.setValue(w, forAnnotationKey: InkOverlay.widthsKey) }
                page.removeAnnotation(old)
                page.addAnnotation(new)
            }
        }
    }
}
