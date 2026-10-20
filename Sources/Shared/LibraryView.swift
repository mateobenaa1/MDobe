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
    /// Últimos PDFs abiertos en este dispositivo (para «Seguir leyendo»).
    var recents: [URL] = []
    /// Abrir un PDF de fuera de la biblioteca.
    var openOther: (() -> Void)?

    var body: some View {
        NavigationStack(path: $model.path) {
            Group {
                if let root = model.root {
                    FolderView(model: model, folder: root, open: open, recents: recents, openOther: openOther)
                } else {
                    LibrarySetup(model: model, recents: recents, open: open, openOther: openOther)
                }
            }
            .navigationDestination(for: URL.self) { FolderView(model: model, folder: $0, open: open, recents: [], openOther: nil) }
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

// MARK: Estilo

private enum Palette {
    #if os(macOS)
    static let page = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    #else
    static let page = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    #endif
    private static let tints: [Color] = [.blue, .indigo, .teal, .orange, .pink, .green, .purple, .red, .mint, .cyan]

    /// Color fijo para cada proyecto (sale del nombre, así es el mismo en todos los dispositivos).
    static func tint(for name: String) -> Color {
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return tints[sum % tints.count]
    }
}

private struct Card: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Palette.card, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary.opacity(0.6)))
            .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }
}

private extension View {
    func card() -> some View { modifier(Card()) }
}

private struct SectionTitle: View {
    let title: String
    var trailing: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer()
            if let trailing { Text(trailing).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}

// MARK: Primera vez

private struct LibrarySetup: View {
    let model: LibraryModel
    let recents: [URL]
    let open: (URL) -> Void
    let openOther: (() -> Void)?
    @State private var picking = false

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 14) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(.white)
                        .frame(width: 104, height: 104)
                        .background(LinearGradient(colors: [Color(red: 0.86, green: 0.2, blue: 0.16), Color(red: 0.6, green: 0.08, blue: 0.08)],
                                                   startPoint: .top, endPoint: .bottom), in: .rect(cornerRadius: 26))
                    Text("Bienvenido a MDobe").font(.largeTitle.bold())
                    Text("Tus PDFs y apuntes, iguales en el Mac y en el iPad.")
                        .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 16) {
                    step(1, "Elige una carpeta en la nube", "Por ejemplo «MDobe» dentro de OneDrive (créala si no existe).", "icloud.and.arrow.up")
                    step(2, "Un proyecto por asignatura", "Cada proyecto es una subcarpeta con sus PDFs y cuadernos.", "folder.fill")
                    step(3, "Elige la misma en tus otros dispositivos", "Los apuntes van dentro de cada PDF, así que la nube lo sincroniza todo.", "arrow.triangle.2.circlepath")
                }
                .padding(20)
                .card()
                Button { picking = true } label: {
                    Label("Elegir carpeta de la biblioteca", systemImage: "folder.badge.gearshape")
                        .font(.headline).frame(maxWidth: 360).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                if let openOther {
                    Button("O abre un PDF suelto…", action: openOther).buttonStyle(.borderless)
                }
                if !recents.isEmpty {
                    RecentShelf(model: model, urls: recents, open: open)
                }
            }
            .padding(28)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.page)
        .navigationTitle("MDobe")
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.setRoot(url) }
        }
    }

    private func step(_ n: Int, _ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(n). \(title)").font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Carpeta (y portada en la raíz)

private struct FolderView: View {
    let model: LibraryModel
    let folder: URL
    let open: (URL) -> Void
    let recents: [URL]
    let openOther: (() -> Void)?

    @AppStorage("library.sort") private var sort = LibraryFS.Sort.name
    @AppStorage("library.grid") private var grid = true
    @State private var items: [LibraryItem] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var results: [LibraryItem] = []

    @State private var naming: Naming?
    @State private var nameText = ""
    @State private var moving: LibraryItem?
    @State private var deleting: LibraryItem?
    @State private var importingPDFs = false
    @State private var changingRoot = false

    private enum Naming: Equatable { case folder, notebook(PageFactory.Paper), rename(LibraryItem) }

    private var isRoot: Bool { folder == model.root }
    private var folders: [LibraryItem] { items.filter(\.isFolder) }
    private var documents: [LibraryItem] { items.filter { !$0.isFolder } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                if !query.isEmpty {
                    searchResults
                } else {
                    if isRoot { home }
                    if !folders.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionTitle(title: isRoot ? "Proyectos" : "Carpetas", trailing: "\(folders.count)")
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 14)], spacing: 14) {
                                ForEach(folders) { folderCard($0) }
                            }
                        }
                    }
                    if !documents.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionTitle(title: "Documentos", trailing: "\(documents.count)")
                            documentsView(documents)
                        }
                    }
                    if loaded, items.isEmpty { emptyState }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.page)
        .navigationTitle(isRoot ? "Biblioteca" : folder.lastPathComponent)
        #if os(iOS)
        .navigationBarTitleDisplayMode(isRoot ? .inline : .large)
        #endif
        .searchable(text: $query, prompt: isRoot ? "Buscar en la biblioteca" : "Buscar en esta carpeta")
        .task(id: query) {
            guard !query.isEmpty else { return results = [] }
            try? await Task.sleep(for: .milliseconds(250))
            let q = query, f = folder
            results = await Task.detached { LibraryFS.search(q, in: f) }.value
        }
        .task(id: model.revision) { await reload() }
        .refreshable { await reload() }
        .dropDestination(for: URL.self) { urls, _ in return receive(urls, into: folder) }
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
        // Dos selectores en vistas distintas: uno solo que cambiaba de tipo a veces salía con el de PDFs
        // al pedir la carpeta, y la biblioteca acababa siendo un PDF.
        .fileImporter(isPresented: $importingPDFs, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { _ = receive(urls, into: folder) }
        }
        .background {
            Color.clear.fileImporter(isPresented: $changingRoot, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.setRoot(url) }
            }
        }
    }

    // MARK: Portada

    @ViewBuilder private var home: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(greeting).font(.largeTitle.bold())
            Label(model.rootDescription, systemImage: "icloud")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
            if let openOther {
                QuickAction(title: "Abrir PDF", subtitle: "De cualquier sitio", symbol: "doc.badge.plus", tint: .blue, action: openOther)
            }
            Menu {
                ForEach(PageFactory.Paper.allCases, id: \.self) { paper in
                    Button("Hojas \(paper.rawValue)") { ask(.notebook(paper)) }
                }
            } label: {
                QuickActionLabel(title: "Nuevo cuaderno", subtitle: "Para escribir a mano", symbol: "book.closed.fill", tint: .orange)
            }
            .menuStyle(.button).buttonStyle(.plain)
            .focusEffectDisabled()
            QuickAction(title: "Nuevo proyecto", subtitle: "Una asignatura", symbol: "folder.fill.badge.plus", tint: .green) { ask(.folder) }
            QuickAction(title: "Importar PDFs", subtitle: "A la biblioteca", symbol: "square.and.arrow.down.fill", tint: .purple) { importingPDFs = true }
        }
        if !recents.isEmpty {
            RecentShelf(model: model, urls: recents, open: open)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 6..<14: "Buenos días"
        case 14..<21: "Buenas tardes"
        default: "Buenas noches"
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: isRoot ? "folder.badge.plus" : "tray")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text(isRoot ? "Aún no tienes proyectos" : "Carpeta vacía").font(.title2.bold())
            Text(isRoot ? "Crea un proyecto para cada asignatura y mete ahí sus PDFs. También puedes arrastrar PDFs aquí."
                 : "Añade un cuaderno o importa PDFs. También puedes arrastrarlos aquí.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack {
                if isRoot {
                    Button("Nuevo proyecto", systemImage: "folder.badge.plus") { ask(.folder) }.buttonStyle(.borderedProminent)
                } else {
                    Menu("Nuevo cuaderno", systemImage: "book.closed") {
                        ForEach(PageFactory.Paper.allCases, id: \.self) { paper in
                            Button("Hojas \(paper.rawValue)") { ask(.notebook(paper)) }
                        }
                    }
                    .fixedSize().buttonStyle(.borderedProminent)
                }
                Button("Importar PDFs", systemImage: "square.and.arrow.down") { importingPDFs = true }.buttonStyle(.bordered)
            }
        }
        .padding(36)
        .frame(maxWidth: .infinity)
        .card()
    }

    @ViewBuilder private var searchResults: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: results.isEmpty ? "Sin resultados" : "Resultados", trailing: results.isEmpty ? nil : "\(results.count)")
            if results.isEmpty {
                Text("No hay nada que se llame «\(query)».").foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(results) { item in
                        row(item, showLocation: true)
                        if item.id != results.last?.id { Divider().padding(.leading, 66) }
                    }
                }
                .card()
            }
        }
    }

    // MARK: Tarjetas

    private func folderCard(_ item: LibraryItem) -> some View {
        NavigationLink(value: item.url) {
            FolderCard(item: item)
        }
        .buttonStyle(.plain)
        .dropDestination(for: URL.self) { urls, _ in return receive(urls, into: item.url) }
        .draggable(item.url)
        .contextMenu { menu(for: item) }
    }

    @ViewBuilder private func documentsView(_ docs: [LibraryItem]) -> some View {
        if grid {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 18)], alignment: .leading, spacing: 22) {
                ForEach(docs) { item in
                    Button { open(item.url) } label: { DocumentCard(item: item) }
                        .buttonStyle(.plain)
                        .draggable(item.url)
                        .contextMenu { menu(for: item) }
                }
            }
        } else {
            VStack(spacing: 0) {
                ForEach(docs) { item in
                    row(item)
                    if item.id != docs.last?.id { Divider().padding(.leading, 66) }
                }
            }
            .card()
        }
    }

    private func row(_ item: LibraryItem, showLocation: Bool = false) -> some View {
        let subtitle = showLocation ? model.location(of: item.url) : item.modified?.formatted(.relative(presentation: .named))
        return Group {
            if item.isFolder {
                NavigationLink(value: item.url) {
                    RowContent(item: item, subtitle: subtitle)
                }
            } else {
                Button { open(item.url) } label: { RowContent(item: item, subtitle: subtitle) }
            }
        }
        .buttonStyle(.plain)
        .draggable(item.url)
        .contextMenu { menu(for: item) }
    }

    @ViewBuilder private func menu(for item: LibraryItem) -> some View {
        if !item.isFolder { Button("Abrir", systemImage: "doc.text") { open(item.url) } }
        Button("Renombrar…", systemImage: "pencil") { ask(.rename(item)) }
        Button("Mover a…", systemImage: "folder") { moving = item }
        #if os(macOS)
        Button("Mostrar en Finder", systemImage: "finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        #endif
        Divider()
        Button("Eliminar…", systemImage: "trash", role: .destructive) { deleting = item }
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
                Button("Importar PDFs…", systemImage: "square.and.arrow.down") { importingPDFs = true }
            }
            Menu("Opciones", systemImage: "ellipsis.circle") {
                Picker("Ver documentos como", selection: $grid) {
                    Label("Portadas", systemImage: "square.grid.2x2").tag(true)
                    Label("Lista", systemImage: "list.bullet").tag(false)
                }
                Picker("Ordenar por", selection: $sort) {
                    ForEach(LibraryFS.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                if isRoot {
                    Divider()
                    Button("Cambiar carpeta de la biblioteca…") { changingRoot = true }
                }
            }
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

// MARK: Piezas

private struct QuickActionLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(tint.gradient, in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.8)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 64)
        .contentShape(Rectangle())
        .card()
    }
}

private struct QuickAction: View {
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) { QuickActionLabel(title: title, subtitle: subtitle, symbol: symbol, tint: tint) }
            .buttonStyle(.plain)
            .focusEffectDisabled()
    }
}

/// Fila horizontal con las portadas de los últimos PDFs abiertos.
private struct RecentShelf: View {
    /// «Tema_3_Integrales» → «Tema 3 Integrales» (solo para mostrar).
    static func pretty(_ name: String) -> String { name.replacingOccurrences(of: "_", with: " ") }
    let model: LibraryModel
    let urls: [URL]
    let open: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Seguir leyendo")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(urls, id: \.self) { url in
                        Button { open(url) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                PDFThumb(url: url, modified: nil, size: CGSize(width: 116, height: 150))
                                Text(Self.pretty(url.deletingPathExtension().lastPathComponent))
                                    .font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                                Text(model.contains(url) ? model.location(of: url) : url.deletingLastPathComponent().lastPathComponent)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(width: 128, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

private struct FolderCard: View {
    let item: LibraryItem
    @State private var count: Int?

    var body: some View {
        let tint = Palette.tint(for: item.name)
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title)
                .foregroundStyle(tint.gradient)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.headline).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                Text(countText).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .background(alignment: .topTrailing) {
            Circle().fill(tint.opacity(0.12)).frame(width: 90, height: 90).offset(x: 30, y: -30)
        }
        .clipShape(.rect(cornerRadius: 14))
        .contentShape(Rectangle())
        .card()
        .task(id: item.modified) {
            let url = item.url
            count = await Task.detached { (try? LibraryFS.list(url, sort: .name))?.filter { !$0.isFolder }.count }.value
        }
    }

    private var countText: String {
        guard let count else { return " " }
        return count == 1 ? "1 documento" : "\(count) documentos"
    }
}

private struct DocumentCard: View {
    let item: LibraryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PDFThumb(url: item.url, modified: item.modified, size: CGSize(width: 150, height: 194))
                .frame(maxWidth: .infinity)
            Text(RecentShelf.pretty(item.name)).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
            if let date = item.modified {
                Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct RowContent: View {
    let item: LibraryItem
    let subtitle: String?

    var body: some View {
        HStack(spacing: 14) {
            if item.isFolder {
                Image(systemName: "folder.fill").font(.title2).foregroundStyle(Palette.tint(for: item.name).gradient)
                    .frame(width: 38, height: 48)
            } else {
                PDFThumb(url: item.url, modified: item.modified, size: CGSize(width: 38, height: 48))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(RecentShelf.pretty(item.name)).lineLimit(2).foregroundStyle(.primary)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if item.isFolder { Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

/// Miniatura de la primera página (si el archivo aún está solo en la nube, el proveedor da la suya o se ve un icono).
private struct PDFThumb: View {
    let url: URL
    let modified: Date?
    let size: CGSize
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: scale).resizable().scaledToFit()
                    .clipShape(.rect(cornerRadius: size.width > 60 ? 6 : 3))
                    .overlay(RoundedRectangle(cornerRadius: size.width > 60 ? 6 : 3).strokeBorder(.quaternary))
                    .shadow(color: .black.opacity(size.width > 60 ? 0.15 : 0), radius: 5, y: 3)
            } else {
                RoundedRectangle(cornerRadius: size.width > 60 ? 6 : 3)
                    .fill(.quaternary.opacity(0.5))
                    .overlay(Image(systemName: "doc.richtext").font(size.width > 60 ? .largeTitle : .title3).foregroundStyle(.secondary))
            }
        }
        .frame(width: size.width, height: size.height)
        .task(id: modified) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
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
