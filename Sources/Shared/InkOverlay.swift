import PDFKit

#if os(macOS)
import AppKit
typealias PlatformView = NSView

/// Capa que no se queda con los clics: el ratón sigue llegando al PDF.
private final class OverlayView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#else
import UIKit
typealias PlatformView = UIView
#endif

/// Muestra la tinta a mano encima de cada página como imagen a la resolución del zoom, con el grosor
/// de cada punto (presión del Pencil). En el archivo la tinta es una anotación normal; aquí PDFKit no la pinta (ver SmoothInk):
/// PDFKit dibuja las anotaciones a baja resolución y se ven borrosas al hacer zoom, también las que se dibujan ellas mismas.
/// En el iPad, lo mismo con los cuadros de texto, imágenes y tablas (MovableAnnotation), para que no se vean pixelados.
final class InkOverlay: NSObject, PDFPageOverlayViewProvider {
    weak var pdfView: PDFView?
    private let drawsObjects: Bool
    private var views: [PDFPage: PlatformView] = [:]
    private var cache: [ObjectIdentifier: [SmoothInk.Line]] = [:]
    private var pending: DispatchWorkItem?

    init(drawsObjects: Bool) {
        self.drawsObjects = drawsObjects
    }

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

    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> PlatformView? {
        #if os(macOS)
        let v = OverlayView()
        v.wantsLayer = true
        v.layer?.contentsGravity = .resize
        #else
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.layer.contentsGravity = .resize
        #endif
        views[page] = v
        Self.setCovered(page, true)
        DispatchQueue.main.async { self.render(page) }
        return v
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: PlatformView, for page: PDFPage) {
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

    /// Vuelve a dibujar todas las páginas visibles (p. ej. tras cambiar páginas del documento).
    func renderAll() { views.keys.forEach(render) }

    func render(_ page: PDFPage) {
        guard let v = views[page] else { return }
        #if os(macOS)
        let layer = v.layer
        let screen = pdfView?.window?.backingScaleFactor ?? 2
        #else
        let layer: CALayer? = v.layer
        let screen = pdfView?.window?.screen.scale ?? 2
        #endif
        guard page.rotation == 0 else { layer?.contents = nil; return } // páginas giradas: la pinta SmoothInk
        let box = page.bounds(for: pdfView?.displayBox ?? .cropBox)
        let inks = page.annotations.compactMap { $0 as? SmoothInk }.map { (lines(for: $0), $0.color) }
        let objects = drawsObjects ? page.annotations.compactMap { $0 as? MovableAnnotation } : []
        guard !inks.isEmpty || !objects.isEmpty, box.width > 0, box.height > 0 else { layer?.contents = nil; return }
        let zoom = pdfView?.scaleFactor ?? 1
        let maxScale = (12_000_000 / (box.width * box.height)).squareRoot() // tope de memoria por página
        let scale = min(screen * max(zoom, 0.5), maxScale)
        guard let cg = CGContext(data: nil, width: Int((box.width * scale).rounded(.up)), height: Int((box.height * scale).rounded(.up)),
                                 bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        // Coordenadas de página (y hacia arriba), igual que la imagen.
        cg.scaleBy(x: scale, y: scale)
        cg.translateBy(x: -box.minX, y: -box.minY)
        objects.forEach { a in
            cg.saveGState()
            a.drawContent(in: cg)
            cg.restoreGState()
        }
        for (lines, color) in inks { SmoothInk.stroke(lines, color: color, in: cg) }
        layer?.contents = cg.makeImage()
    }

    private func lines(for a: SmoothInk) -> [SmoothInk.Line] {
        if let cached = cache[ObjectIdentifier(a)] { return cached }
        let result = a.lines()
        cache[ObjectIdentifier(a)] = result
        return result
    }
}
