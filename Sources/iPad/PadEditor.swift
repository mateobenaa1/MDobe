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
    @ObservationIgnored private let overlay = PencilOverlay()
    @ObservationIgnored private var tap: UITapGestureRecognizer?
    @ObservationIgnored private var tapHandler: TapHandler?
    var undoManager: UndoManager?

    var mode: PadMode = .read { didSet { applyMode() } }
    private(set) var hasSelection = false
    var showTextPrompt = false
    @ObservationIgnored private var textTarget: (point: CGPoint, page: PDFPage)?

    var searchText = ""
    private(set) var results: [PDFSelection] = []
    private(set) var resultIndex = 0
    @ObservationIgnored private var lastQuery = ""

    init(document: PDFDocument) {
        self.document = document
        pdfView.document = document
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.pageOverlayViewProvider = overlay
        overlay.editor = self

        let handler = TapHandler { [weak self] g in self?.tapped(g) }
        let tap = UITapGestureRecognizer(target: handler, action: #selector(TapHandler.fire(_:)))
        tap.isEnabled = false
        pdfView.addGestureRecognizer(tap)
        self.tap = tap
        tapHandler = handler

        NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: pdfView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hasSelection = !(self.pdfView.currentSelection?.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            }
        }
    }

    private func applyMode() {
        pdfView.isInMarkupMode = mode == .pencil
        overlay.setActive(mode == .pencil)
        tap?.isEnabled = mode == .text || mode == .erase
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

    /// Convierte los trazos del Apple Pencil en anotaciones del PDF (visibles también en el Mac).
    func commit(_ strokes: [PKStroke], from canvas: UIView, on page: PDFPage) {
        let toPage = { (p: CGPoint) in self.pdfView.convert(self.pdfView.convert(p, from: canvas), to: page) }
        let u0 = toPage(.zero), u1 = toPage(CGPoint(x: 10, y: 0))
        let unit = hypot(u1.x - u0.x, u1.y - u0.y) / 10 // pt de página por pt de pantalla
        grouped("Escribir") {
            for stroke in strokes {
                let marker = stroke.ink.inkType == .marker
                let points = stroke.path.interpolatedPoints(by: .distance(marker ? 3 : 1.2)).map { toPage($0.location.applying(stroke.transform)) }
                let sizes = stroke.path.map(\.size.width)
                let width = max(0.6, (sizes.reduce(0, +) / CGFloat(max(sizes.count, 1))) * unit * (marker ? 1 : 0.85))
                let color = stroke.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
                if marker { addMarker(points, width: width, color: color, on: page) } else { addInk(points, width: width, color: color, on: page) }
            }
        }
    }

    private func addInk(_ pts: [CGPoint], width: CGFloat, color: UIColor, on page: PDFPage) {
        guard var first = pts.first else { return }
        let points = pts.count > 1 ? pts : [first, CGPoint(x: first.x + 0.3, y: first.y)] // un toque = un punto
        first = points[0]
        let path = UIBezierPath()
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        let bounds = path.bounds.insetBy(dx: -width * 2, dy: -width * 2)
        path.apply(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        a.add(path)
        a.color = color
        a.border = PDFBorder()
        a.border?.lineWidth = width
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
            if let a = page.annotation(at: point), a.type != "Widget", a.type != "Link" { remove(a, from: page) }
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
    init(_ action: @escaping (UITapGestureRecognizer) -> Void) { self.action = action }
    @objc func fire(_ g: UITapGestureRecognizer) { action(g) }
}

/// Un lienzo de PencilKit encima de cada página. Al terminar cada trazo se pasa al PDF y el lienzo se vacía.
final class PencilOverlay: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
    weak var editor: PadEditor?
    private let toolPicker = PKToolPicker(toolItems: [
        PKToolPickerInkingItem(type: .pen), PKToolPickerInkingItem(type: .pencil),
        PKToolPickerInkingItem(type: .marker), PKToolPickerRulerItem(),
    ])
    private var canvases: [PDFPage: PKCanvasView] = [:]
    private var active = false

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.drawingPolicy = .pencilOnly // con el dedo se navega
        canvas.delegate = self
        canvas.isUserInteractionEnabled = active
        toolPicker.addObserver(canvas)
        canvases[page] = canvas
        if active, !toolPicker.isVisible { show(on: canvas) }
        return canvas
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        if let canvas = overlayView as? PKCanvasView { toolPicker.removeObserver(canvas) }
        canvases[page] = nil
    }

    func setActive(_ on: Bool) {
        active = on
        canvases.values.forEach { $0.isUserInteractionEnabled = on }
        if on, let canvas = canvases.values.first {
            show(on: canvas)
        } else {
            for canvas in canvases.values {
                toolPicker.setVisible(false, forFirstResponder: canvas)
                canvas.resignFirstResponder()
            }
        }
    }

    private func show(on canvas: PKCanvasView) {
        toolPicker.setVisible(true, forFirstResponder: canvas)
        canvas.becomeFirstResponder()
    }

    func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
        guard !canvas.drawing.strokes.isEmpty, let page = canvases.first(where: { $0.value === canvas })?.key else { return }
        let strokes = canvas.drawing.strokes
        canvas.drawing = PKDrawing()
        MainActor.assumeIsolated { editor?.commit(strokes, from: canvas, on: page) }
    }
}
