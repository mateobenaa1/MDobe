import Foundation
import FoundationModels
import Observation
import PDFKit

/// Asistente del PDF con dos motores gratuitos:
/// - Gemini con clave gratuita de AI Studio: ve el PDF entero.
/// - Apple Intelligence: local y sin límites, pero con poca memoria de contexto.
@MainActor @Observable
final class Assistant {
    typealias Message = ChatMessage

    enum Provider: String, CaseIterable, Identifiable {
        case gemini, apple
        var id: Self { self }
        var label: String {
            switch self {
            case .gemini: "Gemini"
            case .apple: "Apple · sin internet"
            }
        }
        var usesGemini: Bool { self != .apple }
    }

    var messages: [Message] = []
    var input = ""
    private(set) var busy = false
    private(set) var hasKey = Gemini.hasKey
    var provider: Provider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "assistant.provider") }
    }

    private let editor: Editor
    private var history: [(user: String, model: String)] = []
    private var appleBudget = 6000 // caracteres por petición; se reduce si el modelo de Apple se queda corto

    init(editor: Editor) {
        self.editor = editor
        provider = Provider(rawValue: UserDefaults.standard.string(forKey: "assistant.provider") ?? "") ?? .gemini
    }

    var unavailableReason: String? {
        guard provider == .apple else { return nil }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Activa Apple Intelligence en Ajustes del Sistema → Apple Intelligence y Siri."
        case .unavailable(.modelNotReady): return "El modelo de Apple Intelligence se está descargando. Prueba en unos minutos."
        case .unavailable(.deviceNotEligible): return "Este Mac no es compatible con Apple Intelligence."
        case .unavailable: return "Apple Intelligence no está disponible ahora mismo."
        }
    }

    func saveKey(_ key: String) {
        Gemini.saveKey(key)
        hasKey = Gemini.hasKey
    }

    func goToPage(_ n: Int) {
        guard let page = editor.document.page(at: n - 1) else { return }
        editor.pdfView.go(to: page)
    }

    func reset() {
        messages = []
        history = []
    }

    private var location: String {
        "El usuario está viendo la página \(editor.currentPageIndex + 1) de \(editor.document.pageCount)."
    }

    // MARK: Acciones

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        input = ""
        if provider.usesGemini { return askGemini(q, shown: q) }
        run(user: q) { [self] in
            let notes = String(editor.annotationSummary.prefix(1200))
            try await appleStream("\(location)\n\n\(notes)\n\nFragmentos del documento:\n\(relevantText(for: q))\n\nPetición del usuario: \(q)", tools: true)
        }
    }

    func summarize() {
        if provider.usesGemini {
            return askGemini("Resume el documento: un párrafo corto y después los puntos clave en una lista.", shown: "Resume el documento")
        }
        run(user: "Resume el documento") { [self] in
            let chunks = chunked(editor.pageTexts)
            let final = "Resume este documento: un párrafo corto y después los puntos clave en una lista."
            guard chunks.count > 1 else { return try await appleStream("\(final)\n\n\(chunks.first ?? "")") }
            // Documento largo: resumimos por partes y luego unimos.
            var partials: [String] = []
            for (i, chunk) in chunks.enumerated() {
                setLast("Leyendo parte \(i + 1) de \(chunks.count)…")
                partials.append(try await LanguageModelSession(instructions: Self.appleInstructions).respond(to: "Resume en 3-6 puntos breves:\n\n\(chunk)").content)
            }
            try await appleStream("Estos son resúmenes parciales de un documento, en orden. \(final)\n\n\(partials.joined(separator: "\n\n"))")
        }
    }

    func explainSelection() {
        guard let sel = editor.pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty else {
            return messages.append(.init(role: .info, text: "Selecciona primero un texto en el PDF (herramienta Seleccionar)."))
        }
        let ask = "Explica de forma sencilla este fragmento del documento:\n\n\(sel.prefix(appleBudget))"
        if provider.usesGemini { return askGemini(ask, shown: "Explica la selección") }
        run(user: "Explica la selección") { [self] in try await appleStream(ask) }
    }

    @Generable
    struct KeyPhrases {
        @Guide(description: "Entre 3 y 6 frases importantes, copiadas literalmente y completas del texto")
        var phrases: [String]
    }

    func highlightKeyIdeas() {
        let page = editor.currentPageIndex + 1
        if provider.usesGemini {
            return askGemini("Resalta las 3-6 ideas clave de la página \(page) y explica brevemente por qué son importantes.", shown: "Resalta las ideas clave de esta página")
        }
        run(user: "Resalta las ideas clave de esta página") { [self] in
            let text = String(editor.pageTexts[page - 1].prefix(appleBudget))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return setLast("Esta página no tiene texto seleccionable (puede ser una imagen escaneada).")
            }
            setLast("Analizando la página…")
            let s = LanguageModelSession(instructions: Self.appleInstructions)
            let phrases = try await s.respond(to: "Elige las frases más importantes de este texto:\n\n\(text)", generating: KeyPhrases.self).content.phrases
            let found = apply(phrases.map { ($0, nil) })
            setLast(found > 0 ? "He resaltado \(found) ideas clave. ⌘Z para deshacer." : "No he podido localizar las frases en el PDF.")
        }
    }

    // MARK: Gemini

    private func askGemini(_ question: String, shown: String) {
        run(user: shown) { [self] in
            guard let pdf = editor.document.dataRepresentation() else { throw Gemini.Failure.other("No se pudo leer el PDF.") }
            setLast("Gemini está leyendo el PDF…")
            var prompt = "\(location)\n\(editor.annotationSummary)\n\n"
            if !history.isEmpty {
                prompt += "Conversación anterior:\n" + history.suffix(4).map { "Usuario: \($0.user)\nAsistente: \($0.model)" }.joined(separator: "\n\n") + "\n\n"
            }
            prompt += "Petición del usuario: \(question)"

            let reply = try await Gemini.askAPI(prompt: prompt, pdf: pdf) { [self] in setLast($0) }
            let found = apply(reply.highlights)
            var text = reply.text
            if !reply.highlights.isEmpty {
                text += found > 0 ? "\n\n✓ \(found) resaltados en el PDF (⌘Z para deshacer)." : "\n\n(No he podido localizar en el PDF las frases a resaltar.)"
            }
            setLast(text)
            history.append((question, reply.text))
        }
    }

    func explainFormula(_ png: Data, page: Int) {
        guard provider == .gemini else {
            return messages.append(.init(role: .info, text: "Para leer fórmulas cambia el asistente a Gemini (Apple no puede ver imágenes)."))
        }
        run(user: "Fórmula recuadrada en la página \(page)") { [self] in
            setLast("Gemini está leyendo la fórmula…")
            let reply = try await Gemini.askAPI(prompt: """
                La imagen es un fragmento recuadrado de la página \(page) del PDF. Transcríbelo a LaTeX en un bloque $$...$$ \
                (si hay varias líneas, usa un entorno aligned). Después explica de forma sencilla qué dice y qué significa cada símbolo.
                """, pdf: nil, image: png) { [self] in setLast($0) }
            setLast(reply.text)
            history.append(("Fórmula de la página \(page)", reply.text))
        }
    }

    private func apply(_ highlights: [(phrase: String, note: String?)]) -> Int {
        var found = 0
        editor.grouped("Resaltar") {
            for h in highlights where editor.highlight(text: h.phrase, note: h.note) { found += 1 }
        }
        return found
    }

    // MARK: Motor común

    private func run(user: String, _ body: @escaping () async throws -> Void) {
        if let reason = unavailableReason {
            return messages.append(.init(role: .info, text: reason))
        }
        if provider == .gemini, !hasKey {
            return messages.append(.init(role: .info, text: Gemini.Failure.noKey.localizedDescription))
        }
        messages.append(.init(role: .user, text: user))
        messages.append(.init(role: .ai, text: ""))
        busy = true
        Task {
            defer { busy = false }
            do {
                try await body()
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                appleBudget = max(1500, appleBudget / 2)
                setLast("El texto era demasiado largo para Apple Intelligence. He reducido el tamaño; vuelve a intentarlo (o usa Gemini).")
            } catch {
                setLast("No he podido responder: \(error.localizedDescription)")
            }
        }
    }

    private func setLast(_ text: String) {
        guard !messages.isEmpty else { return }
        messages[messages.count - 1].text = text
    }

    // MARK: Apple Intelligence

    private static let appleInstructions = """
        Eres el asistente de MDobe, un lector de PDF para Mac. Responde siempre en español, de forma clara y breve.
        Basa tus respuestas en los fragmentos del documento; si algo no aparece, dilo.
        Si el usuario pide resaltar, marcar o anotar algo, usa la herramienta "resaltar" con frases copiadas literalmente de los fragmentos.
        Escribe las fórmulas en LaTeX: en línea con $...$ y en bloque con $$...$$.
        """

    private func appleStream(_ prompt: String, tools: Bool = false) async throws {
        let session = tools
            ? LanguageModelSession(tools: [HighlightTool(editor: editor)], instructions: Self.appleInstructions)
            : LanguageModelSession(instructions: Self.appleInstructions)
        for try await snapshot in session.streamResponse(to: prompt) {
            setLast(snapshot.content)
        }
    }

    /// La página actual primero y después las páginas que más palabras comparten con la pregunta.
    private func relevantText(for question: String) -> String {
        let pages = editor.pageTexts
        let current = editor.currentPageIndex
        let terms = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 3 }.map(String.init))
        let ranked = pages.indices.sorted { a, b in
            if a == current || b == current { return a == current }
            let (sa, sb) = (score(pages[a], terms), score(pages[b], terms))
            return sa != sb ? sa > sb : a < b
        }
        var out = ""
        for i in ranked {
            let piece = "[Página \(i + 1)]\n\(pages[i])\n\n"
            if out.count + piece.count > appleBudget {
                if out.isEmpty { out = String(piece.prefix(appleBudget)) }
                break
            }
            out += piece
        }
        return out
    }

    private func score(_ text: String, _ terms: Set<String>) -> Int {
        let t = text.lowercased()
        return terms.reduce(0) { $0 + t.components(separatedBy: $1).count - 1 }
    }

    private func chunked(_ pages: [String]) -> [String] {
        var chunks: [String] = [], current = ""
        for text in pages where !text.isEmpty {
            if current.count + text.count > appleBudget, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += String(text.prefix(appleBudget)) + "\n\n"
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}

struct HighlightTool: FoundationModels.Tool {
    let name = "resaltar"
    let description = "Resalta en el PDF una frase del documento y, opcionalmente, le añade una nota."
    let editor: Editor

    @Generable
    struct Arguments {
        @Guide(description: "Frase copiada literalmente del documento (como mucho una oración)")
        var frase: String
        @Guide(description: "Nota opcional para añadir junto a la frase; vacío si no hace falta")
        var nota: String
    }

    func call(arguments: Arguments) async throws -> String {
        let ok = await editor.highlight(text: arguments.frase, note: arguments.nota.isEmpty ? nil : arguments.nota)
        return ok ? "Hecho: resaltado en el PDF." : "No encontré esa frase exacta en el PDF."
    }
}
