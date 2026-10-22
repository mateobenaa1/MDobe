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
                show(OpenDoc(url: url, pdf: pdf, scoped: scoped))
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

    private func show(_ doc: OpenDoc) {
        doc.reload = { [weak self, weak doc] in if let doc { self?.reload(doc) } }
        current = doc
    }

    /// Cambia el documento abierto por la versión que hay ahora en el archivo (la de otro dispositivo).
    private func reload(_ doc: OpenDoc) {
        guard current === doc else { return }
        let url = doc.url
        Task {
            do {
                let data = try await Task.detached { try LibraryFS.read(url) }.value
                guard current === doc, let pdf = PDFDocument(data: data) else { return }
                let note = doc.status?.hasPrefix("Tus cambios") == true ? doc.status : "Actualizado con los cambios de otro dispositivo"
                show(OpenDoc(url: url, pdf: pdf, scoped: doc.handOff(), status: note, startPage: doc.currentPage?() ?? 0))
            } catch {
                self.error = "No se pudo recargar «\(url.lastPathComponent)»: \(error.localizedDescription)"
            }
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
/// Vigila el archivo: si otro dispositivo lo cambia (OneDrive baja una versión nueva), se recarga en vez de pisarlo.
@MainActor @Observable
final class OpenDoc: Identifiable {
    let id = UUID()
    let url: URL
    let pdf: PDFDocument
    @ObservationIgnored let undoManager = UndoManager()
    private(set) var status: String?
    /// Otro dispositivo cambió el archivo mientras aquí había cambios sin guardar: hay que elegir qué versión queda.
    private(set) var conflict = false
    @ObservationIgnored private var scoped: Bool
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var saving = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// Fecha del archivo la última vez que lo leímos o escribimos nosotros.
    @ObservationIgnored private var known: Date?
    @ObservationIgnored private var watcher: FileWatcher?
    /// Lo que se escribe en el archivo (el editor añade las hojas del cuaderno). Sin él, el PDF tal cual.
    @ObservationIgnored var export: (() -> Data?)?
    /// Vuelve a abrir el archivo desde disco (lo pone la biblioteca).
    @ObservationIgnored var reload: (() -> Void)?
    /// Página que se está viendo (la pone el editor), para que al recargar se siga en ella.
    @ObservationIgnored var currentPage: (() -> Int)?
    /// Página en la que abrir (0 = primera).
    let startPage: Int
    /// Observadores de NotificationCenter (con bloque): se quitan al liberar el objeto.
    @ObservationIgnored nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    var name: String { url.deletingPathExtension().lastPathComponent }

    init(url: URL, pdf: PDFDocument, scoped: Bool, status: String? = nil, startPage: Int = 0) {
        self.url = url
        self.pdf = pdf
        self.startPage = startPage
        self.scoped = scoped
        self.status = status
        known = LibraryFS.modified(url)
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.changed() }
            })
        }
        let watcher = FileWatcher(url: url) { [weak self] in self?.checkForChanges() }
        NSFileCoordinator.addFilePresenter(watcher)
        self.watcher = watcher
        if status != nil { clearStatus(after: 3) }
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
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

    /// ¿Ha cambiado el archivo por fuera? Sin cambios propios pendientes se recarga; con ellos, se pregunta.
    func checkForChanges() {
        guard !saving, !conflict, let date = LibraryFS.modified(url), date != known else { return }
        if dirty {
            saveTask?.cancel()
            conflict = true
        } else {
            reload?()
        }
    }

    func save() async {
        guard dirty, !conflict, !saving else { return }
        if let date = LibraryFS.modified(url), date != known {
            conflict = true
            return
        }
        guard let data = export?() ?? pdf.dataRepresentation() else { return }
        dirty = false
        saving = true
        status = "Guardando…"
        let url = url, watcher = watcher
        do {
            try await Task.detached { try LibraryFS.write(data, to: url, presenter: watcher) }.value
            known = LibraryFS.modified(url)
            saving = false
            status = "Guardado"
            clearStatus(after: 2)
        } catch {
            saving = false
            dirty = true
            status = "No se pudo guardar: \(error.localizedDescription)"
        }
    }

    // MARK: Conflicto con otro dispositivo

    /// Descarta lo de aquí y abre la versión del otro dispositivo.
    func useTheirs() {
        dirty = false
        conflict = false
        reload?()
    }

    /// Guarda lo de aquí en «Nombre (iPad).pdf» y abre la versión del otro dispositivo: no se pierde nada.
    func keepBoth() async {
        guard let data = export?() ?? pdf.dataRepresentation() else { return useTheirs() }
        let url = url
        do {
            let copy = try await Task.detached { try LibraryFS.writeCopy(data, besides: url, suffix: "iPad") }.value
            dirty = false
            conflict = false
            reload?()
            status = "Tus cambios están en «\(copy.lastPathComponent)»"
        } catch {
            status = "No se pudo guardar la copia: \(error.localizedDescription)"
        }
    }

    /// Sobrescribe la versión del otro dispositivo con la de aquí.
    func keepMine() async {
        conflict = false
        known = LibraryFS.modified(url)
        dirty = true
        await save()
    }

    private func clearStatus(after seconds: Double) {
        let shown = status
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if status == shown { status = nil }
        }
    }

    /// Deja de vigilar y cede el acceso al archivo a la versión recargada (sin guardar nada).
    func handOff() -> Bool {
        saveTask?.cancel()
        stopWatching()
        defer { scoped = false }
        return scoped
    }

    func close() async {
        saveTask?.cancel()
        if !conflict { await save() }
        stopWatching()
        if scoped { url.stopAccessingSecurityScopedResource() }
    }

    private func stopWatching() {
        if let watcher { NSFileCoordinator.removeFilePresenter(watcher) }
        watcher = nil
    }
}

/// Avisa cuando otro proceso cambia el archivo (p. ej. el proveedor de la nube al bajar una versión nueva).
final class FileWatcher: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue.main
    private let changed: @MainActor () -> Void

    init(url: URL, changed: @escaping @MainActor () -> Void) {
        presentedItemURL = url
        self.changed = changed
    }

    func presentedItemDidChange() {
        MainActor.assumeIsolated { changed() }
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
                    guard let doc = library.current else { return }
                    // Al volver a la app se mira si el PDF ha cambiado en otro dispositivo mientras tanto.
                    if phase == .active { doc.checkForChanges() } else { Task { await doc.save() } }
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
