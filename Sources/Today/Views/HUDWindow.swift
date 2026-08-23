import AppKit
import SwiftUI

/// L'accusé de réception : une pastille en bas de l'ÉCRAN, comme le HUD de Raycast ou celui du volume
/// de macOS. Elle rend compte d'un geste dont le résultat n'est pas à l'écran — une tâche déposée par
/// la capsule alors qu'on est dans une autre app, un Pomodoro lancé au clavier sans venir à la
/// fenêtre. Là où le résultat se VOIT (une rangée qui apparaît dans une liste), elle n'a rien à dire.
///
/// Un `NSPanel` hors de l'arbre de vues, pour la même raison que la capsule : il doit s'afficher
/// par-dessus l'app de premier plan sans jamais lui prendre le focus (`orderFrontRegardless` +
/// `ignoresMouseEvents`). Le panneau est fabriqué UNE fois et resservi : deux dépôts d'affilée
/// remplacent le texte de la pastille au lieu de la faire rentrer et sortir deux fois.
@MainActor
final class HUDWindow {
  static let shared = HUDWindow()

  /// Combien de temps la pastille reste lisible avant de s'effacer.
  private static let visibleDuration = Duration.milliseconds(1600)
  private static let fadeDuration = Duration.milliseconds(220)
  private static let entrance = Animation.spring(duration: 0.32, bounce: 0.28)
  private static let exit = Animation.easeOut(duration: 0.20)

  /// Volontairement plus grand que la pastille, et transparent : le ressort d'entrée doit avoir de
  /// la marge où déborder, et le verre a besoin de composer sur ce qu'il y a derrière.
  private static let panelSize = NSSize(width: 620, height: 140)
  /// Mesuré, pas choisi : `visibleFrame` ne réserve RIEN pour un Dock en masquage automatique (il
  /// vaut alors le `frame` entier), et la pastille se retrouvait posée sur les icônes dès que le
  /// Dock se montrait. La marge place son bas à ~100 pt du bord, au-dessus d'un Dock déplié.
  private static let bottomMargin: CGFloat = 52

  private let state = HUDState()
  private var panel: NSPanel?
  private var dismissal: Task<Void, Never>?

  private init() {}

  /// `tint` colore le carré de l'icône — vert pour une création, rien pour le reste : une pastille
  /// qui teinte TOUT ce qu'elle annonce ne distingue plus rien.
  static func show(_ message: String, systemImage: String = "checkmark", tint: Color? = nil) {
    shared.present(message, systemImage: systemImage, tint: tint)
  }

  /// La pastille d'une phase qui S'OUVRE — même texte, même icône, même couleur d'où qu'elle
  /// vienne : une fin d'étape (`PomodoroAlertWindow.announce`) ou une reprise depuis la capsule.
  /// Deux endroits l'écrivaient à la main, ils auraient divergé au premier ajustement.
  static func showPomodoro(_ phase: PomodoroPhase, duration: String) {
    let isWork = phase == .work
    show(
      phase.label + " · " + duration,
      systemImage: isWork ? "play.fill" : "cup.and.saucer.fill",
      tint: isWork ? .red : .blue)
  }

  private func present(_ message: String, systemImage: String, tint: Color?) {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    state.message = message
    state.icon = systemImage
    state.tint = tint
    place(panel)
    panel.orderFrontRegardless()
    withAnimation(Self.entrance) { state.isVisible = true }

    // La sortie est REPROGRAMMÉE à chaque appel : sans l'annulation, la pastille d'un premier dépôt
    // emporterait celle du second, affichée depuis un dixième de seconde.
    dismissal?.cancel()
    dismissal = Task { [weak self] in
      try? await Task.sleep(for: Self.visibleDuration)
      guard !Task.isCancelled, let self else { return }
      withAnimation(Self.exit) { self.state.isVisible = false }
      try? await Task.sleep(for: Self.fadeDuration)
      guard !Task.isCancelled else { return }
      // Retiré, pas détruit : le panneau resservira, et le reconstruire ferait repayer
      // l'instanciation de l'hôte SwiftUI à chaque tâche déposée.
      panel.orderOut(nil)
    }
  }

  private func makePanel() -> NSPanel {
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: Self.panelSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false  // l'ombre vient du verre, à la forme de la pastille
    panel.ignoresMouseEvents = true  // un accusé de réception ne se clique pas, et ne vole rien
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.canHide = false  // ⌘H ne doit pas emporter une pastille en cours d'affichage
    // Au-dessus de tout ce qui n'est pas système, comme le HUD du volume : la pastille rend compte
    // d'un geste fait DANS une autre app, elle serait sans objet cachée derrière elle.
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]

    let theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: AppTheme.storageKey) ?? "")
    let hosting = NSHostingView(
      rootView: HUDView(state: state)
        .preferredColorScheme((theme ?? .system).colorScheme))
    hosting.layer?.backgroundColor = .clear
    panel.contentView = hosting
    return panel
  }

  /// En bas, au milieu de l'écran ACTIF — celui où se trouve le curseur, pas celui de la fenêtre
  /// principale : le geste vient d'ailleurs, la réponse doit apparaître là où l'œil est déjà.
  private func place(_ panel: NSPanel) {
    let mouse = NSEvent.mouseLocation
    let screen =
      NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
    guard let visible = screen?.visibleFrame else { return panel.center() }
    panel.setFrameOrigin(
      NSPoint(
        x: visible.midX - Self.panelSize.width / 2,
        y: visible.minY + Self.bottomMargin))
  }
}

/// Ce que la pastille affiche. Un objet observé et pas un `@State` : l'ordre d'affichage vient
/// d'AppKit (une commande clavier, la fermeture de la capsule), hors de tout cycle de rendu.
@MainActor @Observable private final class HUDState {
  var message = ""
  var icon = "checkmark"
  var tint: Color?
  var isVisible = false
}

private struct HUDView: View {
  @Bindable var state: HUDState

  var body: some View {
    let shape = Capsule(style: .continuous)
    HStack(spacing: 10) {
      Image(systemName: state.icon)
        .font(.app(9, weight: .bold))
        // Teinté, le glyphe passe en blanc et non en `.primary` : sur un carré vert, un glyphe qui
        // suit le thème deviendrait noir en mode clair — illisible sur un fond de couleur pleine.
        .foregroundStyle(state.tint == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
        .frame(width: 18, height: 18)
        .background(
          state.tint ?? Color.primary.opacity(0.10),
          in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      Text(state.message)
        .font(.app(.headline))
        .lineLimit(1)
    }
    .padding(.leading, 10)
    .padding(.trailing, 18)
    .padding(.vertical, 10)
    .background(shape: shape)
    .scaleEffect(state.isVisible ? 1 : 0.90)
    .opacity(state.isVisible ? 1 : 0)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

extension View {
  /// Le même fond que les blocs de la capsule (cf. `QuickEntryPanel.pane`) : verre natif là où il
  /// existe, `.regularMaterial` ailleurs. Rien de figé en dur, donc rien à rejouer en mode sombre.
  ///
  /// Un aplat presque opaque SOUS le verre, contrairement à la capsule qui se contente d'un `tint`.
  /// Mesuré : la capsule se pose au-dessus d'une app, la pastille au-dessus de N'IMPORTE QUOI — sur
  /// une photo claire, le verre (même teinté à 0,90) laissait passer assez de lumière pour que le
  /// texte blanc du thème sombre devienne illisible. Le verre ne garde ici que son liseré et ses
  /// reflets de bord. `windowBackgroundColor` suit le thème, rien n'est figé en dur.
  @ViewBuilder
  fileprivate func background<S: InsettableShape>(shape: S) -> some View {
    if #available(macOS 26, *) {
      self
        .background { shape.fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)) }
        .glassEffect(
          .regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.45)), in: shape
        )
        .paneShadow()
    } else {
      self
        .background(.regularMaterial, in: shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
        .paneShadow()
    }
  }
}
