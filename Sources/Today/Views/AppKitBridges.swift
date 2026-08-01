import AppKit
import SwiftUI

/// Les ponts vers AppKit que SwiftUI ne fournit pas : curseur en zone précise, clic droit, clic
/// hors zone, ⌫ et raccourcis clavier au niveau fenêtre.
///
/// AUCUN ne connaît la moindre notion de tâche ou de liste — ce sont des primitives d'interaction,
/// réutilisables telles quelles par n'importe quelle vue (cf. `WindowConfigurator`, qui se sert
/// déjà de `DeleteKeyMonitor`). Elles n'avaient donc rien à faire dans la page d'une liste.
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
/// clic droit à CÔTÉ, via un moniteur NSEvent (même mécanisme que `DeleteKeyMonitor`) qui ne
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

/// Surveille ⌫ (retour arrière, keyCode 51) au niveau de la fenêtre, hors du système de focus
/// SwiftUI : `.keyboardShortcut`/`.onKeyPress` sans modificateur n'atteignent leur gestionnaire que
/// s'il existe DÉJÀ un premier répondeur AppKit dans la fenêtre — une ligne juste sélectionnée
/// (tap, aucun champ focalisé) n'en établit aucun. Un moniteur local d'événements voit la touche
/// AVANT sa distribution normale, quel que soit le premier répondeur : ni la sélection d'une ligne
/// ni son absence n'entrent en jeu. Il se retire lui-même dès qu'un VRAI champ de texte a le focus
/// (même check `NSText` que `SidebarView.editableTitle`) pour ne jamais lui voler la frappe.
struct DeleteKeyMonitor: NSViewRepresentable {
  var isActive: () -> Bool
  var action: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(isActive: isActive, action: action) }

  func makeNSView(context: Context) -> NSView {
    context.coordinator.install()
    return NSView(frame: .zero)
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.isActive = isActive
    context.coordinator.action = action
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.uninstall()
  }

  /// Isolé au fil principal comme le reste d'AppKit : ses rappels ne partent que de la boucle
  /// d'événements. L'annotation écrit une contrainte déjà vraie, elle n'en ajoute aucune.
  @MainActor
  final class Coordinator {
    var isActive: () -> Bool
    var action: () -> Void
    private var monitor: Any?

    init(isActive: @escaping () -> Bool, action: @escaping () -> Void) {
      self.isActive = isActive
      self.action = action
    }

    func install() {
      guard monitor == nil else { return }
      let ignoredMods: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.keyCode == 51,
          event.modifierFlags.intersection(ignoredMods).isEmpty, self.isActive()
        else { return event }
        // Un vrai champ de texte a le focus (renommage, notes, « Nouvelle tâche »…) : on le
        // laisse gérer sa propre frappe, ⌫ ne doit jamais lui échapper.
        if NSApp.keyWindow?.firstResponder is NSText { return event }
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

/// Raccourci clavier sur `keyCode` + un jeu EXACT de modificateurs, câblé en direct sur NSEvent
/// (même mécanisme que `DeleteKeyMonitor` ci-dessus) — pour ⌘N/⌘⇧N : deux `.keyboardShortcut` sur
/// la même lettre avec des modificateurs différents se marchent dessus sous SwiftUI (⌘⇧N avalé
/// par le gestionnaire ⌘N), ce moniteur compare les modificateurs à l'égalité et évite le conflit.
struct KeyCommandMonitor: NSViewRepresentable {
  var keyCode: UInt16
  var modifiers: NSEvent.ModifierFlags
  var action: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(modifiers: modifiers, action: action) }

  func makeNSView(context: Context) -> NSView {
    context.coordinator.install(keyCode: keyCode)
    return NSView(frame: .zero)
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

    func install(keyCode: UInt16) {
      guard monitor == nil else { return }
      let relevantMods: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
      monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
        guard let self, event.keyCode == keyCode,
          event.modifierFlags.intersection(relevantMods) == self.modifiers
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
