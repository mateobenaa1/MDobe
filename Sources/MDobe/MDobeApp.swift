import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MDobeApp: App {
    @State private var shelf = LibraryModel()

    var body: some Scene {
        // Primera escena: es la ventana que se abre al lanzar la app.
        Window("Biblioteca", id: "library") {
            MacLibrary(shelf: shelf)
        }
        .defaultSize(width: 760, height: 580)
        .commands { LibraryCommands() }

        DocumentGroup(newDocument: { PDFFile() }) { config in
            DocumentView(file: config.document)
        }
    }
}

private struct MacLibrary: View {
    let shelf: LibraryModel
    @Environment(\.openDocument) private var openDocument

    var body: some View {
        LibraryView(model: shelf, open: open, header: AnyView(recents))
    }

    private func open(_ url: URL) {
        Task {
            do { try await openDocument(at: url) } catch { shelf.error = "No se pudo abrir «\(url.lastPathComponent)»: \(error.localizedDescription)" }
        }
    }

    @ViewBuilder private var recents: some View {
        let urls = NSDocumentController.shared.recentDocumentURLs.prefix(5)
        if !urls.isEmpty {
            Section("Recientes") {
                ForEach(Array(urls), id: \.self) { url in
                    Button { open(url) } label: { Label(url.deletingPathExtension().lastPathComponent, systemImage: "clock") }
                        .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct LibraryCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Biblioteca") { openWindow(id: "library") }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
    }
}
