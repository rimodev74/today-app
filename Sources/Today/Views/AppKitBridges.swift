import AppKit
import SwiftUI

/// Les ponts vers AppKit que SwiftUI ne fournit pas : curseur en zone précise, clic droit, clic
/// hors zone, touches de sélection (⌫, ↑/↓) et raccourcis clavier au niveau fenêtre.
///
/// AUCUN ne connaît la moindre notion de tâche ou de liste — ce sont des primitives d'interaction,
/// réutilisables telles quelles par n'importe quelle vue (cf. `WindowConfigurator`, qui se sert
/// déjà de `TaskKeyMonitor`). Elles n'avaient donc rien à faire dans la page d'une liste.
///
/// Chacun démonte son moniteur dans `dismantleNSView` : un moniteur `NSEvent` laissé installé
/// continue d'avaler les frappes de toute l'app (cf. CLAUDE.md, « Ce qui s'installe se démonte »).
/// Curseur « main » fiable sur une zone précise, via les cursor rects AppKit natifs — cf. le
/// commentaire sur `TaskCheckbox`. `resetCursorRects()` est appelé par AppKit lui-même à chaque
/// invalidation de layout, pas par un `.onHover` concurrent d'une vue englobante.
struct PointingHandCursorArea: NSViewRepresentable {
  final class CursorView: NSView {
    override func resetCursorRects() {
      super.resetCursorRects()
      addCursorRect(bounds, cursor: .pointingHand)
    }
  }

  func makeNSView(context: Context) -> NSView { CursorView() }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Clic droit sur une tâche → bascule en édition, EN PLUS du menu contextuel natif (`taskMenu`).
/// SwiftUI ne notifie pas l'ouverture d'un `.contextMenu` (pas de hook « avant présentation ») ;
/// une première tentative interceptait l'événement AppKit directement sur la ligne, mais son
/// propre hit-test empêchait alors la sélection ET le menu de se déclencher. On observe donc le
/// clic droit à CÔTÉ, via un moniteur NSEvent (même mécanisme que `TaskKeyMonitor`) qui ne
/// consomme JAMAIS l'événement (toujours `return event`) et retrouve la ligne visée par géométrie,
/// dans le même espace de coordonnées (`Self.dragSpace`) que `rowFrames` — sans jamais toucher au
/// menu natif, qui continue de s'afficher par son propre mécanisme, intact.
struct RightClickObserver: NSViewRepresentable {
  var onRightClick: (CGPoint) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onRightClick: onRightClick) }

  func makeNSView(context: Context) -> NSView {
    let view = HitTestView()
    context.coordinator.view = view
    context.coordinator.install()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.onRightClick = onRightClick
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  /// Origine haut-gauche, comme tous les espaces de coordonnées SwiftUI (dont `Self.dragSpace`) :
  /// sans ce `isFlipped`, la conversion depuis `event.locationInWindow` (origine bas-gauche AppKit)
  /// donnerait un point inversé en Y par rapport à `rowFrames`.
  final class HitTestView: NSView {
    override var isFlipped: Bool { true }
  }

  /// Isolé au fil principal comme le reste d'AppKit : ses rappels ne partent que de la boucle
  /// d'événements. L'annotation écrit une contrainte déjà vraie, elle n'en ajoute aucune.
  @MainActor
  final class Coordinator {
    var onRightClick: (CGPoint) -> Void
    weak var view: NSView?
    private var monitor: Any?

    init(onRightClick: @escaping (CGPoint) -> Void) { self.onRightClick = onRightClick }

    func install() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
        guard let self, let view = self.view, event.window == view.window else { return event }
        let point = view.convert(event.locationInWindow, from: nil)
        if view.bounds.contains(point) { self.onRightClick(point) }
        return event
      }
    }

    func uninstall() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

/// Clic gauche N'IMPORTE OÙ dans la fenêtre → `ListPageView` décide (via `dismissSelectionIfOutside`)
/// si ça retombe sur une ligne ou pas. Un `.background` posé sur le CONTENU du ScrollView (essayé
/// d'abord) ne couvre que sa largeur RENDUE — pas les marges (`gutter`), pas la zone au-dessus de
/// la page, et jamais la sidebar (hors de cet arbre de vues). Même mécanisme que
/// `RightClickObserver` : un moniteur NSEvent voit TOUT clic de la fenêtre, ne le consomme JAMAIS
/// (toujours `return event`, aucun risque de voler un clic destiné à un contrôle), et le convertit
/// dans le même repère (`Self.dragSpace`) que `rowFrames` pour la comparaison géométrique.
struct LeftClickOutsideObserver: NSViewRepresentable {
  var onClick: (CGPoint) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onClick: onClick) }

  func makeNSView(context: Context) -> NSView {
    let view = HitTestView()
    context.coordinator.view = view
    context.coordinator.install()
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.onClick = onClick
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  /// Origine haut-gauche, comme `Self.dragSpace` : cf. `RightClickObserver.HitTestView`.
  final class HitTestView: NSView {
    override var isFlipped: Bool { true }
  }

  /// Isolé au fil principal comme le reste d'AppKit : ses rappels ne partent que de la boucle
  /// d'événements. L'annotation écrit une contrainte déjà vraie, elle n'en ajoute aucune.
  @MainActor
  final class Coordinator {
    var onClick: (CGPoint) -> Void
    weak var view: NSView?
    private var monitor: Any?

    init(onClick: @escaping (CGPoint) -> Void) { self.onClick = onClick }

    func install() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
        guard let self, let view = self.view, event.window == view.window else { return event }
        self.onClick(view.convert(event.locationInWindow, from: nil))
        return event
      }
    }

    func uninstall() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

/// Les touches qui pilotent la SÉLECTION d'une page de tâches : ⌫ pour supprimer, ↑/↓ pour se
/// déplacer d'une ligne à l'autre.
///
/// Au niveau de la FENÊTRE, hors du système de focus SwiftUI : `.keyboardShortcut`/`.onKeyPress`
/// sans modificateur n'atteignent leur gestionnaire que s'il existe DÉJÀ un premier répondeur AppKit
/// dans la fenêtre — or une ligne juste sélectionnée (un tap, aucun champ focalisé) n'en établit
/// aucun. Un moniteur local voit la touche AVANT sa distribution normale, quel que soit le premier
/// répondeur : ni la sélection d'une ligne ni son absence n'entrent en jeu.
///
/// C'est la PAGE qui écoute, pas la rangée — la sélection n'appartient à aucune vue en particulier,
/// et une ligne non focalisée ne recevrait jamais de frappe.
///
/// Il se retire de lui-même dès qu'un VRAI champ de texte a le focus (même contrôle `NSText` que
/// `SidebarView.editableTitle`) : ⌫ et les flèches y ont un tout autre sens, et ne doivent jamais
/// lui être volées.
///
/// Les rappels rendent « ai-je agi ? », et l'événement n'est consommé QUE dans ce cas. Un moniteur
/// local avale la touche pour toute la fenêtre : la retenir sans rien en faire (aucune sélection,
/// bord de liste atteint) la vole à qui aurait pu s'en servir — le défilement d'une ↓, la touche
/// répétée d'un futur gestionnaire — et le symptôme se lit comme « le clavier est mort sur cette
/// page ».
struct TaskKeyMonitor: NSViewRepresentable {
  /// La page est-elle en état de consommer ces touches ? Faux dès qu'une carte d'édition est
  /// ouverte : les flèches appartiennent alors au texte.
  var isActive: () -> Bool
  /// Rendent `true` si la touche a produit un effet ; elle n'est consommée qu'alors.
  var onDelete: () -> Bool
  /// -1 vers le haut, +1 vers le bas.
  var onMove: (Int) -> Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(isActive: isActive, onDelete: onDelete, onMove: onMove)
  }

  func makeNSView(context: Context) -> NSView {
    let host = NSView(frame: .zero)
    context.coordinator.host = host
    context.coordinator.install()
    return host
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.isActive = isActive
    context.coordinator.onDelete = onDelete
    context.coordinator.onMove = onMove
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  /// Isolé au fil principal comme le reste d'AppKit : ses rappels ne partent que de la boucle
  /// d'événements. L'annotation écrit une contrainte déjà vraie, elle n'en ajoute aucune.
  @MainActor
  final class Coordinator {
    var isActive: () -> Bool
    var onDelete: () -> Bool
    var onMove: (Int) -> Bool
    private var monitor: Any?

    init(
      isActive: @escaping () -> Bool, onDelete: @escaping () -> Bool,
      onMove: @escaping (Int) -> Bool
    ) {
      self.isActive = isActive
      self.onDelete = onDelete
      self.onMove = onMove
    }

    /// La vue qui porte ce moniteur — sa fenêtre est la SEULE dans laquelle il doit agir. Même
    /// raison que dans `KeyCommandMonitor` : un moniteur local écoute toute l'APPLICATION. Ce
    /// moniteur-ci s'en tirait par un effet de bord (son test « un champ texte a le focus ? »
    /// écarte la capsule de saisie rapide et les Réglages, où l'on tape toujours dans un champ),
    /// mais rien ne le garantissait — une fenêtre auxiliaire sans champ texte aurait vu ⌫
    /// supprimer une tâche dans la fenêtre de derrière.
    weak var host: NSView?

    func install() {
      guard monitor == nil else { return }
      // Sans modificateur : ⌘⌫ ou ⌥↑ appartiennent à d'autres gestes, existants ou à venir.
      let ignored: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.modifierFlags.intersection(ignored).isEmpty, self.isActive(),
          let window = self.host?.window, event.window === window
        else { return event }
        if NSApp.keyWindow?.firstResponder is NSText { return event }

        let handled: Bool
        switch Int(event.keyCode) {
        case 51: handled = self.onDelete()
        case 126: handled = self.onMove(-1)
        case 125: handled = self.onMove(1)
        default: return event
        }
        return handled ? nil : event  // rendue intacte si elle n'a rien fait
      }
    }

    func uninstall() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

/// Raccourci clavier sur `keyCode` + un jeu EXACT de modificateurs, câblé en direct sur NSEvent
/// (même mécanisme que `TaskKeyMonitor` ci-dessus) — pour ⌘N/⌘⇧N : deux `.keyboardShortcut` sur
/// la même lettre avec des modificateurs différents se marchent dessus sous SwiftUI (⌘⇧N avalé
/// par le gestionnaire ⌘N), ce moniteur compare les modificateurs à l'égalité et évite le conflit.
struct KeyCommandMonitor: NSViewRepresentable {
  var keyCode: UInt16
  var modifiers: NSEvent.ModifierFlags
  var action: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(modifiers: modifiers, action: action) }

  func makeNSView(context: Context) -> NSView {
    let host = NSView(frame: .zero)
    context.coordinator.host = host
    context.coordinator.install(keyCode: keyCode)
    return host
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.modifiers = modifiers
    context.coordinator.action = action
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  /// Isolé au fil principal comme le reste d'AppKit : ses rappels ne partent que de la boucle
  /// d'événements. L'annotation écrit une contrainte déjà vraie, elle n'en ajoute aucune.
  @MainActor
  final class Coordinator {
    var modifiers: NSEvent.ModifierFlags
    var action: () -> Void
    private var monitor: Any?

    init(modifiers: NSEvent.ModifierFlags, action: @escaping () -> Void) {
      self.modifiers = modifiers
      self.action = action
    }

    /// La vue qui porte ce moniteur — sa fenêtre est la SEULE dans laquelle il doit agir.
    ///
    /// `addLocalMonitorForEvents` écoute toute l'APPLICATION, pas une fenêtre. Sans cette garde,
    /// ⌘N frappé dans les Réglages ou dans la capsule de saisie rapide créait une tâche dans la
    /// fenêtre principale, derrière — une tâche apparue là où l'on ne regardait même pas.
    /// (`TaskKeyMonitor` échappait au même défaut par accident : son test « un champ texte a le
    /// focus ? » écarte la capsule, mais rien ne l'écartait par principe.)
    weak var host: NSView?

    func install(keyCode: UInt16) {
      guard monitor == nil else { return }
      let relevantMods: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.keyCode == keyCode,
          event.modifierFlags.intersection(relevantMods) == self.modifiers,
          let window = self.host?.window, event.window === window
        else { return event }
        self.action()
        return nil
      }
    }

    func uninstall() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}

/// Referme ce qui est accroché à une rangée dès que la liste DÉFILE.
///
/// Un popover est une fenêtre accrochée à une vue. Quand cette vue se déplace — et défiler la
/// déplace à chaque cran de molette — macOS ré-affiche la fenêtre pour la resituer, en plein calcul
/// de mise en page. C'est là qu'il a levé une exception dans `NSRemoteView` le 5 août 2026 (deux
/// rapports, `NSPopover showRelativeToRect:` en frame 19). Et même sans planter, le panneau
/// restait posé dans le vide, loin de la ligne qui l'avait ouvert.
///
/// Un moniteur `NSEvent`, comme les autres ponts de ce fichier, et pas une lecture de la position
/// de défilement : la molette est l'ÉVÉNEMENT, la position n'en est que la conséquence — et sur
/// macOS l'inertie continue de faire bouger la vue longtemps après le geste.
///
/// Installé UNIQUEMENT tant qu'il y a quelque chose à refermer (cf. son usage dans `TaskRow`) :
/// un moniteur par rangée, en permanence, ferait passer chaque cran de molette par autant de
/// fermetures que la page a de lignes.
struct ScrollDismissObserver: NSViewRepresentable {
  var onScroll: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

  func makeNSView(context: Context) -> NSView {
    context.coordinator.install()
    return NSView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.onScroll = onScroll
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  /// Isolé au fil principal comme le reste d'AppKit : ses rappels ne partent que de la boucle
  /// d'événements. L'annotation écrit une contrainte déjà vraie, elle n'en ajoute aucune.
  @MainActor
  final class Coordinator {
    var onScroll: () -> Void
    private var monitor: Any?

    init(onScroll: @escaping () -> Void) { self.onScroll = onScroll }

    func install() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        self?.onScroll()
        return event  // le défilement poursuit sa route : la liste bouge normalement
      }
    }

    func uninstall() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
  }
}
