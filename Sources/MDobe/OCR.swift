import CoreText
import PDFKit
import Vision

/// OCR de páginas escaneadas con Vision (local): se añade una capa de texto invisible
/// para poder buscar, seleccionar y que la IA lea el contenido.
extension Editor {
    func runOCR() {
        guard ocrStatus == nil else { return }
        suggestOCR = false
        let targets = (0..<document.pageCount).filter(isScanned).compactMap { document.page(at: $0) }
        guard !targets.isEmpty else { return flash("Todas las páginas ya tienen texto.") }

        Task {
            var pairs: [(from: PDFPage, to: PDFPage)] = []
            for (n, page) in targets.enumerated() {
                ocrStatus = "Reconociendo texto… página \(n + 1) de \(targets.count)"
                guard let ref = page.pageRef else { continue }
                let box = ref.getBoxRect(.mediaBox)
                guard let image = Self.render(ref, box: box) else { continue }
                let lines = await Task.detached { Self.recognize(image) }.value
                guard !lines.isEmpty, let newPage = Self.makePage(ref, box: box, lines: lines) else { continue }
                newPage.rotation = page.rotation
                newPage.setBounds(page.bounds(for: .cropBox), for: .cropBox)
                pairs.append((page, newPage))
            }
            ocrStatus = nil
            guard !pairs.isEmpty else { return flash("No he encontrado texto en las páginas escaneadas.") }
            exchange(pairs)
            undoManager?.setActionName("Reconocer texto")
            flash("Texto reconocido en \(pairs.count) páginas. Ya puedes buscar y seleccionar.")
        }
    }

    private func flash(_ message: String) {
        ocrStatus = message
        Task {
            try? await Task.sleep(for: .seconds(4))
            if ocrStatus == message { ocrStatus = nil }
        }
    }

    nonisolated private static func render(_ ref: CGPDFPage, box: CGRect) -> CGImage? {
        let scale = min(3, 2600 / max(box.width, box.height))
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(ref)
        return ctx.makeImage()
    }

    /// Líneas reconocidas con su caja normalizada (origen abajo-izquierda, como en PDF).
    nonisolated private static func recognize(_ image: CGImage) -> [(text: String, box: CGRect)] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["es-ES", "en-US"]
        request.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { o in o.topCandidates(1).first.map { ($0.string, o.boundingBox) } }
    }

    /// Copia la página original y dibuja encima el texto reconocido en modo invisible.
    nonisolated private static func makePage(_ ref: CGPDFPage, box: CGRect, lines: [(text: String, box: CGRect)]) -> PDFPage? {
        let data = NSMutableData()
        var mediaBox = box
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        ctx.drawPDFPage(ref)
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let r = CGRect(x: box.minX + line.box.minX * box.width, y: box.minY + line.box.minY * box.height,
                           width: line.box.width * box.width, height: line.box.height * box.height)
            let font = CTFontCreateWithName("Helvetica" as CFString, max(r.height * 0.85, 1), nil)
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font]))
            let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard width > 0 else { continue }
            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: r.minX, y: r.minY + r.height * 0.2)
            ctx.scaleBy(x: r.width / width, y: 1) // que el texto ocupe justo el ancho de la línea escaneada
            ctx.textPosition = .zero
            CTLineDraw(ctLine, ctx)
            ctx.restoreGState()
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }
}
