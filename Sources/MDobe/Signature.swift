import SwiftUI

/// Firma del usuario guardada como trazos normalizados: x en 0…1, y hacia abajo en la misma escala.
enum SignatureStore {
    private static let key = "signature.strokes"

    static func load() -> [[CGPoint]]? {
        guard let raw = UserDefaults.standard.array(forKey: key) as? [[[Double]]], !raw.isEmpty else { return nil }
        return raw.map { $0.map { CGPoint(x: $0[0], y: $0[1]) } }
    }

    static func save(_ strokes: [[CGPoint]]) {
        let all = strokes.joined()
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(), let minY = all.map(\.y).min() else { return }
        let w = max(maxX - minX, 1)
        let raw = strokes.map { $0.map { [Double(($0.x - minX) / w), Double(($0.y - minY) / w)] } }
        UserDefaults.standard.set(raw, forKey: key)
    }
}

struct SignaturePad: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: () -> Void
    @State private var strokes: [[CGPoint]] = []
    @State private var drawing = false

    var body: some View {
        VStack(spacing: 12) {
            Text("Dibuja tu firma").font(.headline)
            Text("Con el trackpad o el ratón. Se guarda en este Mac y la estampas con la herramienta Firmar.")
                .font(.caption).foregroundStyle(.secondary)
            Canvas { ctx, _ in
                for s in strokes {
                    var p = Path()
                    p.addLines(s)
                    ctx.stroke(p, with: .color(.black), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: 520, height: 200)
            .background(.white, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if drawing { strokes[strokes.count - 1].append(v.location) } else { strokes.append([v.location]) }
                        drawing = true
                    }
                    .onEnded { _ in drawing = false }
            )
            HStack {
                Button("Borrar") { strokes = [] }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar firma") {
                    SignatureStore.save(strokes)
                    onSave()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(strokes.isEmpty)
            }
        }
        .padding(20)
    }
}
