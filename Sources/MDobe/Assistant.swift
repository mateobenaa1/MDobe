import FoundationModels
import Observation
import PDFKit

/// Asistente con Apple Intelligence: gratis, en el propio Mac y sin claves.
/// El modelo tiene una ventana de contexto pequeña, así que solo le pasamos los trozos del PDF relevantes.
@MainActor @Observable
final class Assistant {
    struct Message: Identifiable {
        enum Role { case user, ai, info }
        let id = UUID()
        let role: Role
        var text: String
    }

    var messages: [Message] = []
    var input = ""
    private(set) var busy = false
    private let editor: Editor
    private var budget = 6000 // caracteres de documento por petición; se reduce si el modelo se queda corto

    init(editor: Editor) { self.editor = editor }

    var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: nil
        case .unavailable(.appleIntelligenceNotEnabled): "Activa Apple Intelligence en Ajustes del Sistema → Apple Intelligence y Siri."
        case .unavailable(.modelNotReady): "El modelo de Apple Intelligence se está descargando. Prueba en unos minutos."
        case .unavailable(.deviceNotEligible): "Este Mac no es compatible con Apple Intelligence."
        case .unavailable: "Apple Intelligence no está disponible ahora mismo."
        }
    }

    private static let instructions = """
        Eres el asistente de MDobe, un lector de PDF para Mac. Responde siempre en español, de forma clara y breve.
        Basa tus respuestas solo en los fragmentos del documento que se te dan; si la respuesta no está, dilo.
        Si el usuario pide resaltar, marcar o anotar algo, usa las herramientas pasando frases copiadas literalmente de los fragmentos.
        """

    // MARK: Acciones

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        input = ""
        run(user: q) { [self] in
            try await stream(prompt: "Fragmentos del documento:\n\(relevantText(for: q))\n\nPetición del usuario: \(q)", tools: true)
        }
    }

    func summarize() {
        run(user: "Resume el documento") { [self] in
            let chunks = chunked(editor.pageTexts)
            guard chunks.count > 1 else {
                return try await stream(prompt: "Resume este documento en un párrafo corto y después los puntos clave en una lista:\n\n\(chunks.first ?? "")")
            }
            // Documento largo: resumimos por partes y luego unimos.
            var partials: [String] = []
            for (i, chunk) in chunks.enumerated() {
                setLast("Leyendo parte \(i + 1) de \(chunks.count)…")
                let s = LanguageModelSession(instructions: Self.instructions)
                partials.append(try await s.respond(to: "Resume en 3-5 puntos breves:\n\n\(chunk)").content)
            }
            try await stream(prompt: "Estos son resúmenes parciales de un documento, en orden. Escribe un resumen global: un párrafo corto y después los puntos clave en una lista.\n\n\(partials.joined(separator: "\n\n"))")
        }
    }

    func explainSelection() {
        guard let sel = editor.pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty else {
            return messages.append(.init(role: .info, text: "Selecciona primero un texto en el PDF (herramienta Seleccionar)."))
        }
        run(user: "Explica la selección") { [self] in
            try await stream(prompt: "Explica de forma sencilla este fragmento de un documento:\n\n\(String(sel.prefix(budget)))")
        }
    }

    @Generable
    struct KeyPhrases {
        @Guide(description: "Entre 3 y 6 frases importantes, copiadas literalmente y completas del texto")
        var phrases: [String]
    }

    func highlightKeyIdeas() {
        run(user: "Resalta las ideas clave de esta página") { [self] in
            let text = String(editor.pageTexts[editor.currentPageIndex].prefix(budget))
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return setLast("Esta página no tiene texto seleccionable (puede ser una imagen escaneada).")
            }
            setLast("Analizando la página…")
            let s = LanguageModelSession(instructions: Self.instructions)
            let result = try await s.respond(to: "Elige las frases más importantes de este texto:\n\n\(text)", generating: KeyPhrases.self).content
            var found = 0
            editor.grouped("Resaltar ideas clave") {
                for p in result.phrases where editor.highlight(text: p) { found += 1 }
            }
            setLast(found > 0 ? "He resaltado \(found) ideas clave. ⌘Z para deshacer." : "No he podido localizar las frases en el PDF.")
        }
    }

    // MARK: Motor

    private func run(user: String, _ body: @escaping () async throws -> Void) {
        if let reason = unavailableReason {
            return messages.append(.init(role: .info, text: reason))
        }
        messages.append(.init(role: .user, text: user))
        messages.append(.init(role: .ai, text: ""))
        busy = true
        Task {
            defer { busy = false }
            do {
                try await body()
            } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
                budget = max(1500, budget / 2)
                setLast("El texto era demasiado largo para el modelo. He reducido el tamaño; vuelve a intentarlo.")
            } catch {
                setLast("No he podido responder: \(error.localizedDescription)")
            }
        }
    }

    private func stream(prompt: String, tools: Bool = false) async throws {
        let session = tools
            ? LanguageModelSession(tools: [HighlightTool(editor: editor)], instructions: Self.instructions)
            : LanguageModelSession(instructions: Self.instructions)
        for try await snapshot in session.streamResponse(to: prompt) {
            setLast(snapshot.content)
        }
    }

    private func setLast(_ text: String) {
        guard !messages.isEmpty else { return }
        messages[messages.count - 1].text = text
    }

    // MARK: Contexto

    /// La página actual primero y después las páginas que más palabras comparten con la pregunta.
    private func relevantText(for question: String) -> String {
        let pages = editor.pageTexts
        let current = editor.currentPageIndex
        let terms = Set(question.lowercased().split { !$0.isLetter && !$0.isNumber }.filter { $0.count > 3 }.map(String.init))
        let ranked = pages.indices.sorted { a, b in
            if a == current || b == current { return a == current }
            return score(pages[a], terms) > score(pages[b], terms)
        }
        var out = ""
        for i in ranked {
            let piece = "[Página \(i + 1)]\n\(pages[i])\n\n"
            if out.count + piece.count > budget {
                if out.isEmpty { out = String(piece.prefix(budget)) }
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
            if current.count + text.count > budget, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current += String(text.prefix(budget)) + "\n\n"
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
