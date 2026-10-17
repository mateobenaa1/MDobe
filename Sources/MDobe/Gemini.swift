import Foundation
import Security

/// Gemini vía la API gratuita de Google AI Studio (clave en el Llavero).
/// Recibe el PDF completo, así que ve también las anotaciones a mano del usuario.
enum Gemini {
    struct Reply {
        var text: String
        var highlights: [(phrase: String, note: String?)]
    }

    enum Failure: LocalizedError {
        case noKey, badKey, rateLimited, tooLarge, other(String)
        var errorDescription: String? {
            switch self {
            case .noKey: "Pega tu clave gratuita de Gemini en el panel (aistudio.google.com/apikey)."
            case .badKey: "Google ha rechazado la clave. Revísala en el panel."
            case .rateLimited: "Has llegado al límite gratuito por ahora. Espera un poco o usa Apple mientras tanto."
            case .tooLarge: "El PDF es demasiado grande para enviarlo (máx. ~18 MB)."
            case .other(let msg): msg
            }
        }
    }

    static let instructions = """
        Eres el asistente de MDobe, un lector y editor de PDF para Mac. Tienes adjunto el PDF que el usuario tiene abierto, \
        incluidas sus anotaciones (resaltados, trazos a mano, notas) tal y como se ven en la página.
        Responde siempre en español, claro y bien estructurado. Puedes usar **negrita** y listas con guiones. \
        Cuando menciones una página escribe «página N», donde N es el número de página del archivo PDF (la primera página del archivo es la 1); \
        si el número impreso en la página es distinto, puedes añadirlo así: (numerada 5).
        No uses LaTeX: escribe las fórmulas con símbolos Unicode (α, β, ∈, ≤, ², √, ∑…).
        Devuelve SOLO un objeto JSON: {"respuesta": "texto para el usuario", "resaltar": [{"frase": "texto literal del PDF", "nota": "opcional"}]}.
        Rellena "resaltar" únicamente si el usuario pide resaltar, marcar o anotar algo; cada "frase" debe copiarse literalmente \
        del PDF y ser corta (una oración como mucho). Si no, "resaltar": [].
        """

    static let maxPDFBytes = 18_000_000

    // MARK: Respuesta común

    static func parse(_ raw: String) -> Reply {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
              let obj = (try? JSONSerialization.jsonObject(with: Data(raw[start...end].utf8))) as? [String: Any]
        else { return Reply(text: raw.trimmingCharacters(in: .whitespacesAndNewlines), highlights: []) }
        let items = obj["resaltar"] as? [[String: Any]] ?? []
        return Reply(
            text: obj["respuesta"] as? String ?? "",
            highlights: items.compactMap { item in
                guard let p = item["frase"] as? String, !p.isEmpty else { return nil }
                let n = item["nota"] as? String
                return (p, n?.isEmpty == false ? n : nil)
            }
        )
    }

    // MARK: API gratuita

    static let keyURL = URL(string: "https://aistudio.google.com/apikey")!
    static var hasKey: Bool { Keychain.read(account: "gemini-api") != nil }
    static func saveKey(_ k: String) { Keychain.write(k.trimmingCharacters(in: .whitespacesAndNewlines), account: "gemini-api") }

    static func askAPI(prompt: String, pdf: Data) async throws -> Reply {
        guard let key = Keychain.read(account: "gemini-api") else { throw Failure.noKey }
        guard pdf.count < maxPDFBytes else { throw Failure.tooLarge }
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/gemini-flash-latest:generateContent")!
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": instructions]]],
            "contents": [["role": "user", "parts": [
                ["inlineData": ["mimeType": "application/pdf", "data": pdf.base64EncodedString()]],
                ["text": prompt],
            ]]],
            "generationConfig": ["responseMimeType": "application/json", "temperature": 0.3],
        ]
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = (obj?["error"] as? [String: Any])?["message"] as? String
        switch status {
        case 200: break
        case 400 where message?.localizedCaseInsensitiveContains("API key") == true, 401, 403: throw Failure.badKey
        case 429: throw Failure.rateLimited
        default: throw Failure.other("Error \(status): \(message ?? String(decoding: data.prefix(300), as: UTF8.self))")
        }
        let parts = (((obj?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw Failure.other("Gemini no ha devuelto respuesta. Prueba a reformular la pregunta.") }
        return parse(text)
    }
}

enum Keychain {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "MDobe", kSecAttrAccount as String: account]
    }

    static func read(account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        SecItemDelete(query(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
