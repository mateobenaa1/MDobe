import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Un PDF abierto. Los cambios se registran en el UndoManager, que es lo que marca el documento como modificado.
final class PDFFile: ReferenceFileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    let pdf: PDFDocument

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
        guard let data = pdf.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
        return data
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }
}
