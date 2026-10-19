import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Biblioteca con proyectos (carpetas), cuadernos y PDFs. La misma en el Mac y en el iPad.
struct LibraryView: View {
    @Bindable var model: LibraryModel
    let open: (URL) -> Void
    /// Lo que va arriba del todo en la raíz (recientes, abrir de fuera…).
    var header: AnyView = AnyView(EmptyView())

    var body: some View {
        NavigationStack(path: $model.path) {
            Group {
                if let root = model.root {
                    FolderView(model: model, folder: root, open: open, header: header)
                } else {
                    LibrarySetup(model: model, header: header)
                }
            }
            .navigationDestination(for: URL.self) { FolderView(model: model, folder: $0, open: open, header: AnyView(EmptyView())) }
        }
        // Al volver a la app, lo que haya llegado de la nube desde otros dispositivos.
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.changed() }
        #else
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.changed() }
        #endif
        .alert("MDobe", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
    }
}

private struct LibrarySetup: View {
    let model: LibraryModel
    let header: AnyView
    @State private var picking = false

    var body: some View {
        List {
            header
            Section {
                Button { picking = true } label: {
                    Label("Elegir carpeta de la biblioteca…", systemImage: "folder.badge.gearshape").font(.title3)
                }
            } header: {
                Text("Biblioteca")
            } footer: {
                Text("Elige o crea una carpeta «MDobe» en OneDrive, iCloud Drive o Google Drive. Cada proyecto será una subcarpeta y los apuntes van dentro de cada PDF, así que la nube lo sincroniza todo. En tus otros dispositivos elige la misma carpeta.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("MDobe")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.setRoot(url) }
        }
    }
}

private struct FolderView: View {
    let model: LibraryModel
    let folder: URL
    let open: (URL) -> Void
    let header: AnyView

    @AppStorage("library.sort") private var sort = LibraryFS.Sort.name
    @State private var items: [LibraryItem] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var results: [LibraryItem] = []

    @State private var naming: Naming?
    @State private var nameText = ""
    @State private var moving: LibraryItem?
    @State private var deleting: LibraryItem?
    @State private var picker: FilePick?

    private enum Naming: Equatable { case folder, notebook(PageFactory.Paper), rename(LibraryItem) }
    private enum FilePick { case importPDFs, changeRoot }

    private var isRoot: Bool { folder == model.root }
    private var folders: [LibraryItem] { items.filter(\.isFolder) }
    private var documents: [LibraryItem] { items.filter { !$0.isFolder } }

    var body: some View {
        List {
            if !query.isEmpty {
                Section(results.isEmpty ? "Sin resultados" : "Resultados") {
                    ForEach(results) { row($0, showLocation: true) }
                }
            } else {
                if isRoot { header }
                if !folders.isEmpty {
                    Section(isRoot ? "Proyectos" : "Carpetas") { ForEach(folders) { row($0) } }
                }
                if !documents.isEmpty {
                    Section("Documentos") { ForEach(documents) { row($0) } }
                }
                if loaded, items.isEmpty {
                    Section {
                        Text(isRoot ? "Crea tu primer proyecto con el botón +." : "Carpeta vacía. Añade un cuaderno o importa PDFs con el botón +.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(isRoot ? "MDobe" : folder.lastPathComponent)
        .searchable(text: $query, prompt: isRoot ? "Buscar en la biblioteca" : "Buscar en esta carpeta")
        .task(id: query) {
            guard !query.isEmpty else { return results = [] }
            try? await Task.sleep(for: .milliseconds(250))
            let q = query, f = folder
            results = await Task.detached { LibraryFS.search(q, in: f) }.value
        }
        .task(id: model.revision) { await reload() }
        .refreshable { await reload() }
        .dropDestination(for: URL.self) { urls, _ in receive(urls, into: folder) }
        .toolbar { toolbar }
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Nombre", text: $nameText)
            Button(namingAction) { commitName() }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog("¿Eliminar «\(deleting?.name ?? "")»?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Eliminar", role: .destructive) {
                guard let item = deleting else { return }
                Task { await model.perform("No se pudo eliminar") { try LibraryFS.delete(item.url) } }
            }
        } message: {
            Text(deleting?.isFolder == true ? "Se elimina la carpeta con todo lo que contiene, en todos tus dispositivos." : "Se elimina en todos tus dispositivos.")
        }
        .sheet(item: $moving) { item in MoveSheet(model: model, item: item) }
        .fileImporter(isPresented: Binding(get: { picker != nil }, set: { if !$0 { picker = nil } }),
                      allowedContentTypes: picker == .changeRoot ? [.folder] : [.pdf],
                      allowsMultipleSelection: picker == .importPDFs) { result in
            guard case .success(let urls) = result else { return }
            if picker == .changeRoot, let url = urls.first { model.setRoot(url) } else { _ = receive(urls, into: folder) }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu("Añadir", systemImage: "plus") {
                Button("Nuevo proyecto o carpeta", systemImage: "folder.badge.plus") { ask(.folder) }
                Menu("Nuevo cuaderno", systemImage: "book.closed") {
                    ForEach(PageFactory.Paper.allCases, id: \.self) { paper in
                        Button("Hojas \(paper.rawValue)") { ask(.notebook(paper)) }
                    }
                }
                Button("Importar PDFs…", systemImage: "square.and.arrow.down") { picker = .importPDFs }
            }
            Menu("Opciones", systemImage: "ellipsis.circle") {
                Picker("Ordenar por", selection: $sort) {
                    ForEach(LibraryFS.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if isRoot {
                    Divider()
                    Button("Cambiar carpeta de la biblioteca…") { picker = .changeRoot }
                }
            }
        }
    }

    private func row(_ item: LibraryItem, showLocation: Bool = false) -> some View {
        Group {
            if item.isFolder {
                NavigationLink(value: item.url) {
                    Label {
                        LibraryRowText(title: item.name, subtitle: showLocation ? model.location(of: item.url) : nil)
                    } icon: {
                        Image(systemName: "folder.fill").foregroundStyle(.tint)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in receive(urls, into: item.url) }
            } else {
                Button { open(item.url) } label: {
                    HStack(spacing: 12) {
                        PDFThumb(url: item.url, modified: item.modified)
                        LibraryRowText(title: item.name,
                                       subtitle: showLocation ? model.location(of: item.url) : item.modified?.formatted(.relative(presentation: .named)))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .draggable(item.url)
        .contextMenu {
            if !item.isFolder { Button("Abrir", systemImage: "doc.text") { open(item.url) } }
            Button("Renombrar…", systemImage: "pencil") { ask(.rename(item)) }
            Button("Mover a…", systemImage: "folder") { moving = item }
            #if os(macOS)
            Button("Mostrar en Finder", systemImage: "finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            #endif
            Divider()
            Button("Eliminar…", systemImage: "trash", role: .destructive) { deleting = item }
        }
    }

    private func reload() async {
        let f = folder, s = sort
        do {
            items = try await Task.detached { try LibraryFS.list(f, sort: s) }.value
        } catch {
            items = []
            model.error = "No puedo leer «\(f.lastPathComponent)»: \(error.localizedDescription)"
        }
        loaded = true
    }

    /// Lo de dentro de la biblioteca se mueve; lo de fuera (Finder, Archivos) se copia.
    private func receive(_ urls: [URL], into target: URL) -> Bool {
        let inside = urls.filter { model.contains($0) && $0.deletingLastPathComponent().standardizedFileURL != target.standardizedFileURL
                                   && !target.standardizedFileURL.path.hasPrefix($0.standardizedFileURL.path + "/") }
        let outside = urls.filter { !model.contains($0) && $0.pathExtension.lowercased() == "pdf" }
        guard !inside.isEmpty || !outside.isEmpty else { return false }
        Task {
            await model.perform("No se pudo mover") {
                for url in inside { _ = try LibraryFS.move(url, into: target) }
                for url in outside { _ = try LibraryFS.importCopy(url, into: target) }
            }
        }
        return true
    }

    // MARK: Nombres

    private func ask(_ what: Naming) {
        if case .rename(let item) = what { nameText = item.name } else { nameText = "" }
        naming = what
    }

    private var namingTitle: String {
        switch naming {
        case .folder: "Nuevo proyecto o carpeta"
        case .notebook: "Nuevo cuaderno"
        case .rename: "Renombrar"
        case nil: ""
        }
    }

    private var namingAction: String {
        if case .rename = naming { return "Renombrar" }
        return "Crear"
    }

    private func commitName() {
        let name = nameText, f = folder
        switch naming {
        case .folder:
            Task { await model.perform("No se pudo crear la carpeta") { try LibraryFS.makeFolder(named: name, in: f) } }
        case .notebook(let paper):
            Task {
                if let url = await model.perform("No se pudo crear el cuaderno", { try LibraryFS.makeNotebook(named: name, paper: paper, in: f) }) {
                    open(url)
                }
            }
        case .rename(let item):
            Task { await model.perform("No se pudo renombrar") { try LibraryFS.rename(item.url, to: name) } }
        case nil: break
        }
        naming = nil
    }
}

private struct LibraryRowText: View {
    let title: String
    let subtitle: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(2)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

/// Miniatura de la primera página (si el archivo aún está solo en la nube, el proveedor da la suya o se ve un icono).
private struct PDFThumb: View {
    let url: URL
    let modified: Date?
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: scale).resizable().scaledToFit()
                    .clipShape(.rect(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.quaternary))
            } else {
                Image(systemName: "doc.richtext").font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 46)
        .task(id: modified) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 36, height: 46), scale: scale, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
        }
    }
}

private struct MoveSheet: View {
    let model: LibraryModel
    let item: LibraryItem
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [(url: URL, depth: Int)] = []

    var body: some View {
        NavigationStack {
            List(folders, id: \.url) { f in
                Button {
                    let src = item.url
                    Task { await model.perform("No se pudo mover") { try LibraryFS.move(src, into: f.url) } }
                    dismiss()
                } label: {
                    Label(f.depth == 0 ? "Biblioteca (raíz)" : f.url.lastPathComponent, systemImage: f.depth == 0 ? "books.vertical" : "folder")
                        .padding(.leading, CGFloat(max(f.depth - 1, 0)) * 18)
                }
                .disabled(!allowed(f.url))
            }
            .navigationTitle("Mover «\(item.name)»")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { dismiss() } } }
            .task {
                guard let root = model.root else { return }
                folders = await Task.detached { LibraryFS.folders(in: root) }.value
            }
        }
        .frame(minWidth: 360, minHeight: 420)
    }

    /// No a su propia carpeta, ni una carpeta dentro de sí misma.
    private func allowed(_ target: URL) -> Bool {
        let t = target.standardizedFileURL.path, src = item.url.standardizedFileURL.path
        return target.standardizedFileURL != item.url.deletingLastPathComponent().standardizedFileURL
            && t != src && !t.hasPrefix(src + "/")
    }
}
