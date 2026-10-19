import CoreGraphics
import PDFKit

/// Páginas nuevas dibujadas con Core Graphics (compartido Mac/iPad).
enum PageFactory {
    enum Paper: String, CaseIterable {
        case plain = "lisa", grid = "cuadrícula", lines = "rayas"
    }

    static func blank(_ paper: Paper, box: CGRect) -> PDFPage? {
        compose(box: box) { ctx in drawPaper(paper, in: box, ctx) }
    }

    static func compose(box: CGRect, draw: (CGContext) -> Void) -> PDFPage? {
        let data = NSMutableData()
        var mediaBox = box
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        draw(ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    static func drawPaper(_ paper: Paper, in box: CGRect, _ ctx: CGContext) {
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(box)
        ctx.setLineWidth(0.4)
        switch paper {
        case .plain: break
        case .grid:
            ctx.setStrokeColor(CGColor(red: 0.55, green: 0.7, blue: 0.9, alpha: 0.55))
            let step: CGFloat = 14.17 // 5 mm
            for x in stride(from: box.minX, through: box.maxX, by: step) { ctx.move(to: CGPoint(x: x, y: box.minY)); ctx.addLine(to: CGPoint(x: x, y: box.maxY)) }
            for y in stride(from: box.minY, through: box.maxY, by: step) { ctx.move(to: CGPoint(x: box.minX, y: y)); ctx.addLine(to: CGPoint(x: box.maxX, y: y)) }
            ctx.strokePath()
        case .lines:
            ctx.setStrokeColor(CGColor(red: 0.55, green: 0.7, blue: 0.9, alpha: 0.7))
            for y in stride(from: box.maxY - 72, through: box.minY + 36, by: -22.7) { // 8 mm
                ctx.move(to: CGPoint(x: box.minX + 36, y: y)); ctx.addLine(to: CGPoint(x: box.maxX - 36, y: y))
            }
            ctx.strokePath()
        }
    }

    /// Copia de la página con espacio extra a la derecha para tomar apuntes junto al contenido.
    static func withMargin(_ page: PDFPage, paper: Paper, fraction: CGFloat = 0.6) -> PDFPage? {
        guard page.rotation == 0, let ref = page.pageRef else { return nil }
        let media = ref.getBoxRect(.mediaBox), crop = page.bounds(for: .cropBox)
        let margin = CGRect(x: crop.maxX, y: crop.minY, width: crop.width * fraction, height: crop.height)
        let box = CGRect(x: media.minX, y: media.minY, width: max(media.maxX, margin.maxX) - media.minX, height: media.height)
        let new = compose(box: box) { ctx in
            drawPaper(paper, in: margin, ctx)
            ctx.drawPDFPage(ref)
            ctx.setStrokeColor(CGColor(gray: 0.75, alpha: 1)) // separación entre la página y el margen
            ctx.setLineWidth(0.6)
            ctx.move(to: CGPoint(x: margin.minX, y: margin.minY))
            ctx.addLine(to: CGPoint(x: margin.minX, y: margin.maxY))
            ctx.strokePath()
        }
        new?.setBounds(crop.union(margin), for: .cropBox)
        return new
    }
}

/// Hojas del cuaderno de apuntes: en el archivo van justo detrás de su página, marcadas con una anotación oculta.
/// El iPad las saca del PDF y las muestra al lado de la página; cualquier otro lector las ve como páginas normales.
extension PDFPage {
    static let notesMarker = "MDobe-apuntes"

    var isNotesSheet: Bool {
        annotations.contains { $0.userName == Self.notesMarker } // PDFKit no guarda claves propias ni /NM; el autor (/T) sí
    }

    func markAsNotesSheet() {
        let box = bounds(for: .mediaBox)
        let a = PDFAnnotation(bounds: CGRect(x: box.minX, y: box.minY, width: 1, height: 1), forType: .square, withProperties: nil)
        a.userName = Self.notesMarker
        a.shouldDisplay = false
        a.shouldPrint = false
        addAnnotation(a)
    }
}
