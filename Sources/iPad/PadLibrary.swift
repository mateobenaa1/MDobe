import Observation
import PDFKit
import SwiftUI

/// Apertura y guardado de PDFs en su sitio (OneDrive, iCloud, En mi iPad…) sin el explorador de documentos de SwiftUI,
/// que con OneDrive no llega a abrir los archivos. Usa coordinación de archivos para que el proveedor descargue y suba.
@MainActor @Observable
final class PadLibrary {
    struct Recent: Codable, Identifiable {
        var id: String { name + bookmark.base64EncodedString().suffix(16) }
        let name: String
        let bookmark: Data
    }

    private(set) var current: OpenDoc?
    private(set) var recents: [Recent] = []
    private(set) var opening = false
    var error: String?

    private static let recentsKey = "pad.recents"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.recentsKey),
           let list = try? JSONDecoder().decode([Recent].self, from: data) { recents = list }
    }

    func open(_ url: URL) {
        guard !opening else { return }
        opening = true
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { opening = false }
            do {
                let data = try await Task.detached { try LibraryFS.read(url) }.value
                guard let pdf = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
                await current?.close()
                current = OpenDoc(url: url, pdf: pdf, scoped: scoped)
                remember(url)
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                self.error = "No se pudo abrir «\(url.lastPathComponent)»: \(error.localizedDescription)"
            }
        }
    }

    func open(_ recent: Recent) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: recent.bookmark, bookmarkDataIsStale: &stale) else {
            recents.removeAll { $0.id == recent.id }
            saveRecents()
            error = "Ya no encuentro «\(recent.name)». Ábrelo de nuevo con «Abrir PDF»."
            return
        }
        open(url)
    }

    /// Recientes que aún se encuentran (para «Seguir leyendo»).
    var recentURLs: [URL] {
        recents.prefix(8).compactMap { r in
            var stale = false
            return try? URL(resolvingBookmarkData: r.bookmark, bookmarkDataIsStale: &stale)
        }
    }

    func close() {
        guard let doc = current else { return }
        current = nil
        Task { await doc.close() }
    }

    private func remember(_ url: URL) {
        guard let bookmark = try? url.bookmarkData() else { return }
        recents.removeAll { $0.name == url.lastPathComponent }
        recents.insert(Recent(name: url.lastPathComponent, bookmark: bookmark), at: 0)
        recents = Array(recents.prefix(12))
        saveRecents()
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: Self.recentsKey) }
    }
}

/// Un PDF abierto. Cada cambio que se registra en su UndoManager programa un guardado automático.
@MainActor @Observable
final class OpenDoc: Identifiable {
    let id = UUID()
    let url: URL
    let pdf: PDFDocument
    @ObservationIgnored let undoManager = UndoManager()
    private(set) var status: String?
    @ObservationIgnored private let scoped: Bool
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Lo que se escribe en el archivo (el editor añade las hojas del cuaderno). Sin él, el PDF tal cual.
    @ObservationIgnored var export: (() -> Data?)?

    var name: String { url.deletingPathExtension().lastPathComponent }

    init(url: URL, pdf: PDFDocument, scoped: Bool) {
        self.url = url
        self.pdf = pdf
        self.scoped = scoped
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            }
        }
    }

    private func changed() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    func save() async {
        guard dirty, let data = export?() ?? pdf.dataRepresentation() else { return }
        dirty = false
        status = "Guardando…"
        let url = url
        do {
            try await Task.detached { try LibraryFS.write(data, to: url) }.value
            status = "Guardado"
            try? await Task.sleep(for: .seconds(2))
            if status == "Guardado" { status = nil }
        } catch {
            dirty = true
            status = "No se pudo guardar: \(error.localizedDescription)"
        }
    }

    func close() async {
        saveTask?.cancel()
        await save()
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}

// MARK: Pantallas

@main
struct MDobePadApp: App {
    @State private var library = PadLibrary()
    @State private var shelf = LibraryModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            PadRootView(library: library, shelf: shelf)
                .onOpenURL { library.open($0) } // «Abrir con MDobe» desde Archivos u OneDrive
                #if DEBUG
                .task { if let path = ProcessInfo.processInfo.environment["MDOBE_OPEN"] { library.open(URL(fileURLWithPath: path)) } }
                #endif
                .onChange(of: phase) {
                    if phase != .active, let doc = library.current { Task { await doc.save() } }
                }
        }
    }
}

struct PadRootView: View {
    @Bindable var library: PadLibrary
    let shelf: LibraryModel
    @State private var picking = false

    var body: some View {
        Group {
            if let doc = library.current {
                NavigationStack {
                    PadDocumentView(doc: doc)
                        .id(doc.id)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Cerrar", systemImage: "chevron.backward") {
                                    library.close()
                                    shelf.changed()
                                }
                            }
                        }
                }
            } else {
                LibraryView(model: shelf, open: { library.open($0) }, recents: library.recentURLs, openOther: { picking = true })
                    .overlay(alignment: .bottom) {
                        if library.opening {
                            HStack(spacing: 10) {
                                ProgressView()
                                Text("Abriendo… (si está en la nube, se está descargando)")
                            }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                            .padding()
                        }
                    }
            }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { library.open(url) }
        }
        .alert("MDobe", isPresented: Binding(get: { library.error != nil }, set: { if !$0 { library.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(library.error ?? "")
        }
    }
}
