import PDFKit
import SwiftUI
import WebKit

// MARK: Páginas y bloques

extension Editor {
    enum Paper: String, CaseIterable {
        case plain = "lisa", grid = "cuadrícula", lines = "rayas"
    }

    @discardableResult
    func insertBlankPage(_ paper: Paper) -> PDFPage? {
        let box = pdfView.currentPage?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let page = Self.composePage(box: box, draw: { ctx in Self.drawPaper(paper, in: box, ctx) }) else { return nil }
        insert(page, at: currentPageIndex + 1)
        undoManager?.setActionName("Insertar página")
        pdfView.go(to: page)
        return page
    }

    /// Dibuja el bloque (Markdown + LaTeX) dentro de la propia página, como contenido vectorial con texto real.
    func placeBlock(_ text: String, plain: Bool, at point: CGPoint, on page: PDFPage) {
        pendingBlock = nil
        Task {
            let crop = page.bounds(for: .cropBox), margin: CGFloat = 36
            let x = min(max(point.x, crop.minX + margin), crop.maxX - margin - 160)
            do {
                let (block, size) = try await BlockRenderer.shared.render(text, width: crop.maxX - margin - x, plain: plain)
                var target = page, top = min(point.y, crop.maxY - margin), left = x
                if top - size.height < crop.minY + margin {
                    // No cabe debajo del clic: a una página nueva, arriba del todo.
                    pdfView.go(to: page)
                    guard let fresh = insertBlankPage(.plain) else { return }
                    target = fresh
                    top = fresh.bounds(for: .cropBox).maxY - margin
                    left = fresh.bounds(for: .cropBox).minX + margin
                }
                guard let ref = target.pageRef else { return }
                let rect = CGRect(x: left, y: top - size.height, width: size.width, height: size.height)
                guard let newPage = Self.composePage(box: ref.getBoxRect(.mediaBox), draw: { ctx in
                    ctx.drawPDFPage(ref)
                    ctx.translateBy(x: rect.minX, y: rect.minY)
                    ctx.drawPDFPage(block)
                }) else { return }
                newPage.rotation = target.rotation
                newPage.setBounds(target.bounds(for: .cropBox), for: .cropBox)
                exchange([(target, newPage)])
                undoManager?.setActionName("Insertar bloque")
            } catch {
                ocrStatus = "No se pudo crear el bloque: \(error.localizedDescription)"
            }
        }
    }

    static func composePage(box: CGRect, draw: (CGContext) -> Void) -> PDFPage? {
        let data = NSMutableData()
        var mediaBox = box
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        draw(ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    private static func drawPaper(_ paper: Paper, in box: CGRect, _ ctx: CGContext) {
        ctx.setFillColor(.white)
        ctx.fill(box)
        ctx.setLineWidth(0.4)
        switch paper {
        case .plain: break
        case .grid:
            ctx.setStrokeColor(CGColor(red: 0.55, green: 0.7, blue: 0.9, alpha: 0.55))
            let step: CGFloat = 14.17 // 5 mm
            for x in stride(from: box.minX, through: box.maxX, by: step) { ctx.move(to: CGPoint(x: x, y: box.minY)); ctx.addLine(to: CGPoint(x: x, y: box.maxY)) }
            for y in stride(from: box.minY, through: box.maxY, by: step) { ctx.move(to: CGPoint(x: box.minX, y: y)); ctx.addLine(to: CGPoint(x: box.maxX, y: y)) }
            ctx.strokePath()
        case .lines:
            ctx.setStrokeColor(CGColor(red: 0.55, green: 0.7, blue: 0.9, alpha: 0.7))
            for y in stride(from: box.maxY - 72, through: box.minY + 36, by: -22.7) { // 8 mm
                ctx.move(to: CGPoint(x: box.minX + 36, y: y)); ctx.addLine(to: CGPoint(x: box.maxX - 36, y: y))
            }
            ctx.strokePath()
        }
    }
}

// MARK: Render con WebKit

/// Convierte Markdown + LaTeX en una página PDF vectorial usando la misma plantilla que el chat (KaTeX local).
@MainActor
final class BlockRenderer: NSObject, WKNavigationDelegate {
    static let shared = BlockRenderer()
    private let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 100))
    private var loading: CheckedContinuation<Void, Never>?
    private var loaded = false

    enum Failure: LocalizedError {
        case missingResources, badPDF
        var errorDescription: String? { self == .missingResources ? "Faltan los recursos de la app; reinstálala." : "WebKit no generó el PDF." }
    }

    func render(_ text: String, width: CGFloat, plain: Bool) async throws -> (page: CGPDFPage, size: CGSize) {
        try await load()
        web.frame.size.width = width
        let h = try await web.callAsyncJavaScript("return await setContent(text, width, plain)",
                                                  arguments: ["text": text, "width": Double(width), "plain": plain],
                                                  contentWorld: .page) as? Double ?? 40
        let size = CGSize(width: width, height: max(h, 10))
        web.frame.size = size
        let config = WKPDFConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        let data = try await web.pdf(configuration: config)
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider), let page = doc.page(at: 1) else {
            throw Failure.badPDF
        }
        return (page, size)
    }

    private func load() async throws {
        guard !loaded else { return }
        guard let dir = Bundle.main.url(forResource: "Web", withExtension: nil) else { throw Failure.missingResources }
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        await withCheckedContinuation { c in
            loading = c
            web.loadFileURL(dir.appendingPathComponent("block.html"), allowingReadAccessTo: dir)
        }
        loaded = true
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loading?.resume()
            loading = nil
        }
    }
}

// MARK: Editor de bloques

struct BlockEditor: View {
    let editor: Editor
    @Environment(\.dismiss) private var dismiss
    @AppStorage("block.draft") private var text = ""
    @State private var plain = false
    @State private var aiPrompt = ""
    @State private var aiBusy = false
    @State private var aiError: String?

    private static let templates: [(String, String)] = [
        ("Demostración", "**Demostración.** Sea $\\varepsilon > 0$. \n\n$$\n\n$$\n\nLuego … $\\blacksquare$"),
        ("Teorema / Proposición", "**Teorema.** *Si* $f$ es … *entonces* …"),
        ("Definición", "**Definición.** Decimos que … si\n\n$$\n\n$$"),
        ("Ejercicio resuelto", "**Ejercicio.** \n\n**Solución.** \n\n$$\n\n$$\n\n**Resultado:** $\\boxed{\\;}$"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bloque de texto y fórmulas").font(.headline)
                Spacer()
                Menu("Plantillas") {
                    ForEach(Self.templates, id: \.0) { t in Button(t.0) { text += (text.isEmpty ? "" : "\n\n") + t.1 } }
                }
                .fixedSize()
            }
            HStack(spacing: 10) {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background, in: .rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
                BlockPreview(text: text, plain: plain)
                    .background(.white, in: .rect(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            }
            Text("**negrita**, *cursiva*, listas con «- », fórmulas en línea con `$x^2$` y en bloque con `$$\\int_a^b f(x)\\,dx$$`.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                TextField("Pide a Gemini, p. ej. «resuelve el ejercicio 3 de esta página paso a paso»", text: $aiPrompt)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(askAI)
                if aiBusy { ProgressView().controlSize(.small) } else {
                    Button("Generar con IA", systemImage: "sparkles", action: askAI).disabled(aiPrompt.isEmpty)
                }
            }
            if let aiError { Text(aiError).font(.caption).foregroundStyle(.red) }

            HStack {
                Toggle("Sin recuadro", isOn: $plain)
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("En una página nueva") { insert(newPage: true) }.disabled(text.isEmpty)
                Button("Colocar en el PDF…") { insert(newPage: false) }.keyboardShortcut(.defaultAction).disabled(text.isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 860, minHeight: 560)
    }

    private func insert(newPage: Bool) {
        let content = text, plain = plain
        dismiss()
        text = "" // el borrador se vacía al insertar
        if newPage, let page = editor.insertBlankPage(.plain) {
            let crop = page.bounds(for: .cropBox)
            editor.placeBlock(content, plain: plain, at: CGPoint(x: crop.minX + 36, y: crop.maxY - 36), on: page)
        } else {
            editor.pendingBlock = (content, plain)
        }
    }

    private func askAI() {
        guard !aiPrompt.isEmpty, !aiBusy else { return }
        aiBusy = true
        aiError = nil
        let request = aiPrompt, page = editor.currentPageIndex + 1, pdf = editor.document.dataRepresentation()
        Task {
            defer { aiBusy = false }
            do {
                let reply = try await Gemini.askAPI(prompt: """
                    El usuario está en la página \(page). Escribe en Markdown con LaTeX ($...$ y $$...$$) el contenido que pide, \
                    listo para pegarlo en sus apuntes: sin saludos ni comentarios sobre lo que haces. Petición: \(request)
                    """, pdf: pdf)
                text += (text.isEmpty ? "" : "\n\n") + reply.text
                aiPrompt = ""
            } catch {
                aiError = error.localizedDescription
            }
        }
    }
}

/// Vista previa en vivo con la misma plantilla que se dibuja en el PDF.
private struct BlockPreview: NSViewRepresentable {
    let text: String
    let plain: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let web = WKWebView()
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        if let dir = Bundle.main.url(forResource: "Web", withExtension: nil) {
            web.loadFileURL(dir.appendingPathComponent("block.html"), allowingReadAccessTo: dir)
        }
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.update(web, text: text, plain: plain)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var loaded = false
        private var pending: (String, Bool)?

        func update(_ web: WKWebView, text: String, plain: Bool) {
            guard loaded else { pending = (text, plain); return }
            web.callAsyncJavaScript("await setContent(text, 0, plain)", arguments: ["text": text, "plain": plain], in: nil, in: .page)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            if let (text, plain) = pending { update(webView, text: text, plain: plain) }
        }
    }
}
