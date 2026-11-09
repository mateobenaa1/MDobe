import PDFKit
import SwiftUI

enum TableGrow { case row, column }

/// Petición de editar (o crear) un cuadro de texto, una tabla o una imagen: la vista la muestra como hoja.
struct ObjectEdit: Identifiable {
    enum Kind { case text, table, image }
    let id = UUID()
    let kind: Kind
    let page: PDFPage
    let point: CGPoint
    var object: MovableAnnotation?
}

/// Lo común del Mac y del iPad para cuadros de texto, imágenes y tablas. Todo pasa por el UndoManager.
@MainActor
protocol ObjectEditing: AnyObject {
    var undoManager: UndoManager? { get }
    var objectEdit: ObjectEdit? { get set }
    var objectNotice: String? { get set }
    var objectView: PDFView { get }
    func add(_ a: PDFAnnotation, to page: PDFPage)
    func remove(_ a: PDFAnnotation, from page: PDFPage)
    /// Vuelve a pintar la página tras cambiar un objeto.
    func refresh(_ page: PDFPage)
}

extension ObjectEditing {
    func registerChange(_ a: MovableAnnotation, on page: PDFPage, restore: @escaping () -> Void) {
        undoManager?.registerUndo(withTarget: self) { ed in
            let redo = a.capture()
            restore()
            ed.refresh(page)
            ed.registerChange(a, on: page, restore: redo)
        }
    }

    func finishDrag(_ drag: ObjectDrag) {
        guard drag.moved else { return }
        drag.finish()
        refresh(drag.page)
        registerChange(drag.object, on: drag.page, restore: drag.restore)
        undoManager?.setActionName("Mover")
    }

    /// Toque o clic con la herramienta de texto: edita lo que haya debajo o empieza un cuadro nuevo.
    func beginText(at point: CGPoint, on page: PDFPage) {
        if let hit = PageObjects.object(at: point, on: page, tolerance: 4 / max(objectView.scaleFactor, 0.1)) {
            edit(hit, on: page)
        } else {
            objectEdit = ObjectEdit(kind: .text, page: page, point: point)
        }
    }

    func edit(_ object: MovableAnnotation, on page: PDFPage) {
        let kind: ObjectEdit.Kind = object is TextBox ? .text : object is TableBox ? .table : .image
        objectEdit = ObjectEdit(kind: kind, page: page, point: .zero, object: object)
    }

    /// nil = borrar la imagen.
    func commitImage(_ edit: ObjectEdit, _ change: ImageChange?) {
        guard let box = edit.object as? ImageBox else { return }
        guard let change else {
            remove(box, from: edit.page)
            undoManager?.setActionName("Borrar imagen")
            return
        }
        let restore = box.capture()
        guard box.apply(change) else {
            objectNotice = "No he podido editar la imagen."
            return
        }
        refresh(edit.page)
        registerChange(box, on: edit.page, restore: restore)
        undoManager?.setActionName("Editar imagen")
    }

    /// Texto vacío = borrar el cuadro.
    func commitText(_ edit: ObjectEdit, _ text: String, size: CGFloat, color: Color) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let color = PlatformColor(color)
        let maxX = edit.page.bounds(for: .cropBox).maxX - 8
        if let box = edit.object as? TextBox {
            guard !text.isEmpty else {
                remove(box, from: edit.page)
                undoManager?.setActionName("Borrar texto")
                return
            }
            let restore = box.capture()
            box.set(text, size: size, color: color, topLeft: CGPoint(x: box.bounds.minX, y: box.bounds.maxY), maxX: maxX)
            refresh(edit.page)
            registerChange(box, on: edit.page, restore: restore)
            undoManager?.setActionName("Editar texto")
        } else if !text.isEmpty {
            add(TextBox.make(text, size: size, color: color, topLeft: edit.point, on: edit.page), to: edit.page)
            undoManager?.setActionName("Añadir texto")
        }
    }

    /// nil = borrar la tabla.
    func commitTable(_ edit: ObjectEdit, _ model: TableModel?) {
        if let table = edit.object as? TableBox {
            guard let model else {
                remove(table, from: edit.page)
                undoManager?.setActionName("Borrar tabla")
                return
            }
            let restore = table.capture()
            table.apply(model)
            refresh(edit.page)
            registerChange(table, on: edit.page, restore: restore)
            undoManager?.setActionName("Editar tabla")
        } else if let model {
            add(TableBox.make(model, topLeft: edit.point), to: edit.page)
            undoManager?.setActionName("Insertar tabla")
        }
    }

    func insertImage(_ data: Data) {
        guard let (page, center) = PageObjects.visibleCenter(in: objectView) else { return }
        insertImage(data, on: page, at: center)
    }

    func insertImage(_ data: Data, on page: PDFPage, at center: CGPoint) {
        guard let box = ImageBox.make(data, center: center, on: page) else {
            objectNotice = "No he podido leer esa imagen."
            return
        }
        add(box, to: page)
        undoManager?.setActionName("Insertar imagen")
    }

    func insertTable() {
        guard let (page, center) = PageObjects.visibleCenter(in: objectView) else { return }
        insertTable(on: page, at: center)
    }

    func insertTable(on page: PDFPage, at center: CGPoint) {
        let size = TableModel.blank.size, crop = page.bounds(for: .cropBox)
        let corner = CGPoint(x: max(crop.minX + 20, min(center.x - size.width / 2, crop.maxX - 20 - size.width)),
                             y: min(crop.maxY - 20, max(center.y + size.height / 2, crop.minY + 20 + size.height)))
        objectEdit = ObjectEdit(kind: .table, page: page, point: corner)
    }

    /// Añade una fila debajo o una columna a la derecha de la tabla que hay en `point`
    /// (una tabla nuestra, o una dibujada en el PDF: se continúa con sus mismas líneas).
    func growTable(_ grow: TableGrow, at point: CGPoint, on page: PDFPage) {
        if let table = PageObjects.object(at: point, on: page, tolerance: 2) as? TableBox {
            return change(table, on: page, grow)
        }
        guard let grid = TableFinder.find(on: page, at: point) else {
            objectNotice = "No encuentro una tabla con líneas en ese sitio. Pulsa dentro de una celda de la tabla, o usa Insertar → Tabla para crear una nueva."
            return
        }
        let left = grid.xs[0], right = grid.xs[grid.xs.count - 1], top = grid.ys[0], bottom = grid.ys[grid.ys.count - 1]
        // Si ya la habíamos ampliado, se sigue ampliando esa misma continuación.
        let corner = grow == .row ? CGPoint(x: left, y: bottom) : CGPoint(x: right, y: top)
        if let ext = page.annotations.compactMap({ $0 as? TableBox })
            .first(where: { abs($0.gridTopLeft.x - corner.x) < 3 && abs($0.gridTopLeft.y - corner.y) < 3 }) {
            return change(ext, on: page, grow)
        }
        var model: TableModel
        switch grow {
        case .row:
            let cols = zip(grid.xs.dropFirst(), grid.xs).map { $0 - $1 }
            model = TableModel(cols: cols, rows: [grid.rowHeight], cells: [Array(repeating: "", count: cols.count)])
            model.top = false
        case .column:
            let rows = zip(grid.ys, grid.ys.dropFirst()).map { $0 - $1 }
            let width = grid.xs.count > 2 ? grid.xs[grid.xs.count - 1] - grid.xs[grid.xs.count - 2] : 80
            model = TableModel(cols: [width], rows: rows, cells: rows.map { _ in [""] })
            model.left = false
        }
        model.fontSize = grid.fontSize
        model.lineWidth = grid.lineWidth
        model.verticals = grid.verticals
        let table = TableBox.make(model, topLeft: corner)
        add(table, to: page)
        undoManager?.setActionName(grow == .row ? "Añadir fila" : "Añadir columna")
        objectEdit = ObjectEdit(kind: .table, page: page, point: corner, object: table)
    }

    private func change(_ table: TableBox, on page: PDFPage, _ grow: TableGrow) {
        let restore = table.capture()
        var m = table.model
        if grow == .row { m.addRow() } else { m.addColumn() }
        table.apply(m)
        refresh(page)
        registerChange(table, on: page, restore: restore)
        undoManager?.setActionName(grow == .row ? "Añadir fila" : "Añadir columna")
    }
}

// MARK: Hojas de edición

struct ObjectEditSheet: View {
    let edit: ObjectEdit
    var defaultColor: Color = .black
    let editor: ObjectEditing

    var body: some View {
        switch edit.kind {
        case .text:
            let box = edit.object as? TextBox
            TextBoxSheet(text: box?.contents ?? "", size: box?.font?.pointSize ?? 12,
                         color: box?.fontColor.map { Color(cgColor: $0.cgColor) } ?? defaultColor, isNew: box == nil) {
                editor.commitText(edit, $0, size: $1, color: $2)
            }
        case .table:
            TableSheet(model: (edit.object as? TableBox)?.model ?? .blank, isNew: edit.object == nil) {
                editor.commitTable(edit, $0)
            }
        case .image:
            if let image = (edit.object as? ImageBox)?.image {
                ImageSheet(image: image) { editor.commitImage(edit, $0) }
            }
        }
    }
}

struct TextBoxSheet: View {
    @State private var text: String
    @State private var size: CGFloat
    @State private var color: Color
    let isNew: Bool
    let done: (String, CGFloat, Color) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    init(text: String, size: CGFloat, color: Color, isNew: Bool, done: @escaping (String, CGFloat, Color) -> Void) {
        _text = State(initialValue: text)
        _size = State(initialValue: size)
        _color = State(initialValue: color)
        self.isNew = isNew
        self.done = done
    }

    private var sizes: [CGFloat] { Array(Set([9, 11, 14, 18, 24, size])).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Añadir texto" : "Editar texto").font(.headline)
            TextEditor(text: $text)
                .font(.system(size: 15))
                .focused($focused)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            HStack {
                Picker("Tamaño", selection: $size) {
                    ForEach(sizes, id: \.self) { Text("\(Int($0)) pt").tag($0) }
                }
                .pickerStyle(.segmented)
                ColorPicker("Color", selection: $color).labelsHidden()
            }
            HStack {
                if !isNew {
                    Button("Eliminar", role: .destructive) { done("", size, color); dismiss() }
                }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Añadir" : "Guardar") { done(text, size, color); dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Después puedes arrastrar el cuadro para moverlo; por su esquina de abajo a la derecha cambias el ancho.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(minWidth: 440)
        .onAppear { focused = true }
    }
}

struct TableSheet: View {
    @State private var model: TableModel
    let isNew: Bool
    let done: (TableModel?) -> Void
    @Environment(\.dismiss) private var dismiss

    init(model: TableModel, isNew: Bool, done: @escaping (TableModel?) -> Void) {
        _model = State(initialValue: model)
        self.isNew = isNew
        self.done = done
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Nueva tabla" : "Tabla").font(.headline)
            HStack {
                Button("Fila", systemImage: "plus") { model.addRow() }
                Button("Columna", systemImage: "plus") { model.addColumn() }
                Button("Fila", systemImage: "minus") { model.removeRow() }.disabled(model.rows.count < 2)
                Button("Columna", systemImage: "minus") { model.removeColumn() }.disabled(model.cols.count < 2)
                Spacer()
                Stepper("Letra \(Int(model.fontSize)) pt", value: $model.fontSize, in: 6...24).fixedSize()
            }
            .buttonStyle(.bordered)
            ScrollView([.horizontal, .vertical]) {
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(model.rows.indices, id: \.self) { r in
                        GridRow {
                            ForEach(model.cols.indices, id: \.self) { c in
                                TextField("", text: cell(r, c), axis: .vertical)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: max(80, min(220, model.cols[c] * 1.3)))
                            }
                        }
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 160, maxHeight: 360)
            Toggle("Líneas verticales", isOn: $model.verticals)
            HStack {
                if !isNew {
                    Button("Eliminar tabla", role: .destructive) { done(nil); dismiss() }
                }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Insertar" : "Guardar") { done(model); dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(minWidth: 520)
    }

    private func cell(_ r: Int, _ c: Int) -> Binding<String> {
        Binding(get: { r < model.cells.count && c < model.cells[r].count ? model.cells[r][c] : "" },
                set: { if r < model.cells.count, c < model.cells[r].count { model.cells[r][c] = $0 } })
    }
}

/// Recortar, girar y cambiar el tamaño de una imagen.
struct ImageSheet: View {
    @State private var shown: CGImage
    @State private var change = ImageChange()
    let done: (ImageChange?) -> Void
    @Environment(\.dismiss) private var dismiss

    init(image: CGImage, done: @escaping (ImageChange?) -> Void) {
        _shown = State(initialValue: image)
        self.done = done
    }

    private var full: CGRect { CGRect(x: 0, y: 0, width: 1, height: 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Editar imagen").font(.headline)
            CropView(image: shown, crop: $change.crop)
                .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 420)
            HStack {
                Button("Girar", systemImage: "rotate.right") {
                    guard let r = ImageData.rotated(shown, quarterTurns: 1) else { return }
                    shown = r
                    change.turns += 1
                    change.crop = full
                }
                Button("Quitar recorte") { change.crop = full }
                    .disabled(change.crop == full)
                Spacer()
            }
            HStack {
                Text("Tamaño")
                Slider(value: $change.scale, in: 0.25...3)
                Text("\(Int((change.scale * 100).rounded())) %").monospacedDigit().frame(width: 52, alignment: .trailing)
                Button("100 %") { change.scale = 1 }.disabled(change.scale == 1)
            }
            HStack {
                Button("Eliminar", role: .destructive) { done(nil); dismiss() }
                Spacer()
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Guardar") { done(change); dismiss() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            Text("Arrastra las esquinas para recortar. También puedes cambiar el tamaño en la página arrastrando la esquina de abajo a la derecha de la imagen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(minWidth: 480)
    }
}

/// La imagen con un marco de recorte: se arrastra por las esquinas o entero.
private struct CropView: View {
    let image: CGImage
    @Binding var crop: CGRect
    @State private var start: CGRect?

    private enum Handle { case move, corner(left: Bool, top: Bool) }
    private static let corners = [(true, true), (false, true), (true, false), (false, false)]

    var body: some View {
        Image(decorative: image, scale: 1)
            .resizable()
            .aspectRatio(CGFloat(image.width) / CGFloat(image.height), contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    let size = geo.size
                    let r = CGRect(x: crop.minX * size.width, y: crop.minY * size.height,
                                   width: crop.width * size.width, height: crop.height * size.height)
                    ZStack(alignment: .topLeading) {
                        Path { p in
                            p.addRect(CGRect(origin: .zero, size: size))
                            p.addRect(r)
                        }
                        .fill(.black.opacity(0.5), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                        Rectangle()
                            .stroke(.white, lineWidth: 1.5)
                            .contentShape(Rectangle())
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                            .gesture(drag(.move, size))
                        ForEach(0..<4, id: \.self) { i in
                            let (left, top) = Self.corners[i]
                            Circle()
                                .fill(.white)
                                .overlay(Circle().stroke(.black.opacity(0.4)))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle().inset(by: -10))
                                .position(x: left ? r.minX : r.maxX, y: top ? r.minY : r.maxY)
                                .gesture(drag(.corner(left: left, top: top), size))
                        }
                    }
                }
            }
    }

    private func drag(_ handle: Handle, _ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let s = start ?? crop
                start = s
                let dx = g.translation.width / max(size.width, 1), dy = g.translation.height / max(size.height, 1)
                switch handle {
                case .move:
                    crop.origin = CGPoint(x: min(max(0, s.minX + dx), 1 - s.width), y: min(max(0, s.minY + dy), 1 - s.height))
                case .corner(let left, let top):
                    let m: CGFloat = 0.05
                    var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
                    if left { minX = min(max(0, s.minX + dx), maxX - m) } else { maxX = max(min(1, s.maxX + dx), minX + m) }
                    if top { minY = min(max(0, s.minY + dy), maxY - m) } else { maxY = max(min(1, s.maxY + dy), minY + m) }
                    crop = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                }
            }
            .onEnded { _ in start = nil }
    }
}
