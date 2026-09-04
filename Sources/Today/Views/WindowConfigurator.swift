import AppKit
import SwiftUI

/// Fenêtre standard OPAQUE (coins + ombre natifs) en style toolbar unifiée + contenu plein cadre.
/// C'est la toolbar qui déclenche le gros rayon « moderne » ; la sidebar custom se fond derrière.
struct WindowConfigurator: NSViewRepresentable {
  /// Isolé au fil principal comme le reste d'AppKit : ses rappels ne partent que de la boucle
  /// d'événements. L'annotation écrit une contrainte déjà vraie, elle n'en ajoute aucune.
  @MainActor
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
      // AppKit assigne par défaut un "premier répondeur" initial au 1er champ de texte
      // focalisable rencontré (ici, un champ « Nouvelle tâche » ou le titre de page) — SANS
      // qu'aucune interaction réelle ne l'ait demandé. Résultat : `firstResponder` pointe déjà un
      // champ de texte avant même le premier clic, ce qui trompait `DeleteKeyMonitor` (il croit
      // qu'un champ a le focus et lui laisse ⌫, au lieu de supprimer la tâche qu'on vient de
      // sélectionner). Une seule fois, au lancement, avant toute interaction : on résigne ce
      // focus fantôme pour repartir d'un premier répondeur neutre (`nil` = la fenêtre).
      window.makeFirstResponder(nil)
      // SwiftUI (WindowGroup) réimpose son titre par défaut à chaque flush de la fenêtre
      // (ex. clic sur la sidebar) → il faut le remasquer après coup.
      //
      // Mais SEULEMENT le titre, et seulement s'il a bougé. `didUpdateNotification` est posté à
      // la fréquence d'affichage — mesuré ici : 120 fois par seconde, EN CONTINU, fenêtre au
      // repos et sans la moindre interaction. Y rejouer tout `configure()` réécrivait `styleMask`
      // et `toolbarStyle` à chaque image, ce qui resalit la fenêtre… qui reposte un `didUpdate` :
      // la boucle s'auto-entretenait et l'app ne redescendait jamais au repos.
      coordinator.observer = NotificationCenter.default.addObserver(
        forName: NSWindow.didUpdateNotification, object: window, queue: .main
      ) { _ in
        // `queue: .main` garantit le fil, mais la fermeture est `@Sendable` et le compilateur ne
        // peut pas le déduire de là. On l'affirme à l'endroit exact où c'est vrai.
        MainActor.assumeIsolated {
          if !window.title.isEmpty { window.title = "" }
        }
      }
    }
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {}

  /// L'observateur ci-dessus tire à la fréquence d'affichage (120 Hz, mesuré) et RETIENT la
  /// fenêtre par sa capture. Sans ce démontage, fermer la fenêtre au bouton rouge puis la rouvrir
  /// (⌘N, une commande de raccourci, le clic Dock) empilait un observateur de plus à chaque cycle,
  /// tous vivants pour le reste du process, chacun sur une fenêtre morte.
  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    if let observer = coordinator.observer {
      NotificationCenter.default.removeObserver(observer)
      coordinator.observer = nil
    }
  }

  /// Appelée UNE fois, au montage. Cf. l'observateur de `didUpdateNotification` ci-dessus pour
  /// pourquoi elle n'est pas rejouée ensuite.
  private func configure(_ window: NSWindow) {
    window.styleMask.insert(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.title = ""
    window.toolbarStyle = .unified
    // Une seule fenêtre, donc AUCUN onglet : sans ça macOS garde *Présentation ▸ Afficher la
    // barre d'onglets* et les cinq entrées d'onglets du menu *Fenêtre*, toutes sans objet. C'est
    // ce regroupement en onglets qui faisait ouvrir un onglet sur ⌘N (cf. `MainMenuCommands`).
    window.tabbingMode = .disallowed
    // Fenêtre laissée OPAQUE → macOS dessine coins + ombre natifs.
    // Pas d'inset manuel des feux tricolores : la position native est celle voulue
    // (un décalage manuel se fait défaire par le relayout AppKit au premier clic).
  }
}
