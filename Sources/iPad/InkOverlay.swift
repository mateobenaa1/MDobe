import PDFKit
import PencilKit
import UIKit

/// Muestra la tinta a mano encima de cada página como imagen a la resolución del zoom, con el grosor
/// de cada punto (presión del Pencil). En el archivo la tinta es una anotación normal; aquí PDFKit no la pinta (ver SmoothInk).
final class InkOverlay: NSObject, PDFPageOverlayViewProvider {
    weak var pdfView: PDFView?
    private var views: [PDFPage: UIImageView] = [:]
    private var cache: [ObjectIdentifier: [Line]] = [:]
    private var pending: DispatchWorkItem?

    static let widthsKey = PDFAnnotationKey(rawValue: "/MDobeW")

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        let iv = UIImageView()
        iv.isUserInteractionEnabled = false
        iv.contentMode = .scaleToFill
        views[page] = iv
        DispatchQueue.main.async { self.render(page) }
        return iv
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        views[page] = nil
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
        guard !inks.isEmpty, box.width > 0, box.height > 0 else { iv.image = nil; return }
        let screen = pdfView?.window?.screen.scale ?? 2
        let zoom = pdfView?.scaleFactor ?? 1
        let maxScale = (12_000_000 / (box.width * box.height)).squareRoot() // tope de memoria por página
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(screen * max(zoom, 0.5), maxScale)
        format.opaque = false
        iv.image = UIGraphicsImageRenderer(size: box.size, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for (lines, color) in inks {
                cg.setStrokeColor(color.withAlphaComponent(1).cgColor)
                for line in lines {
                    // Segmento a segmento con el grosor de cada punto (presión del Pencil).
                    for i in line.points.indices.dropFirst() {
                        cg.setLineWidth((line.widths[i - 1] + line.widths[i]) / 2)
                        cg.move(to: line.points[i - 1])
                        cg.addLine(to: line.points[i])
                        cg.strokePath()
                    }
                    if line.points.count == 1, let p = line.points.first {
                        let r = line.widths[0] / 2
                        cg.setFillColor(color.cgColor)
                        cg.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
                    }
                }
            }
        }
    }

    private struct Line {
        var points: [CGPoint]
        var widths: [CGFloat]
    }

    /// Puntos (en coordenadas de la vista, origen arriba) y grosor guardado de cada punto.
    private func stroke(for a: SmoothInk, box: CGRect) -> [Line] {
        if let cached = cache[ObjectIdentifier(a)] { return cached }
        let widths = (a.value(forAnnotationKey: Self.widthsKey) as? String)?.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) } ?? []
        let fallback = a.border?.lineWidth ?? 1.5
        var result: [Line] = []
        var w = 0
        for path in a.paths ?? [] {
            var pts: [CGPoint] = []
            path.cgPath.applyWithBlock { el in
                let e = el.pointee
                switch e.type {
                case .moveToPoint, .addLineToPoint: pts.append(e.points[0])
                case .addQuadCurveToPoint: pts.append(e.points[1])
                case .addCurveToPoint: pts.append(e.points[2])
                default: break
                }
            }
            var line = Line(points: [], widths: [])
            for p in pts {
                line.points.append(CGPoint(x: a.bounds.minX + p.x - box.minX, y: box.maxY - (a.bounds.minY + p.y)))
                line.widths.append(w < widths.count ? widths[w] : fallback)
                w += 1
            }
            if !line.points.isEmpty { result.append(line) }
        }
        cache[ObjectIdentifier(a)] = result
        return result
    }
}
