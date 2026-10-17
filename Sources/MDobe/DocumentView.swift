import PDFKit
import SwiftUI

struct DocumentView: View {
    @ObservedObject var file: PDFFile
    @Environment(\.undoManager) private var undoManager
    @State private var editor: Editor
    @State private var assistant: Assistant
    @State private var showAI = false

    init(file: PDFFile) {
        self.file = file
        let editor = Editor(document: file.pdf)
        _editor = State(initialValue: editor)
        _assistant = State(initialValue: Assistant(editor: editor))
    }

    var body: some View {
        @Bindable var editor = editor
        NavigationSplitView {
            ThumbnailsView(pdfView: editor.pdfView)
                .navigationSplitViewColumnWidth(min: 120, ideal: 160, max: 260)
        } detail: {
            PDFKitView(pdfView: editor.pdfView)
                .overlay(alignment: .bottom) { statusOverlay }
        }
        .inspector(isPresented: $showAI) {
            AIPanel(assistant: assistant)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
        }
        .searchable(text: $editor.searchText, placement: .toolbar, prompt: "Buscar en el PDF")
        .onSubmit(of: .search) { editor.submitSearch() }
        .toolbar { toolbar }
        .onAppear {
            editor.onFormula = { png, page in
                showAI = true
                assistant.explainFormula(png, page: page)
            }
        }
        .sheet(isPresented: $editor.showSignaturePad) {
            SignaturePad { editor.tool = .sign }
        }
        .onAppear { editor.undoManager = undoManager }
        .onChange(of: undoManager) { editor.undoManager = undoManager }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if let status = editor.ocrStatus {
            Label(status, systemImage: "text.viewfinder")
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding()
        } else if editor.suggestOCR {
            HStack {
                Label("Este PDF parece escaneado: no se puede buscar ni seleccionar texto.", systemImage: "doc.viewfinder")
                Button("Reconocer texto") { editor.runOCR() }.buttonStyle(.borderedProminent)
                Button("Ahora no", systemImage: "xmark") { editor.suggestOCR = false }.labelStyle(.iconOnly).buttonStyle(.borderless)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding()
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Picker("Herramienta", selection: $editor.tool) {
                ForEach(Tool.allCases) { t in
                    Label(t.label, systemImage: t.symbol).help(t.label).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
        }
        ToolbarItem {
            ColorPicker("Color", selection: $editor.color).labelsHidden().help("Color")
        }
        ToolbarItemGroup {
            Button("Alejar", systemImage: "minus.magnifyingglass") { editor.pdfView.zoomOut(nil) }
                .keyboardShortcut("-")
            Button("Ajustar", systemImage: "arrow.up.left.and.down.right.magnifyingglass") { editor.pdfView.autoScales = true }
                .keyboardShortcut("0")
            Button("Acercar", systemImage: "plus.magnifyingglass") { editor.pdfView.zoomIn(nil) }
                .keyboardShortcut("+")
        }
        ToolbarItem {
            Menu("Páginas", systemImage: "doc.on.doc") {
                Button("Girar a la izquierda") { editor.rotateCurrentPage(by: -90) }
                Button("Girar a la derecha") { editor.rotateCurrentPage(by: 90) }
                Divider()
                Button("Mover página arriba") { editor.moveCurrentPage(by: -1) }
                Button("Mover página abajo") { editor.moveCurrentPage(by: 1) }
                Divider()
                Button("Insertar PDF después de esta página…") { editor.insertPDFs() }
                Button("Eliminar esta página", role: .destructive) { editor.deleteCurrentPage() }
                Divider()
                Picker("Vista", selection: Binding(get: { editor.pdfView.displayMode }, set: { editor.pdfView.displayMode = $0 })) {
                    Text("Una página continua").tag(PDFDisplayMode.singlePageContinuous)
                    Text("Dos páginas continuas").tag(PDFDisplayMode.twoUpContinuous)
                    Text("Una página").tag(PDFDisplayMode.singlePage)
                }
            }
        }
        ToolbarItem {
            Menu("Más", systemImage: "ellipsis.circle") {
                Button("Cambiar mi firma…") { editor.showSignaturePad = true }
                Divider()
                let fields = editor.formFields.count
                Text(fields > 0 ? "Formulario: \(fields) campos" : "Este PDF no tiene campos de formulario")
                Button("Ir al siguiente campo vacío") { editor.goToNextEmptyField() }.disabled(fields == 0)
                Button("Vaciar formulario") { editor.clearForm() }.disabled(fields == 0)
                Divider()
                Button("Reconocer texto (OCR)") { editor.runOCR() }.disabled(editor.ocrStatus != nil)
            }
        }
        ToolbarItemGroup {
            if !editor.results.isEmpty {
                Text("\(editor.resultIndex + 1)/\(editor.results.count)").monospacedDigit().foregroundStyle(.secondary)
                Button("Anterior", systemImage: "chevron.up") { editor.step(-1) }.keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Siguiente", systemImage: "chevron.down") { editor.step(1) }.keyboardShortcut("g")
            }
        }
        ToolbarItemGroup {
            Button("Imprimir", systemImage: "printer") { editor.print() }.keyboardShortcut("p")
            Button("Asistente IA", systemImage: "sparkles") { showAI.toggle() }.keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

struct PDFKitView: NSViewRepresentable {
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFView { pdfView }
    func updateNSView(_ nsView: PDFView, context: Context) {}
}

struct ThumbnailsView: NSViewRepresentable {
    let pdfView: PDFView
    func makeNSView(context: Context) -> PDFThumbnailView {
        let v = PDFThumbnailView()
        v.pdfView = pdfView
        v.thumbnailSize = CGSize(width: 110, height: 150)
        v.backgroundColor = .clear
        return v
    }
    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {}
}

struct AIPanel: View {
    @Bindable var assistant: Assistant
    @State private var token = ""

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Label("Asistente", systemImage: "sparkles").font(.headline)
                Spacer()
                Button("Nueva conversación", systemImage: "square.and.pencil") { assistant.reset() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(assistant.busy)
            }
            Picker("Motor", selection: $assistant.provider) {
                ForEach(Assistant.Provider.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            if assistant.provider == .gemini, !assistant.hasKey {
                keyBox
            }
            if let reason = assistant.unavailableReason {
                Text(reason).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Resumir") { assistant.summarize() }
                Button("Explicar selección") { assistant.explainSelection() }
                Button("Ideas clave") { assistant.highlightKeyIdeas() }.help("Resalta las frases más importantes de la página actual")
            }
            .controlSize(.small)
            .disabled(assistant.busy)

            ChatWebView(messages: assistant.messages, goToPage: assistant.goToPage)
                .clipShape(.rect(cornerRadius: 6))

            HStack(alignment: .bottom) {
                TextField("Pregunta o pide «resalta las fechas»…", text: $assistant.input, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { assistant.send() }
                if assistant.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Enviar", systemImage: "arrow.up.circle.fill") { assistant.send() }
                        .labelStyle(.iconOnly).buttonStyle(.plain).font(.title2)
                }
            }
        }
        .padding()
    }

    private var keyBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Conectar Gemini gratis").font(.subheadline.bold())
            Text("1. Entra con tu cuenta de Google y pulsa **Create API key**.").font(.caption)
            Link("Abrir Google AI Studio", destination: Gemini.keyURL).font(.caption)
            Text("2. Pega la clave aquí. Se guarda en tu Llavero.").font(.caption)
            HStack {
                SecureField("AIza…", text: $token).textFieldStyle(.roundedBorder)
                Button("Guardar") {
                    assistant.saveKey(token)
                    token = ""
                }
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }
}
