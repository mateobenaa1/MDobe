import Foundation
import Observation
import PDFKit

/// Biblioteca: una carpeta normal (en OneDrive, iCloud Drive, Google Drive…) elegida en cada dispositivo.
/// Los proyectos son subcarpetas y los apuntes van dentro de cada PDF, así que la nube lo sincroniza todo sola.
@MainActor @Observable
final class LibraryModel {
    private(set) var root: URL?
    /// Carpetas abiertas dentro de la biblioteca (se conserva al abrir y cerrar un PDF).
    var path: [URL] = []
    /// Cambia tras cada modificación para que las listas se recarguen.
    private(set) var revision = 0
    var error: String?

    private static let rootKey = "library.root"

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.rootKey) else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { return }
        _ = url.startAccessingSecurityScopedResource() // mientras la app viva (en iOS da acceso a todo lo de dentro)
        // Un PDF elegido por error como biblioteca: se olvida y se vuelve a pedir la carpeta.
        guard Self.isFolder(url) else {
            url.stopAccessingSecurityScopedResource()
            UserDefaults.standard.removeObject(forKey: Self.rootKey)
            return
        }
        root = url
        if stale, let fresh = try? url.bookmarkData() { UserDefaults.standard.set(fresh, forKey: Self.rootKey) }
    }

    func setRoot(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        guard Self.isFolder(url) else {
            if scoped { url.stopAccessingSecurityScopedResource() }
            error = "«\(url.lastPathComponent)» es un archivo, no una carpeta. Elige la carpeta donde guardas tus PDFs (p. ej. «MDobe» en OneDrive)."
            return
        }
        if root != url { root?.stopAccessingSecurityScopedResource() }
        guard let data = try? url.bookmarkData() else {
            error = "No puedo recordar la carpeta «\(url.lastPathComponent)». Prueba con otra."
            return
        }
        UserDefaults.standard.set(data, forKey: Self.rootKey)
        root = url
        path = []
        changed()
    }

    func changed() { revision += 1 }

    private static func isFolder(_ url: URL) -> Bool {
        if let dir = try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory { return dir }
        return url.pathExtension.isEmpty
    }

    func contains(_ url: URL) -> Bool {
        guard let root else { return false }
        return url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/")
    }

    /// Dónde está la biblioteca, p. ej. «OneDrive-UPV › MDobe».
    var rootDescription: String {
        guard let root else { return "" }
        let parts = root.standardizedFileURL.pathComponents
        if let i = parts.firstIndex(of: "CloudStorage"), i + 1 < parts.count, parts[i + 1] != root.lastPathComponent {
            return "\(parts[i + 1]) › \(root.lastPathComponent)"
        }
        return root.lastPathComponent
    }

    /// Ruta legible dentro de la biblioteca, p. ej. «Cálculo / Tema 3».
    func location(of url: URL) -> String {
        guard let root else { return "" }
        let base = root.standardizedFileURL.pathComponents.count
        let parts = url.deletingLastPathComponent().standardizedFileURL.pathComponents.dropFirst(base)
        return parts.isEmpty ? "Biblioteca" : parts.joined(separator: " / ")
    }

    /// Ejecuta una operación de archivos fuera del hilo principal y recarga las listas.
    @discardableResult
    func perform<T: Sendable>(_ what: String, _ op: @escaping @Sendable () throws -> T) async -> T? {
        do {
            let result = try await Task.detached { try op() }.value
            changed()
            return result
        } catch {
            self.error = "\(what): \(error.localizedDescription)"
            changed()
            return nil
        }
    }
}

struct LibraryItem: Identifiable, Hashable, Sendable {
    let url: URL
    let isFolder: Bool
    let modified: Date?
    var id: URL { url }
    var name: String { isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent }
}

/// Operaciones de archivos con coordinación, para que OneDrive/iCloud descarguen y suban lo que toca.
enum LibraryFS {
    enum Sort: String, CaseIterable { case name = "Nombre", date = "Fecha" }

    private static let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]

    static func list(_ folder: URL, sort: Sort) throws -> [LibraryItem] {
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])
        return sorted(urls.compactMap(item), sort)
    }

    /// Busca por nombre (sin distinguir mayúsculas ni tildes) en la carpeta y todas sus subcarpetas.
    static func search(_ query: String, in folder: URL) -> [LibraryItem] {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return [] }
        var found: [LibraryItem] = []
        for case let url as URL in e {
            if url.lastPathComponent.hasPrefix("."), !url.lastPathComponent.hasSuffix(".icloud") {
                e.skipDescendants()
                continue
            }
            guard let it = item(url), it.name.localizedStandardContains(query) else { continue }
            found.append(it)
            if found.count >= 300 { break }
        }
        return sorted(found, .name)
    }

    /// Todas las carpetas de la biblioteca (para «Mover a…»), con su profundidad.
    static func folders(in root: URL) -> [(url: URL, depth: Int)] {
        var out = [(url: root, depth: 0)]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return out }
        for case let url as URL in e where item(url)?.isFolder == true {
            out.append((url, e.level))
        }
        return out.sorted { $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending }
    }

    private static func item(_ url: URL) -> LibraryItem? {
        var url = url
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: Set(keys))
        if name.hasPrefix(".") {
            // iCloud aún sin descargar: «.Tema 1.pdf.icloud». Al abrirlo con coordinación se descarga.
            guard name.hasSuffix(".icloud") else { return nil }
            url = url.deletingLastPathComponent().appendingPathComponent(String(name.dropFirst().dropLast(7)))
        }
        let folder = values?.isDirectory == true && values?.isPackage != true
        guard folder || url.pathExtension.lowercased() == "pdf" else { return nil }
        return LibraryItem(url: url, isFolder: folder, modified: values?.contentModificationDate)
    }

    private static func sorted(_ items: [LibraryItem], _ sort: Sort) -> [LibraryItem] {
        items.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            if sort == .date, !a.isFolder, a.modified != b.modified { return (a.modified ?? .distantPast) > (b.modified ?? .distantPast) }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    // MARK: Lectura y escritura

    static func read(_ url: URL) throws -> Data {
        var coordError: NSError?, result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { u in
            result = Result { try Data(contentsOf: u) }
        }
        if let coordError { throw coordError }
        return try result.get()
    }

    /// `presenter`: quien escribe, para que no reciba el aviso de su propio cambio.
    static func write(_ data: Data, to url: URL, presenter: NSFilePresenter? = nil) throws {
        var coordError: NSError?, writeError: Error?
        NSFileCoordinator(filePresenter: presenter).coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { u in
            do { try data.write(to: u, options: .atomic) } catch { writeError = error }
        }
        if let error = coordError ?? writeError { throw error }
    }

    /// Fecha de modificación actual (sin caché): sirve para saber si otro dispositivo ha cambiado el archivo.
    static func modified(_ url: URL) -> Date? {
        var url = url
        url.removeAllCachedResourceValues()
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// Guarda `data` como «Nombre (sufijo).pdf» junto a `url`, sin pisar nada.
    static func writeCopy(_ data: Data, besides url: URL, suffix: String) throws -> URL {
        let dst = unique("\(url.deletingPathExtension().lastPathComponent) (\(suffix))", ext: url.pathExtension.isEmpty ? nil : url.pathExtension, in: url.deletingLastPathComponent())
        try write(data, to: dst)
        return dst
    }

    // MARK: Organizar

    static func makeFolder(named name: String, in folder: URL) throws -> URL {
        let url = unique(clean(name, fallback: "Carpeta nueva"), ext: nil, in: folder)
        var coordError: NSError?, writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordError) { u in
            do { try FileManager.default.createDirectory(at: u, withIntermediateDirectories: false) } catch { writeError = error }
        }
        if let error = coordError ?? writeError { throw error }
        return url
    }

    /// Cuaderno nuevo: un PDF A4 con una hoja del papel elegido (se añaden más desde el editor).
    static func makeNotebook(named name: String, paper: PageFactory.Paper, in folder: URL) throws -> URL {
        let url = unique(clean(name, fallback: "Cuaderno"), ext: "pdf", in: folder)
        let doc = PDFDocument()
        guard let page = PageFactory.blank(paper, box: CGRect(x: 0, y: 0, width: 595, height: 842)) else { throw CocoaError(.fileWriteUnknown) }
        doc.insert(page, at: 0)
        guard let data = doc.dataRepresentation() else { throw CocoaError(.fileWriteUnknown) }
        try write(data, to: url)
        return url
    }

    /// Copia un PDF de fuera de la biblioteca a una carpeta.
    static func importCopy(_ src: URL, into folder: URL) throws -> URL {
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }
        let dst = unique(src.deletingPathExtension().lastPathComponent, ext: src.pathExtension.isEmpty ? nil : src.pathExtension, in: folder)
        var coordError: NSError?, copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [], writingItemAt: dst, options: .forReplacing, error: &coordError) { s, d in
            do { try FileManager.default.copyItem(at: s, to: d) } catch { copyError = error }
        }
        if let error = coordError ?? copyError { throw error }
        return dst
    }

    static func move(_ src: URL, into folder: URL) throws -> URL {
        let ext = src.hasDirectoryPath || src.pathExtension.isEmpty ? nil : src.pathExtension
        let name = ext == nil ? src.lastPathComponent : src.deletingPathExtension().lastPathComponent
        return try relocate(src, to: unique(name, ext: ext, in: folder))
    }

    static func rename(_ src: URL, to name: String) throws -> URL {
        let isPDF = src.pathExtension.lowercased() == "pdf"
        let base = clean(name, fallback: isPDF ? src.deletingPathExtension().lastPathComponent : src.lastPathComponent)
        return try relocate(src, to: unique(base, ext: isPDF ? src.pathExtension : nil, in: src.deletingLastPathComponent()))
    }

    private static func relocate(_ src: URL, to dst: URL) throws -> URL {
        let c = NSFileCoordinator()
        var coordError: NSError?, moveError: Error?
        c.coordinate(writingItemAt: src, options: .forMoving, writingItemAt: dst, options: .forReplacing, error: &coordError) { s, d in
            c.item(at: s, willMoveTo: d)
            do { try FileManager.default.moveItem(at: s, to: d) } catch { moveError = error }
            c.item(at: s, didMoveTo: d)
        }
        if let error = coordError ?? moveError { throw error }
        return dst
    }

    /// A la papelera si el sistema/proveedor la tiene; si no, se borra (la nube suele guardar una copia en su papelera).
    static func delete(_ url: URL) throws {
        var coordError: NSError?, deleteError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordError) { u in
            do {
                do { try FileManager.default.trashItem(at: u, resultingItemURL: nil) } catch { try FileManager.default.removeItem(at: u) }
            } catch { deleteError = error }
        }
        if let error = coordError ?? deleteError { throw error }
    }

    private static func clean(_ name: String, fallback: String) -> String {
        let s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty || s.hasPrefix(".") ? fallback : s
    }

    /// «Nombre», «Nombre 2», «Nombre 3»… el primero libre en la carpeta.
    private static func unique(_ base: String, ext: String?, in folder: URL) -> URL {
        func make(_ n: Int) -> URL {
            let name = n == 1 ? base : "\(base) \(n)"
            return ext.map { folder.appendingPathComponent(name).appendingPathExtension($0) } ?? folder.appendingPathComponent(name, isDirectory: true)
        }
        var n = 1
        while FileManager.default.fileExists(atPath: make(n).path)
                || FileManager.default.fileExists(atPath: folder.appendingPathComponent("." + make(n).lastPathComponent + ".icloud").path) {
            n += 1
        }
        return make(n)
    }
}
