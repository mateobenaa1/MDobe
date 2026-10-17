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
                let data = try await Task.detached { try Self.coordinatedRead(url) }.value
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

    nonisolated static func coordinatedRead(_ url: URL) throws -> Data {
        var coordError: NSError?, result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result { try Data(contentsOf: u) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    nonisolated static func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordError: NSError?, writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try data.write(to: u, options: .atomic) } catch { writeError = error }
        }
        if let error = coordError ?? writeError { throw error }
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
        guard dirty, let data = pdf.dataRepresentation() else { return }
        dirty = false
        status = "Guardando…"
        let url = url
        do {
            try await Task.detached { try PadLibrary.coordinatedWrite(data, to: url) }.value
            status = "Guardado"
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
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            PadRootView(library: library)
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
    @State private var picking = false

    var body: some View {
        NavigationStack {
            Group {
                if let doc = library.current {
                    PadDocumentView(doc: doc)
                        .id(doc.id)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Cerrar", systemImage: "chevron.backward") { library.close() }
                            }
                        }
                } else {
                    home
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

    private var home: some View {
        List {
            Section {
                Button {
                    picking = true
                } label: {
                    Label("Abrir PDF…", systemImage: "folder").font(.title3)
                }
                .disabled(library.opening)
                if library.opening {
                    HStack { ProgressView(); Text("Abriendo (si está en OneDrive, se está descargando)…") }
                }
            } footer: {
                Text("Puedes abrir PDFs de OneDrive, iCloud o del iPad. Los cambios se guardan solos en el mismo archivo.")
            }
            if !library.recents.isEmpty {
                Section("Recientes") {
                    ForEach(library.recents) { r in
                        Button { library.open(r) } label: { Label(r.name, systemImage: "doc.richtext") }
                    }
                }
            }
        }
        .navigationTitle("MDobe")
    }
}
