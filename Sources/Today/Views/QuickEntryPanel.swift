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

  private var panel: NSPanel?
  private var channel: QuickEntryChannel?

  private init() {}

  func toggle(container: ModelContainer) {
    if panel != nil { requestClose() } else { show(container: container) }
  }

  /// Le raccourci clavier d'une action de saisie (`@today`, `#Courses`). Capsule OUVERTE, le jeton
  /// se pose sur la tâche en cours d'écriture — exactement ce que ferait l'abréviation tapée ;
  /// fermée, il ouvre la capsule avec le jeton déjà appliqué. Rouvrir dans tous les cas jetterait
  /// le titre à moitié tapé, alors que le geste ne demandait qu'à le dater.
  func apply(token: String, container: ModelContainer) {
    if let channel, panel != nil {
      channel.token = token
    } else {
      show(container: container, prefill: token)
    }
  }

  func show(container: ModelContainer, prefill: String = "") {
    close()  // panneau NEUF à chaque ouverture : pas de titre à moitié tapé qui survivrait
    let panel = makePanel(container: container, prefill: prefill)
    self.panel = panel
    // Le panneau est jetable, sa POSITION ne l'est pas : `setFrameUsingName` relit celle où on l'a
    // laissé (AppKit l'écrit dans les défauts à chaque déplacement, grâce à l'autosave posé dans
    // `makePanel`). Faux au tout premier lancement, et seulement là, on retombe sur le tiers haut.
    if !panel.setFrameUsingName(panel.frameAutosaveName) { position(panel) }
    panel.makeKeyAndOrderFront(nil)
  }

  /// Fermeture DEMANDÉE : la vue joue sa sortie et rappellera `close()` une fois le ressort fini.
  /// Tout ce qui ferme le panneau passe par ici — Échap, le raccourci global rejoué — sans quoi la
  /// fenêtre disparaîtrait au milieu de l'animation.
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

  func close() {
    panel?.orderOut(nil)
    panel = nil
    channel = nil
  }

  private func makePanel(container: ModelContainer, prefill: String) -> NSPanel {
    // Fenêtre volontairement plus grande que la capsule, et TRANSPARENTE : le verre a besoin de
    // composer sur ce qu'il y a derrière (une fenêtre opaque le réduirait à un aplat), et le
    // ressort d'ouverture comme le dépli des notes doivent avoir de la marge où déborder. On ne
    // redimensionne donc jamais le panneau — c'est le contenu qui bouge à l'intérieur.
    // ponytail: hauteur fixe dimensionnée pour la capsule + ses notes + une dizaine de tâches en
    // attente ; au-delà la fournée déborderait — à passer en `setFrame` animé si ça arrive.
    let panel = FloatingPanel(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 620),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false)
    // `.borderless` ne devient jamais clé tout seul (d'où `canBecomeKey` dans la sous-classe), mais
    // c'est le seul style sans chrome ni coins arrondis système imposés sous la capsule.
    let channel = QuickEntryChannel()
    self.channel = channel
    panel.onCancel = { [weak self] in self?.requestClose() }
    panel.onEscape = { [weak self] in self?.requestClose(discardDraft: true) }
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false  // l'ombre vient du verre, à la forme de la capsule
    panel.isMovableByWindowBackground = true
    // ponytail: l'autosave sauve le CADRE entier, taille comprise — si `contentRect` change un jour,
    // les défauts existants imposeront l'ancienne ; ajouter un `setContentSize` après restauration.
    panel.setFrameAutosaveName("QuickEntryPanel")
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = false
    panel.hidesOnDeactivate = false
    // La capsule ne fait pas partie de l'app « masquée ». Sans ça, ⌘H puis le raccourci global
    // rouvraient la capsule ET la fenêtre principale : ordonner devant une fenêtre masquable
    // oblige AppKit à démasquer TOUTE l'app. Exemptée, elle s'affiche seule, l'app reste cachée.
    panel.canHide = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

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
    return panel
  }

  /// Au tiers supérieur, pas au centre : c'est là que Spotlight se pose, et l'œil y va sans chercher.
  private func position(_ panel: NSPanel) {
    guard let visible = (panel.screen ?? NSScreen.main)?.visibleFrame else {
      panel.center()
      return
    }
    let size = panel.frame.size
    panel.setFrameOrigin(
      NSPoint(
        x: visible.midX - size.width / 2,
        y: visible.maxY - visible.height * 0.20 - size.height))
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
/// se déplie sur un second bloc pour les notes et les sous-tâches. Pas de barre de validation :
/// Entrée enregistre, Échap ferme, et les deux boutons ne faisaient qu'afficher des raccourcis que
/// tout le monde connaît.

/// Une tâche déposée mais pas encore écrite : les mêmes champs que la saisie, gelés. Le titre
/// garde ses jetons (`@demain`, `#liste`), analysés seulement à l'insertion — comme s'il venait
/// d'être tapé.
private struct PendingTask: Identifiable {
  let id = UUID()
  var title: String
  var notes: String
  var subtasks: [String]
  var when: Date?
  var targetID: PersistentIdentifier?
}

/// Le brouillon perdu à une fermeture accidentelle (Échap, clic ailleurs, raccourci global rejoué)
/// — gardé en mémoire pour la durée de l'app, la capsule étant un panneau NEUF à chaque ouverture
/// (cf. `QuickEntryWindow.show`). Une vraie validation (`save`) ne le touche jamais : `restoreDraft`
/// le vide dès qu'il est repris, avant qu'aucune sauvegarde n'ait pu le voir.
@MainActor
private final class QuickEntryDraftStore {
  static let shared = QuickEntryDraftStore()
  var draft: Draft?

  struct Draft {
    var title = ""
    var notes = ""
    var subtasks: [String] = []
    var when: Date?
    var targetID: PersistentIdentifier?
    var queued: [PendingTask] = []

    var isEmpty: Bool {
      title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

  /// Le ressort de la capsule, joué à l'endroit à l'ouverture et à l'envers à la fermeture — c'est
  /// la même courbe, donc le même rebond, dans les deux sens.
  private static let motion = Animation.spring(response: 0.34, dampingFraction: 0.62)
  /// Un poil au-delà du ressort : la fenêtre ne doit pas s'escamoter avant la fin du rebond.
  private static let motionDuration = Duration.milliseconds(380)

  @Environment(\.modelContext) private var modelContext
  @Query(sort: [SortDescriptor(\TodoList.sortIndex)]) private var lists: [TodoList]
  @Query(sort: [SortDescriptor(\Project.sortIndex)]) private var projects: [Project]

  @State private var title = ""
  @State private var notes = ""
  /// Sous-tâches en brouillon : de simples chaînes, pas des `Subtask`. Le modèle n'existera qu'à
  /// l'enregistrement — en créer avant obligerait à les rattacher à une `TaskItem` fantôme, puis à
  /// la nettoyer si le panneau se ferme sur Échap.
  @State private var subtasks: [String] = []
  /// Destination CHOISIE à la main, par son identifiant SwiftData et pas par l'objet : le `Picker`
  /// exige un tag `Hashable` stable, et un `PersistentIdentifier` en est un même si le modèle est
  /// rechargé sous le panneau. Un jeton `#liste` dans le titre l'emporte au moment d'enregistrer.
  @State private var targetID: PersistentIdentifier?
  @State private var when: Date?
  /// La fournée en attente : ⌘↩ y dépose la tâche en cours et rend le champ vide, ↩ enregistre tout
  /// et ferme. Vider trois idées d'affilée ne demande plus de rouvrir le panneau à chaque fois.
  @State private var queued: [PendingTask] = []
  @State private var expanded = false
  @State private var picking = false
  /// Hauteur naturelle de la liste des destinations, mesurée en continu. Nécessaire parce que le
  /// bloc s'ouvre en animant sa hauteur : il faut une valeur cible, `nil` ne s'anime pas.
  @State private var destinationHeight: CGFloat = 0
  @State private var hovered: PersistentIdentifier?
  @State private var appeared = false
  @AppStorage(TextShortcut.storageKey) private var shortcutData = Data()
  @FocusState private var focus: Field?
  @Namespace private var morph

  private var shortcuts: [TextShortcut] { TextShortcut.decode(shortcutData) }

  private enum Field: Hashable {
    case title, notes
    case subtask(Int)
  }

  /// Identités de morphing du verre. Distinctes de `Field` : un bloc n'est pas une cible de focus.
  private enum Block: Hashable { case bar, destination, details, queue }

  var body: some View {
    glassStack
      .frame(width: 650)
      // L'ancrage haut fait grandir la capsule depuis sa propre ligne : ancrée au centre, elle
      // remonterait pendant le ressort parce que le bloc s'allonge vers le bas quand les notes
      // s'ouvrent.
      .scaleEffect(appeared ? 1 : 0.88, anchor: .top)
      .opacity(appeared ? 1 : 0)
      // 56, pas 32 : le halo de `paneShadow` (rayon 40) déborde d'environ radius − y = 22pt
      // au-dessus de la capsule, et sa traîne, elle, va plus loin encore (un flou n'a pas de bord
      // net). 32pt le coupait au ras de la fenêtre — un aplat au lieu d'un fondu.
      .padding(.top, 56)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .onAppear {
        withAnimation(Self.motion) { appeared = true }
      }
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
  private var glassStack: some View {
    if #available(macOS 26, *) {
      GlassEffectContainer(spacing: 26) { stack }
        // Posée ICI, HORS du conteneur — pas dans `pane` : une ombre posée par bloc, À
        // L'INTÉRIEUR du conteneur, ne sortait pas du tout (mesuré : aucune amélioration malgré
        // des densités doublées). `GlassEffectContainer` compose son rendu Liquid Glass dans un
        // calque à la mesure des FORMES, pas de leur débord — l'ombre, elle, en a besoin. Posée
        // sur le conteneur lui-même, elle en épouse quand même le CONTOUR réel (`.shadow` suit
        // l'alpha du rendu, pas une boîte) : au repos, seule la capsule est visible, l'ombre en
        // épouse donc exactement son contour.
        .paneShadow()
    } else {
      stack
    }
  }

  /// `spacing: 0` et un écart porté par chaque bloc : celui des destinations est TOUJOURS monté
  /// (cf. `destinationPane`), il doit donc pouvoir replier son écart en même temps que sa hauteur,
  /// sinon un trou de 10pt resterait sous la barre quand il est fermé.
  private var stack: some View {
    VStack(spacing: 0) {
      pane(.bar, shape: Capsule()) { bar }
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
    }
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
      .background(alignment: .top) {
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
      .onPreferenceChange(DestinationHeightKey.self) { destinationHeight = $0 }
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

  private var bar: some View {
    HStack(spacing: 12) {
      destinationChip
      // La date à GAUCHE, en pastille, exactement comme la rangée « Nouvelle tâche » d'une liste
      // (cf. `TokenPill`) : c'est là que se lit ce qui est déjà décidé. Le menu calendrier de
      // droite n'en garde que l'icône, sans quoi la date s'afficherait deux fois.
      if let when {
        TokenPill(text: when.formatted(.dateTime.day().month(.abbreviated)))
          .onTapGesture { self.when = nil }
          .help("Retirer la date")
      }
      TextField("Nouvelle tâche", text: $title, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.app(20))
        .focused($focus, equals: .title)
        // Seul chemin d'enregistrement au clavier depuis que la barre de validation a disparu :
        // plus de bouton par défaut avec qui se dédoubler.
        .onSubmit(save)
        // Les jetons quittent le texte dès qu'un espace les valide, comme dans les listes. Le
        // panneau ne les analysait qu'à l'enregistrement : rien ne confirmait « @demain » sous les
        // doigts — et un raccourci texte n'aurait rien eu à montrer non plus.
        .onChange(of: title) { _, new in
          let cleaned = consumeTokens(new)
          if cleaned != new { title = cleaned }
        }
        .onKeyPress(phases: .down, action: enqueueShortcut)
        // Tab sert deux gestes qui ne peuvent pas se croiser : le dernier mot est un raccourci
        // texte (« ajd ») et il se change en jeton, sinon Tab ouvre les notes comme avant.
        .onKeyPress(.tab) {
          guard let resolved = QuickEntry.resolving(title, shortcuts: shortcuts) else {
            expand(focusing: .notes)
            return .handled
          }
          // Une commande n'écrit rien : elle emmène ailleurs, et la capsule s'efface derrière elle.
          // `save` la reconnaît par le même chemin qu'Entrée, emporte la fournée et referme.
          if resolved.command == nil { title = resolved.text } else { save() }
          return .handled
        }
      if canSave {
        // Sans cette mention, l'empilement n'existe que pour qui le connaît déjà.
        Text("⌘↩")
          .font(.app(11, weight: .medium))
          .foregroundStyle(.tertiary)
          .transition(.opacity)
      }
      dateMenu
      notesToggle
      subtaskButton
      sendButton
    }
    // Les icônes de droite n'ont pas de police à elles : la donner ICI les met à l'échelle du champ
    // sans toucher aux vues qui fixent déjà la leur (le champ, la mention ⌘↩, le chip).
    .font(.app(15))
    .padding(.horizontal, 17)
    .padding(.vertical, 15)
    // La pastille de date entre et sort de la rangée : sans ça, la barre se réagence d'un coup
    // sous le curseur au moment où le jeton est reconnu.
    .animation(.bouncy(duration: 0.35), value: when)
  }

  private var detailsBox: some View {
    VStack(alignment: .leading, spacing: 9) {
      TextField("Notes", text: $notes, axis: .vertical)
        .textFieldStyle(.plain)
        .font(.app(14))
        .lineLimit(2...6)
        .focused($focus, equals: .notes)
        // Un `TextField` vertical rend Entrée au field editor, qui en fait un saut de ligne ; le
        // panneau, lui, doit enregistrer. `onSubmit` n'est jamais appelé dans ce mode, d'où
        // l'interception directe — ⇧/⌥ + Entrée rend la nouvelle ligne à qui la veut.
        // La variante `phases:` est la seule à livrer le `KeyPress`, donc les modificateurs.
        .onKeyPress(phases: .down) { press in
          guard press.key == .return else { return .ignored }
          if press.modifiers.contains(.command) {
            enqueue()
            return .handled
          }
          guard press.modifiers.isDisjoint(with: [.shift, .option]) else { return .ignored }
          save()
          return .handled
        }
        // Tab a ouvert le bloc, le même Tab le referme : sans ça l'icône était la SEULE sortie, il
        // fallait lâcher le clavier pour annuler un dépli fait au clavier. Des notes ou des
        // sous-tâches déjà écrites le retiennent — replier effacerait du travail de la vue.
        .onKeyPress(.tab) {
          guard notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, subtasks.isEmpty
          else { return .ignored }
          collapseDetails()
          return .handled
        }
      if !subtasks.isEmpty {
        Divider()
        ForEach(subtasks.indices, id: \.self, content: subtaskRow)
      }
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
        Text(when.formatted(.dateTime.day().month(.abbreviated)))
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
      // Un seul bloc ouvert à la fois sous la barre : les destinations et les notes empilées
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
      Text(destination?.title ?? SmartList.all.label)
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

  @ViewBuilder private var destinationIcon: some View {
    if let destination, !destination.isInbox {
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
    ScrollView { destinationList }
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
        Button("Aucune date") { when = nil }
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

  /// Double du Tab : Tab est le geste, mais rien ne l'annonce — l'icône rend le dépli visible.
  private var notesToggle: some View {
    Button {
      if expanded {
        collapseDetails()
      } else {
        expand(focusing: .notes)
      }
    } label: {
      Image(systemName: "text.alignleft")
        .foregroundStyle(expanded ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
    }
    .buttonStyle(.plain)
    .help("Ajouter des notes (Tab)")
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

  /// Ouvre le bloc notes/sous-tâches — et referme les destinations : réciproque du chip, un seul
  /// bloc à la fois.
  private func expand(focusing field: Field) {
    withAnimation(.bouncy(duration: 0.45)) {
      expanded = true
      picking = false
    }
    focus = field
  }

  private func collapseDetails() {
    withAnimation(.bouncy(duration: 0.4)) { expanded = false }
    focus = .title
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
    notes = saved.notes
    subtasks = saved.subtasks
    when = saved.when
    if let savedTarget = saved.targetID { targetID = savedTarget }
    queued = saved.queued
    if !saved.notes.isEmpty || !saved.subtasks.isEmpty { expanded = true }
  }

  /// Range l'état courant avant une fermeture qui n'est PAS une validation. Vide, il efface un
  /// brouillon devenu obsolète plutôt que d'en garder un fantôme.
  private func persistDraft() {
    let saved = QuickEntryDraftStore.Draft(
      title: title, notes: notes, subtasks: subtasks, when: when, targetID: targetID,
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
      title: text, notes: notes, subtasks: subtasks, when: when, targetID: targetID)
  }

  /// ⌘↩ depuis n'importe quel champ : dépose et rend le champ vide. Partagé plutôt que réécrit sur
  /// chacun — trois copies auraient divergé à la première retouche.
  private func enqueueShortcut(_ press: KeyPress) -> KeyPress.Result {
    guard press.key == .return, press.modifiers.contains(.command) else { return .ignored }
    enqueue()
    return .handled
  }

  private func enqueue() {
    guard let draft else { return }
    withAnimation(.bouncy(duration: 0.4)) {
      queued.append(draft)
      title = ""
      notes = ""
      subtasks = []
      when = nil
      expanded = false  // les notes et sous-tâches sont parties avec la tâche déposée
    }
    // `targetID` survit exprès : trois tâches lancées d'affilée vont le plus souvent au même
    // endroit, et le chip reste modifiable entre deux dépôts.
    focus = .title
  }

  private func save() {
    // Entrée maintenue pendant la sortie : une tâche, pas deux. `dismiss()` a déjà remis `appeared`
    // à false quand il repasse ici.
    guard appeared else { return }
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
    let task = TaskItem(
      title: text, notes: encodedNotes(pending.notes), when: entry.when ?? pending.when, list: list)
    task.sortIndex = anchor + 1
    // Avant l'insertion : SwiftData propage la relation, les sous-tâches entrent avec la tâche.
    for line in pending.subtasks {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }  // lignes ouvertes puis laissées vides
      task.addSubtask().title = trimmed
    }
    modelContext.insertAndSave(task)
  }

  /// La sortie : le ressort d'ouverture rejoué à l'envers, puis seulement le démontage de la
  /// fenêtre. Échap, le raccourci global et la fin de l'accusé de réception y passent tous — un
  /// panneau qui s'évanouit d'un coup après être entré en rebondissant se lit comme un plantage.
  private func dismiss() {
    guard appeared else { return }  // sortie déjà en cours (Échap martelé)
    focus = nil
    withAnimation(Self.motion) { appeared = false }
    Task { @MainActor in
      try? await Task.sleep(for: Self.motionDuration)
      onClose()
    }
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
    if let list = entry.target.flatMap(resolve) { targetID = list.persistentModelID }
    return remaining
  }

  private var quickEntryNames: [String] { reachable.map(\.title) + projects.map(\.title) }

  private func resolve(_ name: String) -> TodoList? {
    reachable.first { $0.title == name } ?? projects.first { $0.title == name }?.orderedLists.first
  }

  /// Mêmes police et couleur que le cadre de notes des pages (cf. `NotesBox`) : sans elles, le RTF
  /// repartirait sur les défauts d'AppKit (Helvetica 12, noir) et la note changerait d'allure en
  /// s'ouvrant dans la tâche.
  private func encodedNotes(_ source: String) -> Data {
    let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return Data() }
    return NotesCodec.encode(
      NSAttributedString(
        string: text,
        attributes: [
          .font: NSFont.app(),
          .foregroundColor: NSColor.labelColor,
        ]))
  }
}
