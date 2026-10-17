import PDFKit

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

extension PDFDocument {
    /// Descripción en texto de las anotaciones del usuario, para que la IA sepa qué ha marcado.
    var annotationSummary: String {
        let document = self
        var lines: [String] = []
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i) else { continue }
            for a in page.annotations {
                let kind: String = switch a.type {
                case "Highlight": "resaltado"
                case "Underline": "subrayado"
                case "StrikeOut": "tachado"
                case "Ink": "trazo a mano"
                case "Text": "nota"
                case "FreeText": "texto añadido"
                case "Square": "rectángulo"
                case "Circle": "círculo"
                case "Widget", "Link", "Popup": ""
                default: "anotación"
                }
                guard !kind.isEmpty else { continue }
                var line = "- Página \(i + 1): \(kind) \(Self.colorName(a.color))"
                let covered = (page.selection(for: a.bounds)?.string ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !covered.isEmpty { line += " sobre el texto: «\(covered.prefix(400))»" }
                if let c = a.contents, !c.isEmpty, ["nota", "texto añadido"].contains(kind) { line += " que dice: «\(c.prefix(200))»" }
                lines.append(line)
            }
        }
        return lines.isEmpty ? "El usuario no ha hecho anotaciones en el PDF." : "Anotaciones del usuario en el PDF (en orden):\n" + lines.prefix(60).joined(separator: "\n")
    }

    private static func colorName(_ color: PlatformColor) -> String {
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        #if os(macOS)
        guard let c = color.usingColorSpace(.sRGB) else { return "" }
        c.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        #else
        color.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        #endif
        if sat < 0.2 { return b < 0.3 ? "negro" : b > 0.85 ? "blanco" : "gris" }
        switch h * 360 {
        case ..<15, 345...: return "rojo"
        case ..<40: return "naranja"
        case ..<70: return "amarillo"
        case ..<170: return "verde"
        case ..<260: return "azul"
        case ..<300: return "morado"
        default: return "rosa"
        }
    }
}
