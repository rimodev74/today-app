import AppKit
import SwiftData
import SwiftUI

/// La fenêtre de saisie rapide : une capsule flottante qui s'ouvre PAR-DESSUS l'app en cours sans la
/// désactiver. C'est le seul point de l'app qui capture une tâche sans qu'on ait à venir à l'app.
///
/// Un `NSPanel` et pas une `Window` SwiftUI : une scène SwiftUI ne sait ni devenir clé sans activer
/// Today (la fenêtre principale passerait devant, exactement ce qu'on veut éviter), ni flotter
/// au-dessus des autres apps. `.nonactivatingPanel` + `becomesKeyOnlyIfNeeded = false` donne le
/// couple recherché : le panneau prend le clavier, l'app de premier plan garde la main. Le contenu,
/// lui, reste du SwiftUI ordinaire adossé au même `ModelContainer` que la fenêtre principale — une
/// tâche créée ici apparaît immédiatement dans les listes.
@MainActor
final class QuickEntryWindow {
  static let shared = QuickEntryWindow()
  /// Le nom de la notification distribuée qui ouvre ou ferme la capsule (cf. `TodayApp.init`).
  static let toggleNotification = "app.today.quickEntry.toggle"

  /// La largeur VISIBLE, c'est `capsuleWidth`. La fenêtre garde 120 pt de plus pour laisser déborder
  /// le verre et l'ombre (`paneShadow`, rayon 40) : les deux se resserrent ensemble, sinon cette
  /// marge devient une zone morte — un clic y tombe dans le panneau sans le fermer.
  static let panelSize = NSSize(width: 770, height: 620)
  static let capsuleWidth: CGFloat = 650
  /// L'écart entre le haut de la fenêtre et celui de la capsule. Lu des deux côtés : la vue s'en
  /// sert pour son retrait, la fenêtre pour ancrer son ressort sur le haut de la capsule.
  ///
  /// 56, pas 32 : le halo de `paneShadow` (rayon 40) déborde d'environ radius − y = 22pt au-dessus
  /// de la capsule, et sa traîne va plus loin encore (un flou n'a pas de bord net). 32pt le coupait
  /// au ras de la fenêtre — un aplat au lieu d'un fondu.
  static let capsuleTopInset: CGFloat = 56
  /// La hauteur de la barre repliée — le seul bloc TOUJOURS visible de la capsule. C'est elle qu'on
  /// centre, pas la fenêtre : celle-ci descend 500pt plus bas pour loger les résultats.
  /// ponytail: mesurée sur le rendu (champ en `.app(20)` + 15pt de retrait haut et bas) plutôt que
  /// relevée à l'exécution — la position est calculée avant que le contenu existe.
  static let capsuleBarHeight: CGFloat = 56

  /// Où la barre se pose DANS l'écran, en FRACTIONS de la zone utile — 0,5 / 0,5, le centre, tant
  /// qu'on ne l'a pas déplacée. Une fraction et pas des points : la capsule paraît sur l'écran où
  /// l'on travaille, et deux écrans n'ont ni la même taille ni la même origine.
  ///
  /// Surtout pas l'autosave d'AppKit (`setFrameAutosaveName`) : il enregistre le CADRE avec la
  /// configuration d'écrans du moment, puis remet la fenêtre « à l'échelle » dès qu'elle change.
  /// C'est par là que la capsule dérivait. → `PIEGES.md` § Fenêtres.
  private static let barCenterKey = "quickEntry.barCenter"

  /// Le panneau, créé UNE fois et GARDÉ pour la vie du process. Le jeter à chaque fermeture coûtait
  /// un plantage : le champ de texte de la capsule fait créer la liste de complétion d'AppKit, qui
  /// vit HORS PROCESS ; sa fenêtre conteneur disparue, l'abonnement de cette vue distante survit et
  /// la fenêtre suivante ordonnée à l'écran fait lever une assertion d'Apple qui tue le process.
  /// Mesuré : 3 morts sur 594 ouvertures en le reconstruisant. → `PIEGES.md` § Fenêtres.
  ///
  /// Ce qui reste NEUF à chaque ouverture, c'est le CONTENU — `contentView`, donc tout l'état
  /// SwiftUI et le canal. Rien du titre à moitié tapé ne survit ; le brouillon volontairement gardé
  /// passe, lui, par `QuickEntryDraftStore`.
  private var panel: FloatingPanel?
  private var channel: QuickEntryChannel?

  /// La sortie dure ~400 ms, pendant lesquelles le panneau est encore visible. Sans ces deux-là, le
  /// raccourci global frappé dans cet intervalle ne ferait rien du tout : il verrait une capsule
  /// « ouverte » et redemanderait une fermeture déjà en cours.
  private var isClosing = false
  private var closeGeneration = 0

  /// Ouverte = le panneau est À L'ÉCRAN, sortie exclue. `panel != nil` ne le dit plus : il survit
  /// aux fermetures.
  private var isOpen: Bool { panel?.isVisible == true && !isClosing }

  private init() {}

  func toggle(container: ModelContainer) {
    if isOpen { requestClose() } else { show(container: container) }
  }

  /// Le raccourci clavier d'une action de saisie (`@today`, `#Courses`). Capsule OUVERTE, le jeton
  /// se pose sur la tâche en cours d'écriture — exactement ce que ferait l'abréviation tapée ;
  /// fermée, il ouvre la capsule avec le jeton déjà appliqué. Rouvrir dans tous les cas jetterait
  /// le titre à moitié tapé, alors que le geste ne demandait qu'à le dater.
  func apply(token: String, container: ModelContainer) {
    if let channel, isOpen {
      channel.token = token
    } else {
      show(container: container, prefill: token)
    }
  }

  func show(container: ModelContainer, prefill: String = "") {
    let panel = self.panel ?? makePanel()
    self.panel = panel
    // Un glissement interrompu par une fermeture ne voit JAMAIS son `onEnded` : le contenu SwiftUI,
    // et le geste avec lui, viennent d'être remplacés. Sans cette remise à zéro, l'ancre périmée
    // ferait sauter la capsule au premier mouvement du glissement suivant.
    dragAnchor = nil
    // Replacée à CHAQUE ouverture : la capsule doit paraître là où l'on travaille, pas là où on l'a
    // laissée la fois d'avant — sur un autre écran, ou sur un écran débranché depuis.
    position(panel)

    let channel = QuickEntryChannel()
    self.channel = channel
    let theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: AppTheme.storageKey) ?? "")
    let hosting = NSHostingView(
      rootView: QuickEntryView(
        channel: channel, prefill: prefill, onClose: { [weak self] in self?.close() }
      )
      .modelContainer(container)
      .preferredColorScheme((theme ?? .system).colorScheme)
    )
    hosting.layer?.backgroundColor = .clear
    panel.contentView = hosting
    // Une sortie en cours n'a plus lieu d'être : le contenu qu'elle escamotait vient d'être
    // remplacé. Le compteur invalide son `finishClose` différé.
    isClosing = false
    closeGeneration += 1
    animate(hosting, to: .shown)
    panel.makeKeyAndOrderFront(nil)
  }

  /// Le ressort d'entrée et de sortie de la capsule — sur le CALQUE, pas dans SwiftUI.
  ///
  /// Un `.scaleEffect` animé fait re-rendre tout l'arbre à CHAQUE image : mesuré 543 ms de CPU par
  /// cycle ouverture+fermeture, dont 284 pour la seule mise à l'échelle — soit ~9 ms par image sur
  /// un budget de 16,7. Dès qu'autre chose tourne, on rate un vsync sur deux et l'ouverture tombe à
  /// 30 Hz. Confié à CoreAnimation, le contenu est rendu UNE fois et le serveur de rendu met la
  /// texture à l'échelle : l'app ne fait plus rien pendant l'animation.
  ///
  /// `.compositingGroup()` et `.drawingGroup()` ont été essayés d'abord, pour rester en SwiftUI :
  /// 614 → 578 et 528 ms/cycle, dans le bruit de la mesure. → `PIEGES.md` § Animations.
  private enum Presentation { case hidden, shown }

  /// Mêmes nombres que le ressort SwiftUI qu'il remplace (`response: 0.34`, `dampingFraction:
  /// 0.62`) : `bounce` vaut `1 − dampingFraction`, `perceptualDuration` vaut `response`.
  private static func spring() -> CASpringAnimation {
    CASpringAnimation(perceptualDuration: 0.34, bounce: 0.38)
  }

  private func animate(
    _ view: NSView, to state: Presentation, completion: (() -> Void)? = nil
  ) {
    guard let layer = view.layer else {
      completion?()
      return
    }
    // Les bornes de la VUE, pas celles du calque : celui-ci n'adopte le nouveau cadre qu'à la
    // passe de layout, et un pivot calculé sur des bornes encore nulles ferait entrer la capsule
    // de travers.
    let from = state == .shown ? Self.shrunk(in: view.bounds) : CATransform3DIdentity
    let to = state == .shown ? CATransform3DIdentity : Self.shrunk(in: view.bounds)

    // Valeurs de départ posées SANS animation : sans ça, la capsule paraîtrait une image à sa
    // taille pleine avant de rentrer.
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    layer.transform = from
    layer.opacity = state == .shown ? 0 : 1
    CATransaction.commit()

    let scale = Self.spring()
    scale.keyPath = "transform"
    scale.fromValue = from
    scale.toValue = to
    let fade = Self.spring()
    fade.keyPath = "opacity"
    fade.fromValue = layer.opacity
    fade.toValue = state == .shown ? 1 : 0

    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // CoreAnimation valide sa transaction sur le fil principal, mais son bloc de fin n'est pas
    // typé pour le dire — et ce qu'on y fait démonte une fenêtre. Même formule que l'observateur
    // de notification distribuée dans `TodayApp.init`.
    CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion?() } }
    layer.transform = to
    layer.opacity = state == .shown ? 1 : 0
    layer.add(scale, forKey: "quickEntry.transform")
    layer.add(fade, forKey: "quickEntry.opacity")
    CATransaction.commit()
  }

  /// L'état replié : 0,88 pris depuis le HAUT DE LA CAPSULE, pas du calque. Ancrée au centre, elle
  /// remonterait pendant le ressort — le bloc s'allonge vers le bas quand les sous-tâches s'ouvrent.
  /// Le `transform` d'un calque s'applique autour de son `anchorPoint` : plutôt que de déplacer
  /// celui-ci (AppKit le repositionnerait), on encadre l'échelle de deux translations.
  private static func shrunk(in bounds: CGRect) -> CATransform3D {
    let x = bounds.midX
    // Repère du calque : origine en bas à gauche.
    let y = bounds.maxY - capsuleTopInset
    var t = CATransform3DTranslate(CATransform3DIdentity, x, y, 0)
    t = CATransform3DScale(t, 0.88, 0.88, 1)
    return CATransform3DTranslate(t, -x, -y, 0)
  }

  /// Fermeture DEMANDÉE : on passe la main à la VUE, qui seule sait si ce geste doit tout fermer
  /// ou seulement défaire l'étape en cours (Échap sur un bloc ouvert). Elle rappelle `close()`,
  /// qui joue le ressort de sortie. Tout ce qui ferme le panneau passe par ici — Échap, le
  /// raccourci global rejoué — sans quoi la fenêtre disparaîtrait au milieu de l'animation.
  ///
  /// `discardDraft` distingue l'annulation VOLONTAIRE (Échap) de tout le reste (clic ailleurs, perte
  /// de la clé, raccourci global rejoué) : seule la première jette ce qui était en train de s'écrire,
  /// les autres le gardent pour la prochaine ouverture (cf. `QuickEntryView.persistDraft`).
  func requestClose(discardDraft: Bool = false) {
    guard let channel else {
      close()
      return
    }
    channel.discardDraft = discardDraft
    channel.isRequested = true
  }

  /// La sortie : le ressort d'entrée rejoué à l'envers, puis seulement le démontage. Un panneau
  /// qui s'évanouit d'un coup après être entré en rebondissant se lit comme un plantage.
  func close() {
    // `isVisible` écarte la fermeture d'un panneau déjà parti (`requestClose` sans canal y mène) :
    // elle jouerait un ressort sur une fenêtre hors écran, puis la redémonterait.
    guard let panel, panel.isVisible, let content = panel.contentView, !isClosing else { return }
    isClosing = true
    closeGeneration += 1
    let generation = closeGeneration
    animate(content, to: .hidden) { [weak self] in
      // Une réouverture pendant la sortie a déjà remplacé le contenu : ce démontage-ci est périmé.
      guard let self, self.closeGeneration == generation else { return }
      self.finishClose()
    }
  }

  private func finishClose() {
    isClosing = false
    panel?.orderOut(nil)
    // La fenêtre reste, son CONTENU part. Le garder laisserait les `@Query` de la capsule (listes,
    // projets) se rejouer à chaque écriture SwiftData, capsule fermée.
    panel?.contentView = NSView()
    channel = nil
  }

  private func makePanel() -> FloatingPanel {
    // Fenêtre volontairement plus grande que la capsule, et TRANSPARENTE : le verre a besoin de
    // composer sur ce qu'il y a derrière (une fenêtre opaque le réduirait à un aplat), et le
    // ressort d'ouverture comme le dépli des sous-tâches doivent avoir de la marge où déborder. On ne
    // redimensionne donc jamais le panneau — c'est le contenu qui bouge à l'intérieur.
    // ponytail: hauteur fixe dimensionnée pour la capsule + ses sous-tâches + une dizaine de tâches en
    // attente ; au-delà la fournée déborderait — à passer en `setFrame` animé si ça arrive.
    let panel = FloatingPanel(
      contentRect: NSRect(origin: .zero, size: Self.panelSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    // `.borderless` ne devient jamais clé tout seul (d'où `canBecomeKey` dans la sous-classe), mais
    // c'est le seul style sans chrome ni coins arrondis système imposés sous la capsule.
    panel.onCancel = { [weak self] in self?.requestClose() }
    panel.onEscape = { [weak self] in self?.requestClose(discardDraft: true) }
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false  // l'ombre vient du verre, à la forme de la capsule
    // PAS `isMovableByWindowBackground` : AppKit ne le consulte que sur une vue qui laisse passer le
    // clic, et tout le contenu ici est du SwiftUI qui le consomme — le glissement ne prenait que sur
    // la marge transparente, invisible, et rien n'enregistrait ce qu'il posait. La barre s'attrape
    // explicitement (`QuickEntryView.windowDrag`).
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = false
    panel.hidesOnDeactivate = false
    // La capsule ne fait pas partie de l'app « masquée ». Sans ça, ⌘H puis le raccourci global
    // rouvraient la capsule ET la fenêtre principale : ordonner devant une fenêtre masquable
    // oblige AppKit à démasquer TOUTE l'app. Exemptée, elle s'affiche seule, l'app reste cachée.
    panel.canHide = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    return panel
  }

  /// Toute l'arithmétique du placement, testée à part (`QuickEntryPlacementTests`).
  private static let placement = QuickEntryPlacement(
    panelSize: panelSize, barWidth: capsuleWidth, barHeight: capsuleBarHeight,
    topInset: capsuleTopInset)

  /// La barre, posée à sa fraction d'écran sur l'écran ACTIF.
  private func position(_ panel: NSPanel) {
    guard let visible = Self.activeScreen?.visibleFrame else { return }
    let fraction = Self.savedBarCenter ?? CGPoint(x: 0.5, y: 0.5)
    panel.setFrameOrigin(
      Self.placement.panelOrigin(
        barCenter: Self.placement.barCenter(fraction: fraction, in: visible)))
  }

  /// Une valeur trafiquée dans les défauts arrive telle quelle : c'est `QuickEntryPlacement` qui la
  /// rend inoffensive, seul endroit par lequel elle passe.
  private static var savedBarCenter: CGPoint? {
    UserDefaults.standard.string(forKey: barCenterKey).map(NSPointFromString)
  }

  /// L'écran où l'utilisateur travaille : celui de la fenêtre au premier plan. Pas la souris — la
  /// capsule s'ouvre au CLAVIER depuis n'importe quelle app, et le pointeur peut être resté sur un
  /// autre écran. Pas `NSScreen.main` non plus : sur une app qui n'est pas au premier plan,
  /// « principal » suit la fenêtre clé, celle d'une AUTRE app. La souris ne sert que de repli, quand
  /// l'app de devant n'a aucune fenêtre ordinaire (le Finder sur le bureau).
  private static var activeScreen: NSScreen? {
    screen(containing: frontWindowCenter() ?? NSEvent.mouseLocation) ?? NSScreen.main
  }

  private static func screen(containing point: CGPoint) -> NSScreen? {
    NSScreen.screens.first { $0.frame.contains(point) }
  }

  /// Le centre de la fenêtre de devant de l'app active, en coordonnées Cocoa.
  ///
  /// `CGWindowListCopyWindowInfo` et pas l'API d'accessibilité : celle-ci demande une autorisation
  /// que l'app n'a aucune raison de réclamer pour ça. La liste vient de l'avant vers l'arrière, et
  /// `layer 0` écarte panneaux flottants et menus, qui ne disent rien de l'endroit où l'on travaille.
  /// Mesuré le 22 août 2026 : 0,52 ms en moyenne (14 fenêtres à l'écran), une fois par ouverture.
  private static func frontWindowCenter() -> CGPoint? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
      // L'origine de Quartz est en HAUT à gauche de l'écran principal, celle de Cocoa en bas.
      let flip = NSScreen.screens.first?.frame.maxY
    else { return nil }
    for window in windows
    where window[kCGWindowOwnerPID as String] as? pid_t == pid
      && window[kCGWindowLayer as String] as? Int == 0
    {
      guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
        let x = bounds["X"], let y = bounds["Y"],
        let width = bounds["Width"], let height = bounds["Height"]
      else { continue }
      return CGPoint(x: x + width / 2, y: flip - (y + height / 2))
    }
    return nil
  }

  // MARK: Déplacement

  /// L'ancre du glissement en cours : où était le panneau, où était le pointeur.
  ///
  /// Les deltas se prennent sur `NSEvent.mouseLocation` et pas sur la translation du geste SwiftUI :
  /// la fenêtre bouge SOUS le curseur, donc une translation mesurée dans la vue se réinjecterait
  /// dans elle-même à chaque image et la capsule s'emballerait.
  private var dragAnchor: (origin: NSPoint, mouse: NSPoint)?

  /// La distance à laquelle l'aimant de ⌘ prend. 60pt : assez pour se sentir sans qu'on ait à viser,
  /// assez peu pour qu'on puisse encore poser la barre à 100pt du centre si on le veut.
  private static let snapDistance: CGFloat = 60

  func dragMoved() {
    guard let panel else { return }
    let anchor = dragAnchor ?? (panel.frame.origin, NSEvent.mouseLocation)
    dragAnchor = anchor
    let mouse = NSEvent.mouseLocation
    let free = NSPoint(
      x: anchor.origin.x + mouse.x - anchor.mouse.x,
      y: anchor.origin.y + mouse.y - anchor.mouse.y)
    // `NSEvent.modifierFlags` lit l'état COURANT du clavier : la touche peut être prise ou lâchée en
    // plein glissement, l'aimant suit sans qu'on ait à suivre des frappes.
    let center = Self.placement.barCenter(ofPanel: NSRect(origin: free, size: panel.frame.size))
    guard NSEvent.modifierFlags.contains(.command),
      let visible = (Self.screen(containing: center) ?? panel.screen)?.visibleFrame
    else {
      panel.setFrameOrigin(free)
      return
    }
    panel.setFrameOrigin(
      Self.placement.panelOrigin(
        barCenter: Self.placement.snappedToCenter(
          barCenter: center, in: visible, within: Self.snapDistance)))
  }

  /// La position n'est écrite qu'ICI : une fois, à la fin du geste, en fraction de l'écran où on
  /// vient de poser la barre — c'est ce qui la fera revenir au même endroit RELATIF sur l'écran où
  /// l'on travaillera la prochaine fois.
  func dragEnded() {
    guard let panel, dragAnchor != nil else { return }
    dragAnchor = nil
    let center = Self.placement.barCenter(ofPanel: panel.frame)
    guard let visible = (Self.screen(containing: center) ?? panel.screen)?.visibleFrame,
      let fraction = Self.placement.fraction(barCenter: center, in: visible)
    else { return }
    UserDefaults.standard.set(NSStringFromPoint(fraction), forKey: Self.barCenterKey)
  }
}

/// Le canal par lequel AppKit parle à la vue SwiftUI du panneau. Un objet observé plutôt qu'un appel
/// direct : `cancelOperation` comme un raccourci global sont déclenchés par la fenêtre, hors de tout
/// cycle de rendu, et n'ont aucun moyen d'atteindre l'état d'une vue autrement.
@MainActor @Observable final class QuickEntryChannel {
  var isRequested = false
  /// Jeton (`@today`, `#Courses`) poussé par un raccourci clavier alors que la capsule est déjà
  /// ouverte. Remis à `nil` par la vue une fois posé — sans quoi deux frappes de suite sur la même
  /// combinaison ne feraient rien la seconde fois, la valeur n'ayant pas changé.
  var token: String?
  /// Posé par `QuickEntryWindow.requestClose(discardDraft:)` juste avant `isRequested` : la vue le
  /// lit au même instant pour savoir si cette fermeture doit jeter le brouillon (Échap) ou le
  /// garder (tout le reste).
  var discardDraft = false
}

/// Une fenêtre sans bordure refuse le focus clavier et ignore Échap tant qu'on ne le lui apprend pas.
private final class FloatingPanel: NSPanel {
  /// Clic ailleurs, perte de la clé : ACCIDENTEL — le brouillon en cours doit survivre.
  var onCancel: (() -> Void)?
  /// Échap : annulation VOLONTAIRE — c'est le seul geste qui doit jeter le brouillon.
  var onEscape: (() -> Void)?

  override var canBecomeKey: Bool { true }

  /// AppKit route Échap ici via la chaîne de responder, y compris depuis le field editor d'un
  /// `TextField` — plus fiable qu'un `.keyboardShortcut(.cancelAction)` sur un bouton caché.
  override func cancelOperation(_ sender: Any?) {
    onEscape?()
  }

  /// Cliquer ailleurs referme, comme Spotlight. Perdre la clé est le bon signal plutôt qu'un moniteur
  /// de clics globaux : le panneau la garde pendant le tracking d'un `NSMenu` (le chip de
  /// destination), donc ouvrir le menu ne le ferme pas. `isVisible` écarte le rappel que `orderOut`
  /// provoque à la fermeture, qui relancerait la sortie sur une fenêtre déjà partie.
  override func resignKey() {
    super.resignKey()
    if isVisible { onCancel?() }
  }
}

/// L'ombre portée d'un bloc de la capsule, écrite UNE fois pour les deux branches de `pane` — la
/// branche verre n'en avait aucune (le panneau pose `hasShadow = false` en comptant sur le verre) et
/// le repli material avait la sienne, en dur : deux traitements pour un même besoin.
///
/// Le verre seul ne se détache pas d'un fond CLAIR — la capsule passait inaperçue par-dessus une
/// fenêtre blanche, là où le Spotlight système reste lisible partout. Deux ombres comme lui : une
/// courte et dense qui pose le contact, une longue et diffuse qui creuse le fond. Une seule obligerait
/// à choisir entre les deux, donc à la vouloir soit trop dure, soit trop molle.
///
/// Comparée au Spotlight système (capture du 4 août 2026) : la première version restait bien plus
/// pâle que lui sur un fond clair, alors même que Spotlight vit sur le même verre. Densités montées
/// pour tenir la comparaison — au prix, sur fond sombre, d'un contact qui se voit un peu plus qu'avant.
extension View {
  func paneShadow() -> some View {
    self
      .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
      .shadow(color: .black.opacity(0.24), radius: 40, y: 18)
  }
}

/// Remonte la hauteur naturelle de la liste des destinations jusqu'au bloc qui l'ouvre.
private struct DestinationHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Le contenu du panneau : une capsule d'une ligne — d'où part la tâche, ce qu'elle dit, quand — qui
/// se déplie sur un second bloc pour les sous-tâches. Pas de barre de validation :
/// Entrée enregistre, Échap ferme, et les deux boutons ne faisaient qu'afficher des raccourcis que
/// tout le monde connaît.

/// Une tâche déposée mais pas encore écrite : les mêmes champs que la saisie, gelés. Le titre
/// garde ses jetons (`@demain`, `#liste`), analysés seulement à l'insertion — comme s'il venait
/// d'être tapé.
private struct PendingTask: Identifiable {
  let id = UUID()
  var title: String
  var subtasks: [String]
  var when: Date?
  /// Heure planifiée, en minutes depuis minuit (cf. `TaskItem.whenMinutes`).
  var minutes: Int?
  var targetID: PersistentIdentifier?
}

/// Le brouillon perdu à une fermeture accidentelle (Échap, clic ailleurs, raccourci global rejoué)
/// — gardé en mémoire pour la durée de l'app, le CONTENU de la capsule étant neuf à chaque
/// ouverture (cf. `QuickEntryWindow.show`). Une vraie validation (`save`) ne le touche jamais : `restoreDraft`
/// le vide dès qu'il est repris, avant qu'aucune sauvegarde n'ait pu le voir.
@MainActor
private final class QuickEntryDraftStore {
  static let shared = QuickEntryDraftStore()
  var draft: Draft?

  struct Draft {
    var title = ""
    var subtasks: [String] = []
    var when: Date?
    var minutes: Int?
    var targetID: PersistentIdentifier?
    var queued: [PendingTask] = []

    var isEmpty: Bool {
      title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && subtasks.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        && queued.isEmpty
    }
  }

  private init() {}
}

private struct QuickEntryView: View {
  var channel: QuickEntryChannel
  /// Jeton posé d'entrée par le raccourci clavier qui a ouvert la capsule. Il passe par le même
  /// `consumeTokens` que la frappe : la pastille de date ou le chip apparaissent par le chemin
  /// habituel, la capsule ne montre jamais de « @today » à l'écran.
  var prefill: String = ""
  var onClose: () -> Void

  @Environment(\.modelContext) private var modelContext
  @Query(sort: [SortDescriptor(\TodoList.sortIndex)]) private var lists: [TodoList]
  @Query(sort: [SortDescriptor(\Project.sortIndex)]) private var projects: [Project]
  /// Toutes les tâches, chargées À LA DEMANDE — pas par un `@Query`.
  ///
  /// Un `@Query` se matérialise pendant la construction de la vue, donc AVANT que la fenêtre
  /// paraisse : mesuré 7 ms pour les requêtes du panneau, et un fetch complet coûte 2,4 ms à 136
  /// tâches, 35 ms à 2 000. Or la capsule s'ouvre sur une barre VIDE, qui n'a besoin d'aucune
  /// tâche. On paie donc à la première frappe, où la frappe couvre le coût.
  ///
  /// Sans tri : `QuickPalette` pose le sien (l'ordre d'« Aujourd'hui » pour le coup d'œil, la
  /// pertinence pour une recherche), et un `SortDescriptor` de plus ne ferait que trier deux fois.
  @State private var allTasks: [TaskItem] = []
  @State private var allTasksLoaded = false

  @State private var title = ""
  /// Sous-tâches en brouillon : de simples chaînes, pas des `Subtask`. Le modèle n'existera qu'à
  /// l'enregistrement — en créer avant obligerait à les rattacher à une `TaskItem` fantôme, puis à
  /// la nettoyer si le panneau se ferme sur Échap.
  @State private var subtasks: [String] = []
  /// Destination CHOISIE à la main, par son identifiant SwiftData et pas par l'objet : le `Picker`
  /// exige un tag `Hashable` stable, et un `PersistentIdentifier` en est un même si le modèle est
  /// rechargé sous le panneau. Un jeton `#liste` dans le titre l'emporte au moment d'enregistrer.
  @State private var targetID: PersistentIdentifier?
  @State private var when: Date?
  /// L'heure, à CÔTÉ du jour et pas dedans — même partage que le modèle (cf. `TaskItem.whenMinutes`).
  @State private var whenMinutes: Int?
  /// La fournée en attente : ⌘↩ y dépose la tâche en cours et rend le champ vide, ↩ enregistre tout
  /// et ferme. Vider trois idées d'affilée ne demande plus de rouvrir le panneau à chaque fois.
  @State private var queued: [PendingTask] = []
  /// La ligne de la palette visée au clavier.
  ///
  /// En RECHERCHE elle est toujours posée sur une ligne (0 au départ) : c'est ce qui rend ↩
  /// prévisible — il fait ce que la ligne surlignée annonce, jamais autre chose. En seconde étape
  /// elle vaut `nil`, la barre redevient le lieu de l'action ; `↓` descend dans le contexte pour y
  /// cocher.
  ///
  /// Un index et pas un `TaskFocus` : la palette mêle des vues, des dossiers, des listes, des
  /// tâches et des commandes, là où `TaskFocus` ne connaît que des tâches et porte en plus une
  /// notion d'édition qui n'a pas de sens ici.
  @State private var selection: Int? = 0
  /// Le temps où l'on en est. Voir `Step`.
  @State private var step: Step = .search
  @State private var expanded = false
  @State private var picking = false
  /// Hauteur naturelle de la liste des destinations, mesurée en continu. Nécessaire parce que le
  /// bloc s'ouvre en animant sa hauteur : il faut une valeur cible, `nil` ne s'anime pas.
  @State private var destinationHeight: CGFloat = 0
  /// Le contenu du bloc des destinations est-il monté ?
  ///
  /// Le BLOC, lui, l'est toujours — c'est ce qui donne la fusion progressive du verre (cf.
  /// `destinationPane`). Mais son contenu se reconstruisait donc à CHAQUE rendu de la capsule,
  /// chaque rangée y lisant `list.progress()`, qui retraverse les tâches de sa liste. Mesuré :
  /// **19 ms sur les 28 que coûtait encore l'ouverture**, pour une liste que personne ne regarde.
  @State private var showsDestinations = false
  /// Invalide un démontage en attente quand le bloc se rouvre pendant sa fermeture (même jeton que
  /// `TaskRow.editSession`).
  @State private var destinationSession = 0
  @State private var hovered: PersistentIdentifier?
  /// Sortie demandée. Il ferme la porte derrière lui : Échap martelé, un ⌘↩ qui arrive après le
  /// dernier ↩, et la capsule sortirait deux fois — ou enregistrerait deux tâches.
  @State private var closing = false
  @AppStorage(TextShortcut.storageKey) private var shortcutData = Data()
  @FocusState private var focus: Field?
  @Namespace private var morph

  private var shortcuts: [TextShortcut] { TextShortcut.decode(shortcutData) }

  /// La fournée de tâches, chargée une fois par ouverture. Appelée depuis `onChange` et `begin`,
  /// donc DANS la transaction qui change le titre ou l'étape : le body qui suit voit déjà la
  /// fournée, il n'y a pas d'image intermédiaire sans tâches.
  ///
  /// Elle ne suit pas les écritures faites ailleurs pendant que la capsule est ouverte — une
  /// tâche ajoutée depuis la fenêtre principale n'apparaîtra qu'à la prochaine ouverture. La
  /// capsule est un panneau de passage, la question ne se pose pas dans son usage.
  private func loadAllTasks() {
    guard !allTasksLoaded else { return }
    allTasks = (try? modelContext.fetch(FetchDescriptor<TaskItem>())) ?? []
    allTasksLoaded = true
  }

  private enum Field: Hashable {
    case title
    case subtask(Int)
  }

  /// Les DEUX temps de la capsule.
  ///
  /// En recherche, la barre filtre et ↩ actionne la ligne visée. Ensuite, la barre écrit et ↩
  /// enregistre. La transition est explicite (↩ sur une ligne), l'état se VOIT (le chip, le libellé
  /// du champ, les icônes de droite changent) et Échap la défait.
  ///
  /// C'est ce découpage qui répare le défaut de fond : la capsule supposait qu'on composait
  /// TOUJOURS une tâche. Tant qu'elle n'affichait rien c'était vrai ; dès qu'elle a listé des
  /// choses, chaque touche a eu deux lectures possibles — Tab ouvrait « les notes de la tâche en
  /// cours » alors qu'on regardait une autre tâche.
  private enum Step {
    case search
    case addTask(QuickPalette.TaskTarget)
    case createList(Project)

    var isSearch: Bool { if case .search = self { return true } else { return false } }
    /// Sous-tâches, date, fournée : tout ça n'a de sens que sur une TÂCHE en train de
    /// s'écrire. Ni la recherche ni le nom d'une liste n'en veulent.
    var composesTask: Bool { if case .addTask = self { return true } else { return false } }
  }

  /// Identités de morphing du verre. Distinctes de `Field` : un bloc n'est pas une cible de focus.
  private enum Block: Hashable { case bar, destination, details, queue, results }

  var body: some View {
    // Construite UNE fois par rendu, puis distribuée — jamais en propriété calculée relue par
    // chaque sous-vue : une propriété calculée d'une `View` repart de zéro à chaque lecture, et
    // celle-ci filtre et trie toute la base.
    let palette = currentPalette
    return glassStack(palette)
      .frame(width: QuickEntryWindow.capsuleWidth)
      // L'entrée et la sortie de la capsule ne sont PAS ici : `QuickEntryWindow` les joue sur le
      // calque, en CoreAnimation. Un `.scaleEffect` animé fait re-rendre tout cet arbre à chaque
      // image (mesuré : la moitié du CPU de l'ouverture). Ce qui reste dans SwiftUI, ce sont les
      // mouvements INTERNES — un pan qui s'ouvre, la fournée qui grandit.
      .padding(.top, QuickEntryWindow.capsuleTopInset)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .onChange(of: channel.isRequested) { _, requested in
        guard requested else { return }
        // Échap referme d'abord ce qui est ouvert PAR-DESSUS la capsule, comme un menu système :
        // emporter tout le panneau ferait perdre une saisie en cours pour un simple clic de trop.
        if picking {
          channel.isRequested = false
          withAnimation(.bouncy(duration: 0.4)) { picking = false }
          focus = .title
          return
        }
        // Même règle un cran plus bas : Échap DÉFAIT la dernière étape avant de fermer. On est
        // entré dans une liste par erreur, on en ressort — sans perdre la capsule.
        if !step.isSearch {
          channel.isRequested = false
          backToSearch()
          return
        }
        // Échap est la SEULE annulation volontaire : elle jette le brouillon. Tout le reste (clic
        // ailleurs, perte de la clé, raccourci global rejoué) est accidentel et le garde — pour
        // toujours, jusqu'à la prochaine ouverture ou un vrai enregistrement (cf. `persistDraft`).
        if channel.discardDraft {
          QuickEntryDraftStore.shared.draft = nil
        } else {
          persistDraft()
        }
        dismiss()
      }
      // Le focus se pose ICI et pas dans `onAppear` : à ce moment-là le panneau n'est pas encore
      // clé (`makeKeyAndOrderFront` est en cours), et AppKit rend son premier répondeur à la
      // fenêtre juste après — le champ perdait le focus aussitôt reçu. Un tour de boucle suffit à
      // passer après.
      .task {
        try? await Task.sleep(for: .milliseconds(50))
        // Après le sommeil, donc après le premier tour de boucle : la `@Query` a livré les listes,
        // et un `#Courses` de prefill trouve sa destination. Avant, elle serait tombée à côté.
        restoreDraft()
        applyToken(prefill)
        focus = .title
      }
      // Raccourci clavier frappé alors que la capsule est déjà ouverte : le jeton rejoint la tâche
      // en cours d'écriture.
      // Le contenu des destinations suit l'ouverture du bloc, avec un temps de retard à la
      // fermeture pour ne pas se vider avant d'avoir fini de se replier.
      .onChange(of: picking) { _, open in
        destinationSession += 1
        guard !open else {
          showsDestinations = true
          return
        }
        let token = destinationSession
        // Un poil au-delà du ressort qui referme le bloc (`.bouncy(duration: 0.4)`).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
          if token == destinationSession { showsDestinations = false }
        }
      }
      .onChange(of: channel.token) { _, token in
        guard let token else { return }
        applyToken(token)
        channel.token = nil
      }
      // La destination par défaut doit être COCHÉE, pas seulement sous-entendue par le chip. Sur
      // `inbox` et pas dans `onAppear` : la `@Query` peut n'avoir encore rien livré au premier
      // rendu, et le menu s'ouvrirait sans coche.
      .onChange(of: inbox?.persistentModelID, initial: true) { _, id in
        if targetID == nil { targetID = id }
      }
  }

  /// Les blocs de verre dans un `GlassEffectContainer` : c'est lui qui produit l'étirement élastique
  /// entre eux quand l'un apparaît — les formes fusionnent en se pinçant au milieu tant qu'elles
  /// sont à moins de `spacing` l'une de l'autre. Rien de tout ça n'existe sous macOS 26
  /// (Package.swift cible .v14, donc le `#available` est obligatoire) : le repli est un material,
  /// sans morphing.
  @ViewBuilder
  private func glassStack(_ palette: QuickPalette) -> some View {
    if #available(macOS 26, *) {
      GlassEffectContainer(spacing: 26) { stack(palette) }
        // Posée ICI, HORS du conteneur — pas dans `pane` : une ombre posée par bloc, À
        // L'INTÉRIEUR du conteneur, ne sortait pas du tout (mesuré : aucune amélioration malgré
        // des densités doublées). `GlassEffectContainer` compose son rendu Liquid Glass dans un
        // calque à la mesure des FORMES, pas de leur débord — l'ombre, elle, en a besoin. Posée
        // sur le conteneur lui-même, elle en épouse quand même le CONTOUR réel (`.shadow` suit
        // l'alpha du rendu, pas une boîte) : au repos, seule la capsule est visible, l'ombre en
        // épouse donc exactement son contour.
        .paneShadow()
    } else {
      stack(palette)
    }
  }

  /// `spacing: 0` et un écart porté par chaque bloc : celui des destinations est TOUJOURS monté
  /// (cf. `destinationPane`), il doit donc pouvoir replier son écart en même temps que sa hauteur,
  /// sinon un trou de 10pt resterait sous la barre quand il est fermé.
  private func stack(_ palette: QuickPalette) -> some View {
    VStack(spacing: 0) {
      pane(.bar, shape: Capsule()) { bar(palette) }
        .gesture(windowDrag)
      destinationPane
      if expanded {
        pane(.details, shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) {
          detailsBox
        }
        .padding(.top, 10)
        .padding(.horizontal, 26)
      }
      if !queued.isEmpty {
        pane(.queue, shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) {
          queueBox
        }
        .padding(.top, 10)
        .padding(.horizontal, 14)
      }
      if !palette.isEmpty {
        pane(.results, shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) {
          QuickEntryResultsBox(rows: palette.rows, selection: selection, onActivate: activate)
        }
        .padding(.top, 10)
        .padding(.horizontal, 14)
      }
    }
  }

  /// La barre s'attrape comme une barre de titre : c'est le seul moyen de déplacer une fenêtre sans
  /// chrome. Le geste ne sert qu'à dire « le bouton est enfoncé et ça bouge » — le calcul est chez
  /// `QuickEntryWindow`, seul à savoir où en est le panneau.
  ///
  /// Parti du champ de texte, un glissement SÉLECTIONNE : AppKit y traite l'événement avant SwiftUI,
  /// et c'est exactement ce que fait Spotlight. On attrape la barre par ses bords.
  private var windowDrag: some Gesture {
    DragGesture(minimumDistance: 3)
      .onChanged { _ in QuickEntryWindow.shared.dragMoved() }
      .onEnded { _ in QuickEntryWindow.shared.dragEnded() }
  }

  // MARK: Palette

  /// Ce que la capsule montre sous sa barre, ou rien.
  ///
  /// Un SEUL bloc de liste à la fois : le panneau a une hauteur FIXE (cf.
  /// `QuickEntryWindow.makePanel`) et deux listes empilées en sortiraient. D'où les trois retraits :
  /// - **un dépliant ouvert** (sous-tâches, destinations) — on compose une tâche, on n'en cherche
  ///   pas ;
  /// - **une fournée en cours** — même raison, et c'est elle qui doit rester visible : elle est la
  ///   seule preuve de ce qui est déjà déposé ;
  /// - sinon la palette, avec le coup d'œil sur la journée pour état vide.
  private var currentPalette: QuickPalette {
    guard !expanded, !picking, queued.isEmpty else { return QuickPalette(rows: []) }
    switch step {
    case .search:
      return QuickPalette.search(title, lists: reachable, projects: projects, tasks: allTasks)
    case .addTask(let target):
      return QuickPalette.inside(target, lists: reachable, tasks: allTasks)
    case .createList(let project):
      return QuickPalette.inside(project: project)
    }
  }

  /// ↓ descend dans la liste, ↑ y remonte.
  ///
  /// La borne haute n'est pas la même selon le temps où l'on est, et c'est délibéré : en RECHERCHE
  /// la sélection ne quitte jamais la liste (une barre sans ligne visée n'aurait aucune action à
  /// offrir) ; en seconde étape, ↑ depuis la première ligne rend la main à la barre, puisque c'est
  /// là qu'on écrit.
  private func moveSelection(_ press: KeyPress, count: Int) -> KeyPress.Result {
    guard count > 0 else { return .ignored }
    switch press.key {
    case .downArrow:
      selection = selection.map { min($0 + 1, count - 1) } ?? 0
      return .handled
    case .upArrow:
      guard let current = selection else { return .ignored }
      if current == 0 {
        selection = step.isSearch ? 0 : nil
      } else {
        selection = current - 1
      }
      return .handled
    default:
      return .ignored
    }
  }

  /// ⌘↩ : ouvrir l'app SUR la ligne visée, au lieu d'y faire quelque chose. Le pendant « aller
  /// voir » de ↩, qui, lui, « fait ici ».
  ///
  /// Il vaut aux DEUX temps : les listes d'un dossier s'ouvrent comme les lignes d'une recherche.
  /// Borné à la première étape, ⌘↩ sur l'une d'elles finissait en bip système.
  ///
  /// Une tâche ouvre la LISTE qui la porte (cf. `QuickPalette.taskRow`) ; sans ligne visée, c'est
  /// l'endroit de l'ÉTAPE — sauf quand une tâche s'écrit, où ⌘↩ appartient à l'empilement.
  private func openSelected(_ press: KeyPress) -> KeyPress.Result {
    guard press.key == .return, press.modifiers.contains(.command) else { return .ignored }
    let rows = currentPalette.rows
    // Une ligne VISÉE nous appartient, même sans endroit où aller (une commande) : la touche est
    // consommée quand même, sans quoi AppKit la refuse en bip. Sans ligne visée, on laisse passer —
    // c'est `enqueueShortcut`, juste derrière, qui a le dernier mot.
    if let index = selection, rows.indices.contains(index) {
      guard let destination = rows[index].destination else { return .handled }
      return reveal(destination)
    }
    guard let destination = stepDestination else { return .ignored }
    return reveal(destination)
  }

  /// `dismiss()` AVANT d'ouvrir, comme pour une commande : la capsule ne doit pas rester devant la
  /// fenêtre qu'elle vient de ramener.
  private func reveal(_ destination: SidebarSelection) -> KeyPress.Result {
    dismiss()
    AppCommand.reveal(destination)
    return .handled
  }

  /// L'endroit de l'étape en cours, quand aucune ligne n'est visée. En recherche il n'y en a aucun,
  /// et sur une tâche en écriture ⌘↩ appartient à l'empilement.
  private var stepDestination: SidebarSelection? {
    if case .createList(let project) = step { return .project(project) }
    return nil
  }

  /// Ce que ↩ (ou un clic) fait d'une ligne : exactement ce qu'elle annonçait.
  private func activate(_ row: QuickPalette.Row) {
    switch row.action {
    case .addTask(let target): begin(.addTask(target), landingOn: target)
    case .createList(let project): begin(.createList(project), landingOn: nil)
    case .complete(let task): toggle(task)
    case .run(let command): run(command)
    }
  }

  /// Le passage à la seconde étape. La destination choisie est posée dans l'état QUE LA CAPSULE
  /// AVAIT DÉJÀ (`targetID`, `when`) : tout le chemin d'écriture existant — jetons, fournée,
  /// `insert` — continue de marcher sans rien savoir des étapes.
  ///
  /// `title` est vidé : la frappe qui a servi à TROUVER l'endroit n'est pas le titre de ce qu'on
  /// va y écrire. C'est la confusion que le découpage en deux temps existe pour éviter.
  private func begin(_ next: Step, landingOn target: QuickPalette.TaskTarget?) {
    // La seconde étape liste ce que le contenant porte déjà : « Aujourd'hui » se construit à
    // partir de la fournée, qui peut ne pas encore avoir été chargée si l'on est arrivé ici sans
    // taper une lettre (un prefill, un brouillon repris).
    loadAllTasks()
    if let target {
      let resolved = target.resolve(in: reachable)
      targetID = resolved.list?.persistentModelID
      when = resolved.when
    }
    withAnimation(.bouncy(duration: 0.35)) {
      step = next
      title = ""
      selection = nil
    }
    focus = .title
  }

  /// Le retour en arrière d'Échap : on jette ce qu'on écrivait pour CETTE étape, pas la capsule.
  private func backToSearch() {
    withAnimation(.bouncy(duration: 0.35)) {
      step = .search
      title = ""
      subtasks = []
      when = nil
      whenMinutes = nil
      expanded = false
      selection = 0
    }
    focus = .title
  }

  /// L'action d'un DOSSIER. Le rang se prend à la suite de ses listes, comme partout ailleurs.
  private func createList(in project: Project) {
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let list = TodoList(title: name, project: project)
    list.sortIndex = (project.orderedLists.last?.sortIndex ?? -1) + 1
    modelContext.insertAndSave(list)
    // La capsule s'utilise depuis une AUTRE app : la sidebar où la liste vient d'apparaître n'est
    // pas à l'écran. Même raison que pour une tâche déposée.
    HUDWindow.show("Liste « \(name) » créée", systemImage: "checkmark", tint: .green)
    dismiss()
  }

  /// Cocher depuis la capsule. Elle RESTE ouverte : on en coche souvent deux ou trois d'affilée, et
  /// Échap la referme.
  private func toggle(_ task: TaskItem) {
    withAnimation(.bouncy(duration: 0.3)) { task.toggleCompletion() }
    // Enregistré tout de suite plutôt que laissé à l'autosave : c'est `ModelContext.didSave` qui
    // réveille la passe Rappels (cf. `ContentView.syncWithReminders`), et le panneau peut très bien
    // se fermer avant qu'un autosave ne tombe.
    // ponytail: pas de `pushCompletion` direct comme dans `TaskRow` — `RemindersService` n'est pas
    // dans l'environnement de ce panneau, qui vit hors de l'arbre de `ContentView`. Fenêtre
    // principale fermée, la coche part donc au prochain réveil de la synchro, comme le fait déjà
    // une tâche créée ici.
    try? modelContext.save()
  }

  /// Une commande n'écrit rien : elle emmène ailleurs, et la capsule s'efface derrière elle — même
  /// ordre que dans `save`, pour que le panneau ne reste pas devant la fenêtre qu'il vient de
  /// ramener.
  private func run(_ command: AppCommand) {
    dismiss()
    command.run()
  }

  /// Le bloc des destinations n'est JAMAIS inséré ni retiré : il est toujours là, à hauteur nulle
  /// quand il est fermé. C'est la seule façon d'obtenir la fusion progressive du verre — pendant
  /// une `transition`, SwiftUI compose la vue qui entre dans un calque séparé, et le
  /// `GlassEffectContainer` ne la fond au reste qu'une fois la transition terminée : le pont se
  /// collait d'un coup, à la dernière image. En animant la HAUTEUR d'une vue déjà en place, le
  /// verre s'étire hors de la barre et la jonction se forme au fil de la croissance.
  ///
  /// Un `HStack` + `Spacer` plutôt qu'un `frame(maxWidth:alignment:)` pour le caler à gauche : le
  /// gabarit pleine largeur deviendrait la vue animée, et le bloc grandirait depuis le milieu de
  /// la capsule au lieu de son chip.
  private var destinationPane: some View {
    HStack(spacing: 0) {
      pane(
        .destination, shape: RoundedRectangle(cornerRadius: 22, style: .continuous),
        morphing: false
      ) {
        destinationBox
      }
      // Une mesure ratée doit donner un bloc TROP GRAND, jamais un bloc invisible : sans ce repli,
      // une hauteur restée à zéro rendrait le menu impossible à ouvrir.
      .frame(
        width: 290,
        height: picking ? (destinationHeight > 0 ? min(destinationHeight, 260) : 260) : 0
      )
      // La hauteur cible se mesure sur une copie INVISIBLE, laissée à sa taille idéale. Mesurer
      // la vraie ferait un nœud : repliée à zéro, elle se mesure à zéro, et le bloc ne pourrait
      // plus jamais s'ouvrir.
      //
      // Bornée DEUX fois. À l'étape qui COMPOSE une tâche, parce que c'est la seule où le chip
      // existe, donc la seule où `picking` peut passer à vrai : la rendre en recherche revenait à
      // mesurer un bloc que rien ne peut ouvrir (8 ms sur chaque ouverture de la capsule, payés
      // avant que la fenêtre paraisse). Et tant que la hauteur n'est pas connue : une fois mesurée
      // elle est en `@State` pour la session, la copie n'a plus rien à apprendre — sans quoi elle
      // se reconstruirait à chaque frappe du titre.
      .background(alignment: .top) {
        if step.composesTask, destinationHeight == 0 {
          destinationList
            .frame(width: 290)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .background {
              GeometryReader { proxy in
                Color.clear.preference(key: DestinationHeightKey.self, value: proxy.size.height)
              }
            }
        }
      }
      // Zéro n'est jamais une mesure, c'est le défaut de la clé — celui que la copie publie en
      // partant. Le retenir la ferait remonter aussitôt, et les deux se relanceraient sans fin.
      .onPreferenceChange(DestinationHeightKey.self) { if $0 > 0 { destinationHeight = $0 } }
      Spacer(minLength: 0)
    }
    .padding(.leading, 14)
    .padding(.top, picking ? 10 : 0)
    // Fermé, le bloc ne fait plus que 0pt de haut mais reste dans l'arbre : sans ça il avalerait
    // les clics de la zone qu'il occupe encore.
    .allowsHitTesting(picking)
  }

  /// Un bloc de la pile. Générique sur la forme pour que le repli garde `.strokeBorder` (défini sur
  /// `InsettableShape` seulement), et pour n'écrire qu'une fois le contenu des deux branches.
  ///
  /// `morphing: false` laisse le bloc HORS du morphing : un bloc identifié naît du barycentre des
  /// autres verres du conteneur — soit le centre de la capsule — et aucune `.transition` ne reprend
  /// la main dessus. C'est juste pour les blocs pleine largeur, faux pour un bloc accroché à un
  /// bouton précis, qui doit sortir de CE bouton.
  @ViewBuilder
  private func pane<S: InsettableShape, V: View>(
    _ id: Block, shape: S, morphing: Bool = true, @ViewBuilder content: () -> V
  ) -> some View {
    if #available(macOS 26, *) {
      // Le verre nu laisse trop passer le bureau : le texte perd son contraste. Le `tint` est la
      // seule densification prévue par l'API — un calque posé par-dessus tuerait les reflets
      // internes. `windowBackgroundColor` suit déjà le thème, pas de couleur figée ici.
      let glass = content()
        .glassEffect(
          .regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.25)).interactive(),
          in: shape
        )
      let identified = Group {
        if morphing {
          glass.glassEffectID(id, in: morph)
        } else {
          glass
        }
      }
      // La bordure vient APRÈS `glassEffectID`, pas avant : posée sur le verre lui-même (chaînée
      // avant l'identité de morphing), elle ne se voyait quasiment pas — deux hausses de densité
      // sans effet visible. Le conteneur retraite le sous-arbre identifié pour son fondu élastique ;
      // ce qui est accroché AVANT cette étape n'en ressortait pas intact, exactement comme
      // `paneShadow`, qu'il a fallu sortir du conteneur pour la même raison.
      identified
        .overlay { shape.strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.25) }
    } else {
      content()
        .background(.regularMaterial, in: shape)
        .overlay { shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
        .paneShadow()
        .transition(.scale(scale: 0.92, anchor: .top).combined(with: .opacity))
    }
  }

  /// Ce que la barre annonce — et c'est le seul endroit qui dit à quel temps on en est, avec les
  /// icônes de droite. Un état qui ne se voit pas est un état qu'on oublie.
  private var placeholder: String {
    switch step {
    case .search: return "Rechercher une vue, un dossier, une liste, une tâche…"
    case .addTask(let target): return "Nouvelle tâche dans " + target.label
    case .createList(let project):
      return "Nom de la liste dans " + (project.title.isEmpty ? "ce dossier" : project.title)
    }
  }

  /// À gauche du champ : la loupe quand on cherche, la destination quand on écrit une tâche, le
  /// dossier quand on nomme une liste.
  @ViewBuilder private var barLeading: some View {
    switch step {
    case .search:
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
    case .addTask:
      destinationChip
    case .createList(let project):
      HStack(spacing: 6) {
        Image(systemName: "folder").foregroundStyle(.secondary)
        Text(project.title.isEmpty ? "Sans titre" : project.title)
      }
      .font(.app(14))
      .fixedSize()
    }
  }

  private func bar(_ palette: QuickPalette) -> some View {
    HStack(spacing: 12) {
      barLeading
      // La date à GAUCHE, en pastille, exactement comme la rangée « Nouvelle tâche » d'une liste
      // (cf. `TokenPill`) : c'est là que se lit ce qui est déjà décidé. Le menu calendrier de
      // droite n'en garde que l'icône, sans quoi la date s'afficherait deux fois.
      if step.composesTask, let when {
        // Jour et heure dans UNE pastille, comme sur la ligne au repos (cf. `TokenPill.schedule`).
        TokenPill(text: TokenPill.schedule(when, minutes: whenMinutes))
          .onTapGesture {
            self.when = nil
            whenMinutes = nil
          }
          .help("Retirer la date")
      }
      TextField(placeholder, text: $title, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.app(20))
        // Une recherche tient sur UNE ligne, quoi qu'il arrive : l'axe vertical sert aux titres de
        // tâche longs, mais il ferait aussi passer le libellé de recherche à la ligne et la barre
        // grandirait sous le curseur avant même qu'on ait tapé.
        .lineLimit(step.isSearch ? 1 : nil)
        .focused($focus, equals: .title)
        // Seul chemin d'enregistrement au clavier depuis que la barre de validation a disparu :
        // plus de bouton par défaut avec qui se dédoubler.
        .onSubmit(save)
        // Les jetons quittent le texte dès qu'un espace les valide, comme dans les listes. Le
        // panneau ne les analysait qu'à l'enregistrement : rien ne confirmait « @demain » sous les
        // doigts — et un raccourci texte n'aurait rien eu à montrer non plus.
        .onChange(of: title) { _, new in
          // La première frappe est le moment où la palette a besoin des tâches — et le premier où
          // elle en a besoin tout court (cf. `allTasks`).
          if !new.isEmpty { loadAllTasks() }
          // Les jetons n'ont de sens que sur une tâche en train de s'écrire : dans une recherche,
          // « @demain » est un texte cherché, pas une date à ranger.
          if step.composesTask {
            let cleaned = consumeTokens(new)
            if cleaned != new { title = cleaned }
          }
          // La frappe rebat la liste : en recherche la sélection revient sur la première ligne (↩
          // doit toujours avoir une action), en seconde étape elle rend la main à la barre.
          selection = step.isSearch ? 0 : nil
        }
        // Un SEUL gestionnaire pour les deux gestes, plutôt que deux `.onKeyPress(phases:)`
        // empilés dont l'ordre de consultation ne se lit nulle part.
        .onKeyPress(phases: .down) { press in
          if openSelected(press) == .handled { return .handled }
          if enqueueShortcut(press) == .handled { return .handled }
          return moveSelection(press, count: palette.rows.count)
        }
        // Tab ne sert PLUS qu'à un geste : changer le dernier mot en jeton (« ajd » → une date).
        //
        // Il ouvrait aussi les notes quand aucun raccourci ne correspondait, et c'est ce double
        // sens qui le rendait imprévisible dès que la capsule affichait autre chose qu'une tâche en
        // cours d'écriture. Les notes parties, la question ne se pose plus : hors de ce cas précis,
        // Tab ne répond rien du tout.
        .onKeyPress(.tab) {
          guard step.composesTask,
            let resolved = QuickEntry.resolving(title, shortcuts: shortcuts)
          else { return .ignored }
          // Une commande n'écrit rien : elle emmène ailleurs, et la capsule s'efface derrière elle.
          // `save` la reconnaît par le même chemin qu'Entrée, emporte la fournée et referme.
          if resolved.command == nil { title = resolved.text } else { save() }
          return .handled
        }
      if step.composesTask, canSave {
        // Sans cette mention, l'empilement n'existe que pour qui le connaît déjà.
        Text("⌘↩")
          .font(.app(11, weight: .medium))
          .foregroundStyle(.tertiary)
          .transition(.opacity)
      }
      // Date et sous-tâches : les attributs d'une TÂCHE. Ils n'ont rien à faire dans une recherche
      // ni dans le nom d'une liste, et les laisser là était la porte par laquelle une touche
      // prenait deux sens.
      if step.composesTask {
        dateMenu
        subtaskButton
      }
      if !step.isSearch { sendButton }
    }
    // Les icônes de droite n'ont pas de police à elles : la donner ICI les met à l'échelle du champ
    // sans toucher aux vues qui fixent déjà la leur (le champ, la mention ⌘↩, le chip).
    .font(.app(15))
    .padding(.horizontal, 17)
    .padding(.vertical, 15)
    // La pastille de date entre et sort de la rangée : sans ça, la barre se réagence d'un coup
    // sous le curseur au moment où le jeton est reconnu. L'heure la fait GRANDIR sans la faire
    // entrer — même réagencement, même courbe.
    .animation(.bouncy(duration: 0.35), value: when)
    .animation(.bouncy(duration: 0.35), value: whenMinutes)
  }

  /// Les sous-tâches, et rien d'autre.
  ///
  /// Les notes ont été retirées : dans une capsule dont le geste est « noter vite et repartir »,
  /// personne n'écrivait de texte long — et elles coûtaient cher pour ça. C'est leur `TextField`
  /// que Tab ouvrait, le double sens de touche par lequel la capsule plantait dès qu'elle affichait
  /// autre chose. Une note s'écrit dans la tâche, une fois ouverte.
  private var detailsBox: some View {
    VStack(alignment: .leading, spacing: 9) {
      ForEach(subtasks.indices, id: \.self, content: subtaskRow)
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 14)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Case ronde décorative, comme dans les sous-tâches d'une vraie tâche : il n'y a rien à cocher
  /// sur une étape qu'on est en train d'écrire, mais la ligne doit se lire comme une sous-tâche.
  private func subtaskRow(_ index: Int) -> some View {
    HStack(spacing: 9) {
      TaskCheckbox(isCompleted: false, circular: true) {}
        .allowsHitTesting(false)
      TextField("Sous-tâche", text: $subtasks[index])
        .textFieldStyle(.plain)
        .font(.app(14))
        .focused($focus, equals: .subtask(index))
        .onKeyPress(phases: .down, action: enqueueShortcut)
        // Même geste que dans la page d'une tâche (cf. `enterOnSubtask`) : Entrée enchaîne sur une
        // étape de plus, et n'enregistre que si celle-ci est restée vide.
        .onSubmit {
          if subtasks[index].trimmingCharacters(in: .whitespaces).isEmpty {
            save()
          } else {
            addSubtask()
          }
        }
    }
  }

  /// La fournée en attente. Sa raison d'être est de rendre VISIBLE ce qui est déjà déposé : sans
  /// elle, empiler à l'aveugle reviendrait à taper dans le vide en espérant que ça a pris.
  private var queueBox: some View {
    VStack(spacing: 0) {
      ForEach(Array(queued.enumerated()), id: \.element.id) { index, pending in
        if index > 0 { Divider() }
        queueRow(pending)
      }
    }
    .padding(.vertical, 4)
  }

  private func queueRow(_ pending: PendingTask) -> some View {
    HStack(spacing: 10) {
      TaskCheckbox(isCompleted: false) {}
        .allowsHitTesting(false)
      Text(pending.title).font(.app(14)).lineLimit(1)
      Spacer(minLength: 10)
      if let when = pending.when {
        Text(TokenPill.schedule(when, minutes: pending.minutes))
          .font(.app(11))
          .foregroundStyle(Color.accentColor)
      }
      // La destination est rappelée sur chaque ligne : rien n'oblige les tâches d'une même fournée
      // à partir au même endroit, le chip peut changer entre deux ⌘↩.
      if let name = list(for: pending.targetID)?.title {
        Text(name).font(.app(11)).foregroundStyle(.tertiary)
      }
      Button {
        withAnimation(.bouncy(duration: 0.35)) { queued.removeAll { $0.id == pending.id } }
      } label: {
        Image(systemName: "xmark").font(.app(10, weight: .semibold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(.tertiary)
      .help("Retirer de la fournée")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }

  /// Teinte du chip de destination : la même couleur de base que le fond de la capsule, mélangée au
  /// noir par petites touches pour se lire un cran plus SOMBRE — mais gardée translucide, PAS un
  /// aplat opaque. Un aplat opaque se voit bien sur un fond clair (c'est pour ça qu'il avait
  /// remplacé `.quaternary.opacity(…)`, qui s'y noyait), mais posé par-dessus un verre qui, lui,
  /// laisse deviner ce qu'il y a derrière, il devient un timbre mort dès que le fond est chargé —
  /// mesuré par-dessus une capture d'écran riche en contraste : le chip seul perdait tout l'effet
  /// liquid glass que le reste de la capsule gardait.
  private static func chipTint(picking: Bool) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base =
          NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor
        let fraction = picking ? (dark ? 0.22 : 0.14) : (dark ? 0.14 : 0.08)
        return base.blended(withFraction: fraction, of: .black) ?? base
      }
    )
    // Un cran au-dessus du tint de la capsule (0.45) : assez pour rester lisible sur un fond clair
    // sans redevenir l'aplat qu'on vient de retirer.
    .opacity(0.6)
  }

  /// Repli pré-macOS 26 : pas de verre à nourrir, donc l'aplat opaque d'origine reste le bon choix —
  /// c'est la même densification que le repli material de `pane`.
  private static func chipFill(picking: Bool) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base =
          NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .windowBackgroundColor
        let fraction = picking ? (dark ? 0.22 : 0.14) : (dark ? 0.14 : 0.08)
        return base.blended(withFraction: fraction, of: .black) ?? base
      })
  }

  /// Où ira la tâche, à gauche du champ : la seule information que la capsule doit porter en
  /// permanence, parce qu'elle est la seule qu'on ne peut pas deviner en lisant ce qu'on tape.
  private var destinationChip: some View {
    Button {
      // Un seul bloc ouvert à la fois sous la barre : les destinations et les sous-tâches empilées
      // faisaient une colonne plus haute que la capsule elle-même, dans une fenêtre qui doit se
      // lire d'un coup d'œil.
      withAnimation(.bouncy(duration: 0.4)) {
        picking.toggle()
        if picking { expanded = false }
      }
    } label: {
      chipLabel
    }
    .buttonStyle(.plain)
    .fixedSize()
    .help("Choisir la destination")
  }

  /// Verre imbriqué plutôt qu'un aplat : le chip doit rester du VERRE, comme le reste de la
  /// capsule, sinon il se détache en timbre opaque dès que le fond derrière la fenêtre est chargé
  /// (cf. `chipTint`).
  @ViewBuilder
  private var chipLabel: some View {
    let content = HStack(spacing: 6) {
      destinationIcon
      Text(chipTitle)
    }
    .font(.app(14))
    .padding(.vertical, 5)
    .padding(.horizontal, 12)
    .contentShape(Capsule())

    if #available(macOS 26, *) {
      content.glassEffect(
        .regular.tint(Self.chipTint(picking: picking)).interactive(), in: Capsule())
    } else {
      content.background(Self.chipFill(picking: picking), in: Capsule())
    }
  }

  /// Le chip dit l'endroit QU'ON A CHOISI, pas la liste dans laquelle il se résout.
  ///
  /// « Aujourd'hui » se range dans la boîte de réception avec une date — le chip affichait donc
  /// « Tâches » alors qu'on venait de choisir « Aujourd'hui ». Le contenant et son point de chute
  /// sont deux choses différentes, et c'est le premier qui doit se lire.
  private var chipTitle: String {
    if case .addTask(let target) = step { return target.label }
    return destination?.title ?? SmartList.all.label
  }

  @ViewBuilder private var destinationIcon: some View {
    if case .addTask(.today) = step {
      Image(systemName: SmartList.today.systemImage).foregroundStyle(.secondary)
    } else if let destination, !destination.isInbox {
      ProgressRing(progress: destination.progress(), size: 11, lineWidth: 1.8)
        .tint(destination.project?.color?.color)
    } else {
      Image(systemName: "tray.full.fill").foregroundStyle(.secondary)
    }
  }

  /// Les destinations, dans un bloc de la pile plutôt que dans un `Menu` : le verre d'un `NSMenu`
  /// est celui du système, impossible à accorder à celui de la capsule (ni à faire participer au
  /// morphing du `GlassEffectContainer`). Le prix est la coche et le survol à écrire à la main.
  private var destinationBox: some View {
    // Monté sur `showsDestinations` et non sur `picking` : le contenu survit à la fermeture, le
    // temps que la hauteur retombe à zéro. Démonté d'un coup, le bloc se viderait sous les yeux
    // avant d'avoir fini de se replier — même motif que `TaskRow.showEditor`.
    ScrollView {
      if showsDestinations { destinationList.transition(.identity) }
    }
    // Les listes sans projet sont volontairement absentes : la sidebar n'en montre aucune (elle
    // ne rend que l'inbox et les listes DANS un projet), les proposer ici revenait à offrir
    // comme destination des listes héritées que rien d'autre dans l'app ne sait rouvrir.
    .scrollBounceBehavior(.basedOnSize)
  }

  private var destinationList: some View {
    VStack(alignment: .leading, spacing: 1) {
      if let inbox { destinationRow(inbox) }
      // Un projet n'est PAS une destination : `TaskItem.project` se déduit de la liste
      // (`list?.project`), une tâche se pose donc toujours dans une liste. Il n'est ici qu'un
      // titre de section.
      ForEach(projects) { project in
        if !project.orderedLists.isEmpty {
          Text(project.title.isEmpty ? "Sans titre" : project.title)
            .font(.app(11, weight: .medium))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 1)
          ForEach(project.orderedLists, content: destinationRow)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.vertical, 6)
    .padding(.horizontal, 6)
  }

  private func destinationRow(_ list: TodoList) -> some View {
    let id = list.persistentModelID
    return Button {
      withAnimation(.bouncy(duration: 0.4)) {
        targetID = id
        // L'étape suit le choix, sinon le chip continuerait d'annoncer l'endroit d'où l'on vient
        // (« Aujourd'hui ») alors que la tâche partirait ailleurs. Une seule vérité pour la
        // destination. La date, elle, reste : elle est visible dans sa pastille et s'y retire.
        step = .addTask(.list(list))
        picking = false
      }
      focus = .title
    } label: {
      HStack(spacing: 8) {
        Group {
          if list.isInbox {
            Image(systemName: "tray.full.fill").foregroundStyle(.secondary)
          } else {
            ProgressRing(progress: list.progress(), size: 11, lineWidth: 1.8)
              .tint(list.project?.color?.color)
          }
        }
        .frame(width: 14)
        Text(list.title.isEmpty ? "Sans titre" : list.title).font(.app(13)).lineLimit(1)
        Spacer(minLength: 8)
        if destination?.persistentModelID == id {
          Image(systemName: "checkmark")
            .font(.app(11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      .background(
        hovered == id ? Color.primary.opacity(0.08) : .clear,
        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { hovered = $0 ? id : (hovered == id ? nil : hovered) }
  }

  /// La date est le seul réglage que le modèle porte ET que la saisie rapide ne sait pas déjà
  /// exprimer par un jeton.
  // ponytail: pas de tag (le modèle n'en a pas), pas de checklist ni de drapeau ici — ils
  // s'ajoutent en deux clics sur la tâche une fois créée.
  private var dateMenu: some View {
    Menu {
      Button("Aujourd'hui") { when = Calendar.current.startOfDay(for: Date()) }
      Button("Demain") {
        when = Calendar.current.date(
          byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
      }
      if when != nil {
        Divider()
        Button("Aucune date") {
          when = nil
          whenMinutes = nil  // l'heure ne survit pas à son jour (cf. `TaskItem.whenMinutes`)
        }
      }
    } label: {
      // Icône seule : la date choisie se lit dans la pastille de gauche (cf. `bar`).
      Image(systemName: "calendar")
        .foregroundStyle(when == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Planifier la tâche")
  }

  private var subtaskButton: some View {
    Button(action: addSubtask) {
      Image(systemName: "checklist")
        .foregroundStyle(
          subtasks.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
    }
    .buttonStyle(.plain)
    .help("Ajouter une sous-tâche")
  }

  private var sendButton: some View {
    Button(action: save) {
      Image(systemName: "arrow.up").font(.app(15, weight: .semibold))
    }
    .buttonStyle(.plain)
    .foregroundStyle(canSave ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
    .disabled(!canSave)
    .scaleEffect(canSave ? 1 : 0.82)
    .animation(.spring(response: 0.3, dampingFraction: 0.55), value: canSave)
    .help(queued.isEmpty ? "Enregistrer (↩)" : "Enregistrer les \(queued.count + 1) tâches (↩)")
  }

  /// Ouvre le bloc des sous-tâches — et referme les destinations : réciproque du chip, un seul
  /// bloc à la fois.
  private func expand(focusing field: Field) {
    withAnimation(.bouncy(duration: 0.45)) {
      expanded = true
      picking = false
    }
    focus = field
  }

  private func addSubtask() {
    subtasks.append("")
    expand(focusing: .subtask(subtasks.count - 1))
  }

  // MARK: Brouillon

  /// Réapplique le brouillon laissé par une fermeture accidentelle. Consommé une fois : la suite
  /// des frappes reconstitue l'état courant, que `persistDraft` regardera si la capsule se referme
  /// encore sans validation.
  private func restoreDraft() {
    guard let saved = QuickEntryDraftStore.shared.draft else { return }
    QuickEntryDraftStore.shared.draft = nil
    title = saved.title
    subtasks = saved.subtasks
    when = saved.when
    whenMinutes = saved.minutes
    if let savedTarget = saved.targetID { targetID = savedTarget }
    queued = saved.queued
    if !saved.subtasks.isEmpty { expanded = true }
  }

  /// Range l'état courant avant une fermeture qui n'est PAS une validation. Vide, il efface un
  /// brouillon devenu obsolète plutôt que d'en garder un fantôme.
  private func persistDraft() {
    let saved = QuickEntryDraftStore.Draft(
      title: title, subtasks: subtasks, when: when, minutes: whenMinutes, targetID: targetID,
      queued: queued)
    QuickEntryDraftStore.shared.draft = saved.isEmpty ? nil : saved
  }

  // MARK: Enregistrement

  /// Les listes que l'app sait ROUVRIR : l'inbox et celles rangées dans un projet. Une liste sans
  /// projet n'apparaît nulle part dans la sidebar (cf. `projectsGroup`) — il en traîne d'anciennes
  /// en base, et le panneau était le seul endroit à les rendre visibles, donc atteignables au
  /// `#jeton` comme au chip. Une tâche qui y tombait devenait introuvable.
  private var reachable: [TodoList] { lists.filter { $0.isInbox || $0.project != nil } }
  private var inbox: TodoList? { reachable.first(where: \.isInbox) }
  private func list(for id: PersistentIdentifier?) -> TodoList? {
    id.flatMap { wanted in reachable.first { $0.persistentModelID == wanted } } ?? inbox
      ?? reachable.first
  }
  private var destination: TodoList? { list(for: targetID) }
  private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

  /// L'état de saisie, figé tel quel : ce que ⌘↩ dépose dans la fournée et ce que ↩ emporte avec
  /// elle. `nil` si le titre est vide — une tâche sans titre n'existe pas.
  private var draft: PendingTask? {
    // Le raccourci resté en fin de frappe est résolu ICI, donc pour TOUS les chemins qui valident
    // (Entrée, ⌘↩, le bouton d'envoi) et pas seulement pour ⇥ : sans ça « ajd » seul deviendrait
    // une tâche nommée « ajd ». Un déclencheur de commande ne laisse rien derrière lui, la tâche
    // disparaît alors d'elle-même — c'est `save` qui exécute la commande.
    let text = QuickEntry.resolving(title, shortcuts: shortcuts)?.text ?? title
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return PendingTask(
      title: text, subtasks: subtasks, when: when, minutes: whenMinutes, targetID: targetID)
  }

  /// ⌘↩ depuis n'importe quel champ : dépose et rend le champ vide. Partagé plutôt que réécrit sur
  /// chacun — trois copies auraient divergé à la première retouche.
  private func enqueueShortcut(_ press: KeyPress) -> KeyPress.Result {
    guard press.key == .return, press.modifiers.contains(.command) else { return .ignored }
    // `composesTask` et pas seulement « il y a un titre » : en RECHERCHE, la frappe désigne une
    // ligne, elle n'écrit pas une tâche. Sans cette garde, ⌘↩ sur une ligne sans destination
    // déposait le texte de la recherche dans la fournée.
    guard step.composesTask else { return .ignored }
    enqueue()
    return .handled
  }

  private func enqueue() {
    guard let draft else { return }
    withAnimation(.bouncy(duration: 0.4)) {
      queued.append(draft)
      title = ""
      subtasks = []
      when = nil
      whenMinutes = nil
      expanded = false  // les sous-tâches sont parties avec la tâche déposée
    }
    // `targetID` survit exprès : trois tâches lancées d'affilée vont le plus souvent au même
    // endroit, et le chip reste modifiable entre deux dépôts.
    focus = .title
  }

  private func save() {
    // Entrée maintenue pendant la sortie : une tâche, pas deux. `dismiss()` a déjà posé `closing`
    // quand il repasse ici.
    guard !closing else { return }
    // ↩ ne veut pas dire la même chose aux deux temps, et c'est TOUT le principe. Le branchement
    // est posé ICI, au point de passage unique de toutes les validations (Entrée, le bouton
    // d'envoi, la dernière sous-tâche) plutôt que sur chacune — trois copies auraient divergé.
    //
    // Bornes vérifiées à chaque fois : la palette est rebâtie à chaque rendu, et une ligne peut
    // avoir disparu sous la sélection (tâche supprimée ailleurs, date qui la sort du contexte)
    // entre le ↓ et le ↩.
    let rows = currentPalette.rows
    if step.isSearch {
      // En recherche, ↩ n'écrit JAMAIS rien de lui-même : il fait ce que la ligne annonce.
      if let index = selection, rows.indices.contains(index) { activate(rows[index]) }
      return
    }
    // Seconde étape, une ligne de contexte visée : c'est ELLE qui agit — cocher une tâche, entrer
    // dans une liste du dossier. Testé AVANT l'action de la barre, sinon nommer une liste
    // l'emporterait sur la ligne qu'on vient de viser au clavier.
    if let index = selection, rows.indices.contains(index) {
      activate(rows[index])
      return
    }
    if case .createList(let project) = step {
      createList(in: project)
      return
    }
    // Une commande d'app laissée en fin de frappe (« op ↩ ») : elle part APRÈS la fermeture, pour
    // que la capsule ne reste pas devant la fenêtre qu'elle vient de ramener.
    let command = QuickEntry.resolving(title, shortcuts: shortcuts)?.command
    // La tâche en cours de frappe part avec la fournée : ↩ enregistre TOUT, sans quoi la dernière
    // resterait à l'écran au moment où la fenêtre se ferme.
    let batch = queued + [draft].compactMap { $0 }
    // Une validation, même sans rien à écrire (une commande seule) : le brouillon qu'elle
    // remplace n'a plus lieu d'être repêché à la prochaine ouverture.
    QuickEntryDraftStore.shared.draft = nil
    // Rien à enregistrer : on sort par la même porte que Échap, pas en escamotant la fenêtre.
    guard !batch.isEmpty else {
      dismiss()
      command?.run()
      return
    }
    batch.forEach(insert)
    // La capsule s'utilise depuis une AUTRE app : la liste où la tâche vient d'atterrir n'est pas à
    // l'écran, et rien ne dirait que le dépôt a eu lieu. La pastille est le seul retour possible.
    HUDWindow.show(
      batch.count == 1 ? "Tâche ajoutée" : "\(batch.count) tâches ajoutées",
      systemImage: "checkmark", tint: .green)
    dismiss()
    command?.run()
  }

  private func insert(_ pending: PendingTask) {
    // Mêmes jetons que partout ailleurs (`@demain`, `#Courses`) : le panneau n'invente pas sa
    // propre syntaxe, il rejoue `applyQuickEntry`.
    let entry = QuickEntry(parsing: pending.title, names: quickEntryNames)
    let text = entry.title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let list = entry.target.flatMap(resolve) ?? list(for: pending.targetID)
    else { return }
    // Ancre lue AVANT la création : `task.list` rattacherait sinon la neuve à `list.tasks` avant
    // qu'on ait lu son ancre. À la fin de ce qui reste à faire, avant les cochées — sans quoi une
    // tâche notée depuis la capsule atterrirait sous des tâches déjà terminées.
    let anchor = TodoList.appendAnchor(among: list.orderedTasks)?.sortIndex ?? -1
    for t in list.tasks where t.sortIndex > anchor { t.sortIndex += 1 }
    // Le jeton resté dans le titre l'emporte sur la pastille, pour l'heure comme pour la date ; une
    // heure sans jour se complète par aujourd'hui (cf. `QuickEntry.day`).
    let minutes = entry.minutes ?? pending.minutes
    let task = TaskItem(
      title: text, when: QuickEntry.day(entry.when ?? pending.when, minutes: minutes),
      whenMinutes: minutes, list: list)
    task.sortIndex = anchor + 1
    // Avant l'insertion : SwiftData propage la relation, les sous-tâches entrent avec la tâche.
    for line in pending.subtasks {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }  // lignes ouvertes puis laissées vides
      task.addSubtask().title = trimmed
    }
    modelContext.insertAndSave(task)
  }

  /// La sortie. Échap, le raccourci global et la fin de l'accusé de réception y passent tous ; le
  /// ressort de sortie et le démontage appartiennent à `QuickEntryWindow.close`.
  ///
  /// Le focus est rendu AVANT : un champ encore premier répondeur pendant que sa fenêtre s'escamote
  /// est le chemin exact des plantages ViewBridge d'août 2026 (→ `PIEGES.md` § Fenêtres).
  private func dismiss() {
    guard !closing else { return }  // sortie déjà en cours (Échap martelé)
    closing = true
    focus = nil
    onClose()
  }

  /// Sort du texte les jetons validés par un espace (cf. `QuickEntry.consuming`) et les range dans
  /// l'état du panneau, que le chip de destination et la pastille de date affichent déjà ; renvoie
  /// le texte à réafficher. Le jeton tapé sans espace final reste dans le titre : `insert` le
  /// rattrapera au moment d'écrire.
  /// Colle un jeton en fin de titre et le laisse consommer : l'espace final est ce qui déclenche
  /// `consuming` (cf. `QuickEntry`), donc la date et la destination se rangent dans l'état du
  /// panneau au lieu de rester écrites dans le champ.
  private func applyToken(_ token: String) {
    let token = token.trimmingCharacters(in: .whitespaces)
    guard !token.isEmpty else { return }
    let base = title.trimmingCharacters(in: .whitespaces)
    withAnimation(.bouncy(duration: 0.35)) {
      title = consumeTokens(base.isEmpty ? token + " " : base + " " + token + " ")
    }
  }

  private func consumeTokens(_ text: String) -> String {
    guard let (remaining, entry) = QuickEntry.consuming(text, names: quickEntryNames) else {
      return text
    }
    if let date = entry.when { when = date }
    if let minutes = entry.minutes { whenMinutes = minutes }
    if let list = entry.target.flatMap(resolve) { targetID = list.persistentModelID }
    // Une heure seule vise aujourd'hui, sinon la pastille n'aurait aucun jour à afficher. Après le
    // jeton de date, jamais avant : « @14h @demain » doit garder demain.
    when = QuickEntry.day(when, minutes: whenMinutes)
    return remaining
  }

  private var quickEntryNames: [String] { reachable.map(\.title) + projects.map(\.title) }

  private func resolve(_ name: String) -> TodoList? {
    reachable.first { $0.title == name } ?? projects.first { $0.title == name }?.orderedLists.first
  }

}
