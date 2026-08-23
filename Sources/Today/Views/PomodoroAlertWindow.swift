import AppKit
import SwiftUI

/// L'annonce VISUELLE d'une fin d'étape du pomodoro, dans la forme choisie par
/// `PomodoroAlertStyle` : la pastille du bas d'écran, ou un écran entier qu'il faut congédier.
///
/// Un `NSPanel` hors de l'arbre de vues, pour la même raison que la pastille et la capsule : il
/// doit couvrir n'importe quelle app de premier plan. Contrairement à la pastille, il PREND les
/// clics et la touche clavier — c'est son bouton qui ouvre la phase suivante. Fabriqué une fois et
/// resservi ; seul son contenu est neuf à chaque fin d'étape.
@MainActor
final class PomodoroAlertWindow {
  static let shared = PomodoroAlertWindow()

  /// L'entrée est plus longue que la sortie : l'écran s'impose doucement — il interrompt — et
  /// s'efface vite, une fois la réponse donnée.
  private static let fadeIn: CFTimeInterval = 0.45
  private static let fadeOut: CFTimeInterval = 0.22
  /// Sans réponse, l'écran s'efface de lui-même — exactement comme un « Fermer » : il n'ouvre PAS la
  /// phase suivante. Parti prendre un café, on retrouve le minuteur en attente, pas une pause à
  /// moitié écoulée.
  private static let autoDismissDelay = Duration.seconds(30)
  /// Même garde que `PomodoroSound.play` : les tests appellent `handlePhaseCompletion` en série, et
  /// un écran plein par appel n'apprendrait rien à personne.
  private static let isTesting = NSClassFromString("XCTestCase") != nil

  private var panel: NSPanel?
  private var autoDismiss: Task<Void, Never>?

  private init() {}

  /// Le seul point d'entrée : le minuteur dit ce qui vient de finir, le style dit quoi en montrer.
  static func announce(
    _ style: PomodoroAlertStyle, finished: PomodoroPhase, next: PomodoroPhase, duration: String,
    onStart: @escaping () -> Void
  ) {
    guard !isTesting, style != .none else { return }
    if style.takesOver(after: finished) {
      shared.present(finished: finished, next: next, duration: duration, onStart: onStart)
    } else {
      // La pastille annonce ce qui S'OUVRE, pas ce qui s'achève.
      HUDWindow.showPomodoro(next, duration: duration)
    }
  }

  private func present(
    finished: PomodoroPhase, next: PomodoroPhase, duration: String, onStart: @escaping () -> Void
  ) {
    let panel = self.panel ?? makePanel()
    self.panel = panel

    // Le cadre AVANT le contenu : monté sur un panneau encore à sa taille de fabrication, le verre
    // gardait la forme de ce premier cadre et se voyait, étiré, au milieu de l'écran.
    // Le `frame` PLEIN, pas `visibleFrame` : l'écran doit couvrir la barre de menus et le Dock,
    // sinon ce n'est plus une interruption, c'est une grande fenêtre.
    if let screen = Self.activeScreen { panel.setFrame(screen.frame, display: false) }

    // Le thème est posé sur la FENÊTRE, pas par un `.preferredColorScheme` : glissé sous le calque
    // de flou, le contenu SwiftUI reprenait l'apparence système et ignorait le réglage. Posé ici, il
    // descend aussi dans le matériau, qui s'éclaircit ou s'assombrit avec.
    switch AppTheme(rawValue: UserDefaults.standard.string(forKey: AppTheme.storageKey) ?? "") {
    case .light: panel.appearance = NSAppearance(named: .aqua)
    case .dark: panel.appearance = NSAppearance(named: .darkAqua)
    case .system, nil: panel.appearance = nil
    }

    let hosting = NSHostingView(
      rootView: PomodoroAlertView(
        finished: finished, next: next, duration: duration,
        onStart: { [weak self] in
          onStart()
          self?.dismiss()
        },
        onClose: { [weak self] in self?.dismiss() }
      ))
    hosting.autoresizingMask = [.width, .height]

    // Le flou est posé en AppKit, pas par un `.background(.regularMaterial)` : en SwiftUI il se
    // dessinait comme un grand rectangle arrondi flou au milieu de l'écran — un panneau fantôme.
    // `.fullScreenUI` est le matériau prévu pour exactement ça, et il suit le thème.
    let blur = NSVisualEffectView()
    blur.material = .fullScreenUI
    blur.blendingMode = .behindWindow
    blur.state = .active
    blur.autoresizingMask = [.width, .height]

    // Un conteneur NEUTRE porte le fondu, pas le calque du flou : `NSVisualEffectView` gère son
    // propre arbre de calques et écrase l'animation qu'on y ajoute — mesuré, l'opacité valait déjà
    // 1,00 soixante millisecondes après le départ.
    // Le conteneur naît à la taille du panneau, pas à zéro : ses deux enfants s'autoredimensionnent
    // depuis leur cadre de départ, et partir de rien les faisait dépendre d'une passe de layout.
    let container = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
    container.wantsLayer = true
    for view in [blur, hosting] {
      view.frame = container.bounds
      container.addSubview(view)
    }
    panel.contentView = container

    panel.makeKeyAndOrderFront(nil)
    fade(container, from: 0, to: 1, duration: Self.fadeIn)

    // Reprogrammé à CHAQUE ouverture : une fin d'étape qui en suit une autre ne doit pas hériter du
    // compte à rebours de la précédente.
    autoDismiss?.cancel()
    autoDismiss = Task { [weak self] in
      try? await Task.sleep(for: Self.autoDismissDelay)
      guard !Task.isCancelled else { return }
      self?.dismiss()
    }
  }

  private func dismiss() {
    autoDismiss?.cancel()
    autoDismiss = nil
    guard let panel, let content = panel.contentView else { return }
    fade(content, from: 1, to: 0, duration: Self.fadeOut) {
      panel.orderOut(nil)  // retiré, pas détruit : il resservira à la prochaine fin d'étape
      // Le CONTENU, lui, ne resservira pas : chaque fin d'étape en monte un neuf. Le garder
      // laisserait un arbre SwiftUI plein écran et un flou actif dans une fenêtre que personne ne
      // regarde — c'est la règle « une vue invisible coûte plein tarif », côté AppKit.
      panel.contentView = nil
    }
  }

  /// Le fondu, joué sur le CALQUE du contenu — même frontière que la capsule : ce qui fait paraître
  /// une fenêtre appartient à CoreAnimation, pas à SwiftUI (→ `PIEGES.md` § Animations).
  ///
  /// `panel.animator().alphaValue` a été essayé d'abord : posé dans le même tour de boucle que
  /// l'ordre à l'écran, il ne joue pas — l'écran paraissait d'un coup.
  private func fade(
    _ view: NSView, from: Float, to: Float, duration: CFTimeInterval,
    completion: (() -> Void)? = nil
  ) {
    guard let layer = view.layer else {
      completion?()
      return
    }
    // Valeur de départ posée SANS animation : sans ça, la première image paraîtrait déjà pleine.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.opacity = from
    CATransaction.commit()

    let animation = CABasicAnimation(keyPath: "opacity")
    animation.fromValue = from
    animation.toValue = to
    animation.duration = duration
    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // CoreAnimation valide sa transaction sur le fil principal, mais son bloc de fin n'est pas typé
    // pour le dire — et ce qu'on y fait retire une fenêtre.
    CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion?() } }
    layer.opacity = to
    layer.add(animation, forKey: "pomodoroAlert.opacity")
    CATransaction.commit()
  }

  private func makePanel() -> NSPanel {
    let panel = AlertPanel(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 800, height: 600)),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.canHide = false  // ⌘H ne doit pas emporter l'écran qui attend une réponse
    // `.statusBar`, comme la pastille : au-dessus de la barre de menus et du Dock, donc l'écran
    // couvre bien tout. PAS `.screenSaver` : au-delà du niveau bouclier, le serveur de fenêtres
    // sort la fenêtre des captures d'écran — invisible à `screencapture`, donc invérifiable.
    panel.level = .statusBar
    panel.collectionBehavior = [
      .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
    ]
    return panel
  }

  /// L'écran ACTIF — celui du curseur, comme la pastille : la fin d'étape tombe pendant qu'on
  /// travaille ailleurs, elle doit paraître là où l'œil est déjà.
  private static var activeScreen: NSScreen? {
    let mouse = NSEvent.mouseLocation
    return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
  }
}

/// `.borderless` ne devient jamais clé tout seul — et sans la clé, ni ⏎ ni Échap n'atteignent les
/// boutons. `.nonactivatingPanel` fait qu'il la prend SANS ramener Today au premier plan.
private final class AlertPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

private struct PomodoroAlertView: View {
  let finished: PomodoroPhase
  let next: PomodoroPhase
  let duration: String
  let onStart: () -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 16) {
      Text("POMODORO")
        .font(.app(11, weight: .semibold))
        .tracking(6)
        .foregroundStyle(.secondary)

      Text(finished == .work ? "Travail terminé" : "Pause terminée")
        .font(.app(64, weight: .bold, design: .rounded))

      Text(next.label + " · " + duration)
        .font(.app(.title2))
        .foregroundStyle(.secondary)

      // Des boutons de plein écran : même à `.extraLarge`, les tailles système passaient pour des
      // boutons de boîte de dialogue égarés sous un titre de 64 points. D'où le retrait explicite.
      HStack(spacing: 14) {
        Button(action: onStart) { label(startLabel) }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
        Button(action: onClose) { label("Fermer") }
          .buttonStyle(.bordered)
          .keyboardShortcut(.cancelAction)
      }
      .controlSize(.extraLarge)
      .padding(.top, 24)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    // Le flou seul laisse l'écran d'en dessous lisible — on y suit encore une vidéo. Ce voile le
    // pousse au second plan. `windowBackgroundColor` suit le thème : rien de figé à reprendre.
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.62))
  }

  private func label(_ text: String) -> some View {
    Text(text)
      .font(.app(17, weight: .semibold))
      .padding(.horizontal, 22)
      .padding(.vertical, 12)
  }

  private var startLabel: String {
    switch next {
    case .work: return "Reprendre le travail"
    case .shortBreak: return "Commencer la pause courte"
    case .longBreak: return "Commencer la pause longue"
    }
  }
}
