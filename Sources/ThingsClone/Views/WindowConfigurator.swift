import AppKit
import SwiftUI

/// Fenêtre standard OPAQUE (coins + ombre natifs) en style toolbar unifiée + contenu plein cadre.
/// C'est la toolbar qui déclenche le gros rayon « moderne » ; la sidebar custom se fond derrière.
struct WindowConfigurator: NSViewRepresentable {
  final class Coordinator {
    var observer: NSObjectProtocol?
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    let coordinator = context.coordinator
    DispatchQueue.main.async {
      guard let window = view.window else { return }
      configure(window)
      // SwiftUI (WindowGroup) réimpose son titre par défaut à chaque flush de la fenêtre
      // (ex. clic sur la sidebar) → on réapplique le masquage à chaque update plutôt
      // qu'une seule fois au lancement.
      coordinator.observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didUpdateNotification, object: window, queue: .main
      ) { _ in configure(window) }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  private func configure(_ window: NSWindow) {
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.title = ""
    window.toolbarStyle = .unified
    // Fenêtre laissée OPAQUE → macOS dessine coins + ombre natifs.
    // Pas d'inset manuel des feux tricolores : la position native est celle voulue
    // (un décalage manuel se fait défaire par le relayout AppKit au premier clic).
  }
}
