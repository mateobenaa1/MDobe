import CoreGraphics
import PDFKit

/// Lleva los apuntes de un PDF a una nueva versión del original (p. ej. el profe retoca los apuntes y los vuelve a subir).
/// Empareja las páginas por su texto, en orden: las emparejadas pasan a ser la página nueva con tus anotaciones
/// (y tu margen de apuntes, si lo tenía); las que no están en la nueva versión (tus páginas en blanco, bloques,
/// o páginas que el profe ha quitado) se conservan justo después de la página a la que seguían.
enum PDFUpdate {
    struct Move {
        let annotation: PDFAnnotation
        let from: PDFPage
        let to: PDFPage
    }

    struct Plan {
        var pages: [PDFPage] = []
        var moves: [Move] = []
        var matched = 0, added = 0, kept = 0

        var summary: String {
            var lines = ["\(matched) páginas actualizadas a la nueva versión, con tus anotaciones."]
            if added > 0 { lines.append("\(added) páginas nuevas del original.") }
            if kept > 0 { lines.append("\(kept) páginas tuyas (o que ya no están en el original) conservadas en su sitio.") }
            lines.append("Si algo no te convence, Deshacer lo deja como estaba.")
            return lines.joined(separator: "\n")
        }
    }

    static func plan(old: PDFDocument, new: PDFDocument) -> Plan {
        let oldPages = (0..<old.pageCount).compactMap { old.page(at: $0) }
        let newPages = (0..<new.pageCount).compactMap { new.page(at: $0) }
        var vocabulary: [String: Int] = [:]
        let oldWords = oldPages.map { words($0.string ?? "", &vocabulary) }
        let newWords = newPages.map { words($0.string ?? "", &vocabulary) }
        let pairs = align(oldWords, newWords)

        var plan = Plan()
        let matchOf = Dictionary(uniqueKeysWithValues: pairs.map { ($0.new, $0.old) })
        // Cada página sin pareja se queda detrás de la última página emparejada que tenía delante.
        var following: [Int: [PDFPage]] = [:]
        var anchor = -1
        let matchedOld = Set(pairs.map(\.old))
        for (i, page) in oldPages.enumerated() {
            if matchedOld.contains(i) { anchor = i } else { following[anchor, default: []].append(page) }
        }

        plan.pages += following[-1] ?? []
        for (j, fresh) in newPages.enumerated() {
            guard let i = matchOf[j] else {
                if let copy = fresh.copy() as? PDFPage { plan.pages.append(copy) }
                plan.added += 1
                continue
            }
            let mine = oldPages[i]
            guard let page = keepingMargin(fresh, from: mine) ?? fresh.copy() as? PDFPage else { continue }
            if page.rotation != mine.rotation { page.rotation = mine.rotation }
            for a in mine.annotations where a.type != "Link" && a.type != "Widget" {
                plan.moves.append(Move(annotation: a, from: mine, to: page))
            }
            plan.pages.append(page)
            plan.pages += following[i] ?? []
            plan.matched += 1
        }
        plan.kept = oldPages.count - pairs.count
        return plan
    }

    /// Cambia las páginas del documento por `pages` moviendo las anotaciones. Devuelve lo necesario para deshacerlo.
    static func apply(_ pages: [PDFPage], _ moves: [Move], to document: PDFDocument) -> (pages: [PDFPage], moves: [Move]) {
        let previous = (0..<document.pageCount).compactMap { document.page(at: $0) }
        for m in moves {
            m.from.removeAnnotation(m.annotation)
            m.to.addAnnotation(m.annotation)
        }
        while document.pageCount > 0 { document.removePage(at: document.pageCount - 1) }
        for p in pages { document.insert(p, at: document.pageCount) }
        return (previous, moves.map { Move(annotation: $0.annotation, from: $0.to, to: $0.from) })
    }

    // MARK: Emparejado

    /// Pares de palabras seguidas de la página (sin mayúsculas ni acentos) como números, para comparar rápido.
    /// Los pares distinguen mucho mejor que las palabras sueltas páginas del mismo tema.
    private static func words(_ text: String, _ vocabulary: inout [String: Int]) -> Set<Int> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let list = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        var result = Set<Int>()
        for (a, b) in zip(list, list.dropFirst()) {
            let key = "\(a) \(b)"
            if let id = vocabulary[key] { result.insert(id) } else {
                vocabulary[key] = vocabulary.count
                result.insert(vocabulary.count - 1)
            }
        }
        return result
    }

    private static func similarity(_ a: Set<Int>, _ b: Set<Int>) -> Double {
        guard a.count >= 3, b.count >= 3 else { return 0 } // páginas sin texto (en blanco, escaneadas): no se emparejan
        let (small, big) = a.count < b.count ? (a, b) : (b, a)
        let common = small.reduce(0) { big.contains($1) ? $0 + 1 : $0 }
        return 2 * Double(common) / Double(a.count + b.count)
    }

    /// Alineación en orden (como un diff) que maximiza el parecido total entre páginas emparejadas.
    private static func align(_ old: [Set<Int>], _ new: [Set<Int>]) -> [(old: Int, new: Int)] {
        let n = old.count, m = new.count, threshold = 0.3
        guard n > 0, m > 0 else { return [] }
        var sim = [Double](repeating: 0, count: n * m)
        for i in 0..<n { for j in 0..<m { sim[i * m + j] = similarity(old[i], new[j]) } }
        var score = [[Double]](repeating: [Double](repeating: 0, count: m + 1), count: n + 1)
        for i in 1...n {
            for j in 1...m {
                var best = max(score[i - 1][j], score[i][j - 1])
                let s = sim[(i - 1) * m + j - 1]
                if s >= threshold { best = max(best, score[i - 1][j - 1] + s) }
                score[i][j] = best
            }
        }
        var pairs: [(old: Int, new: Int)] = []
        var i = n, j = m
        while i > 0, j > 0 {
            let s = sim[(i - 1) * m + j - 1]
            if s >= threshold, score[i][j] == score[i - 1][j - 1] + s {
                pairs.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if score[i][j] == score[i - 1][j] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return pairs.reversed()
    }

    // MARK: Margen de apuntes

    /// Si la página antigua tenía margen para apuntes, la nueva lo conserva con todo lo que hubiera en él.
    private static func keepingMargin(_ fresh: PDFPage, from mine: PDFPage) -> PDFPage? {
        guard mine.rotation == 0, fresh.rotation == 0, let oldRef = mine.pageRef, let newRef = fresh.pageRef else { return nil }
        let oldCrop = mine.bounds(for: .cropBox), newCrop = fresh.bounds(for: .cropBox)
        guard oldCrop.width > newCrop.width * 1.15 else { return nil }
        let area = CGRect(x: oldCrop.minX, y: oldCrop.minY, width: newCrop.width, height: oldCrop.height)
        let page = PageFactory.compose(box: oldRef.getBoxRect(.mediaBox)) { ctx in
            ctx.drawPDFPage(oldRef) // la página antigua con su margen…
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(area) // …tapando el contenido antiguo…
            ctx.saveGState()
            ctx.clip(to: area)
            ctx.translateBy(x: area.minX - newCrop.minX, y: area.maxY - newCrop.maxY)
            ctx.drawPDFPage(newRef) // …y la versión nueva encima, alineada arriba a la izquierda.
            ctx.restoreGState()
        }
        page?.setBounds(oldCrop, for: .cropBox)
        return page
    }
}
