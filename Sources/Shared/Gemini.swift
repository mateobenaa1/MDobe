import Foundation
import Security
import CryptoKit

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
        Escribe TODA la matemática en LaTeX: en línea con $...$ y en bloque con $$...$$ (fórmulas importantes o largas en bloque). \
        Usa notación estándar (\\mathbb{R}, \\frac, \\int, \\sum, \\lim…).
        Cuando menciones una página escribe «página N», donde N es el número de página del archivo PDF (la primera página del archivo es la 1); \
        si el número impreso en la página es distinto, puedes añadirlo así: (numerada 5).
        Escribe la respuesta directamente en Markdown, sin envolverla en JSON ni en bloques de código.
        Solo si el usuario pide resaltar, marcar o anotar algo: al terminar la respuesta añade una línea con exactamente \
        \(marker) y, debajo, un array JSON [{"frase": "texto literal del PDF", "nota": "opcional"}]. Cada "frase" debe copiarse \
        literalmente del PDF y ser corta (una oración como mucho). Si no hay nada que resaltar, no escribas esa línea.
        """

    /// Separa la respuesta visible de la lista de frases a resaltar.
    static let marker = "===RESALTAR==="

    static let maxPDFBytes = 18_000_000

    // MARK: Respuesta común

    /// Texto que se puede mostrar mientras llega la respuesta (sin la lista de resaltados).
    static func visible(_ raw: String) -> String {
        var text = raw.components(separatedBy: marker)[0]
        // No enseñar un marcador a medio llegar ("===RES…")
        if let tail = text.range(of: "=+[A-Z]*$", options: .regularExpression) { text.removeSubrange(tail) }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parse(_ raw: String) -> Reply {
        if let r = raw.range(of: marker) {
            let list = raw[r.upperBound...]
            var highlights: [(phrase: String, note: String?)] = []
            if let a = list.firstIndex(of: "["), let b = list.lastIndex(of: "]"),
               let items = (try? JSONSerialization.jsonObject(with: Data(list[a...b].utf8))) as? [[String: Any]] {
                highlights = items.compactMap { item in
                    guard let p = item["frase"] as? String, !p.isEmpty else { return nil }
                    let n = item["nota"] as? String
                    return (p, n?.isEmpty == false ? n : nil)
                }
            }
            return Reply(text: visible(raw), highlights: highlights)
        }
        // Respuesta en el formato JSON antiguo, o texto normal
        guard raw.trimmingCharacters(in: .whitespaces).hasPrefix("{"), let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"),
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

    private static let base = "https://generativelanguage.googleapis.com"
    private static let model = "gemini-flash-latest"
    /// Razonamiento corto: la mayor parte de la espera era el modelo "pensando". Si el modelo
    /// no admite `thinkingLevel`, se desactiva y se repite sin él.
    nonisolated(unsafe) private static var useThinkingLevel = true

    /// `onPartial` recibe el texto acumulado según va llegando, para mostrarlo en directo.
    static func askAPI(prompt: String, pdf: Data?, image: Data? = nil,
                       onPartial: (@MainActor (String) -> Void)? = nil) async throws -> Reply {
        guard let key = Keychain.read(account: "gemini-api") else { throw Failure.noKey }
        guard (pdf?.count ?? 0) < maxPDFBytes else { throw Failure.tooLarge }

        // El PDF se sube una sola vez (Files API) y en las preguntas siguientes solo se envía su URI.
        // Si la subida falla, se manda en línea como antes.
        var pdfPart: [String: Any]?
        if let pdf {
            if let uri = try? await uploadedURI(for: pdf, key: key) {
                pdfPart = ["fileData": ["mimeType": "application/pdf", "fileUri": uri]]
            } else {
                pdfPart = ["inlineData": ["mimeType": "application/pdf", "data": pdf.base64EncodedString()]]
            }
        }

        var attempt = 0
        while true {
            attempt += 1
            var parts: [[String: Any]] = []
            if let pdfPart { parts.append(pdfPart) }
            if let image { parts.append(["inlineData": ["mimeType": "image/png", "data": image.base64EncodedString()]]) }
            parts.append(["text": prompt])
            var config: [String: Any] = ["temperature": 0.3]
            if useThinkingLevel { config["thinkingConfig"] = ["thinkingLevel": "low"] }
            let body: [String: Any] = [
                "systemInstruction": ["parts": [["text": instructions]]],
                "contents": [["role": "user", "parts": parts]],
                "generationConfig": config,
            ]
            var req = URLRequest(url: URL(string: "\(base)/v1beta/models/\(model):streamGenerateContent?alt=sse")!, timeoutInterval: 180)
            req.httpMethod = "POST"
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let bytes: URLSession.AsyncBytes, response: URLResponse
            do {
                (bytes, response) = try await URLSession.shared.bytes(for: req)
            } catch let e as URLError where e.code == .timedOut && attempt < 2 {
                continue
            } catch let e as URLError where e.code == .timedOut {
                throw tooSlow
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status != 200 {
                var data = Data()
                for try await b in bytes { data.append(b) }
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                let message = (obj?["error"] as? [String: Any])?["message"] as? String
                switch status {
                case 400 where useThinkingLevel && message?.localizedCaseInsensitiveContains("thinking") == true:
                    useThinkingLevel = false
                    continue
                case 400...404 where pdfPart?["fileData"] != nil && message?.localizedCaseInsensitiveContains("file") == true:
                    // El archivo subido caducó (Google los borra a las 48 h): se manda en línea.
                    uploads.removeAll()
                    pdfPart = pdf.map { ["inlineData": ["mimeType": "application/pdf", "data": $0.base64EncodedString()]] }
                    continue
                case 400 where message?.localizedCaseInsensitiveContains("API key") == true, 401, 403: throw Failure.badKey
                case 429: throw Failure.rateLimited
                case 500...504 where attempt < 3:
                    // Sobrecarga momentánea de Google: reintenta tras una pausa.
                    try await Task.sleep(for: .seconds(2 * attempt))
                    continue
                default: throw Failure.other("Error \(status): \(message ?? String(decoding: data.prefix(300), as: UTF8.self))")
                }
            }

            // Server-sent events: cada línea "data: {…}" trae un trozo de la respuesta.
            var text = ""
            do {
                for try await line in bytes.lines where line.hasPrefix("data:") {
                    let obj = (try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8))) as? [String: Any]
                    let parts = (((obj?["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
                    let chunk = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
                    guard !chunk.isEmpty else { continue }
                    text += chunk
                    if let onPartial { await onPartial(visible(text)) }
                }
            } catch let e as URLError where e.code == .timedOut {
                if text.isEmpty { throw tooSlow }
                text += "\n\n*(Respuesta cortada: Gemini dejó de enviar.)*"
            }
            guard !text.isEmpty else { throw Failure.other("Gemini no ha devuelto respuesta. Prueba a reformular la pregunta.") }
            return parse(text)
        }
    }

    private static let tooSlow = Failure.other("Gemini ha tardado demasiado en responder. Vuelve a intentarlo en un momento.")

    // MARK: Files API

    /// PDFs ya subidos en esta sesión, por huella del contenido (cambia si el usuario anota).
    nonisolated(unsafe) private static var uploads: [String: (uri: String, date: Date)] = [:]

    private static func uploadedURI(for pdf: Data, key: String) async throws -> String {
        let fingerprint = SHA256.hash(data: pdf).description
        if let u = uploads[fingerprint], Date().timeIntervalSince(u.date) < 40 * 3600 { return u.uri }

        var start = URLRequest(url: URL(string: "\(base)/upload/v1beta/files")!, timeoutInterval: 60)
        start.httpMethod = "POST"
        start.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue("\(pdf.count)", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue("application/pdf", forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": "MDobe.pdf"]])
        let (_, r1) = try await URLSession.shared.data(for: start)
        guard let http = r1 as? HTTPURLResponse, http.statusCode == 200,
              let upload = http.value(forHTTPHeaderField: "x-goog-upload-url").flatMap(URL.init(string:))
        else { throw Failure.other("upload start") }

        var put = URLRequest(url: upload, timeoutInterval: 120)
        put.httpMethod = "POST"
        put.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        put.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")
        let (data, r2) = try await URLSession.shared.upload(for: put, from: pdf)
        guard (r2 as? HTTPURLResponse)?.statusCode == 200,
              var file = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["file"] as? [String: Any],
              let uri = file["uri"] as? String, let name = file["name"] as? String
        else { throw Failure.other("upload") }

        // Los PDF suelen quedar listos al instante; si no, espera a que Google los procese.
        for _ in 0..<15 where file["state"] as? String == "PROCESSING" {
            try await Task.sleep(for: .seconds(1))
            var get = URLRequest(url: URL(string: "\(base)/v1beta/\(name)")!)
            get.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            let (d, _) = try await URLSession.shared.data(for: get)
            file = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:]
        }
        guard (file["state"] as? String ?? "ACTIVE") == "ACTIVE" else { throw Failure.other("upload state") }
        uploads[fingerprint] = (uri, Date())
        return uri
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
