import Foundation
import Security

/// Modelos de ChatGPT gratis a través de GitHub Models (límite diario gratuito, sin coste).
/// Usa un token de GitHub con permiso solo de "Models", guardado en el Llavero.
enum ChatGPT {
    static let models = ["openai/gpt-4.1", "openai/gpt-4.1-mini"]
    static let tokenURL = URL(string: "https://github.com/settings/personal-access-tokens/new?name=MDobe&description=ChatGPT+en+MDobe")!
    private static let endpoint = URL(string: "https://models.github.ai/inference/chat/completions")!
    private static var cachedToken: String?

    enum Failure: LocalizedError {
        case noToken, unauthorized, rateLimited, server(String)
        var errorDescription: String? {
            switch self {
            case .noToken: "Conecta ChatGPT en Ajustes del asistente (es gratis, 1 minuto)."
            case .unauthorized: "GitHub ha rechazado el token. Vuelve a conectarlo en Ajustes del asistente."
            case .rateLimited: "Has llegado al límite gratuito de hoy. Usa Apple Intelligence hasta mañana."
            case .server(let msg): msg
            }
        }
    }

    static var hasToken: Bool { token() != nil }

    static func token() -> String? {
        if cachedToken == nil { cachedToken = Keychain.read() }
        return cachedToken
    }

    static func saveToken(_ t: String) {
        let t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.write(t)
        cachedToken = t.isEmpty ? nil : t
    }

    /// Una llamada a chat/completions. Devuelve el mensaje del asistente (puede traer `tool_calls`).
    static func complete(_ messages: [[String: Any]], tools: [[String: Any]]? = nil, json: Bool = false) async throws -> [String: Any] {
        guard let token = token() else { throw Failure.noToken }
        var lastError: Error = Failure.server("Sin respuesta")
        // Si el modelo principal agota su cupo diario, probamos con el pequeño (cupo aparte).
        for model in models {
            var body: [String: Any] = ["model": model, "messages": messages, "temperature": 0.3]
            if let tools { body["tools"] = tools }
            if json { body["response_format"] = ["type": "json_object"] }
            var req = URLRequest(url: endpoint, timeoutInterval: 90)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            switch status {
            case 200:
                let choices = obj?["choices"] as? [[String: Any]]
                guard let msg = choices?.first?["message"] as? [String: Any] else { throw Failure.server("Respuesta vacía") }
                return msg
            case 401, 403:
                throw Failure.unauthorized
            case 429:
                lastError = Failure.rateLimited
            default:
                let msg = (obj?["error"] as? [String: Any])?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
                throw Failure.server("Error \(status): \(msg)")
            }
        }
        throw lastError
    }
}

private enum Keychain {
    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "MDobe",
        kSecAttrAccount as String: "github-models",
    ]

    static func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ value: String) {
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var q = query
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}
