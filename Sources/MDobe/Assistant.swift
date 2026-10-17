import Foundation
import FoundationModels
import Observation
import PDFKit

/// Asistente del PDF con dos motores gratuitos:
/// - ChatGPT (GPT-4.1 vía GitHub Models): el más listo, con límite diario gratuito.
/// - Apple Intelligence: local y sin límites, pero con poca memoria de contexto.
@MainActor @Observable
final class Assistant {
    struct Message: Identifiable {
        enum Role { case user, ai, info }
        let id = UUID()
        let role: Role
        var text: String
    }

    enum Provider: String, CaseIterable, Identifiable {
        case chatgpt = "ChatGPT", apple = "Apple"
        var id: Self { self }
    }

    var messages: [Message] = []
    var input = ""
    private(set) var busy = false
    private(set) var connected = ChatGPT.hasToken
    var provider: Provider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "assistant.provider")
            history = []
        }
    }

    private let editor: Editor
    private var history: [[String: Any]] = [] // turnos anteriores (solo ChatGPT)
    private var appleBudget = 6000 // se reduce si el modelo de Apple se queda corto
    /// Caracteres de documento por petición (GitHub Models gratis admite ~8000 tokens de entrada).
    private var budget: Int { provider == .chatgpt ? 22000 : appleBudget }

    init(editor: Editor) {
        self.editor = editor
        provider = Provider(rawValue: UserDefaults.standard.string(forKey: "assistant.provider") ?? "") ?? .chatgpt
    }

    var unavailableReason: String? {
        if provider == .chatgpt { return nil } // la falta de token se resuelve en el propio panel
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Activa Apple Intelligence en Ajustes del Sistema → Apple Intelligence y Siri."
        case .unavailable(.modelNotReady): return "El modelo de Apple Intelligence se está descargando. Prueba en unos minutos."
        case .unavailable(.deviceNotEligible): return "Este Mac no es compatible con Apple Intelligence."
        case .unavailable: return "Apple Intelligence no está disponible ahora mismo."
        }
    }

    func connect(token: String) {
        ChatGPT.saveToken(token)
        connected = ChatGPT.hasToken
    }

    func reset() {
        messages = []
        history = []
    }

    private static let instructions = """
        Eres el asistente de MDobe, un lector y editor de PDF para Mac. Responde siempre en español, de forma clara y bien estructurada.
        Basa tus respuestas en el documento; si algo no aparece en los fragmentos que tienes, dilo.
        Si el usuario pide resaltar, marcar o anotar algo, usa la herramienta "resaltar" con frases copiadas literalmente del documento (una llamada por frase).
        """

    private var location: String {
        "El usuario está viendo la página \(editor.currentPageIndex + 1) de \(editor.document.pageCount)."
    }

    // MARK: Acciones

    func send() {
        let q = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        input = ""
        run(user: q) { [self] in
            let context = "\(location)\n\nFragmentos del documento:\n\(relevantText(for: q))"
            switch provider {
            case .chatgpt: try await chatGPTConversation(context: context, question: q)
            case .apple: try await appleStream("\(context)\n\nPetición del usuario: \(q)", tools: true)
            }
        }
    }

    func summarize() {
        run(user: "Resume el documento") { [self] in
            let chunks = chunked(editor.pageTexts)
            let final = "Resume este documento: un párrafo corto y después los puntos clave en una lista."
            guard chunks.count > 1 else { return try await answer("\(final)\n\n\(chunks.first ?? "")") }
            // Documento largo: resumimos por partes y luego unimos.
            var partials: [String] = []
            for (i, chunk) in chunks.enumerated() {
                setLast("Leyendo parte \(i + 1) de \(chunks.count)…")
                partials.append(try await oneShot("Resume en 3-6 puntos breves:\n\n\(chunk)"))
            }
            try await answer("Estos son resúmenes parciales de un documento, en orden. \(final)\n\n\(partials.joined(separator: "\n\n"))")
        }
    }

    func explainSelection() {
        guard let sel = editor.pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !sel.isEmpty else {
            return messages.append(.init(role: .info, text: "Selecciona primero un texto en el PDF (herramienta Seleccionar)."))
        }
        run(user: "Explica la selección") { [self] in
            try await answer("Explica de forma sencilla este fragmento de un documento:\n\n\(String(sel.prefix(budget)))")
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
            let phrases: [String]
            switch provider {
            case .apple:
                let s = LanguageModelSession(instructions: Self.instructions)
                phrases = try await s.respond(to: "Elige las frases más importantes de este texto:\n\n\(text)", generating: KeyPhrases.self).content.phrases
            case .chatgpt:
                let msg = try await ChatGPT.complete([
                    ["role": "system", "content": Self.instructions],
                    ["role": "user", "content": "Devuelve JSON {\"frases\": [...]} con las 3-6 frases más importantes de este texto, copiadas literalmente y completas:\n\n\(text)"],
                ], json: true)
                let data = Data((msg["content"] as? String ?? "{}").utf8)
                phrases = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["frases"] as? [String] ?? []
            }
            var found = 0
            editor.grouped("Resaltar ideas clave") {
                for p in phrases where editor.highlight(text: p) { found += 1 }
            }
            setLast(found > 0 ? "He resaltado \(found) ideas clave. ⌘Z para deshacer." : "No he podido localizar las frases en el PDF.")
        }
    }

    // MARK: Motores

    private func run(user: String, _ body: @escaping () async throws -> Void) {
        if let reason = unavailableReason {
            return messages.append(.init(role: .info, text: reason))
        }
        if provider == .chatgpt, !connected {
            return messages.append(.init(role: .info, text: ChatGPT.Failure.noToken.localizedDescription))
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
                setLast("El texto era demasiado largo para Apple Intelligence. He reducido el tamaño; vuelve a intentarlo (o usa ChatGPT).")
            } catch ChatGPT.Failure.unauthorized {
                connected = false // vuelve a mostrar la caja para conectar
                setLast(ChatGPT.Failure.unauthorized.localizedDescription)
            } catch {
                setLast("No he podido responder: \(error.localizedDescription)")
            }
        }
    }

    /// Respuesta final visible para el usuario (sin historial).
    private func answer(_ prompt: String) async throws {
        switch provider {
        case .apple: try await appleStream(prompt)
        case .chatgpt: setLast(try await oneShot(prompt))
        }
    }

    /// Respuesta de una sola petición, sin herramientas.
    private func oneShot(_ prompt: String) async throws -> String {
        switch provider {
        case .apple:
            return try await LanguageModelSession(instructions: Self.instructions).respond(to: prompt).content
        case .chatgpt:
            let msg = try await ChatGPT.complete([["role": "system", "content": Self.instructions], ["role": "user", "content": prompt]])
            return msg["content"] as? String ?? ""
        }
    }

    private func appleStream(_ prompt: String, tools: Bool = false) async throws {
        let session = tools
            ? LanguageModelSession(tools: [HighlightTool(editor: editor)], instructions: Self.instructions)
            : LanguageModelSession(instructions: Self.instructions)
        for try await snapshot in session.streamResponse(to: prompt) {
            setLast(snapshot.content)
        }
    }

    private static let chatTools: [[String: Any]] = [[
        "type": "function",
        "function": [
            "name": "resaltar",
            "description": "Resalta en el PDF una frase del documento y, opcionalmente, le añade una nota.",
            "parameters": [
                "type": "object",
                "properties": [
                    "frase": ["type": "string", "description": "Frase copiada literalmente del documento (como mucho una oración)"],
                    "nota": ["type": "string", "description": "Nota opcional junto a la frase"],
                ],
                "required": ["frase"],
            ],
        ],
    ]]

    /// Conversación con memoria de los últimos turnos y uso de herramientas.
    private func chatGPTConversation(context: String, question: String) async throws {
        var msgs: [[String: Any]] = [["role": "system", "content": "\(Self.instructions)\n\n\(context)"]]
        msgs += history.suffix(6)
        msgs.append(["role": "user", "content": question])
        var marked = 0
        for _ in 0..<4 {
            let reply = try await ChatGPT.complete(msgs, tools: Self.chatTools)
            guard let calls = reply["tool_calls"] as? [[String: Any]], !calls.isEmpty else {
                let text = reply["content"] as? String ?? ""
                setLast(marked > 0 ? "\(text)\n\n✓ \(marked) frases resaltadas (⌘Z para deshacer)." : text)
                history += [["role": "user", "content": question], ["role": "assistant", "content": text]]
                return
            }
            msgs.append(reply)
            setLast("Resaltando en el PDF…")
            for call in calls {
                let fn = call["function"] as? [String: Any]
                let args = (try? JSONSerialization.jsonObject(with: Data((fn?["arguments"] as? String ?? "{}").utf8))) as? [String: Any]
                let note = (args?["nota"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let ok = editor.highlight(text: args?["frase"] as? String ?? "", note: note)
                if ok { marked += 1 }
                msgs.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": ok ? "Resaltado." : "No encontré esa frase exacta en el PDF."])
            }
        }
        setLast("He hecho \(marked) cambios.")
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
            let (sa, sb) = (score(pages[a], terms), score(pages[b], terms))
            return sa != sb ? sa > sb : a < b
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
