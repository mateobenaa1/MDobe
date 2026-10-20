import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
#else
import UIKit
typealias PlatformFont = UIFont
#endif

// MARK: Objetos que se pueden mover

/// Cuadros de texto, imágenes y tablas: anotaciones que se mueven, cambian de tamaño y se editan.
/// Se dibujan ellas mismas en vectorial (nítidas a cualquier zoom); al guardar, PDFKit convierte ese dibujo
/// en la apariencia de la anotación, así que se ven igual en Acrobat o Vista Previa.
class MovableAnnotation: PDFAnnotation {
    static let kindKey = PDFAnnotationKey(rawValue: "/MDobeObj")
    /// En el iPad las pinta la capa de tinta a la resolución del zoom (PDFKit las dejaría pixeladas).
    nonisolated(unsafe) static var drawnElsewhere: (PDFPage) -> Bool = { _ in false }
    /// Mientras se genera el archivo hay que dibujarlas siempre: ese dibujo es lo que se guarda.
    nonisolated(unsafe) static var exporting = false

    var keepsAspect: Bool { false }
    /// Alto que necesita el contenido con ese ancho (nil = alto libre al cambiar el tamaño).
    func fittedHeight(width: CGFloat) -> CGFloat? { nil }
    func didResize() {}
    func drawContent(in ctx: CGContext) {}

    /// Guarda el estado actual y devuelve cómo volver a él (para deshacer).
    func capture() -> () -> Void {
        let b = bounds
        return { [self] in bounds = b }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        if !Self.exporting, let page, Self.drawnElsewhere(page) { return }
        context.saveGState()
        drawContent(in: context)
        context.restoreGState()
    }
}

final class TextBox: MovableAnnotation {
    static let padding: CGFloat = 3
    /// PDFKit no conserva bien el tamaño de letra al guardar: lo apuntamos aparte.
    static let sizeKey = PDFAnnotationKey(rawValue: "/MDobeSize")
    static let colorKey = PDFAnnotationKey(rawValue: "/MDobeColor")

    static func make(_ text: String, size: CGFloat, color: PlatformColor, topLeft: CGPoint, on page: PDFPage) -> TextBox {
        let a = TextBox(bounds: .zero, forType: .freeText, withProperties: nil)
        a.setValue("text", forAnnotationKey: kindKey)
        a.color = .clear
        a.border = PDFBorder()
        a.border?.lineWidth = 0
        a.set(text, size: size, color: color, topLeft: topLeft, maxX: page.bounds(for: .cropBox).maxX - 8)
        return a
    }

    /// Cambia el texto y ajusta el cuadro a él, manteniendo la esquina de arriba a la izquierda.
    func set(_ text: String, size: CGFloat, color: PlatformColor, topLeft: CGPoint, maxX: CGFloat) {
        contents = text
        font = PlatformFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        fontColor = color
        remember()
        let fit = TextDraw.size(attributed, width: max(60, maxX - topLeft.x) - 2 * Self.padding)
        let w = ceil(fit.width) + 2 * Self.padding + 1, h = ceil(fit.height) + 2 * Self.padding
        bounds = CGRect(x: topLeft.x, y: topLeft.y - h, width: w, height: h)
    }

    /// Apunta tamaño y color en claves propias (ver `sizeKey`).
    func remember() {
        if let font { setValue(String(format: "%.1f", font.pointSize), forAnnotationKey: Self.sizeKey) }
        if let c = fontColor?.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components, c.count >= 3 {
            setValue(c.prefix(3).map { String(format: "%.3f", $0) }.joined(separator: " "), forAnnotationKey: Self.colorKey)
        }
    }

    /// Recupera lo apuntado por `remember` al abrir el PDF.
    func restoreStyle(from old: PDFAnnotation) {
        if let size = (old.value(forAnnotationKey: Self.sizeKey) as? String).flatMap(Double.init) {
            font = PlatformFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
        }
        let rgb = ((old.value(forAnnotationKey: Self.colorKey) as? String) ?? "").split(separator: " ").compactMap { Double($0) }
        if rgb.count == 3 { fontColor = PlatformColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1) }
        remember()
    }

    private var attributed: NSAttributedString {
        let f = font ?? PlatformFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
        return TextDraw.attributed(contents ?? "", font: CTFontCreateWithName(f.fontName as CFString, f.pointSize, nil),
                                   color: (fontColor ?? .black).cgColor)
    }

    override func fittedHeight(width: CGFloat) -> CGFloat? {
        ceil(TextDraw.size(attributed, width: width - 2 * Self.padding).height) + 2 * Self.padding
    }

    override func drawContent(in ctx: CGContext) {
        TextDraw.draw(attributed, in: bounds.insetBy(dx: Self.padding, dy: Self.padding), ctx: ctx)
    }

    override func capture() -> () -> Void {
        let b = bounds, text = contents, f = font, c = fontColor
        return { [self] in
            contents = text
            font = f
            fontColor = c
            remember()
            bounds = b
        }
    }
}

final class ImageBox: MovableAnnotation {
    static let dataKey = PDFAnnotationKey(rawValue: "/MDobeImg")
    private var image: CGImage?
    override var keepsAspect: Bool { true }

    /// Coloca la imagen centrada en `center`, a un tamaño razonable para la página.
    static func make(_ data: Data, center: CGPoint, on page: PDFPage) -> ImageBox? {
        guard let (stored, image) = ImageData.prepare(data) else { return nil }
        let crop = page.bounds(for: .cropBox)
        let aspect = CGFloat(image.height) / CGFloat(image.width)
        var w = min(crop.width * 0.5, CGFloat(image.width) / 2)
        if w * aspect > crop.height * 0.5 { w = crop.height * 0.5 / aspect }
        let h = w * aspect
        let x = min(max(center.x - w / 2, crop.minX), crop.maxX - w)
        let y = min(max(center.y - h / 2, crop.minY), crop.maxY - h)
        let a = ImageBox(bounds: CGRect(x: x, y: y, width: w, height: h), forType: .stamp, withProperties: nil)
        a.setValue("image", forAnnotationKey: kindKey)
        a.setValue(stored.base64EncodedString(), forAnnotationKey: dataKey)
        a.image = image
        return a
    }

    func load() {
        guard let s = value(forAnnotationKey: Self.dataKey) as? String, let d = Data(base64Encoded: s),
              let src = CGImageSourceCreateWithData(d as CFData, nil) else { return }
        image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    override func drawContent(in ctx: CGContext) {
        guard let image else { return }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)
    }
}

/// Celdas de una tabla: anchos de columna y altos de fila en puntos de página, de izquierda a derecha y de arriba abajo.
struct TableModel: Codable, Equatable {
    var cols: [CGFloat]
    var rows: [CGFloat]
    var cells: [[String]]
    var fontSize: CGFloat = 11
    var lineWidth: CGFloat = 0.8
    var verticals = true
    /// Línea de arriba y de la izquierda: no se dibujan cuando la tabla continúa una que ya está en el PDF.
    var top = true
    var left = true

    static let blank = TableModel(cols: [90, 90, 90], rows: [20, 20, 20], cells: Array(repeating: ["", "", ""], count: 3))

    var size: CGSize { CGSize(width: cols.reduce(0, +), height: rows.reduce(0, +)) }

    mutating func addRow() {
        rows.append(rows.last ?? 20)
        cells.append(Array(repeating: "", count: cols.count))
    }

    mutating func addColumn() {
        cols.append(cols.last ?? 80)
        for i in cells.indices { cells[i].append("") }
    }

    mutating func removeRow() {
        guard rows.count > 1 else { return }
        rows.removeLast()
        cells.removeLast()
    }

    mutating func removeColumn() {
        guard cols.count > 1 else { return }
        cols.removeLast()
        for i in cells.indices { cells[i].removeLast() }
    }

    /// Asegura que haya una celda por cada fila y columna.
    mutating func normalize() {
        cells = rows.indices.map { r in
            let row = r < cells.count ? cells[r] : []
            return cols.indices.map { c in c < row.count ? row[c] : "" }
        }
    }
}

final class TableBox: MovableAnnotation {
    static let dataKey = PDFAnnotationKey(rawValue: "/MDobeTable")
    private var cached: TableModel?

    static func make(_ model: TableModel, topLeft: CGPoint) -> TableBox {
        let a = TableBox(bounds: .zero, forType: .stamp, withProperties: nil)
        a.setValue("table", forAnnotationKey: kindKey)
        a.apply(model, topLeft: topLeft)
        return a
    }

    var model: TableModel {
        if let cached { return cached }
        var m = (value(forAnnotationKey: Self.dataKey) as? String).flatMap { try? JSONDecoder().decode(TableModel.self, from: Data($0.utf8)) } ?? .blank
        m.normalize()
        cached = m
        return m
    }

    private var pad: CGFloat { max(1, model.lineWidth) }
    /// Esquina de arriba a la izquierda de la cuadrícula (sin el margen para el grosor de las líneas).
    var gridTopLeft: CGPoint { CGPoint(x: bounds.minX + pad, y: bounds.maxY - pad) }

    func apply(_ m: TableModel, topLeft: CGPoint? = nil) {
        var m = m
        m.normalize()
        let corner = topLeft ?? gridTopLeft
        cached = m
        if let json = try? JSONEncoder().encode(m) { setValue(String(decoding: json, as: UTF8.self), forAnnotationKey: Self.dataKey) }
        let p = pad, size = m.size
        bounds = CGRect(x: corner.x - p, y: corner.y - size.height - p, width: size.width + 2 * p, height: size.height + 2 * p)
    }

    /// Tras estirar la tabla con el ratón o el dedo, las columnas y filas se quedan con el nuevo tamaño.
    override func didResize() {
        var m = model
        let grid = bounds.insetBy(dx: pad, dy: pad)
        let sx = grid.width / max(m.size.width, 1), sy = grid.height / max(m.size.height, 1)
        m.cols = m.cols.map { $0 * sx }
        m.rows = m.rows.map { $0 * sy }
        apply(m)
    }

    override func drawContent(in ctx: CGContext) {
        let m = model
        let grid = bounds.insetBy(dx: pad, dy: pad)
        let sx = grid.width / max(m.size.width, 1), sy = grid.height / max(m.size.height, 1)
        var xs = [grid.minX], ys = [grid.maxY]
        for c in m.cols { xs.append(xs.last! + c * sx) }
        for r in m.rows { ys.append(ys.last! - r * sy) }

        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineWidth(m.lineWidth)
        for (i, y) in ys.enumerated() where i > 0 || m.top {
            ctx.move(to: CGPoint(x: xs[0], y: y))
            ctx.addLine(to: CGPoint(x: xs[xs.count - 1], y: y))
        }
        if m.verticals {
            for (i, x) in xs.enumerated() where i > 0 || m.left {
                ctx.move(to: CGPoint(x: x, y: ys[0]))
                ctx.addLine(to: CGPoint(x: x, y: ys[ys.count - 1]))
            }
        }
        ctx.strokePath()

        let font = CTFontCreateWithName("Helvetica" as CFString, m.fontSize, nil)
        let black = CGColor(gray: 0, alpha: 1)
        for r in m.rows.indices {
            for c in m.cols.indices where !m.cells[r][c].isEmpty {
                let cell = CGRect(x: xs[c], y: ys[r + 1], width: xs[c + 1] - xs[c], height: ys[r] - ys[r + 1]).insetBy(dx: 3, dy: 1)
                let text = TextDraw.attributed(m.cells[r][c], font: font, color: black)
                let h = TextDraw.size(text, width: cell.width).height
                let top = cell.maxY - max(0, (cell.height - h) / 2) // centrado en vertical
                TextDraw.draw(text, in: CGRect(x: cell.minX, y: top - h, width: cell.width, height: h), ctx: ctx)
            }
        }
    }

    override func capture() -> () -> Void {
        let b = bounds, m = model
        return { [self] in
            apply(m)
            bounds = b
        }
    }
}

// MARK: Utilidades

enum PageObjects {
    /// Al abrir un PDF: los objetos guardados vuelven a ser movibles (sin pasar por deshacer).
    static func adopt(in document: PDFDocument) {
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for old in page.annotations where !(old is MovableAnnotation) {
                let kind = old.value(forAnnotationKey: MovableAnnotation.kindKey) as? String
                let new: MovableAnnotation
                switch kind {
                case "image":
                    let a = ImageBox(bounds: old.bounds, forType: .stamp, withProperties: nil)
                    a.setValue(old.value(forAnnotationKey: ImageBox.dataKey) ?? "", forAnnotationKey: ImageBox.dataKey)
                    a.load()
                    new = a
                case "table":
                    let a = TableBox(bounds: old.bounds, forType: .stamp, withProperties: nil)
                    a.setValue(old.value(forAnnotationKey: TableBox.dataKey) ?? "", forAnnotationKey: TableBox.dataKey)
                    new = a
                default:
                    // Texto nuestro, también el de versiones anteriores (FreeText sin fondo ni texto enriquecido).
                    let ours = kind == "text" || (old.value(forAnnotationKey: .color) == nil && old.value(forAnnotationKey: PDFAnnotationKey(rawValue: "/RC")) == nil)
                    guard old.type == "FreeText", ours, !(old.contents ?? "").isEmpty else { continue }
                    let a = TextBox(bounds: old.bounds, forType: .freeText, withProperties: nil)
                    a.contents = old.contents
                    a.font = old.font
                    a.fontColor = old.fontColor
                    a.restoreStyle(from: old)
                    a.color = .clear
                    a.border = PDFBorder()
                    a.border?.lineWidth = 0
                    new = a
                }
                new.setValue(old.value(forAnnotationKey: MovableAnnotation.kindKey) ?? "text", forAnnotationKey: MovableAnnotation.kindKey)
                new.shouldPrint = old.shouldPrint
                page.removeAnnotation(old)
                page.addAnnotation(new)
            }
        }
    }

    static func object(at p: CGPoint, on page: PDFPage, tolerance: CGFloat) -> MovableAnnotation? {
        page.annotations.reversed().lazy.compactMap { $0 as? MovableAnnotation }
            .first { $0.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p) }
    }

    /// Centro de lo que se ve en pantalla, en coordenadas de su página.
    static func visibleCenter(in view: PDFView) -> (page: PDFPage, point: CGPoint)? {
        let c = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        guard let page = view.page(for: c, nearest: true) else { return nil }
        let crop = page.bounds(for: .cropBox), p = view.convert(c, to: page)
        return (page, CGPoint(x: min(max(p.x, crop.minX), crop.maxX), y: min(max(p.y, crop.minY), crop.maxY)))
    }
}

/// Arrastre de un objeto: lo mueve o, si se coge por la esquina de abajo a la derecha, le cambia el tamaño.
@MainActor
final class ObjectDrag {
    let object: MovableAnnotation
    let page: PDFPage
    let restore: () -> Void
    private let start: CGPoint
    private let original: CGRect
    private let resizing: Bool
    private let scale: CGFloat
    private(set) var moved = false

    init?(at p: CGPoint, on page: PDFPage, scale: CGFloat) {
        let scale = max(scale, 0.1)
        guard let object = PageObjects.object(at: p, on: page, tolerance: 6 / scale) else { return nil }
        self.object = object
        self.page = page
        self.scale = scale
        restore = object.capture()
        start = p
        original = object.bounds
        resizing = hypot(p.x - original.maxX, p.y - original.minY) <= 16 / scale
    }

    func update(to p: CGPoint) {
        let dx = p.x - start.x, dy = p.y - start.y
        guard moved || hypot(dx, dy) * scale >= 3 else { return }
        moved = true
        guard resizing else { object.bounds = original.offsetBy(dx: dx, dy: dy); return }
        let w = max(16, original.width + dx)
        let h = object.keepsAspect ? original.height * w / original.width
            : object.fittedHeight(width: w) ?? max(10, original.height - dy)
        object.bounds = CGRect(x: original.minX, y: original.maxY - h, width: w, height: h)
    }

    func finish() {
        if moved, resizing { object.didResize() }
    }
}

enum TextDraw {
    static func attributed(_ s: String, font: CTFont, color: CGColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
    }

    static func size(_ text: NSAttributedString, width: CGFloat) -> CGSize {
        let fs = CTFramesetterCreateWithAttributedString(text)
        return CTFramesetterSuggestFrameSizeWithConstraints(fs, CFRange(), nil, CGSize(width: max(width, 1), height: .greatestFiniteMagnitude), nil)
    }

    /// Dibuja desde el borde de arriba de `rect` hacia abajo (contexto con la y hacia arriba, como una página PDF).
    static func draw(_ text: NSAttributedString, in rect: CGRect, ctx: CGContext) {
        let fs = CTFramesetterCreateWithAttributedString(text)
        let area = CGRect(x: rect.minX, y: rect.maxY - 100_000, width: max(rect.width, 1) + 0.5, height: 100_000)
        let frame = CTFramesetterCreateFrame(fs, CFRange(), CGPath(rect: area, transform: nil), nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }
}

enum ImageData {
    /// Endereza (EXIF), reduce a 1600 px como mucho y comprime: JPEG, o PNG si tiene transparencia.
    static func prepare(_ data: Data) -> (data: Data, image: CGImage)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1600,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, (alpha ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, image)
    }
}
