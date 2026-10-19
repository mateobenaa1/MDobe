import Observation
import PDFKit
import SwiftUI

struct PadDocumentView: View {
    let doc: OpenDoc
    @State private var editor: PadEditor
    @State private var assistant: PadAssistant
    @State private var showAI = false
    @AppStorage("pad.showThumbs") private var showThumbs = false
    @State private var newText = ""
    @State private var pickingNewVersion = false
    @State private var updateReport: String?

    private var undoManager: UndoManager { doc.undoManager }

    init(doc: OpenDoc) {
        self.doc = doc
        let editor = PadEditor(document: doc.pdf)
        editor.undoManager = doc.undoManager
        doc.export = { [weak editor] in editor?.fileData() }
        _editor = State(initialValue: editor)
        _assistant = State(initialValue: PadAssistant(editor: editor))
    }

    var body: some View {
        @Bindable var editor = editor
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PDFRepresentable(view: editor.pdfView)
                if editor.showNotes {
                    Divider()
                    NotesPanel(editor: editor)
                }
            }
            .ignoresSafeArea(edges: editor.immersive ? .all : [])
            if showThumbs, !editor.immersive {
                ThumbnailStrip(pdfView: editor.pdfView).frame(height: 92)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Modo", selection: $editor.mode) {
                    ForEach(PadMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if editor.hasSelection {
                    Button("Resaltar", systemImage: "highlighter") { editor.highlightSelection() }
                }
                Button("Deshacer", systemImage: "arrow.uturn.backward") { undoManager.undo() }
                Button("Rehacer", systemImage: "arrow.uturn.forward") { undoManager.redo() }
                Menu("Páginas", systemImage: "doc.on.doc") {
                    ForEach(PageFactory.Paper.allCases, id: \.self) { paper in
                        Button("Página en blanco: \(paper.rawValue)") { editor.insertBlankPage(paper) }
                    }
                    Divider()
                    Menu("Margen para apuntes en esta página") {
                        ForEach(PageFactory.Paper.allCases, id: \.self) { paper in
                            Button(paper.rawValue.capitalized) { editor.addNotesMargin(paper, allPages: false) }
                        }
                    }
                    Menu("Margen para apuntes en todas las páginas") {
                        ForEach(PageFactory.Paper.allCases, id: \.self) { paper in
                            Button(paper.rawValue.capitalized) { editor.addNotesMargin(paper, allPages: true) }
                        }
                    }
                    Divider()
                    Button("Actualizar a una nueva versión del PDF…") { pickingNewVersion = true }
                    Divider()
                    Button("Girar página") { editor.rotateCurrentPage(by: 90) }
                    Button("Eliminar esta página", role: .destructive) { editor.deleteCurrentPage() }
                }
                Button(editor.showNotes ? "Ocultar cuaderno" : "Cuaderno de apuntes", systemImage: editor.showNotes ? "book.fill" : "book") {
                    editor.showNotes.toggle()
                }
                Button(showThumbs ? "Ocultar miniaturas" : "Mostrar miniaturas", systemImage: showThumbs ? "rectangle.bottomthird.inset.filled" : "rectangle") {
                    showThumbs.toggle()
                }
                Button("Asistente", systemImage: "sparkles") { showAI.toggle() }
            }
        }
        .toolbar(editor.immersive ? .hidden : .visible, for: .navigationBar)
        .statusBarHidden(editor.immersive)
        .animation(.easeInOut(duration: 0.2), value: editor.immersive)
        .searchable(text: $editor.searchText, prompt: "Buscar en el PDF")
        .onSubmit(of: .search) { editor.submitSearch() }
        .inspector(isPresented: $showAI) {
            PadAIPanel(assistant: assistant)
        }
        .alert("Añadir texto", isPresented: $editor.showTextPrompt) {
            TextField("Texto", text: $newText)
            Button("Añadir") {
                editor.addPendingText(newText)
                newText = ""
            }
            Button("Cancelar", role: .cancel) { newText = "" }
        }
        .fileImporter(isPresented: $pickingNewVersion, allowedContentTypes: [.pdf]) { result in
            guard case .success(let url) = result else { return }
            Task { await updateToNewVersion(url) }
        }
        .alert("Nueva versión", isPresented: Binding(get: { updateReport != nil }, set: { if !$0 { updateReport = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(updateReport ?? "")
        }
        .navigationTitle(doc.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottomTrailing) {
            if let status = doc.status, !editor.immersive || status.hasPrefix("No se pudo") {
                Text(status).font(.caption).padding(6).background(.regularMaterial, in: Capsule()).padding(8)
            }
        }
    }
}

extension PadDocumentView {
    private func updateToNewVersion(_ url: URL) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try await Task.detached { try PadLibrary.coordinatedRead(url) }.value
            guard let fresh = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            updateReport = editor.updateToNewVersion(fresh)
        } catch {
            updateReport = "No se pudo abrir «\(url.lastPathComponent)»: \(error.localizedDescription)"
        }
    }
}

/// Hojas de apuntes de la página que estás viendo, al lado del PDF. Se pasan deslizando como un libro.
private struct NotesPanel: View {
    let editor: PadEditor

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button("Hoja anterior", systemImage: "chevron.left") { editor.flipNotes(by: -1) }
                    .disabled(editor.notesSheet == 0)
                Text(editor.notesCount == 0 ? "Apuntes · pág. \(editor.notesPage + 1)"
                     : "Pág. \(editor.notesPage + 1) · hoja \(editor.notesSheet + 1) de \(editor.notesCount)")
                    .font(.subheadline).monospacedDigit()
                Button("Hoja siguiente", systemImage: "chevron.right") { editor.flipNotes(by: 1) }
                    .disabled(editor.notesSheet + 1 >= editor.notesCount)
                Spacer()
                paperMenu
                if editor.notesCount > 0 {
                    Button("Eliminar hoja", systemImage: "trash", role: .destructive) { editor.deleteNotesSheet() }
                }
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
            ZStack {
                PDFRepresentable(view: editor.notesView)
                if editor.notesCount == 0 {
                    VStack(spacing: 12) {
                        Image(systemName: "book.pages").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Sin apuntes para esta página").foregroundStyle(.secondary)
                        HStack {
                            ForEach(PageFactory.Paper.allCases, id: \.self) { paper in
                                Button(paper.rawValue.capitalized) { editor.addNotesSheet(paper) }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemBackground))
                }
            }
        }
    }

    private var paperMenu: some View {
        Menu("Añadir hoja", systemImage: "plus") {
            ForEach(PageFactory.Paper.allCases, id: \.self) { paper in
                Button("Hoja \(paper.rawValue)") { editor.addNotesSheet(paper) }
            }
        }
    }
}

private struct PDFRepresentable: UIViewRepresentable {
    let view: PDFView
    func makeUIView(context: Context) -> PDFView { view }
    func updateUIView(_ uiView: PDFView, context: Context) {}
}

private struct ThumbnailStrip: UIViewRepresentable {
    let pdfView: PDFView
    func makeUIView(context: Context) -> PDFThumbnailView {
        let v = PDFThumbnailView()
        v.pdfView = pdfView
        v.layoutMode = .horizontal
        v.thumbnailSize = CGSize(width: 54, height: 72)
        v.backgroundColor = .secondarySystemBackground
        return v
    }
    func updateUIView(_ uiView: PDFThumbnailView, context: Context) {}
}

// MARK: Asistente (Gemini)

@MainActor @Observable
final class PadAssistant {
    var messages: [ChatMessage] = []
    var input = ""
    private(set) var busy = false
    private(set) var hasKey = Gemini.hasKey
    private let editor: PadEditor
    private var history: [(user: String, model: String)] = []

    init(editor: PadEditor) { self.editor = editor }

    func saveKey(_ key: String) {
        Gemini.saveKey(key)
        hasKey = Gemini.hasKey
    }

    func reset() {
        messages = []
        history = []
    }

    func goToPage(_ n: Int) { editor.goToPage(n) }

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        input = ""
        ask(q, shown: q)
    }

    func summarize() { ask("Resume el documento: un párrafo corto y después los puntos clave en una lista.", shown: "Resume el documento") }

    func explainSelection() {
        guard let sel = editor.pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty else {
            return messages.append(.init(role: .info, text: "Selecciona primero un texto en el PDF (modo Leer, mantén pulsado)."))
        }
        ask("Explica de forma sencilla este fragmento del documento:\n\n\(sel.prefix(6000))", shown: "Explica la selección")
    }

    private func ask(_ question: String, shown: String) {
        guard !busy else { return }
        guard hasKey else { return messages.append(.init(role: .info, text: Gemini.Failure.noKey.localizedDescription)) }
        messages.append(.init(role: .user, text: shown))
        messages.append(.init(role: .ai, text: "Gemini está leyendo el PDF…"))
        busy = true
        Task {
            defer { busy = false }
            do {
                guard let pdf = editor.document.dataRepresentation() else { throw Gemini.Failure.other("No se pudo leer el PDF.") }
                var prompt = "El usuario está viendo la página \(editor.currentPageIndex + 1) de \(editor.document.pageCount).\n\(editor.document.annotationSummary)\n\n"
                if !history.isEmpty {
                    prompt += "Conversación anterior:\n" + history.suffix(4).map { "Usuario: \($0.user)\nAsistente: \($0.model)" }.joined(separator: "\n\n") + "\n\n"
                }
                prompt += "Petición del usuario: \(question)"
                let reply = try await Gemini.askAPI(prompt: prompt, pdf: pdf)
                var found = 0
                editor.grouped("Resaltar") {
                    for h in reply.highlights where editor.highlight(text: h.phrase, note: h.note) { found += 1 }
                }
                var text = reply.text
                if !reply.highlights.isEmpty {
                    text += found > 0 ? "\n\n✓ \(found) resaltados en el PDF." : "\n\n(No he podido localizar en el PDF las frases a resaltar.)"
                }
                setLast(text)
                history.append((question, reply.text))
            } catch {
                setLast("No he podido responder: \(error.localizedDescription)")
            }
        }
    }

    private func setLast(_ text: String) {
        guard !messages.isEmpty else { return }
        messages[messages.count - 1].text = text
    }
}

struct PadAIPanel: View {
    @Bindable var assistant: PadAssistant
    @State private var key = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Asistente · Gemini", systemImage: "sparkles").font(.headline)
                Spacer()
                Button("Nueva conversación", systemImage: "square.and.pencil") { assistant.reset() }.labelStyle(.iconOnly)
            }
            if !assistant.hasKey {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pega tu clave gratuita de Gemini (la misma que en el Mac).").font(.caption)
                    Link("Abrir Google AI Studio", destination: Gemini.keyURL).font(.caption)
                    HStack {
                        SecureField("AIza…", text: $key).textFieldStyle(.roundedBorder)
                        Button("Guardar") { assistant.saveKey(key); key = "" }.disabled(key.isEmpty)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            }
            HStack {
                Button("Resumir") { assistant.summarize() }
                Button("Explicar selección") { assistant.explainSelection() }
            }
            .buttonStyle(.bordered).controlSize(.small).disabled(assistant.busy)

            ChatWebView(messages: assistant.messages, goToPage: assistant.goToPage)

            HStack(alignment: .bottom) {
                TextField("Pregunta o pide «resalta las fechas»…", text: $assistant.input, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { assistant.send() }
                if assistant.busy {
                    ProgressView()
                } else {
                    Button("Enviar", systemImage: "arrow.up.circle.fill") { assistant.send() }
                        .labelStyle(.iconOnly).font(.title2)
                }
            }
        }
        .padding()
    }
}
