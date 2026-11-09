import PDFKit
import SwiftUI

// MARK: Cuaderno de apuntes (hojas al lado del PDF, como en el iPad)

extension Editor {
    /// El PDF tal como se guarda: con las hojas del cuaderno detrás de su página.
    func fileData() -> Data? { notes.fileData() }

    /// Muestra las hojas de la página actual del PDF.
    func refreshNotes() {
        let book = notes.book(for: pdfView.currentPage)
        if notesView.document !== book { notesView.document = book }
        notesCount = book?.pageCount ?? 0
        notesPage = currentPageIndex
        notesSheet = book.flatMap { b in notesView.currentPage.map { b.index(for: $0) } } ?? 0
    }

    func flattenNotes() {
        notes.flatten()
        notesView.document = nil
    }

    func flipNotes(by delta: Int) {
        guard let page = notesView.document?.page(at: notesSheet + delta) else { return }
        notesView.go(to: page)
        refreshNotes()
    }

    func addNotesSheet(_ paper: PageFactory.Paper) {
        guard let parent = pdfView.currentPage, let sheet = Notebook.blankSheet(paper, for: parent) else { return }
        attach(sheet, to: parent, at: notes.count(for: parent))
        undoManager?.setActionName("Añadir hoja")
    }

    func deleteNotesSheet() {
        guard let parent = pdfView.currentPage, let sheet = notesView.currentPage else { return }
        detach(sheet, from: parent)
        undoManager?.setActionName("Eliminar hoja")
    }

    private func attach(_ sheet: PDFPage, to parent: PDFPage, at index: Int) {
        notes.insert(sheet, for: parent, at: index)
        refreshNotes()
        if pdfView.currentPage === parent {
            notesView.go(to: sheet)
            refreshNotes()
        }
        undoManager?.registerUndo(withTarget: self) { $0.detach(sheet, from: parent) }
    }

    private func detach(_ sheet: PDFPage, from parent: PDFPage) {
        guard let i = notes.remove(sheet, from: parent) else { return }
        refreshNotes()
        undoManager?.registerUndo(withTarget: self) { $0.attach(sheet, to: parent, at: i) }
    }

    /// Hoja donde poner una imagen o tabla: la que se ve (o una lisa nueva si la página aún no tiene apuntes).
    private func notesTarget() -> (page: PDFPage, center: CGPoint)? {
        if notesView.currentPage == nil { addNotesSheet(.plain) }
        guard let sheet = notesView.currentPage else { return nil }
        if let (page, point) = PageObjects.visibleCenter(in: notesView), page === sheet { return (page, point) }
        let crop = sheet.bounds(for: .cropBox)
        return (sheet, CGPoint(x: crop.midX, y: crop.midY))
    }

    func insertImageInNotes(_ data: Data) {
        showNotes = true
        grouped("Insertar imagen") {
            guard let (page, center) = notesTarget() else { return }
            insertImage(data, on: page, at: center)
        }
    }

    func insertTableInNotes() {
        showNotes = true
        grouped("Insertar tabla") {
            guard let (page, center) = notesTarget() else { return }
            insertTable(on: page, at: center)
        }
    }
}

/// Hojas de apuntes de la página que estás viendo, al lado del PDF.
struct NotesPanel: View {
    let editor: Editor

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button("Hoja anterior", systemImage: "chevron.left") { editor.flipNotes(by: -1) }
                    .disabled(editor.notesSheet == 0)
                Text(editor.notesCount == 0 ? "Apuntes · pág. \(editor.notesPage + 1)"
                     : "Pág. \(editor.notesPage + 1) · hoja \(editor.notesSheet + 1) de \(editor.notesCount)")
                    .font(.subheadline).monospacedDigit()
                Button("Hoja siguiente", systemImage: "chevron.right") { editor.flipNotes(by: 1) }
                    .disabled(editor.notesSheet + 1 >= editor.notesCount)
                Spacer()
                Menu("Insertar en la hoja", systemImage: "photo.badge.plus") {
                    Button("Imagen…") { editor.insertImageFromFile(intoNotes: true) }
                    Button("Pegar imagen copiada") { editor.pasteImage(intoNotes: true) }
                    Divider()
                    Button("Tabla…") { editor.insertTableInNotes() }
                }
                .help("Insertar una imagen o una tabla en esta hoja")
                Menu("Añadir hoja", systemImage: "plus") {
                    ForEach(PageFactory.Paper.allCases, id: \.self) { paper in
                        Button("Hoja \(paper.rawValue)") { editor.addNotesSheet(paper) }
                    }
                }
                .help("Añadir hoja")
                if editor.notesCount > 0 {
                    Button("Eliminar hoja", systemImage: "trash", role: .destructive) { editor.deleteNotesSheet() }
                        .help("Eliminar esta hoja")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.bar)
            Divider()
            ZStack {
                PDFKitView(pdfView: editor.notesView)
                if editor.notesCount == 0 {
                    VStack(spacing: 12) {
                        Image(systemName: "book.pages").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Sin apuntes para esta página").foregroundStyle(.secondary)
                        HStack {
                            ForEach(PageFactory.Paper.allCases, id: \.self) { paper in
                                Button(paper.rawValue.capitalized) { editor.addNotesSheet(paper) }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                }
            }
        }
        .frame(minWidth: 280)
    }
}
