import AppKit
import SwiftUI

/// Les deux tailles de la fenêtre principale. Lues à deux endroits — la taille par défaut de la
/// scène (`TodayApp`) et le passage de l'une à l'autre (`OnboardingWindowFrame`) — qui ne peuvent
/// pas diverger.
enum MainWindowSize {
  static let app = CGSize(width: 1400, height: 900)
  /// Le carré de l'accueil, en zone de CONTENU — sous la barre de titre, comme SwiftUI la mesure : la
  /// fenêtre est plus haute de cette barre (cf. `OnboardingWindowFrame.onboardingFrameSize`). Sa
  /// hauteur est celle de l'écran le plus haut, un Mac dessiné au-dessus de ses réglages : fixe, pour
  /// que rien ne saute d'un écran à l'autre.
  static let onboarding = CGSize(width: 660, height: 760)
}

/// Pendant l'accueil, la fenêtre principale DEVIENT son carré : taille fixe, ni redimensionnement
/// ni plein écran. À la sortie, elle retrouve le cadre qu'elle avait — ou la taille de l'app, si elle
/// est née en carré.
///
/// La fenêtre elle-même, et pas une carte posée dedans : une carte laissait autour d'elle un grand
/// rectangle d'app floutée qui ne servait à rien. Et pas une seconde fenêtre non plus : un champ
/// focalisé veut une fenêtre conteneur gardée du début à la fin (→ `PIEGES.md` § Fenêtres), et
/// celle-ci l'est déjà.
///
/// Le changement de taille passe par AppKit (`setFrame(_:display:animate:)`) : ce qui fait paraître
/// ou changer une fenêtre appartient au calque, pas à SwiftUI (cf. CLAUDE.md § Animations).
struct OnboardingWindowFrame: NSViewRepresentable {
  let isActive: Bool

  @MainActor
  final class Coordinator {
    /// Ce qui est APPLIQUÉ à la fenêtre ; `nil` tant que rien ne l'a été.
    var applied: Bool?
    /// Le cadre de l'app à retrouver en sortant — retenu sur *Revoir l'accueil* seulement. `nil` :
    /// la taille de l'app, centrée sur l'écran.
    var appFrame: NSRect?
  }

  /// Prévient quand la vue entre dans sa fenêtre : au premier `updateNSView`, elle n'y est pas
  /// encore, et un seul report d'un tour de boucle ne garantit pas qu'elle y soit.
  final class HostView: NSView {
    var onWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      if window != nil { onWindow?() }
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> HostView { HostView() }

  func updateNSView(_ view: HostView, context: Context) {
    let wanted = isActive
    let coordinator = context.coordinator
    // `weak` : la vue garde la fermeture, qui la gardait en retour — ni l'une ni le coordinateur
    // n'étaient jamais libérés.
    view.onWindow = { [weak view] in
      guard let view else { return }
      Self.apply(wanted, to: view, coordinator)
    }
    Self.apply(wanted, to: view, coordinator)
  }

  private static func apply(_ wanted: Bool, to view: NSView, _ coordinator: Coordinator) {
    guard let window = view.window, coordinator.applied != wanted else { return }
    let isFirst = coordinator.applied == nil
    coordinator.applied = wanted
    // Un tour plus tard : on est en pleine mise à jour SwiftUI, et redimensionner la fenêtre
    // relancerait un layout dans celui qui s'exécute.
    DispatchQueue.main.async {
      if wanted {
        enter(window, coordinator, animate: !isFirst)
      } else if !isFirst || window.contentLayoutRect.size == MainWindowSize.onboarding {
        // Premier passage HORS accueil dans une fenêtre restée en carré : l'app a été quittée en
        // plein *Revoir l'accueil*, et SwiftUI a restauré le carré. Rien d'autre ne l'agrandirait.
        leave(window, coordinator, animate: !isFirst)
      }
    }
  }

  private static func enter(_ window: NSWindow, _ coordinator: Coordinator, animate: Bool) {
    // Le cadre de l'app ne se retient que sur *Revoir l'accueil* (`animate`) : au lancement, la
    // fenêtre est encore en construction et son cadre ne veut rien dire — mesuré 660 × 1 435 avant
    // que SwiftUI n'applique sa taille par défaut, et c'est ce cadre-là qu'on rendait en sortant.
    if animate { coordinator.appFrame = window.frame }
    window.styleMask.remove(.resizable)
    window.standardWindowButton(.zoomButton)?.isEnabled = false
    let size = onboardingFrameSize(for: window)
    let centered = NSRect(
      x: window.frame.midX - size.width / 2, y: window.frame.midY - size.height / 2,
      width: size.width, height: size.height)
    window.setFrame(fitted(centered, on: window), display: true, animate: animate)
  }

  private static func leave(_ window: NSWindow, _ coordinator: Coordinator, animate: Bool) {
    window.styleMask.insert(.resizable)
    window.standardWindowButton(.zoomButton)?.isEnabled = true
    let target = coordinator.appFrame ?? centeredAppFrame(on: window)
    coordinator.appFrame = nil
    window.setFrame(fitted(target, on: window), display: true, animate: animate)
  }

  /// Le carré, barre de titre comprise. Lue sur la fenêtre (`contentLayoutRect`) et pas écrite en
  /// dur : c'est la barre d'outils de SwiftUI qui en décide, et un cadre plus court que ce que le
  /// contenu exige était aussitôt réagrandi par SwiftUI.
  private static func onboardingFrameSize(for window: NSWindow) -> CGSize {
    let titlebar = window.frame.height - window.contentLayoutRect.height
    return CGSize(
      width: MainWindowSize.onboarding.width, height: MainWindowSize.onboarding.height + titlebar)
  }

  /// La taille de l'app, centrée sur l'écran de la fenêtre — et non sur la fenêtre, dont le carré
  /// peut avoir été déplacé contre un bord.
  private static func centeredAppFrame(on window: NSWindow) -> NSRect {
    let size = MainWindowSize.app
    let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
    return NSRect(
      x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
      width: size.width, height: size.height)
  }

  /// Ramène un cadre dans la zone utile de l'écran de la fenêtre : `setFrame` ne le fait pas, et
  /// 1 400 × 900 dépasse l'écran d'un MacBook Air 13 pouces.
  private static func fitted(_ frame: NSRect, on window: NSWindow) -> NSRect {
    guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return frame }
    var fitted = frame
    fitted.size.width = min(frame.width, visible.width)
    fitted.size.height = min(frame.height, visible.height)
    fitted.origin.x = min(max(frame.minX, visible.minX), visible.maxX - fitted.width)
    fitted.origin.y = min(max(frame.minY, visible.minY), visible.maxY - fitted.height)
    return fitted
  }
}

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
    // Fenêtre TRANSPARENTE : c'est la condition du verre. Un `NSVisualEffectView` en
    // `blendingMode = .behindWindow` (cf. `WindowGlass`) prélève ce qu'il y a DERRIÈRE la fenêtre —
    // le bureau. Tant que la fenêtre est opaque, il n'a rien à prélever et le matériau retombe sur
    // un gris plat : c'est exactement ce qu'on voyait avant, d'où les fonds opaques peints à la
    // main que ce chantier remplace.
    //
    // Les coins arrondis et l'ombre RESTENT natifs : c'est la vue de cadre d'AppKit qui masque le
    // contenu, pas le fond de la fenêtre. Rien à redessiner.
    //
    // Pas d'inset manuel des feux tricolores : la position native est celle voulue
    // (un décalage manuel se fait défaire par le relayout AppKit au premier clic).
    window.isOpaque = false
    window.backgroundColor = .clear
  }
}
