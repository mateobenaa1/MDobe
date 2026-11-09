import PDFKit

/// Cuaderno de apuntes: las hojas de cada página del PDF, que se ven al lado de ella.
/// En el archivo van justo detrás de su página (marcadas, ver `isNotesSheet`); al abrir se sacan del documento
/// y cada página tiene su propio documento de hojas. Al guardar se vuelven a meter detrás de su página.
@MainActor
final class Notebook {
    let document: PDFDocument
    private var books: [PDFPage: PDFDocument] = [:]

    init(document: PDFDocument) {
        self.document = document
        extract()
    }

    func book(for page: PDFPage?) -> PDFDocument? { page.flatMap { books[$0] } }
    func count(for page: PDFPage?) -> Int { book(for: page)?.pageCount ?? 0 }
    var allBooks: [PDFDocument] { Array(books.values) }

    /// Saca del documento las hojas del cuaderno (van detrás de su página) y las agrupa por página.
    func extract() {
        var parent: PDFPage?
        var i = 0
        while i < document.pageCount {
            guard let page = document.page(at: i) else { i += 1; continue }
            if let parent, page.isNotesSheet {
                document.removePage(at: i)
                let book = books[parent] ?? PDFDocument()
                book.insert(page, at: book.pageCount)
                books[parent] = book
            } else {
                parent = page
                i += 1
            }
        }
    }

    /// Vuelve a meter las hojas en el documento, detrás de su página (p. ej. para cambiar de versión del PDF).
    func flatten() {
        for (parent, book) in books {
            let i = document.index(for: parent)
            guard i >= 0, i < document.pageCount else { continue }
            let sheets = (0..<book.pageCount).compactMap { book.page(at: $0) }
            while book.pageCount > 0 { book.removePage(at: 0) }
            for (k, sheet) in sheets.enumerated() { document.insert(sheet, at: i + 1 + k) }
        }
        books = [:]
    }

    /// Si una página se sustituye por otra (margen, OCR, bloque…), sus hojas pasan a la nueva.
    func move(from old: PDFPage, to new: PDFPage) {
        guard old !== new, let book = books.removeValue(forKey: old) else { return }
        books[new] = book
    }

    func insert(_ sheet: PDFPage, for parent: PDFPage, at index: Int) {
        let book = books[parent] ?? PDFDocument()
        books[parent] = book
        book.insert(sheet, at: min(index, book.pageCount))
    }

    /// Devuelve dónde estaba la hoja (para deshacer), o nil si no estaba.
    func remove(_ sheet: PDFPage, from parent: PDFPage) -> Int? {
        guard let book = books[parent] else { return nil }
        let i = book.index(for: sheet)
        guard i >= 0, i < book.pageCount else { return nil }
        book.removePage(at: i)
        if book.pageCount == 0 { books[parent] = nil }
        return i
    }

    /// El PDF tal como se guarda: con las hojas detrás de su página (sin tocar lo que se ve).
    func fileData() -> Data? {
        MovableAnnotation.exporting = true
        defer { MovableAnnotation.exporting = false }
        guard let data = document.dataRepresentation() else { return nil }
        let placed = books.compactMap { parent, book -> (index: Int, book: PDFDocument)? in
            let i = document.index(for: parent)
            return i >= 0 && i < document.pageCount && book.pageCount > 0 ? (i, book) : nil
        }
        guard !placed.isEmpty, let out = PDFDocument(data: data) else { return data }
        for (i, book) in placed.sorted(by: { $0.index > $1.index }) {
            guard let copy = book.dataRepresentation().flatMap({ PDFDocument(data: $0) }) else { continue }
            let sheets = (0..<copy.pageCount).compactMap { copy.page(at: $0) }
            while copy.pageCount > 0 { copy.removePage(at: 0) }
            for (k, sheet) in sheets.enumerated() { out.insert(sheet, at: i + 1 + k) }
        }
        return out.dataRepresentation()
    }

    /// Hoja nueva del tamaño de su página (girada si la página lo está).
    static func blankSheet(_ paper: PageFactory.Paper, for parent: PDFPage) -> PDFPage? {
        var size = parent.bounds(for: .cropBox).size
        if parent.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
        guard let sheet = PageFactory.blank(paper, box: CGRect(origin: .zero, size: size)) else { return nil }
        sheet.markAsNotesSheet()
        return sheet
    }
}
