import CoreGraphics
import PDFKit

/// Encuentra la cuadrícula de una tabla dibujada en la página (sus líneas) alrededor de un punto,
/// para poder añadirle filas por debajo o columnas a la derecha.
enum TableFinder {
    struct Grid {
        /// Bordes de las columnas, de izquierda a derecha.
        var xs: [CGFloat]
        /// Líneas horizontales, de arriba abajo.
        var ys: [CGFloat]
        var lineWidth: CGFloat
        var verticals: Bool
        var fontSize: CGFloat
        /// Alto para una fila nueva (en tablas sin líneas verticales la última franja puede tener varias filas de texto).
        var rowHeight: CGFloat
    }

    private struct Line {
        var a: Int, b: Int   // columnas de píxeles
        var y0: Int, y1: Int // filas de píxeles (0 = arriba)
        var mid: Int { (y0 + y1) / 2 }
    }

    static func find(on page: PDFPage, at point: CGPoint) -> Grid? {
        guard let ref = page.pageRef else { return nil }
        let box = ref.getBoxRect(.mediaBox)
        let s: CGFloat = 3
        let w = Int(box.width * s), h = Int(box.height * s)
        guard w > 10, h > 10, w * h < 40_000_000 else { return nil }

        // Solo el contenido de la página (sin anotaciones), en grises.
        var px = [UInt8](repeating: 255, count: w * h)
        let drawn = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.drawPDFPage(ref)
            return true
        }
        guard drawn else { return nil }

        return px.withUnsafeBufferPointer { px -> Grid? in
            func dark(_ x: Int, _ y: Int) -> Bool { px[y * w + x] < 150 }
            let toX = { (x: Int) in box.minX + CGFloat(x) / s }
            let toY = { (y: Int) in box.minY + CGFloat(h - y) / s }
            let cx = Int((point.x - box.minX) * s), cy = h - Int((point.y - box.minY) * s)
            let tol = Int(4 * s)

            // 1. Líneas horizontales: tramos oscuros largos, uniendo filas de píxeles seguidas (líneas gruesas).
            let minRun = Int(30 * s)
            var lines: [Line] = [], open: [Line] = []
            for y in 0..<h {
                var next: [Line] = []
                var x = 0
                while x < w {
                    guard dark(x, y) else { x += 1; continue }
                    let start = x
                    while x < w, dark(x, y) { x += 1 }
                    guard x - start >= minRun else { continue }
                    if let i = open.firstIndex(where: { abs($0.a - start) <= tol && abs($0.b - x) <= tol }) {
                        var l = open.remove(at: i)
                        l.y1 = y
                        l.a = min(l.a, start)
                        l.b = max(l.b, x)
                        next.append(l)
                    } else {
                        next.append(Line(a: start, b: x, y0: y, y1: y))
                    }
                }
                lines += open
                open = next
            }
            lines += open
            lines = lines.filter { $0.y1 - $0.y0 <= Int(3 * s) } // no bloques rellenos

            // 2. Las líneas justo encima y debajo del clic marcan el ancho de la tabla.
            let crossing = lines.filter { $0.a - tol <= cx && cx <= $0.b + tol }
            guard let below = crossing.filter({ $0.y0 > cy }).min(by: { $0.y0 < $1.y0 }),
                  let above = crossing.filter({ $0.y1 < cy }).max(by: { $0.y1 < $1.y1 }) else { return nil }
            let a = min(above.a, below.a), b = max(above.b, below.b), width = b - a

            func vertical(at x: Int, from y0: Int, to y1: Int) -> Bool {
                guard y1 - y0 > 2 else { return true }
                for xx in max(0, x - tol / 2)...min(w - 1, x + tol / 2) {
                    var n = 0
                    for y in y0...y1 where dark(xx, y) { n += 1 }
                    if Double(n) >= 0.9 * Double(y1 - y0 + 1) { return true }
                }
                return false
            }

            // 3. Todas las líneas de la misma tabla: mismo ancho y seguidas (cerca o unidas por los bordes).
            var table = lines.filter { l in
                let overlap = min(b, l.b) - max(a, l.a)
                return Double(overlap) >= 0.85 * Double(width) && Double(l.b - l.a) <= 1.15 * Double(width)
            }
            for l in [above, below] where !table.contains(where: { $0.y0 == l.y0 && $0.a == l.a }) { table.append(l) }
            table.sort { $0.y0 < $1.y0 }
            func connected(_ u: Line, _ v: Line) -> Bool {
                v.y0 - u.y1 <= Int(80 * s) || vertical(at: a, from: u.y1, to: v.y0) || vertical(at: b, from: u.y1, to: v.y0)
            }
            guard var lo = table.firstIndex(where: { $0.y0 == above.y0 && $0.a == above.a }),
                  var hi = table.firstIndex(where: { $0.y0 == below.y0 && $0.a == below.a }) else { return nil }
            while lo > 0, connected(table[lo - 1], table[lo]) { lo -= 1 }
            while hi < table.count - 1, connected(table[hi], table[hi + 1]) { hi += 1 }
            let rows = Array(table[lo...hi])
            guard rows.count >= 2 else { return nil }

            // 4. Columnas: líneas verticales en la última fila…
            let last0 = rows[rows.count - 2].y1 + 2, last1 = rows[rows.count - 1].y0 - 2
            guard last1 > last0 else { return nil }
            var cols: [Int] = []
            var x = max(0, a - tol)
            while x <= min(w - 1, b + tol) {
                var n = 0
                for y in last0...last1 where dark(x, y) { n += 1 }
                if Double(n) >= 0.9 * Double(last1 - last0 + 1) {
                    let start = x
                    while x + 1 <= min(w - 1, b + tol), (last0...last1).filter({ dark(x + 1, $0) }).count * 10 >= (last1 - last0 + 1) * 9 { x += 1 }
                    cols.append((start + x) / 2)
                }
                x += 1
            }
            let inner = cols.filter { $0 > a + tol && $0 < b - tol }
            let verticals = cols.count > inner.count || !inner.isEmpty
            var xs = [toX(a)] + inner.map(toX) + [toX(b)]
            let ys = rows.map { toY($0.mid) }

            // …o, si no las hay, los huecos entre columnas de texto.
            if inner.isEmpty {
                for i in stride(from: ys.count - 1, to: 0, by: -1) {
                    let gaps = textGaps(on: page, in: CGRect(x: xs[0], y: ys[i], width: xs[xs.count - 1] - xs[0], height: ys[i - 1] - ys[i]))
                    if !gaps.isEmpty { xs = [xs[0]] + gaps + [xs[xs.count - 1]]; break }
                }
            }

            let lastRow = CGRect(x: xs[0], y: ys[ys.count - 1], width: xs[xs.count - 1] - xs[0], height: ys[ys.count - 2] - ys[ys.count - 1])
            let fontSize = min(max(fontSize(on: page, in: lastRow) ?? 10, 6), 20)
            let thickness = rows.map { CGFloat($0.y1 - $0.y0 + 1) }.reduce(0, +) / CGFloat(rows.count) / s
            let rowHeight = verticals ? lastRow.height : min(lastRow.height, fontSize * 1.9)
            return Grid(xs: xs, ys: ys, lineWidth: max(0.4, thickness), verticals: verticals, fontSize: fontSize, rowHeight: rowHeight)
        }
    }

    /// Centros de los huecos horizontales entre bloques de texto dentro de `rect`.
    private static func textGaps(on page: PDFPage, in rect: CGRect) -> [CGFloat] {
        var spans: [(CGFloat, CGFloat)] = []
        for i in 0..<page.numberOfCharacters {
            let r = page.characterBounds(at: i)
            // PDFKit estira los espacios hasta la siguiente palabra: un «carácter» así de ancho es un hueco.
            guard r.width > 0, r.width <= max(14, 3 * r.height), rect.contains(CGPoint(x: r.midX, y: r.midY)) else { continue }
            spans.append((r.minX, r.maxX))
        }
        spans.sort { $0.0 < $1.0 }
        var gaps: [CGFloat] = []
        var end = spans.first?.1 ?? 0
        for (lo, hi) in spans.dropFirst() {
            if lo - end > 7 { gaps.append((lo + end) / 2) }
            end = max(end, hi)
        }
        return gaps
    }

    private static func fontSize(on page: PDFPage, in rect: CGRect) -> CGFloat? {
        guard let text = page.selection(for: rect)?.attributedString, text.length > 0 else { return nil }
        return (text.attribute(.font, at: 0, effectiveRange: nil) as? PlatformFont)?.pointSize
    }
}
