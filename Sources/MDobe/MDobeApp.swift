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
                .documentTabs()
        }
    }
}

private struct MacLibrary: View {
    let shelf: LibraryModel
    @Environment(\.openDocument) private var openDocument

    var body: some View {
        LibraryView(model: shelf, open: open, recents: recents, openOther: openOther)
            .onAppear { recents = Array(NSDocumentController.shared.recentDocumentURLs.prefix(8)) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                recents = Array(NSDocumentController.shared.recentDocumentURLs.prefix(8))
            }
    }

    @State private var recents: [URL] = []

    private func openOther() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "Elige el PDF que quieres abrir"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    private func open(_ url: URL) {
        Task {
            do { try await openDocument(at: url) } catch { shelf.error = "No se pudo abrir «\(url.lastPathComponent)»: \(error.localizedDescription)" }
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
