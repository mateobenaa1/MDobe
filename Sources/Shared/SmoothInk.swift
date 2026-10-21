import PDFKit

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Tinta dibujada por nosotros: PDFKit pinta las anotaciones de tinta desde su apariencia guardada, que se ve
/// borrosa o pixelada al hacer zoom (en el Mac y en el iPad). Dibujándola en vectorial queda nítida, con el grosor
/// de cada punto (presión del Pencil). En el archivo se guarda como una anotación de tinta normal.
final class SmoothInk: PDFAnnotation {
    static let widthsKey = PDFAnnotationKey(rawValue: "/MDobeW")
    /// En el iPad la pinta la capa de tinta a la resolución del zoom.
    nonisolated(unsafe) static var drawnElsewhere: (PDFPage) -> Bool = { _ in false }

    struct Line {
        var points: [CGPoint]
        var widths: [CGFloat]
    }

    /// Trazos en coordenadas de página con el grosor guardado de cada punto.
    func lines() -> [Line] {
        let widths = (value(forAnnotationKey: Self.widthsKey) as? String)?.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) } ?? []
        let fallback = border?.lineWidth ?? 1.5
        var result: [Line] = []
        var w = 0
        for path in paths ?? [] {
            var line = Line(points: [], widths: [])
            path.cgPath.applyWithBlock { el in
                let e = el.pointee
                let p: CGPoint
                switch e.type {
                case .moveToPoint, .addLineToPoint: p = e.points[0]
                case .addQuadCurveToPoint: p = e.points[1]
                case .addCurveToPoint: p = e.points[2]
                default: return
                }
                line.points.append(CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y))
                line.widths.append(w < widths.count ? widths[w] : fallback)
                w += 1
            }
            if !line.points.isEmpty { result.append(line) }
        }
        return result
    }

    /// Dibuja los trazos ya convertidos a las coordenadas de `cg`.
    static func stroke(_ lines: [Line], color: PlatformColor, in cg: CGContext) {
        cg.setShouldAntialias(true)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.setStrokeColor(color.withAlphaComponent(1).cgColor)
        cg.setFillColor(color.withAlphaComponent(1).cgColor)
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
                cg.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            }
        }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        if let page, Self.drawnElsewhere(page) { return }
        guard let paths, !paths.isEmpty else { return super.draw(with: box, in: context) }
        context.saveGState()
        Self.stroke(lines(), color: color, in: context)
        context.restoreGState()
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
                if let w = old.value(forAnnotationKey: widthsKey) { new.setValue(w, forAnnotationKey: widthsKey) }
                page.removeAnnotation(old)
                page.addAnnotation(new)
            }
        }
    }
}
