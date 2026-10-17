import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MDobeApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PDFFile() }) { config in
            DocumentView(file: config.document)
        }
    }
}
