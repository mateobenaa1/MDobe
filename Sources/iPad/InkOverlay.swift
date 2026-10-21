import PDFKit
import PencilKit
import UIKit

/// Muestra la tinta a mano encima de cada página como imagen a la resolución del zoom, con el grosor
/// de cada punto (presión del Pencil). En el archivo la tinta es una anotación normal; aquí PDFKit no la pinta (ver SmoothInk).
/// Lo mismo con los cuadros de texto, imágenes y tablas (MovableAnnotation), para que no se vean pixelados.
final class InkOverlay: NSObject, PDFPageOverlayViewProvider {
    weak var pdfView: PDFView?
    private var views: [PDFPage: UIImageView] = [:]
    private var cache: [ObjectIdentifier: [SmoothInk.Line]] = [:]
    private var pending: DispatchWorkItem?

    /// Páginas que tienen capa de tinta en pantalla. Si una página no la tiene (p. ej. recién insertada),
    /// SmoothInk se dibuja ella misma para que el trazo no desaparezca. PDFKit dibuja en otros hilos: va con candado.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var covered = Set<ObjectIdentifier>()

    static func covers(_ page: PDFPage) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return covered.contains(ObjectIdentifier(page))
    }

    private static func setCovered(_ page: PDFPage, _ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if on { covered.insert(ObjectIdentifier(page)) } else { covered.remove(ObjectIdentifier(page)) }
    }

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let iv = UIImageView()
        iv.isUserInteractionEnabled = false
        iv.contentMode = .scaleToFill
        views[page] = iv
        Self.setCovered(page, true)
        DispatchQueue.main.async { self.render(page) }
        return iv
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        views[page] = nil
        Self.setCovered(page, false)
    }

    /// Tras un zoom, vuelve a dibujar las páginas visibles a la nueva resolución.
    func zoomChanged() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.views.keys.forEach { self?.render($0) } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func forgetCache() { cache = [:] }

    func render(_ page: PDFPage) {
        guard let iv = views[page] else { return }
        guard page.rotation == 0 else { iv.image = nil; return } // páginas giradas: la pinta SmoothInk
        let box = page.bounds(for: pdfView?.displayBox ?? .cropBox)
        let inks = page.annotations.compactMap { $0 as? SmoothInk }.map { (stroke(for: $0, box: box), $0.color) }
        let objects = page.annotations.compactMap { $0 as? MovableAnnotation }
        guard !inks.isEmpty || !objects.isEmpty, box.width > 0, box.height > 0 else { iv.image = nil; return }
        let screen = pdfView?.window?.screen.scale ?? 2
        let zoom = pdfView?.scaleFactor ?? 1
        let maxScale = (12_000_000 / (box.width * box.height)).squareRoot() // tope de memoria por página
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(screen * max(zoom, 0.5), maxScale)
        format.opaque = false
        iv.image = UIGraphicsImageRenderer(size: box.size, format: format).image { ctx in
            let cg = ctx.cgContext
            if !objects.isEmpty {
                // Coordenadas de página (y hacia arriba) sobre la imagen (y hacia abajo).
                cg.saveGState()
                cg.translateBy(x: -box.minX, y: box.maxY)
                cg.scaleBy(x: 1, y: -1)
                objects.forEach { $0.drawContent(in: cg) }
                cg.restoreGState()
            }
            for (lines, color) in inks { SmoothInk.stroke(lines, color: color, in: cg) }
        }
    }

    /// Puntos en coordenadas de la vista (origen arriba).
    private func stroke(for a: SmoothInk, box: CGRect) -> [SmoothInk.Line] {
        if let cached = cache[ObjectIdentifier(a)] { return cached }
        let result = a.lines().map { line in
            SmoothInk.Line(points: line.points.map { CGPoint(x: $0.x - box.minX, y: box.maxY - $0.y) }, widths: line.widths)
        }
        cache[ObjectIdentifier(a)] = result
        return result
    }
}
