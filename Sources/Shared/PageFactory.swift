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
}
