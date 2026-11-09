import AppKit
import SwiftUI

extension View {
    /// Junta las ventanas de PDF en pestañas de una misma ventana, como Acrobat.
    func documentTabs() -> some View { background(TabbingHook()) }
}

private struct TabbingHook: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HookView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class HookView: NSView {
        static let identifier = "MDobe.documentos"
        private let plusButton = OpenOnNewTab()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.tabbingIdentifier != Self.identifier else { return }
            window.tabbingIdentifier = Self.identifier
            window.tabbingMode = .preferred
            // Si la ventana ya se ha mostrado suelta, se mete a mano en la ventana de PDFs que haya.
            DispatchQueue.main.async { [plusButton] in
                // El «+» de las pestañas abre un PDF en vez de crear uno en blanco.
                if window.nextResponder !== plusButton {
                    plusButton.nextResponder = window.nextResponder
                    window.nextResponder = plusButton
                }
                if (window.tabbedWindows?.count ?? 1) <= 1,
                   let host = NSApp.orderedWindows.first(where: { $0 !== window && $0.isVisible && $0.tabbingIdentifier == Self.identifier }) {
                    host.addTabbedWindow(window, ordered: .above)
                    window.makeKeyAndOrderFront(nil)
                }
                // La barra de pestañas siempre visible, aunque solo haya un PDF.
                if let group = window.tabGroup, !group.isTabBarVisible { window.toggleTabBar(nil) }
            }
        }
    }
}

/// Se mete en la cadena de respuesta de la ventana para atender el «+» de la barra de pestañas.
private final class OpenOnNewTab: NSResponder {
    override func newWindowForTab(_ sender: Any?) {
        NSDocumentController.shared.openDocument(sender)
    }
}
