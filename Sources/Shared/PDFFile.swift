import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Un PDF abierto. Los cambios se registran en el UndoManager, que es lo que marca el documento como modificado.
final class PDFFile: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    let pdf: PDFDocument
    /// Lo que se guarda, si el editor lo prepara él (p. ej. con las hojas del cuaderno, que no están en `pdf`).
    @MainActor var export: (() -> Data?)?

    init() {
        pdf = PDFDocument()
        pdf.insert(PDFPage(), at: 0)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let doc = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        pdf = doc
    }

    func snapshot(contentType: UTType) throws -> Data {
        let data = Thread.isMainThread ? MainActor.assumeIsolated { exportData() } : DispatchQueue.main.sync { exportData() }
        guard let data else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    @MainActor private func exportData() -> Data? {
        export?() ?? MovableAnnotation.data(of: pdf)
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
