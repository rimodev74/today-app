import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Marge latérale du contenu du panneau de détail. Interne (pas `private`) : `ArchivePageView`
/// vit dans son propre fichier et doit se caler sur la même marge que les pages de liste.
let gutter: CGFloat = 75

/// Retrait interne d'une ligne de tâche : la respiration du fond de sélection, entre le bord de
/// section et la case à cocher. C'est lui qui définit la colonne des cases — donc celle sur
/// laquelle l'en-tête de page doit se caler (cf. `pageHeader`), sinon le titre de la page flotte
/// 10 pt à gauche de toutes les tâches qu'il coiffe.
let rowInset: CGFloat = 10

/// Icône d'un bandeau de page (« Tâches », « Aujourd'hui », « Archives »). Dessinée à la taille du
/// titre, mais LARGEUR de layout figée à celle d'une `TaskCheckbox` et alignée à gauche : le glyphe
/// débordera de quelques points dans l'espace qui suit (SwiftUI ne rogne pas), ce qui est exactement
/// l'effet voulu — la colonne reste juste des deux côtés, bord gauche sur celui des cases à cocher et
/// titre de page sur celui des titres de tâche, quel que soit le symbole (une étoile est plus large
/// qu'une coche). Sans ce cadrage, chaque page décale son titre d'une valeur différente.
struct PageHeaderIcon: View {
  let systemImage: String
  let tint: Color

  var body: some View {
    Image(systemName: systemImage)
      .font(.title2)
      .foregroundStyle(tint)
      .frame(width: 16, alignment: .leading)
  }
}

/// Instant de la première ouverture de l'onglet courant, posé par `TaskListView`.
///
/// Un HORODATAGE et non un compteur : d'un onglet à l'autre, les lignes n'ont pas la même
/// identité, elles sont donc CRÉÉES par le changement de page et ne reçoivent aucun `onChange`.
/// Il leur faut une valeur qu'elles peuvent consulter à leur naissance pour savoir si elles
/// arrivent avec leur page ou bien plus tard. Passe par l'environnement plutôt que par les
/// initialiseurs : une page qui ne veut pas de fondu n'a rien à déclarer.
struct PageOpenedAtKey: EnvironmentKey {
  static let defaultValue = Date.distantPast
}

extension EnvironmentValues {
  var pageOpenedAt: Date {
    get { self[PageOpenedAtKey.self] }
    set { self[PageOpenedAtKey.self] = newValue }
  }
}

/// Fondu d'ouverture, à poser sur le CONTENU d'une page — jamais sur son en-tête.
///
/// L'anneau de progression, le titre de l'onglet et l'encadré de notes en sont volontairement
/// exclus : ce sont le cadre fixe de la vue. Les faire pâlir donnait l'impression que la page
/// entière tanguait, et surtout ça noyait l'animation propre de l'anneau — qui, lui, doit
/// VRAIMENT parcourir sa valeur (cf. `ProgressRing`) plutôt que se contenter d'un fondu.
///
/// Opacité SEULE, aucun effet géométrique : un `offset` ou un `scaleEffect` posé ici entrerait
/// dans les `rowFrames` que `ListPageView` mesure dans `dragSpace`, et le calcul du trou
/// d'insertion travaillerait sur des positions de repos fausses — même famille de piège que la
/// boucle offset→cadre→offset documentée plus bas.
struct PageReveal: ViewModifier {
  @Environment(\.pageOpenedAt) private var openedAt
  @State private var opacity: Double = 1

  /// Passé ce délai, ce qui apparaît le fait NET. C'est ce qui distingue « l'onglet vient de
  /// s'ouvrir » de « le LazyVStack vient de créer cette rangée parce qu'on a fait défiler » :
  /// sans cette fenêtre, chaque ligne atteinte au défilement serait apparue en fondu.
  private static let window = 0.35

  func body(content: Content) -> some View {
    content
      .opacity(opacity)
      // Les deux déclencheurs sont nécessaires et ne se recouvrent pas : `onAppear` couvre ce que
      // le changement d'onglet CRÉE (la quasi-totalité), `onChange` ce que SwiftUI réutilise et
      // qui ne réapparaît donc jamais.
      .onAppear(perform: reveal)
      .onChange(of: openedAt) { reveal() }
  }

  private func reveal() {
    guard Date().timeIntervalSince(openedAt) < Self.window else {
      opacity = 1
      return
    }
    // Le repli part sans animation, le retour à net est animé : un fondu montant, jamais un
    // clignotement.
    opacity = 0.55
    withAnimation(.easeOut(duration: 0.18)) { opacity = 1 }
  }
}

extension View {
  func pageReveal() -> some View { modifier(PageReveal()) }
}

/// Le lavande de sélection de Things : #D1DFFC. Teinte de l'accent système, translucide, résolue par
/// apparence : périwinkle clair sur fond blanc, bleu voilé sur fond sombre — et suit la couleur
/// d'accent choisie par l'utilisateur. Plus opaque en sombre : sur le fond navy, une même alpha
/// rendrait la sélection quasi invisible. Partagé par la sélection d'une tâche, d'une en-tête, et
/// les calques en cascade du drag d'en-tête.
private let thingsSelectionFill = Color(
  nsColor: NSColor(name: nil) { appearance in
    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    return NSColor.controlAccentColor.withAlphaComponent(dark ? 0.28 : 0.18)
  })

/// Transitions des états d'une tâche (normal ↔ select ↔ edit). Déclenchées en EXPLICITE
/// (`withAnimation` côté parent), jamais en `.animation(value:)` par ligne : ainsi une ligne
/// au repos ne porte aucun modificateur d'animation à traquer, et le scroll reste fluide.
/// `taskFlow` = la Material standard de l'index.html de référence.
// Internes et non `private` : « Aujourd'hui » pilote les mêmes transitions sur les mêmes
// `TaskRow` — deux courbes distinctes se verraient au passage d'une page à l'autre.
let taskFlow = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.2)
let taskSelectFade = Animation.easeOut(duration: 0.05)
/// Apparition (création) ET disparition (suppression) d'une ligne : ressort peu amorti pour un
/// léger rebond, dans les deux sens. Le réordonnancement, lui, passe par des offsets et pas des
/// insertions/suppressions — la transition des rangées n'y répond donc jamais.
/// Interne pour la même raison que `gutter` : `ArchivePageView` anime ses sorties de ligne avec.
let taskInsert = Animation.spring(response: 0.32, dampingFraction: 0.62)

/// Sélection au mouseDOWN + édition au clic sur une ligne DÉJÀ sélectionnée, en UN SEUL geste —
/// pour les pages sans réordonnancement (« Tâches », « Aujourd'hui »).
///
/// SURTOUT PAS deux gestes séparés (`.onTapGesture(count: 2)` pour l'édition + `.onTapGesture`
/// pour la sélection) : dès qu'une vue porte un tap double, AppKit RETIENT le tap simple le temps
/// de la fenêtre de double-clic avant de le délivrer. La surbrillance n'arrivait donc qu'une
/// demi-seconde après le clic — c'était toute la lenteur d'« Aujourd'hui », que les pages de liste
/// n'ont jamais eue parce qu'elles fusionnent déjà tout dans leur geste de drag (même structure
/// ici, moins le réordonnancement — cf. `ListPageView.dragGesture`).
struct RowPressGesture: ViewModifier {
  let isSelected: Bool
  let isEditing: Bool
  var onSelect: () -> Void
  var onEdit: () -> Void

  /// Appui en cours (le premier `onChanged` est le mouseDown) et état de sélection d'AVANT cet
  /// appui : c'est lui qui décide si le relâchement ouvre l'édition (renommage façon Finder).
  @State private var pressing = false
  @State private var wasSelected = false

  func body(content: Content) -> some View {
    content.gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { _ in
          guard !pressing else { return }
          pressing = true
          wasSelected = isSelected
          if !isEditing && !isSelected { onSelect() }
        }
        .onEnded { value in
          pressing = false
          let moved = abs(value.translation.width) > 4 || abs(value.translation.height) > 4
          guard !moved, !isEditing, wasSelected else { return }
          onEdit()
        },
      // En édition, les clics et les sélections de texte appartiennent au champ.
      including: isEditing ? .subviews : .all
    )
  }
}

extension View {
  func rowPressGesture(
    isSelected: Bool, isEditing: Bool, onSelect: @escaping () -> Void,
    onEdit: @escaping () -> Void
  ) -> some View {
    modifier(
      RowPressGesture(
        isSelected: isSelected, isEditing: isEditing, onSelect: onSelect, onEdit: onEdit))
  }
}

/// Aiguillage du panneau de détail. Seule la page d'une to-do list est construite pour
/// l'instant ; les vues intelligentes sont à rebrancher. La recherche vit dans la sidebar
/// (cf. `SearchPopover`) et pilote la sélection, elle n'a plus de branche ici.
struct TaskListView: View {
  @Binding var selection: SidebarSelection?
  @Binding var searchPresented: Bool
  @Binding var pendingTitleFocus: PersistentIdentifier?

  /// Onglets déjà ouverts dans cette session — au sens de la sidebar : liste, projet, Pomodoro,
  /// Tâches, Aujourd'hui, À venir, Archives. Tout ce qui passe par `selection`, donc, et rien
  /// d'autre : les Réglages sont une fenêtre à part, ils ne traversent jamais ce code.
  ///
  /// Le fondu ne joue qu'à la PREMIÈRE ouverture de chacun. Y revenir est une navigation courante,
  /// pas une découverte — rejouer le fondu à chaque aller-retour finissait par se lire comme une
  /// lourdeur.
  @State private var seen: Set<SidebarSelection> = []
  /// `.distantPast` au départ : la page affichée au lancement n'est l'ouverture de personne, elle
  /// s'affiche d'un bloc. « Tâches » reste alors non-vu — le premier CLIC dessus fera son fondu.
  @State private var openedAt = Date.distantPast

  var body: some View {
    page
      .environment(\.pageOpenedAt, openedAt)
      // Ni `.transition` ni `.id(...)` : les deux exigeraient que SwiftUI détruise puis
      // reconstruise la page à chaque liste (NSTextView des notes, tous les TextField, le
      // ScrollView) — précisément ce qui avait été retiré ici, cf. le cas `.list` ci-dessous.
      //
      // Et ceci ne retarde RIEN : quand on arrive ici la sélection est déjà appliquée et la page
      // déjà construite (~1 ms, cf. le geste de `SidebarView`). On ne fait qu'horodater son
      // arrivée à l'écran ; le fondu découvre ce qui est déjà posé.
      .onChange(of: selection) { _, new in
        guard let new, seen.insert(new).inserted else { return }
        openedAt = Date()
      }
  }

  @ViewBuilder
  private var page: some View {
    switch selection {
    case .smartList(.all):
      // N'était que la page de l'Inbox : indiscernable d'une liste, et les tâches des projets n'y
      // apparaissaient jamais. C'est désormais l'inventaire complet (cf. `AllTasksPageView`).
      AllTasksPageView(searchPresented: $searchPresented)
    case .list(let list):
      // PAS de `.id(list.persistentModelID)` ici : il forçait SwiftUI à détruire et reconstruire
      // toute la page à chaque changement de liste (TextEditor/NSTextView, tous les TextField, le
      // ScrollView) → l'à-coup ressenti au clic. On réutilise la vue (switch instantané) ; l'état
      // transitoire par liste (brouillons, sélection, édition) est remis à zéro dans ListPageView
      // via `.onChange(of: list)`.
      ListPageView(
        list: list, selection: $selection, searchPresented: $searchPresented,
        pendingTitleFocus: $pendingTitleFocus)
    case .project(let project):
      ProjectPageView(project: project, selection: $selection, searchPresented: $searchPresented)
    case .pomodoro:
      PomodoroView(searchPresented: $searchPresented)
    case .smartList(.archive):
      ArchivePageView(searchPresented: $searchPresented)
    case .smartList(.today):
      TodayPageView(searchPresented: $searchPresented)
    case .smartList(.upcoming):
      UpcomingPageView(searchPresented: $searchPresented)
    case .smartList(let smart):
      comingSoon(smart.label, searchPresented: $searchPresented)
    case nil:
      comingSoon("Sélectionne une liste", searchPresented: $searchPresented)
    }
  }
}

/// Page d'une to-do list — refonte en cours.
///
/// Volontairement bâtie sur `ScrollView` + `LazyVStack`, et PAS sur `List`. `List` sur macOS
/// est adossée à `NSTableView` (AppKit) : elle donne gratuitement reorder/sélection/clavier,
/// mais elle verrouille tout le reste — hauteur de ligne animée, `matchedGeometryEffect`,
/// fonds et hover custom, ressorts. Pour une surface dont l'animation EST le produit (Things),
/// ce plafond ne convient pas. Ici on possède chaque pixel ; reorder/sélection/clavier seront
/// réintroduits à la main, au fur et à mesure des specs.
///
/// ponytail: coquille minimale. N'affiche que l'en-tête et les tâches en lecture (+ la case à
/// cocher). Édition, création, réordonnancement, sélection : à reconstruire sur specs.
private struct ListPageView: View {
  @Bindable var list: TodoList
  @Environment(RemindersService.self) private var remindersService
  @Binding var selection: SidebarSelection?
  @Binding var searchPresented: Bool
  @Binding var pendingTitleFocus: PersistentIdentifier?

  @Environment(\.modelContext) private var modelContext
  // Toutes les listes, pour l'action « Déplacer vers… » du menu d'une tâche.
  @Query private var allLists: [TodoList]
  // Idem pour la saisie rapide `#projet`, qui vise la première liste du projet.
  @Query private var allProjects: [Project]
  // Un brouillon de saisie par bloc (clé = `TaskBlock.id`) : chaque champ « Nouvelle tâche » garde
  // son texte indépendamment des autres.
  @State private var drafts: [String: String] = [:]
  /// Jetons de saisie rapide déjà sortis du texte et affichés en pastilles, par bloc.
  @State private var draftTokens: [String: DraftTokens] = [:]
  @State private var selectedID: PersistentIdentifier?
  @State private var editingID: PersistentIdentifier?
  // En-tête en attente de confirmation de suppression (non nil ⇒ alerte affichée). Elle ne passe
  // par l'alerte QUE si elle porte des tâches ; vide, la suppression est immédiate.
  @State private var headerDeletionCandidate: TaskItem?
  // Réordonnancement « à la main » (cf. move / dragGesture, plus bas) : `draggingID` est la ligne
  // empoignée, `dragOffsetY` son décalage vertical sous le curseur, `rowFrames` la position de
  // repos de chaque ligne (mesurée) pour savoir où ouvrir le trou.
  @State private var draggingID: PersistentIdentifier?
  // Décalage 2D sous le curseur : la ligne se soulève et suit la souris librement (X ET Y), façon
  // vrai drag. Seul `.height` sert au calcul d'insertion (l'ordre reste vertical).
  @State private var dragOffset: CGSize = .zero
  // Point empoigné (dans l'espace de la liste) : sert d'ancre au léger agrandissement du soulevé,
  // pour que ce point-là reste EXACTEMENT sous le curseur. Ancré au centre (défaut), l'échelle
  // éloigne du curseur les bords d'une ligne large → la ligne « dérive » sous la souris.
  @State private var dragStart: CGPoint = .zero
  // Lignes emportées par le drag en cours : la seule tâche empoignée, ou — si on empoigne une
  // en-tête — TOUT son bloc (en-tête + ses tâches). Figé à l'empoignade (cf. `dragGroup`) : `blocks`
  // ne bouge pas d'un drag, et le recalculer par ligne/frame serait O(n²).
  @State private var draggedGroup: [TaskItem] = []
  // Sélection au mouseDOWN, fusionnée dans le geste de réordonnancement (cf. `dragGesture`) : deux
  // gestes séparés se volaient le drag. `pressID` = ligne dont l'appui est en cours (le premier
  // onChanged est le mouseDown) ; `pressWasSelected` retient son état d'avant l'appui pour n'ouvrir
  // l'édition au relâchement que si elle était DÉJÀ sélectionnée (renommage façon Finder).
  @State private var pressID: PersistentIdentifier?
  @State private var pressWasSelected = false
  // Position de repos mesurée de CHAQUE ligne physique, tâche/en-tête RÉELLE (`.task`) ou champ
  // « Nouvelle tâche » VIRTUEL (`.field`, cf. `RowKey`) — un champ n'est jamais un cas à part, juste
  // une ligne non déplaçable de plus dans la même séquence et le même calcul de décalage
  // (`dragTargets`). `draggedFieldHeight` = hauteur du champ du bloc tiré, figée à l'empoignade
  // (entre dans le repli d'une en-tête tirée).
  @State private var rowFrames: [RowKey: CGRect] = [:]
  @State private var draggedFieldHeight: CGFloat = 0
  @State private var headerHovering = false
  @State private var pickingListDate = false
  @FocusState private var focusedDraft: String?
  @FocusState private var notesFocused: Bool
  // Archivage des tâches cochées. AUCUNE donnée de plus : « archivée » se DÉDUIT de `completedAt`
  // (déjà stocké) et du réglage `CompletedTaskRetention` — rien n'est supprimé ni déplacé, la tâche
  // sort seulement du flux de la liste et rejoint la section « Archivées » dépliable en bas de page.
  // Une règle par date plutôt qu'un ensemble d'ID de tâches cochées : `persistentModelID` mute à
  // l'autosave (cf. la duplication de sous-tâches), un ensemble se serait vidé tout seul.
  @AppStorage(CompletedTaskRetention.storageKey) private var retentionRaw = CompletedTaskRetention
    .untilViewChange.rawValue
  // Ouverture de la page (mode « jusqu'à ce que je quitte la liste ») : tout ce qui a été coché
  // AVANT est déjà archivé, ce qu'on coche maintenant reste visible jusqu'au changement de liste.
  @State private var pageOpenedAt = Date()
  // Mode « après 1,5 s » : `isArchived` dépend de l'heure qu'il est, or SwiftUI ne redessine que sur
  // changement d'état — cocher programme donc un bump de `tick` 1,5 s plus tard, qui fait sortir la
  // ligne. Sans lui, la tâche resterait affichée jusqu'au prochain redessin fortuit.
  @State private var tick = Date()
  @State private var archivesExpanded = false

  var body: some View {
    // Position de repos cible de chaque ligne pendant un drag (trou ouvert sous le curseur) — tâche,
    // en-tête OU champ « Nouvelle tâche » (cf. `RowKey`) : les trois partagent le même calcul, donc
    // la même table. Vide hors drag : chaque ligne reste alors à son offset 0.
    let targets = dragTargets()
    let placeholder = dragPlaceholderRect()
    return GeometryReader { geo in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          pageHeader
            // Calé sur le bord de section (`gutter`), comme les bandeaux d'en-tête et les fonds de
            // sélection des lignes — et comme les en-têtes d'« Aujourd'hui » et « Archives ». Le
            // `rowInset` des lignes est un retrait INTÉRIEUR à leur fond : le reprendre ici
            // décalait tout l'en-tête de 10 pt à droite de chaque bord visible en dessous.
            .padding(.bottom, 14)

          // Une en-tête ouvre un BLOC : elle et les tâches qui la suivent, jusqu'à la prochaine
          // en-tête. Chaque bloc porte son propre champ « Nouvelle tâche » en bas — créer y insère
          // la tâche à la fin de CE bloc (avant l'en-tête suivante), pas tout en bas de la liste.
          ForEach(blocks) { block in
            if let header = block.header {
              draggableRow(for: header, targets: targets)
            }
            ForEach(block.tasks) { task in
              draggableRow(for: task, targets: targets)
            }
            // Pendant N'IMPORTE QUEL drag (en-tête OU tâche), TOUS les champs « Nouvelle tâche »
            // disparaissent : ils encombreraient le déplacement. Restent MONTÉS (juste rendus
            // invisibles par opacité, pas retirés de l'arbre) : `rowFrames`/`dragTargets` sont GELÉS
            // à l'empoignade en supposant que chaque ligne (champs compris) garde sa place dans la
            // mise en page — les retirer aurait fait s'effondrer cet espace pendant TOUT le drag et
            // cassé le calcul du trou d'insertion (le placeholder).
            //
            // Le décalage vient de `fieldOffset` — EXACTEMENT `rowOffset`, pour un champ : au drop,
            // la position CIBLE (anticipée dès le live-drag, cf. `dragTargets`) devient la position
            // RÉELLE (le tri l'a rendue vraie) et le décalage retombe à 0 sans aucun saut, puisque
            // affichée et réelle coïncidaient déjà. Un champ n'est plus un cas à part : c'est cette
            // continuité, pas une astuce d'animation, qui rend sa révélation instantanée et fiable.
            let blockLifted = block.header != nil && block.header?.persistentModelID == draggingID
            newTaskRow(for: block)
              .background {
                GeometryReader { g in
                  Color.clear.preference(
                    key: RowFrameKey.self,
                    value: [.field(block.id): g.frame(in: .named(Self.dragSpace))])
                }
              }
              .opacity(draggingID != nil ? 0 : 1)
              .offset(
                x: blockLifted ? dragOffset.width : 0,
                y: blockLifted ? dragOffset.height : fieldOffset(for: block, targets: targets)
              )
              .zIndex(blockLifted ? 1 : 0)
              .animation(
                blockLifted ? nil : .snappy(duration: 0.22),
                value: fieldOffset(for: block, targets: targets)
              )
              .animation(.easeInOut(duration: 0.15), value: draggingID != nil)
              .pageReveal()
          }

          // Repliée pendant un drag : elle n'entre pas dans `rowFrames`/`dragTargets` (gelés à
          // l'empoignade), une ouverture en cours de drag décalerait le calcul du trou.
          if draggingID == nil {
            dormantSummary.pageReveal()
            archiveSection.pageReveal()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, gutter)
        .padding(.top, 30)
        // Espace de référence partagé : mesure des positions de repos ET translation du drag.
        .coordinateSpace(name: Self.dragSpace)
        // Placeholder du trou d'insertion, DERRIÈRE les lignes (il n'est donc visible que dans
        // le vide ouvert par l'écartement). Sans lui : aucun repère de dépôt, et l'écartement
        // silencieux des voisines se lit comme une saccade.
        .background(alignment: .topLeading) {
          if let placeholder {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color.primary.opacity(0.06))
              .frame(width: placeholder.width, height: placeholder.height)
              .offset(x: placeholder.minX, y: placeholder.minY)
              .allowsHitTesting(false)
          }
        }
        // Même repère que le placeholder ci-dessus (posé au même point d'ancrage) : ses points
        // sont donc directement comparables à `rowFrames`, mesurées dans le même `Self.dragSpace`.
        .background(RightClickObserver(onRightClick: selectAtRightClick))
        .background(LeftClickOutsideObserver(onClick: dismissSelectionIfOutside))
        // GEL pendant le drag. `frame(in: .named(...))` inclut le `.offset` appliqué aux
        // lignes : réinjecter ces frames décalées dans le calcul (qui suppose les positions de
        // REPOS) bouclait — offset → frame → offset… → « update multiple times per frame » et
        // saccade. Le layout de repos ne bouge pas d'un drag (on ne fait que décaler) : les
        // frames capturées avant l'empoignade restent valides jusqu'au relâchement.
        .onPreferenceChange(RowFrameKey.self) { frames in
          guard draggingID == nil else { return }
          rowFrames = frames
        }
        .frame(minHeight: geo.size.height, alignment: .top)
      }
      // Barre d'outils en bas de la fenêtre : nouvelle tâche, en-tête, recherche.
      .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    }
    // Échap ferme l'édition depuis N'IMPORTE OÙ dans la fenêtre. Un bouton .cancelAction agit
    // au niveau fenêtre, sans dépendre du focus — contrairement à `.onExitCommand` sur la ligne,
    // qui exige qu'un champ interne soit premier répondeur.
    .background {
      if editingID != nil {
        Button("", action: dismissEditing)
          .keyboardShortcut(.cancelAction)
          .hidden()
      }
    }
    // ⌘N / ⌘⇧N : PAS de bouton caché + `.keyboardShortcut` (essayé d'abord) — deux raccourcis sur
    // la même lettre avec des modificateurs différents se marchent dessus sous SwiftUI, ⌘⇧N étant
    // avalé par le gestionnaire ⌘N. Même moniteur NSEvent que `DeleteKeyMonitor` ci-dessous, qui
    // contourne déjà cette même classe de problème de routage clavier.
    .background {
      KeyCommandMonitor(keyCode: 45, modifiers: [.command], action: createTaskInEditMode)
      KeyCommandMonitor(keyCode: 45, modifiers: [.command, .shift], action: insertHeader)
    }
    // Retour arrière (⌫) sur la sélection courante (tâche OU en-tête, hors édition) : la supprime.
    // PAS le bouton caché + `.keyboardShortcut` utilisé pour Échap ci-dessus (et pas non plus
    // `.onKeyPress`, essayé puis abandonné) : ces deux mécanismes exigent qu'un VRAI premier
    // répondeur existe déjà dans la fenêtre. Un champ d'édition en a un ; une ligne juste
    // SÉLECTIONNÉE (tap, aucun champ focalisé) n'en établit aucun — la frappe servait alors à
    // ÉTABLIR le key-view-loop (focus jeté sur le 1er champ focalisable, le « Nouvelle tâche » du
    // bloc) au lieu d'atteindre le gestionnaire. `DeleteKeyMonitor` voit la touche AVANT sa
    // distribution normale, indépendamment de tout premier répondeur — et se retire lui-même dès
    // qu'un VRAI champ de texte a le focus (cf. son check `NSText`), pour ne jamais lui voler ⌫.
    .background {
      DeleteKeyMonitor(
        isActive: { editingID == nil && selectedID != nil },
        action: requestDeleteSelected
      )
    }
    // Confirmation seulement si l'en-tête porte des tâches ; sinon `requestDeleteSelectedHeader`
    // supprime directement. Les tâches, elles, ne sont PAS supprimées — l'en-tête retirée, elles
    // rejoignent la section précédente.
    .alert(
      "Supprimer l’en-tête ?",
      isPresented: Binding(
        get: { headerDeletionCandidate != nil },
        set: { if !$0 { headerDeletionCandidate = nil } }
      ),
      presenting: headerDeletionCandidate
    ) { header in
      Button("Supprimer", role: .destructive) {
        delete(header)
        headerDeletionCandidate = nil
      }
      Button("Annuler", role: .cancel) { headerDeletionCandidate = nil }
    } message: { header in
      let name = header.title.isEmpty ? "Cette en-tête" : "« \(header.title) »"
      Text("\(name) contient des tâches. Elles ne seront pas supprimées, seule l’en-tête le sera.")
    }
    // La vue n'est plus recréée à chaque liste (cf. absence de `.id` côté TaskListView) : on
    // remet donc à la main l'état transitoire propre à une liste, sinon la sélection, l'édition
    // ou un brouillon (le bloc « top » partage sa clé entre listes) déborderaient sur la suivante.
    .onChange(of: list.persistentModelID) {
      drafts = [:]
      selectedID = nil
      editingID = nil
      notesFocused = false
      focusedDraft = nil
      // « Quitter la liste » : ce changement EST la sortie de page (la vue n'est pas recréée).
      pageOpenedAt = Date()
      archivesExpanded = false
    }
    // Création de liste (sidebar) : on passe le TITRE de la page en édition. `.task(id:)` et pas
    // `.onChange` — à la 1re création, cette page vient d'être montée, un `.onChange` ne verrait pas
    // la valeur déjà posée. Le titre partage `focusedDraft` avec les champs « Nouvelle tâche », si
    // bien que la validation (Entrée, cf. son `onSubmit`) enchaîne sur la 1re tâche sans quitter la
    // vue — plus de course avec la key-view chain d'AppKit.
    .task(id: pendingTitleFocus) {
      guard pendingTitleFocus == list.persistentModelID else { return }
      pendingTitleFocus = nil
      focusedDraft = Self.titleFocusKey
    }
  }

  /// L'en-tête actuellement sélectionnée (et non en cours d'édition), ou nil.
  private var selectedHeader: TaskItem? {
    guard let id = selectedID else { return nil }
    return list.tasks.first { $0.persistentModelID == id && $0.isHeader }
  }

  /// Bloc contenant la sélection courante (tâche ou en-tête), ou nil hors sélection. Cible du
  /// « + » de la toolbar : insérer dans le bloc qu'on regarde, pas systématiquement le dernier.
  private var selectedBlockID: String? {
    guard let id = selectedID else { return nil }
    return blocks.first { block in
      block.header?.persistentModelID == id || block.tasks.contains { $0.persistentModelID == id }
    }?.id
  }

  /// Tâches rattachées à une en-tête = celles de son bloc (l'en-tête exclue).
  private func attachedTasks(of header: TaskItem) -> [TaskItem] {
    blocks.first { $0.header?.persistentModelID == header.persistentModelID }?.tasks ?? []
  }

  /// ⌫ sur l'en-tête sélectionnée : suppression directe si elle est vide, sinon on demande
  /// confirmation via l'alerte.
  private func requestDeleteSelectedHeader() {
    guard let header = selectedHeader else { return }
    if attachedTasks(of: header).isEmpty {
      delete(header)
    } else {
      headerDeletionCandidate = header
    }
  }

  /// ⌫ sur la sélection courante : délègue à la confirmation d'en-tête si elle en est une, sinon
  /// supprime la tâche directement (pas de tâches rattachées à protéger, contrairement à l'en-tête).
  private func requestDeleteSelected() {
    guard let id = selectedID, let task = list.tasks.first(where: { $0.persistentModelID == id })
    else { return }
    if task.isHeader {
      requestDeleteSelectedHeader()
    } else {
      delete(task)
    }
  }

  /// Découpe les lignes en blocs : une en-tête et les tâches qui la suivent jusqu'à la prochaine.
  /// Les tâches AVANT toute en-tête forment un bloc sans en-tête ; une liste vide reste un bloc
  /// (avec son champ de création). `id` stable (id de l'en-tête, ou "top") pour l'identité SwiftUI,
  /// le focus et le brouillon de saisie de chaque bloc.
  /// Vrai pendant qu'on tire une EN-TÊTE (par opposition à une tâche) : pilote le repli des tâches
  /// et la disparition de tous les champs « Nouvelle tâche ».
  private var isHeaderDragging: Bool {
    draggingID != nil && draggedGroup.first?.isHeader == true
  }

  /// Clé d'un bloc : celle de son en-tête, ou `"top"` pour le bloc sans en-tête. Point d'entrée
  /// UNIQUE (`blocks` et `blockKey(of:in:)` s'appuient dessus) : deux calculs séparés auraient pu
  /// diverger silencieusement.
  private func blockKey(_ header: TaskItem?) -> String {
    header.map { String(describing: $0.persistentModelID) } ?? "top"
  }

  /// Clé du bloc contenant `task` dans `ordered` : celle de la dernière en-tête qui la précède
  /// (ou `"top"`). Même règle que `blocks`, mais sans reconstruire tout le tableau — sert à
  /// `endDrag` à repérer les DEUX blocs dont la composition change lors d'un drag (cf.
  /// `fieldRefresh`), sans attendre que `blocks` (calculé après l'écriture des `sortIndex`)
  /// reflète déjà le nouvel état.
  private func blockKey(of task: TaskItem, in ordered: [TaskItem]) -> String {
    guard let i = ordered.firstIndex(where: { $0.persistentModelID == task.persistentModelID })
    else { return blockKey(nil) }
    return blockKey(ordered[..<i].last(where: \.isHeader))
  }

  // MARK: Archivage des tâches cochées

  private var retention: CompletedTaskRetention {
    CompletedTaskRetention(rawValue: retentionRaw) ?? .untilViewChange
  }

  /// Une tâche cochée quitte le flux de la liste — jamais la base. Les en-têtes, qui ne se cochent
  /// pas, ne sont jamais concernées.
  private func isArchived(_ task: TaskItem) -> Bool {
    guard !task.isHeader, task.isCompleted, let completedAt = task.completedAt else { return false }
    switch retention {
    case .never: return false
    case .untilViewChange: return completedAt < pageOpenedAt
    case .timer: return tick.timeIntervalSince(completedAt) >= CompletedTaskRetention.timerDelay
    }
  }

  /// Les archivées de CETTE liste, la plus récemment cochée en tête — même tri que la vue
  /// « Archives » globale, qui les montre toutes listes confondues.
  private var archivedTasks: [TaskItem] {
    list.orderedTasks.filter(isArchived)
      .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
  }

  /// Cocher en mode « après 1,5 s » : programme le redessin qui fera sortir la ligne. Ailleurs, le
  /// seuil ne dépend pas de l'heure — rien à réveiller.
  private func scheduleArchiveRefresh() {
    guard retention == .timer else { return }
    Task {
      try? await Task.sleep(for: .seconds(CompletedTaskRetention.timerDelay))
      withAnimation(taskInsert) { tick = Date() }
    }
  }

  /// Combien de tâches de cette liste ne sont plus que du décor : ni datées, ni faites, posées
  /// depuis trop longtemps (cf. `Dormancy`). Elles sont déjà pâlies dans la liste — cette ligne
  /// leur donne un CHIFFRE, seul moyen de voir l'accumulation d'un coup d'œil.
  ///
  /// ponytail: un compteur, pas encore la confrontation (« je la fais / je la date / je la tue »).
  /// C'est la sonde : si voir ce nombre grimper ne provoque rien, la confrontation ne servira à
  /// rien non plus.
  @ViewBuilder private var dormantSummary: some View {
    let count = list.orderedTasks.filter(\.isDormant).count
    if count > 0 {
      let plural = count > 1 ? "s" : ""
      HStack(spacing: 6) {
        Image(systemName: "moon.zzz")
          .font(.system(size: 11))
        Text("\(count) tâche\(plural) en sommeil")
      }
      .font(.callout)
      .foregroundStyle(.tertiary)
      .padding(.top, 18)
    }
  }

  /// Section « Archivées », repliée par défaut, en bas de la page : ce que cette liste a déjà
  /// terminé, sans quitter la page ni aller dans la vue « Archives » globale. Absente tant que rien
  /// n'est archivé — une page neuve ne montre pas une section vide.
  @ViewBuilder private var archiveSection: some View {
    let archived = archivedTasks
    let plural = archived.count > 1 ? "s" : ""
    if !archived.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        Divider().padding(.vertical, 10)

        Button {
          withAnimation(.snappy(duration: 0.22)) { archivesExpanded.toggle() }
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "chevron.right")
              .font(.system(size: 10, weight: .semibold))
              .rotationEffect(.degrees(archivesExpanded ? 90 : 0))
            Text("\(archived.count) tâche\(plural) archivée\(plural)")
              .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
          }
          .foregroundStyle(.secondary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        // Même rendu QUE la page « Archives » (`ArchiveMonthSection`) : case, date, titre et son
        // rattachement, groupés par mois. Le contenu est identique, seul le périmètre change —
        // deux rendus auraient divergé au premier ajustement.
        if archivesExpanded {
          ForEach(archiveMonths(archived)) { month in
            ArchiveMonthSection(
              month: month,
              onToggle: { restoreFromArchive($0) },
              onDelete: { delete($0) }
            )
          }
        }
      }
      .transition(.opacity)
    }
  }

  /// Décocher depuis l'archive : la tâche revient dans le flux, à sa place — l'archivage ne l'avait
  /// jamais déplacée.
  private func restoreFromArchive(_ task: TaskItem) {
    withAnimation(taskInsert) { task.toggleCompletion() }
    Task { await remindersService.pushCompletion(for: task) }
  }

  private var blocks: [TaskBlock] {
    var result: [TaskBlock] = []
    var header: TaskItem?
    var tasks: [TaskItem] = []
    // Les archivées sortent ICI : `blocks` est la seule source du flux affiché (lignes, drag,
    // champs de création), donc le seul endroit à filtrer.
    for item in list.orderedTasks where !isArchived(item) {
      if item.isHeader {
        if header != nil || !tasks.isEmpty {
          result.append(TaskBlock(id: blockKey(header), header: header, tasks: tasks))
        }
        header = item
        tasks = []
      } else {
        tasks.append(item)
      }
    }
    result.append(TaskBlock(id: blockKey(header), header: header, tasks: tasks))
    return result
  }

  /// Enveloppe drag/drop d'une ligne (en-tête ou tâche), mutualisée entre les deux : mesure de la
  /// position de repos, décalage/soulevé pendant le drag, et le geste unique de la page.
  private func draggableRow(for task: TaskItem, targets: [RowKey: CGFloat])
    -> some View
  {
    // `lifted` = cette ligne fait partie du groupe tiré (bloc entier pour une en-tête) → elle se
    // soulève. `grabbed` = c'est LA ligne empoignée → elle porte l'ancre du léger agrandissement.
    // `folding` = une tâche du bloc dont on tire l'en-tête : elle s'estompe (se replie dans le
    // bloc), seule l'en-tête reste visible pendant le transport (cf. `dragTargets`, le repli Δ).
    let lifted = draggedGroup.contains { $0.persistentModelID == task.persistentModelID }
    let grabbed = draggingID == task.persistentModelID
    let folding = lifted && !task.isHeader && draggedGroup.first?.isHeader == true
    return
      row(for: task)
      // Carte éditée : marge basse pour ne pas coller la ligne suivante (ou « Nouvelle tâche »).
      // Pas pour une en-tête : elle n'a pas de carte de notes qui s'étend, la marge ne ferait
      // qu'ajouter un vide sous sa pilule.
      .padding(.bottom, editingID == task.persistentModelID && !task.isHeader ? 12 : 0)
      // Position de repos mesurée, pour calculer où ouvrir le trou pendant un drag.
      .background {
        GeometryReader { g in
          Color.clear.preference(
            key: RowFrameKey.self,
            value: [.task(task.persistentModelID): g.frame(in: .named(Self.dragSpace))]
          )
        }
      }
      // La ligne empoignée se soulève et suit le curseur en 2D ; les autres s'écartent verticalement.
      // MÊME vue du début à la fin — pas d'instantané façon `.onDrag`, donc rien ne saute au drop.
      .opacity(folding ? 0 : 1)
      .offset(rowOffset(for: task, targets: targets))
      .scaleEffect(lifted ? 1.03 : 1, anchor: grabbed ? dragAnchor : .center)
      // Ombre de soulevé pour une TÂCHE tirée. Pas pour une tâche qui se replie (elle s'estompe), ni
      // pour une en-tête tirée : sa pile (en-tête + calques) porte ses propres ombres dans `HeaderRow`
      // — une ombre globale ici épouserait la silhouette en escalier et salirait la cascade.
      .shadow(
        color: .black.opacity(lifted && !folding && !task.isHeader ? 0.22 : 0),
        radius: lifted && !folding && !task.isHeader ? 10 : 0,
        y: lifted && !folding && !task.isHeader ? 5 : 0
      )
      .zIndex(lifted ? 1 : 0)
      // Les lignes tirées collent au curseur (aucune animation) ; les voisines glissent.
      .animation(
        lifted ? nil : .snappy(duration: 0.22),
        value: rowOffset(for: task, targets: targets)
      )
      .animation(.easeOut(duration: 0.15), value: lifted)
      .animation(.easeInOut(duration: 0.2), value: folding)
      // Rebond à la création (déclenché par le withAnimation de `createTask`). Ancré à gauche : la
      // rangée grandit depuis sa case à cocher, pas depuis son centre.
      .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
      // En édition, `.subviews` désactive ce geste : les clics/glissers vont au champ texte.
      .gesture(
        dragGesture(for: task),
        including: editingID == task.persistentModelID ? .subviews : .all
      )
      // Posé sur la LIGNE et non sur un `Group` englobant : un modificateur sur le `ForEach` d'un
      // `LazyVStack` risque de lui faire évaluer d'un coup toutes ses rangées — la lenteur qu'on
      // vient justement de retirer. `pageHeader` (anneau, titre, notes) reste au-dessus, intact.
      .pageReveal()
  }

  /// En-tête de section ou tâche : deux rendus distincts, même enveloppe drag/drop (posée par
  /// l'appelant). L'en-tête a désormais, comme la tâche, un état repos (titre en lecture) et un état
  /// édition (double-clic), pilotés par `editingID`.
  @ViewBuilder
  private func row(for task: TaskItem) -> some View {
    if task.isHeader {
      HeaderRow(
        task: task,
        isSelected: selectedID == task.persistentModelID,
        isEditing: editingID == task.persistentModelID,
        isDragging: draggingID == task.persistentModelID,
        // Nombre RÉEL de tâches rattachées (badge rouge) ; les calques, eux, sont plafonnés à 3.
        attachedTaskCount: draggingID == task.persistentModelID ? draggedGroup.count - 1 : 0,
        moveTargets: allLists.filter { $0.persistentModelID != list.persistentModelID },
        onEndEditing: { endEditingHeader(task) },
        onMove: { moveHeader(task, to: $0) },
        onCopy: { copyHeaderToClipboard(task) },
        onDelete: { delete(task) }
      )
    } else {
      TaskRow(
        task: task,
        isSelected: selectedID == task.persistentModelID,
        isEditing: editingID == task.persistentModelID,
        moveTargets: allLists.filter { $0.persistentModelID != list.persistentModelID },
        onBeginEditing: { beginEditing(task) },
        onEndEditing: { endEditing(task) },
        onMove: { move(task, to: $0) },
        onDuplicate: { duplicate(task) },
        onDelete: { delete(task) },
        onCompletionChanged: scheduleArchiveRefresh
      )
    }
  }

  // MARK: États d'une tâche

  /// Sélectionne, avec le fondu de surbrillance. Le fondu N'ÉTAIT PAS le problème de latence : il
  /// démarre désormais dès le mouseDOWN (cf. `selectGesture` dans TaskRow), pas au relâchement — la
  /// surbrillance réagit donc au contact, comme une sélection native, tout en gardant son fondu.
  private func select(_ task: TaskItem) {
    withAnimation(taskSelectFade) {
      editingID = nil
      selectedID = task.persistentModelID
    }
    // Quitte tout focus texte en cours (« Nouvelle tâche », titre de page, notes) : sinon ce champ
    // reste le VRAI premier répondeur AppKit même une fois la tâche sélectionnée, et ⌫ lui est
    // alors livré (il "focus" au lieu de supprimer) plutôt qu'à la suppression de la sélection.
    // Même règle que le rattrapeur de clic sur le vide, plus haut : cliquer AILLEURS — ici sur une
    // tâche — doit toujours faire sortir d'un champ de saisie, peu importe lequel.
    focusedDraft = nil
    notesFocused = false
  }

  /// Double-clic : passe en édition.
  private func beginEditing(_ task: TaskItem) {
    withAnimation(taskFlow) {
      selectedID = task.persistentModelID
      editingID = task.persistentModelID
    }
    // Cf. `select()` : au cas où la tâche était déjà sélectionnée AVANT ce clic (ce geste n'entre
    // alors jamais dans `select()`, cf. `dragGesture`), on quitte quand même tout focus texte
    // resté ouvert ailleurs.
    focusedDraft = nil
    notesFocused = false
  }

  /// Cf. `RightClickObserver` : retrouve, par géométrie, la tâche sous le clic droit (jamais une
  /// en-tête) et la sélectionne — le clic droit sélectionne, il n'ouvre pas l'édition.
  private func selectAtRightClick(_ point: CGPoint) {
    guard
      let task = blocks.flatMap(\.tasks).first(where: {
        rowFrames[.task($0.persistentModelID)]?.contains(point) == true
      })
    else { return }
    select(task)
  }

  /// Fin d'édition (Entrée / Échap / clic à l'extérieur) : repasse en état « normal ».
  private func endEditing(_ task: TaskItem) {
    guard editingID == task.persistentModelID else { return }
    applyQuickEntry(to: task)
    withAnimation(taskFlow) {
      editingID = nil
      selectedID = nil
    }
  }

  /// Applique la saisie rapide (`@demain`, `#Courses`) au titre d'une tâche qu'on vient d'éditer.
  /// Le champ « Nouvelle tâche » n'est PAS le seul chemin de création — ⌘N, le clic droit et le
  /// double-clic écrivent directement dans le titre de la ligne : les jetons doivent y être
  /// reconnus aussi, sinon « @today » reste dans le texte selon la façon dont la tâche a été créée.
  private func applyQuickEntry(to task: TaskItem) {
    guard !task.isHeader else { return }
    let entry = QuickEntry(parsing: task.title, names: quickEntryNames)
    // Titre vide après retrait des jetons : la ligne ne dirait plus rien, on n'y touche pas.
    guard !entry.title.isEmpty, entry.when != nil || entry.target != nil else { return }
    task.title = entry.title
    if let when = entry.when { task.when = when }
    if let destination = entry.target.flatMap(resolveQuickEntryTarget),
      destination.persistentModelID != task.list?.persistentModelID
    {
      // La tâche quitte la page affichée : purge sélection/édition qui pointeraient dessus
      // (même précaution que `moveHeader`).
      if selectedID == task.persistentModelID { selectedID = nil }
      if editingID == task.persistentModelID { editingID = nil }
      move(task, to: destination)
    }
    try? modelContext.save()
  }

  /// Entrée sur le titre d'une en-tête : ferme son édition ET enchaîne sur le champ « Nouvelle
  /// tâche » de SON bloc — même logique que le titre de la liste (cf. `header`, plus bas), pour
  /// écrire directement la 1re tâche de la section qu'on vient de nommer.
  private func endEditingHeader(_ header: TaskItem) {
    endEditing(header)
    focusedDraft = blocks.first { $0.header?.persistentModelID == header.persistentModelID }?.id
  }

  /// Ferme l'édition en cours, quelle que soit la tâche (Échap au niveau fenêtre, clic dehors).
  private func dismissEditing() {
    if let editing = list.tasks.first(where: { $0.persistentModelID == editingID }) {
      applyQuickEntry(to: editing)
    }
    withAnimation(taskFlow) {
      editingID = nil
      selectedID = nil
    }
  }

  /// Cf. `LeftClickOutsideObserver` : `point` (repère `Self.dragSpace`) hors de toute ligne (tâche
  /// OU en-tête) → referme édition/sélection et retire le focus des notes / du champ « Nouvelle
  /// tâche » resté ouvert. Un clic SUR une ligne ne fait rien ici : son propre geste (sélection,
  /// édition) s'en charge déjà.
  private func dismissSelectionIfOutside(_ point: CGPoint) {
    // Rien d'ouvert : on ne touche à RIEN. Ce moniteur voit TOUS les mouseDown de la fenêtre
    // (sidebar, barre du bas, bouton Réglages compris). Sans cette garde il rejouait, à chaque
    // appui, une transaction animée (`dismissEditing`) et deux résignations de focus — donc une
    // résignation de premier répondeur AppKit ENTRE le mouseDown et le mouseUp du contrôle visé.
    // Le contrôle perdait le suivi de son appui : son action ne partait pas, et il fallait
    // cliquer une seconde fois (là où l'état, déjà vide, ne provoquait plus rien).
    guard editingID != nil || selectedID != nil || focusedDraft != nil || notesFocused
    else { return }
    let insideRow = blocks.contains { block in
      if let header = block.header,
        rowFrames[.task(header.persistentModelID)]?.contains(point) == true
      {
        return true
      }
      return block.tasks.contains {
        rowFrames[.task($0.persistentModelID)]?.contains(point) == true
      }
    }
    guard !insideRow else { return }
    dismissEditing()
    notesFocused = false
    focusedDraft = nil
  }

  // MARK: Réordonnancement
  //
  // Réordonnancement « physique » : on ne prend PAS d'instantané (`.onDrag`/`NSItemProvider`, qui
  // masque la ligne et en fait voler une copie bitmap — d'où la disparition/réapparition au drop).
  // Ici la vraie ligne est décalée sous le curseur (`.offset`) tandis que les voisines s'écartent
  // pour ouvrir le trou. Au relâchement, l'ordre est écrit et les décalages retombent à 0 : la
  // ligne est déjà à sa place, rien ne saute. Une seule et même vue, du début à la fin.
  //
  // Sur macOS, un cliquer-glisser dans une ScrollView NE la fait PAS défiler (le défilement passe
  // par la molette/trackpad) : un `DragGesture` sur la ligne n'entre donc pas en conflit avec le
  // scroll, contrairement à iOS. C'est ce qui rend le geste natif inutile ici.

  /// Nom de l'espace de coordonnées partagé par les mesures de position et la translation du drag.
  private static let dragSpace = "taskListReorder"

  /// Clé de focus réservée au TextField du titre de la liste (header). Il partage le `@FocusState`
  /// `focusedDraft` des champs « Nouvelle tâche » pour que SwiftUI arbitre le premier répondeur de
  /// façon déterministe : sinon, le titre pris comme répondeur par AppKit reste hors du contrôle de
  /// SwiftUI et un `focusedDraft = <bloc>` ne le déloge pas. Préfixe non imprimable → jamais un `id`.
  private static let titleFocusKey = "\u{1}listTitle"

  /// Ligne physique de la page : une tâche/en-tête RÉELLE, ou le champ « Nouvelle tâche » VIRTUEL de
  /// fin de bloc. Les deux partagent le MÊME mécanisme de mesure/décalage (`rowFrames`,
  /// `dragTargets`) : un champ n'est jamais un cas spécial à calculer à la main, juste une ligne non
  /// déplaçable de plus dans la séquence — c'est cette uniformité qui lui garantit une continuité
  /// exacte au drop (même principe que la rangée « + Nouvelle liste » de la sidebar, cf.
  /// `SidebarView.RowKey.addList`, qui participe déjà à son propre moteur de réordonnancement).
  fileprivate enum RowKey: Hashable {
    case task(PersistentIdentifier)
    case field(String)
  }

  /// Séquence physique complète, dans l'ordre d'affichage : chaque bloc = son en-tête (s'il y en a
  /// une), ses tâches, puis son champ « Nouvelle tâche ». Base commune du calcul de décalage pour
  /// les tâches ET les champs (cf. `dragTargets`).
  private var physicalRows: [RowKey] {
    var rows: [RowKey] = []
    for block in blocks {
      if let header = block.header { rows.append(.task(header.persistentModelID)) }
      for task in block.tasks { rows.append(.task(task.persistentModelID)) }
      rows.append(.field(block.id))
    }
    return rows
  }

  /// Rectangle englobant d'un ensemble de lignes contiguës (position de repos), pour traiter un bloc
  /// comme une seule « grande ligne ». `nil` tant qu'aucune n'est mesurée.
  private func groupRect(_ items: [TaskItem]) -> CGRect? {
    let frames = items.compactMap { rowFrames[.task($0.persistentModelID)] }
    guard let first = frames.first else { return nil }
    let minY = frames.map(\.minY).min() ?? 0
    let maxY = frames.map(\.maxY).max() ?? 0
    return CGRect(x: first.minX, y: minY, width: first.width, height: maxY - minY)
  }

  /// Lignes qu'emporte le drag si on empoigne `task` : son bloc entier pour une en-tête, sinon elle
  /// seule. Figé à l'empoignade dans `draggedGroup`.
  private func dragGroup(for task: TaskItem) -> [TaskItem] {
    guard task.isHeader else { return [task] }
    return blocks.first { $0.header?.persistentModelID == task.persistentModelID }?.items ?? [task]
  }

  /// Hauteur « repliée » par le drag d'une en-tête : somme des hauteurs de ses tâches PLUS sa rangée
  /// « Nouvelle tâche ». Pendant le transport, ces lignes s'estompent, le bloc se réduit à sa seule
  /// en-tête, et les lignes du dessous remontent d'autant. `nil` hors drag d'en-tête.
  private var blockDelta: CGFloat? {
    guard let header = draggedGroup.first, header.isHeader,
      let hf = rowFrames[.task(header.persistentModelID)],
      let block = groupRect(draggedGroup)
    else { return nil }
    return block.height - hf.height + draggedFieldHeight
  }

  /// Index d'insertion du groupe tiré parmi les autres lignes, d'après son centre projeté sous le
  /// curseur. `nil` si aucun drag en cours (ou positions pas encore mesurées).
  ///
  /// Deux régimes selon ce qu'on empoigne :
  /// - **une tâche** : insertion ligne à ligne, par FRONTIÈRES (mi-chemin entre centres voisins) ;
  ///   le placeholder bascule dès un demi-recouvrement.
  /// - **une en-tête** : insertion BLOC à BLOC, dans l'espace REPLIÉ. Le bloc tiré ne vaut plus que
  ///   son en-tête (les tâches se sont estompées) ; on compare le centre de l'en-tête aux centres
  ///   des blocs restants, corrigés du repli (ceux SOUS le bloc tiré sont remontés de Δ). Sous tous
  ///   les centres → fin de liste. Le placeholder ne se cale qu'aux frontières d'en-têtes.
  ///
  /// Rendu en TÂCHES (`[TaskItem]`), pas en `RowKey` : c'est l'espace où `sortIndex` s'écrit
  /// (`endDrag`). `dragTargets`/`fieldOffset` traduisent ce plan vers l'espace `RowKey` (qui inclut
  /// les champs) quand il leur faut positionner autre chose qu'une tâche.
  private func dragInsertion() -> (dragged: [TaskItem], others: [TaskItem], index: Int)? {
    guard draggingID != nil, let first = draggedGroup.first,
      let groupF = groupRect(draggedGroup)
    else { return nil }
    let ordered = list.orderedTasks
    let draggedIDs = Set(draggedGroup.map(\.persistentModelID))
    let others = ordered.filter { !draggedIDs.contains($0.persistentModelID) }

    if first.isHeader {
      guard let hf = rowFrames[.task(first.persistentModelID)],
        let di = blocks.firstIndex(where: {
          $0.header?.persistentModelID == first.persistentModelID
        })
      else { return nil }
      let delta = blockDelta ?? 0
      // Centre de l'EN-TÊTE (le bloc replié ne fait plus que sa hauteur) sous le curseur.
      let center = hf.midY + dragOffset.height
      var flat = others.count
      for (bi, b) in blocks.enumerated() {
        if bi == di { continue }  // le bloc tiré n'est pas dans `others`
        guard let r = groupRect(b.items) else { continue }
        // Un bloc entier est soit tout au-dessus, soit tout au-dessous du bloc tiré : son centre
        // replié remonte de Δ s'il est en dessous.
        let blockCenter = r.midY - (bi > di ? delta : 0)
        guard center < blockCenter else { continue }
        // Index dans `others`, PAS un cumul de `rowCount` : `blocks` a écarté les tâches archivées
        // (cf. `isArchived`) alors qu'`others` les contient — additionner les lignes visibles
        // donnait un index trop petit d'autant de tâches cochées, et l'en-tête se posait trop haut.
        flat =
          others.firstIndex { $0.persistentModelID == b.items.first?.persistentModelID }
          ?? others.count
        break
      }
      return (draggedGroup, others, min(flat, others.count))
    }

    let center = groupF.midY + dragOffset.height
    var index = ordered.count
    for i in ordered.indices {
      guard let f = rowFrames[.task(ordered[i].persistentModelID)] else { continue }
      let nextMid =
        i + 1 < ordered.count ? rowFrames[.task(ordered[i + 1].persistentModelID)]?.midY : nil
      let boundary = nextMid.map { ($0 + f.midY) / 2 } ?? .greatestFiniteMagnitude
      if center < boundary {
        index = i
        break
      }
    }
    return (draggedGroup, others, min(index, others.count))
  }

  /// Position de repos cible de CHAQUE ligne physique — tâches, en-têtes, ET champs « Nouvelle
  /// tâche » confondus (cf. `RowKey`/`physicalRows`) — trou réservé à l'emplacement d'insertion.
  ///
  /// Fondé sur les positions de repos MESURÉES (`rowFrames.minY`), pas sur un ré-empilement
  /// contigu : retirer la ligne tirée puis la réinsérer décale les lignes situées ENTRE son
  /// ancienne et sa nouvelle place d'exactement sa hauteur (les autres ne bougent pas) — QUEL QUE
  /// SOIT LE TYPE de ces lignes intermédiaires (tâche, en-tête, champ) : seule compte leur POSITION
  /// dans la séquence, jamais un cas particulier par bloc à calculer à la main. C'est cette
  /// continuité, pas une astuce d'animation, qui garantit une révélation de champ instantanée et
  /// fiable au drop, quelle que soit la situation.
  /// ponytail: recalcul O(n) par rendu de drag — négligeable à l'échelle d'une to-do list.
  ///
  /// Drag d'une en-tête : calcul dans l'espace REPLIÉ, TÂCHES SEULEMENT — les champs des AUTRES
  /// blocs restent simplement invisibles pendant un drag d'en-tête (jamais signalé comme un
  /// problème, pas de raison d'étendre ce cas). `h` = hauteur de la SEULE en-tête.
  private func dragTargets() -> [RowKey: CGFloat] {
    guard let (dragged, others, insert) = dragInsertion(),
      let first = dragged.first,
      let dragFrame = rowFrames[.task(first.persistentModelID)],
      let origInsert = list.orderedTasks.firstIndex(where: {
        $0.persistentModelID == first.persistentModelID
      })
    else { return [:] }
    let h = dragFrame.height

    if first.isHeader {
      let delta = blockDelta ?? 0
      let B = origInsert
      var map: [RowKey: CGFloat] = [:]
      for (j, other) in others.enumerated() {
        let key = RowKey.task(other.persistentModelID)
        guard let home = rowFrames[key]?.minY else { continue }
        let base = home - (j >= B ? delta : 0)
        let shift: CGFloat =
          (insert < B && (insert..<B).contains(j))
          ? h
          : (insert > B && (B..<insert).contains(j)) ? -h : 0
        map[key] = base + shift
      }
      return map
    }

    // Tâche : même formule, dans l'espace `RowKey` COMPLET (tâches, en-têtes ET champs) — un champ
    // y participe comme n'importe quelle autre ligne, sans traitement séparé.
    let allRows = physicalRows
    let draggedKey = RowKey.task(first.persistentModelID)
    guard let B = allRows.firstIndex(of: draggedKey) else { return [:] }
    let rowKeyOthers = allRows.filter { $0 != draggedKey }
    let insertRK: Int =
      insert < others.count
      ? (rowKeyOthers.firstIndex(of: .task(others[insert].persistentModelID)) ?? rowKeyOthers.count)
      : rowKeyOthers.count
    var map: [RowKey: CGFloat] = [:]
    for (j, key) in rowKeyOthers.enumerated() {
      guard let home = rowFrames[key]?.minY else { continue }
      let shift: CGFloat =
        (insertRK < B && (insertRK..<B).contains(j))
        ? h
        : (insertRK > B && (B..<insertRK).contains(j)) ? -h : 0
      map[key] = home + shift
    }
    return map
  }

  /// Rectangle du trou d'insertion (le « placeholder ») dans l'espace de la liste : là où la ligne
  /// tirée se posera. Bas de la ligne (déplacée) qui précède le trou, ou le sommet si insertion en
  /// tête. Positions mesurées → juste malgré les trous entre blocs. Drag d'en-tête : taille d'une
  /// en-tête et positions corrigées du repli Δ, comme `dragTargets`.
  private func dragPlaceholderRect() -> CGRect? {
    guard let first = draggedGroup.first,
      let dragFrame = rowFrames[.task(first.persistentModelID)],
      let (_, others, insert) = dragInsertion(),
      let origInsert = list.orderedTasks.firstIndex(where: {
        $0.persistentModelID == first.persistentModelID
      })
    else { return nil }
    let h = dragFrame.height
    let delta = first.isHeader ? (blockDelta ?? 0) : 0
    let B = origInsert
    let gapTop: CGFloat
    if insert == 0 {
      gapTop =
        list.orderedTasks.compactMap { rowFrames[.task($0.persistentModelID)]?.minY }.min() ?? 0
    } else {
      // Dernière ligne MESURÉE au-dessus du trou, pas forcément `insert - 1` : `others` contient
      // les tâches archivées, qui ne sont pas rendues et n'ont donc pas de cadre. Sans ce recul,
      // déposer juste après une tâche cochée faisait disparaître le placeholder.
      guard
        let j = (0..<insert).reversed().first(where: {
          rowFrames[.task(others[$0].persistentModelID)] != nil
        }),
        let f = rowFrames[.task(others[j].persistentModelID)]
      else { return nil }
      let base = f.minY - (j >= B ? delta : 0)
      let shift: CGFloat = (insert > B && j >= B) ? -h : 0
      gapTop = base + shift + f.height
    }
    // `h` reste la hauteur de RANGÉE partout au-dessus (c'est d'elle que les voisines s'écartent,
    // cf. `dragTargets`). Le rectangle DESSINÉ, lui, se ramène à la pilule : une en-tête porte ses
    // marges hors de son fond, un trou à la hauteur de la rangée serait visiblement plus grand que
    // ce qu'on transporte. Une tâche a ses marges dedans → rien à retirer, `inset` vaut 0.
    let top = first.isHeader ? HeaderRow.topInset : 0
    let bottom = first.isHeader ? HeaderRow.bottomInset : 0
    return CGRect(
      x: dragFrame.minX, y: gapTop + top,
      width: dragFrame.width, height: h - top - bottom)
  }

  /// Décalage d'une ligne : la ligne tirée suit le curseur en 2D (soulevée), les autres rejoignent
  /// verticalement leur cible (différence entre position cible et position de repos mesurée).
  private func rowOffset(for task: TaskItem, targets: [RowKey: CGFloat]) -> CGSize {
    if draggedGroup.contains(where: { $0.persistentModelID == task.persistentModelID }) {
      return dragOffset
    }
    let key = RowKey.task(task.persistentModelID)
    guard let target = targets[key], let home = rowFrames[key]?.minY else { return .zero }
    return CGSize(width: 0, height: target - home)
  }

  /// Décalage d'un champ « Nouvelle tâche » : symétrique de `rowOffset`, EXACTEMENT le même
  /// mécanisme (cible − position de repos mesurée) — aucun calcul spécifique au champ, `targets`
  /// (produit par `dragTargets`) contient déjà sa cible s'il doit bouger.
  private func fieldOffset(for block: TaskBlock, targets: [RowKey: CGFloat]) -> CGFloat {
    let key = RowKey.field(block.id)
    guard let target = targets[key], let home = rowFrames[key]?.minY else { return 0 }
    return target - home
  }

  /// Ancre du soulevé (agrandissement) : la position relative du point empoigné dans la ligne
  /// tirée. Scaler autour de CE point le laisse fixe sous le curseur ; `.center` par défaut le
  /// ferait dériver d'autant que le curseur est loin du milieu d'une ligne large.
  private var dragAnchor: UnitPoint {
    guard let draggingID, let f = rowFrames[.task(draggingID)], f.width > 0, f.height > 0
    else { return .center }
    return UnitPoint(x: (dragStart.x - f.minX) / f.width, y: (dragStart.y - f.minY) / f.height)
  }

  /// UN SEUL geste pour sélection (mouseDown), édition ET réordonnancement (glisser).
  /// `minimumDistance: 0` pour capter le mouseDown ; le réordonnancement ne démarre qu'au-delà d'un
  /// seuil. Fusionner tout dans un même geste évite qu'un geste séparé ne « vole » le drag.
  ///
  /// Tâche comme en-tête : clic → sélection (surbrillance lavande) ; clic sur une ligne DÉJÀ
  /// sélectionnée → édition (renommage façon Finder). Les enfants (case, menu •••) gardent leurs
  /// propres clics.
  private func dragGesture(for task: TaskItem) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.dragSpace))
      .onChanged { value in
        // Premier onChanged de l'appui = mouseDown : sélection immédiate (le fondu démarre ici).
        if pressID != task.persistentModelID {
          pressID = task.persistentModelID
          pressWasSelected = selectedID == task.persistentModelID
          if editingID != task.persistentModelID && selectedID != task.persistentModelID {
            select(task)
          }
        }
        // Empoignade au-delà du seuil : pas de drag d'une carte/en-tête ouverte en édition.
        if draggingID == nil {
          guard editingID != task.persistentModelID else { return }
          guard abs(value.translation.height) > 6 || abs(value.translation.width) > 6 else {
            return
          }
          selectedID = task.persistentModelID
          editingID = nil
          draggingID = task.persistentModelID
          draggedGroup = dragGroup(for: task)
          // Hauteur de la rangée « Nouvelle tâche » du bloc tiré, pour un repli sans trou résiduel.
          draggedFieldHeight =
            blocks.first { $0.header?.persistentModelID == task.persistentModelID }
            .flatMap { rowFrames[.field($0.id)]?.height } ?? 0
          dragStart = value.startLocation
        }
        guard draggingID == task.persistentModelID else { return }
        dragOffset = value.translation
      }
      .onEnded { value in
        defer { pressID = nil }
        if draggingID == task.persistentModelID {
          endDrag()
          return
        }
        let moved = abs(value.translation.width) > 4 || abs(value.translation.height) > 4
        guard !moved, editingID != task.persistentModelID else { return }
        if pressWasSelected {
          beginEditing(task)
        }
      }
  }

  /// Écrit l'ordre atteint dans les `sortIndex` et retombe les décalages à 0. Comme les lignes
  /// (ET les champs « Nouvelle tâche », cf. `dragTargets`) sont déjà visuellement à leur cible, la
  /// bascule ordre↔offset ne produit aucun saut — révélation immédiate, sans exception.
  private func endDrag() {
    // `dragInsertion` lit `draggingID`/`draggedGroup` : on capture le plan AVANT de désarmer.
    let plan = dragInsertion()
    withAnimation(.snappy(duration: 0.22)) {
      if let (dragged, others, insert) = plan {
        var newOrder = others
        newOrder.insert(contentsOf: dragged, at: insert)
        for (index, task) in newOrder.enumerated() { task.sortIndex = index }
      }
      draggingID = nil
      dragOffset = .zero
      draggedGroup = []
    }
    try? modelContext.save()
  }

  /// Rangée de création à la fin d'un bloc. Entrée crée la tâche dans CE bloc et garde le focus :
  /// saisir plusieurs tâches d'affilée est le cas courant.
  private func newTaskRow(for block: TaskBlock) -> some View {
    HStack(spacing: 10) {
      // Même carré arrondi que TaskCheckbox, avec un + à l'intérieur, pour que la rangée de
      // création s'aligne visuellement sur les cases des tâches.
      RoundedRectangle(cornerRadius: 4.5, style: .continuous)
        .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1)
        .overlay {
          Image(systemName: "plus")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
        .frame(width: 16, height: 16)
      // Jetons déjà validés (par un espace) : ils quittent le texte et deviennent des pastilles,
      // exactement celles qu'affichera la tâche une fois créée (cf. `dateTag`). Clic = retrait.
      if let tokens = draftTokens[block.id] {
        if let when = tokens.when {
          TokenPill(text: when.formatted(.dateTime.day().month(.abbreviated)))
            .onTapGesture { draftTokens[block.id]?.when = nil }
            .help("Retirer la date")
        }
        if let target = tokens.target {
          TokenPill(text: target)
            .onTapGesture { draftTokens[block.id]?.target = nil }
            .help("Retirer la destination")
        }
      }
      TextField(
        "Nouvelle tâche…",
        text: Binding(get: { drafts[block.id] ?? "" }, set: { drafts[block.id] = $0 })
      )
      .textFieldStyle(.plain)
      .focused($focusedDraft, equals: block.id)
      .onSubmit { createTask(in: block) }
      // Le retrait du jeton se fait ICI et pas dans le `set:` du Binding : réécrire la valeur
      // depuis le setter ne repousse rien vers le field editor AppKit en cours d'édition (la
      // pastille apparaissait, mais « @today » restait affiché). Un `onChange` referme le cycle
      // par un vrai changement d'état, que SwiftUI, lui, redescend dans le champ.
      .onChange(of: drafts[block.id] ?? "") { _, new in
        let cleaned = consumeTokens(in: block, text: new)
        if cleaned != new { drafts[block.id] = cleaned }
      }
      // Clic à l'extérieur (le focus quitte CE champ) avec du texte déjà tapé : la tâche se crée
      // aussi, pas seulement sur Entrée. Sans `refocus`, sinon on volerait le focus au clic qui
      // vient justement de partir ailleurs (autre champ, autre ligne).
      .onChange(of: focusedDraft) { old, new in
        guard old == block.id, new != block.id else { return }
        createTask(in: block, refocus: false)
      }
    }
    // Mêmes paddings qu'une TaskRow au repos (vertical 6, `rowInset` horizontal) : la rangée de
    // création garde exactement le rythme des tâches, sans détachement visuel.
    .padding(.vertical, 6)
    .padding(.horizontal, rowInset)
    .contentShape(Rectangle())
    .onTapGesture { focusedDraft = block.id }
  }

  /// `refocus` : garde le focus sur CE champ pour enchaîner la saisie (Entrée). `false` quand la
  /// création est déclenchée par une PERTE de focus (clic à l'extérieur, cf. `newTaskRow`) —
  /// reposer le focus ferait la course avec l'endroit où l'utilisateur vient justement de cliquer.
  private func createTask(in block: TaskBlock, refocus: Bool = true) {
    let tokens = draftTokens[block.id]
    // Un jeton peut aussi être encore dans le texte (Entrée sans espace final) : le parseur repasse.
    let entry = QuickEntry(parsing: drafts[block.id] ?? "", names: quickEntryNames)
    draftTokens[block.id] = nil
    guard !entry.title.isEmpty else {
      drafts[block.id] = ""
      if refocus { focusedDraft = nil }
      return
    }
    let destination = (entry.target ?? tokens?.target).flatMap(resolveQuickEntryTarget) ?? list
    let task = TaskItem(title: entry.title, when: entry.when ?? tokens?.when, list: destination)

    if destination.persistentModelID != list.persistentModelID {
      // Autre liste : on la range à la fin, il n'y a pas de bloc courant là-bas.
      task.sortIndex = (destination.orderedTasks.last?.sortIndex ?? -1) + 1
      modelContext.insertAndSave(task)
    } else {
      // Insère à la fin du bloc : juste après sa dernière tâche (ou son en-tête si le bloc est vide),
      // avant le bloc suivant. Les tâches situées après glissent d'un cran.
      let anchor = block.tasks.last?.sortIndex ?? block.header?.sortIndex ?? -1
      withAnimation(taskInsert) {
        for t in list.tasks where t.sortIndex > anchor { t.sortIndex += 1 }
        task.sortIndex = anchor + 1
        modelContext.insertAndSave(task)
      }
    }
    drafts[block.id] = ""
    if refocus { focusedDraft = block.id }
  }

  /// Sort du texte les jetons validés par un espace et les range en pastilles (cf.
  /// `QuickEntry.consuming`) ; renvoie le texte à réafficher.
  private func consumeTokens(in block: TaskBlock, text: String) -> String {
    guard let (remaining, entry) = QuickEntry.consuming(text, names: quickEntryNames) else {
      return text
    }
    var tokens = draftTokens[block.id] ?? DraftTokens()
    if let when = entry.when { tokens.when = when }
    if let target = entry.target { tokens.target = target }
    draftTokens[block.id] = tokens
    return remaining
  }

  /// Destinations reconnues après `#`, listes d'abord : un projet ne porte pas de tâche, `#projet`
  /// vise donc sa première liste.
  // ponytail: le projet vide est ignoré (pas de création de liste implicite).
  private var quickEntryNames: [String] {
    allLists.map(\.title) + allProjects.map(\.title)
  }

  private func resolveQuickEntryTarget(_ name: String) -> TodoList? {
    allLists.first { $0.title == name }
      ?? allProjects.first { $0.title == name }?.orderedLists.first
  }

  // MARK: En-tête de liste

  /// La liste Inbox (« Tâches ») a un bandeau fixe, comme les autres pages intelligentes
  /// (`TodayPageView`) — pas de titre éditable, pas de menu ni de notes, comme le « À classer »
  /// de Things : elle n'a pas ces réglages.
  @ViewBuilder private var pageHeader: some View {
    if list.isInbox {
      inboxHeader
    } else {
      header
    }
  }

  private var inboxHeader: some View {
    // Même construction que les bandeaux d'« Aujourd'hui » et « Archives » : les trois pages à
    // titre fixe doivent se lire comme une seule (cf. `PageHeaderIcon` pour le cadrage).
    HStack(spacing: 10) {
      PageHeaderIcon(systemImage: SmartList.all.systemImage, tint: SmartList.all.color)
      Text(SmartList.all.label)
        .font(.title.bold())
      Spacer(minLength: 0)
    }
    // Seul en-tête de ListPageView à reprendre `rowInset` : son icône fait la largeur d'une case à
    // cocher, elle se lit donc comme la tête de cette colonne. Même règle dans « Aujourd'hui »,
    // qui rend les mêmes `TaskRow`. L'en-tête d'une liste nommée, lui, porte un anneau plus large
    // et l'encadré de notes : c'est le bord de section qui lui sert d'aplomb.
    .padding(.leading, rowInset)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 12) {
        ProgressRing(progress: list.progress, size: 26, lineWidth: 3, showsFill: true)
        TextField("Nom de la liste", text: $list.title)
          .textFieldStyle(.plain)
          .font(.title.bold())
          .fixedSize(horizontal: false, vertical: true)
          .focused($focusedDraft, equals: Self.titleFocusKey)
          // Même enchaînement que `pendingTaskFocus` (venant de la sidebar) : titre validé sur une
          // page sans tâche, Entrée enchaîne directement sur le champ « Nouvelle tâche ».
          .onSubmit {
            guard list.countableTasks.isEmpty else { return }
            focusedDraft = blocks.first?.id
          }
        // Le menu ••• n'apparaît qu'au survol du titre (comme Things).
        listMenu.opacity(headerHovering ? 1 : 0)
        Spacer(minLength: 0)
      }
      notesBox
    }
    // Aucun retrait ici : l'anneau, le titre et le notesBox partent du bord de section, à l'aplomb
    // des bandeaux d'en-tête et des fonds de ligne (cf. `pageHeader` dans le LazyVStack).
    // contentShape pour que le survol couvre toute la bande, pas seulement le texte.
    .contentShape(Rectangle())
    .onHover { headerHovering = $0 }
  }

  private var listMenu: some View {
    Menu {
      Button("Terminer la liste") { completeAllTasks() }
      Button("Définir une date…") { pickingListDate = true }
      Menu("Définir une priorité") {
        ForEach(Priority.allCases) { priority in
          Button {
            list.priority = priority
          } label: {
            Label(priority.label, systemImage: priority.systemImage)
          }
        }
      }
      Button("Dupliquer") { duplicateList() }
      Divider()
      Button("Supprimer", role: .destructive) { deleteList() }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.secondary)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .popover(isPresented: $pickingListDate, arrowEdge: .bottom) {
      VStack(spacing: 10) {
        DatePicker(
          "",
          selection: Binding(
            get: { list.scheduledWhen ?? Date() }, set: { list.scheduledWhen = $0 }),
          displayedComponents: .date
        )
        .datePickerStyle(.graphical)
        .labelsHidden()

        if list.scheduledWhen != nil {
          Divider()
          Button("Retirer la date") {
            list.scheduledWhen = nil
            pickingListDate = false
          }
          .buttonStyle(.plain)
          .foregroundStyle(.secondary)
        }
      }
      .padding(12)
    }
  }

  /// Notes de la liste : même encadré que celui du projet (cf. `NotesBox`, partagé pour un design
  /// identique). Entrée y ferme le focus au lieu d'insérer une ligne : sur une page sans tâche,
  /// elle enchaîne plutôt sur le champ « Nouvelle tâche » — sinon elle referme simplement, comme
  /// pour le projet. Un retour à la ligne reste possible via Maj+Entrée.
  private var notesBox: some View {
    NotesBox(
      notes: $list.notes,
      font: .systemFont(ofSize: NSFont.systemFontSize),
      textColor: .labelColor,
      focused: $notesFocused
    ) {
      if list.countableTasks.isEmpty {
        focusedDraft = blocks.first?.id
      } else {
        notesFocused = false
      }
    }
  }

  // MARK: Barre d'outils du bas

  private var bottomBar: some View {
    BottomToolbar(
      onNewTask: { focusNewTaskField() },
      onInsertHeader: { insertHeader() },
      onSearch: { searchPresented = true }
    )
  }

  /// Cible le bloc de la sélection courante (pas systématiquement le dernier) ; la sélection est
  /// ensuite retirée pour que la surbrillance lavande ne reste pas affichée pendant qu'on tape
  /// dans « Nouvelle tâche » — sinon les deux se lisent comme un focus ambigu. Utilisé par le
  /// bouton « + » de la barre d'outils (saisie rapide, sans ouvrir la carte d'édition complète).
  private func focusNewTaskField() {
    let target = selectedBlockID ?? blocks.last?.id
    withAnimation(taskSelectFade) { selectedID = nil }
    focusedDraft = target
  }

  /// ⌘N : crée une tâche VIDE directement dans le bloc de la sélection courante (ou le dernier) et
  /// ouvre sa carte d'édition complète — même geste qu'`insertHeader` pour une en-tête, plutôt que
  /// de se contenter de focaliser le champ « Nouvelle tâche » (cf. `focusNewTaskField`).
  private func createTaskInEditMode() {
    guard let block = blocks.first(where: { $0.id == selectedBlockID }) ?? blocks.last else {
      return
    }
    let task = TaskItem(title: "", list: list)
    let anchor = block.tasks.last?.sortIndex ?? block.header?.sortIndex ?? -1
    withAnimation(taskInsert) {
      for t in list.tasks where t.sortIndex > anchor { t.sortIndex += 1 }
      task.sortIndex = anchor + 1
      modelContext.insertAndSave(task)
    }
    let id = task.persistentModelID
    DispatchQueue.main.async {
      withAnimation(taskFlow) {
        selectedID = id
        editingID = id
      }
    }
  }

  // MARK: Actions de liste

  private func completeAllTasks() {
    let toggled = list.countableTasks.filter { !$0.isCompleted }
    for task in toggled { task.toggleCompletion() }
    try? modelContext.save()
    for task in toggled {
      Task { await remindersService.pushCompletion(for: task) }
    }
    // Même sort qu'une case cochée à la main : sans ça, « Terminer la liste » laisserait tout
    // affiché jusqu'au prochain redessin en mode « après 1,5 s ».
    scheduleArchiveRefresh()
  }

  private func duplicateList() {
    let copy = TodoList(title: list.title + " copie", notes: list.notes, project: list.project)
    copy.sortIndex = list.sortIndex + 1
    modelContext.insert(copy)
    // `TaskItem.copy(into:)` recopie tout, `sortIndex` compris : la liste dupliquée garde son ordre.
    for task in list.orderedTasks {
      modelContext.insert(task.copy(into: copy))
    }
    try? modelContext.save()
    selection = .list(copy)
  }

  private func deleteList() {
    let fallback = list.project.map(SidebarSelection.project)
    modelContext.delete(list)
    try? modelContext.save()
    // Naviguer AILLEURS avant que SwiftUI ne rende une page adossée à un modèle effacé.
    selection = fallback
  }

  private func delete(_ task: TaskItem) {
    if selectedID == task.persistentModelID { selectedID = nil }
    withAnimation(taskInsert) {
      modelContext.delete(task)
      try? modelContext.save()
    }
  }

  /// Déplace une tâche vers une autre liste, en la posant à la fin de sa nouvelle liste.
  private func move(_ task: TaskItem, to target: TodoList) {
    task.list = target
    task.sortIndex = (target.tasks.map(\.sortIndex).max() ?? -1) + 1
    try? modelContext.save()
  }

  /// Déplace une en-tête ET son bloc (les tâches rattachées) vers une autre liste, à la fin,
  /// dans le même ordre. Une en-tête déplacée seule laisserait ses tâches orphelines — le bloc
  /// voyage donc comme dans le drag de réordonnancement (cf. `dragGroup`).
  private func moveHeader(_ header: TaskItem, to target: TodoList) {
    let block = dragGroup(for: header)  // [en-tête, tâches rattachées…], dans l'ordre visuel
    var next = (target.tasks.map(\.sortIndex).max() ?? -1) + 1
    for item in block {
      item.list = target
      item.sortIndex = next
      next += 1
    }
    // Le bloc quitte la liste affichée : purge sélection/édition qui pointeraient dedans.
    if block.contains(where: { $0.persistentModelID == selectedID }) { selectedID = nil }
    if block.contains(where: { $0.persistentModelID == editingID }) { editingID = nil }
    try? modelContext.save()
  }

  /// Duplique une tâche juste sous l'originale (les suivantes glissent d'un cran).
  private func duplicate(_ task: TaskItem) {
    let clone = task.copy(into: list)
    for t in list.tasks where t.sortIndex > task.sortIndex { t.sortIndex += 1 }
    clone.sortIndex = task.sortIndex + 1  // écrase celui repris par `copy(into:)`
    modelContext.insertAndSave(clone)
  }

  /// Copie l'en-tête et ses tâches rattachées en texte brut dans le presse-papiers (titre de
  /// l'en-tête, puis chaque tâche en puce) — collable dans une note, un mail, etc. Même bloc que
  /// `dragGroup` (en-tête d'abord, puis ses tâches dans l'ordre).
  private func copyHeaderToClipboard(_ header: TaskItem) {
    let block = dragGroup(for: header)
    guard let first = block.first else { return }
    let lines = [first.title] + block.dropFirst().map { "- \($0.title)" }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
  }

  private func insertHeader() {
    let header = TaskItem(title: "", isHeader: true, list: list)
    header.headerColor = randomUnusedHeaderColor()
    withAnimation(taskInsert) {
      header.sortIndex = (list.tasks.map(\.sortIndex).max() ?? -1) + 1
      modelContext.insertAndSave(header)
    }
    // Une en-tête ne s'édite plus qu'au double-clic : une en-tête fraîchement créée serait donc
    // vide et en lecture. On ouvre son édition au tour de boucle suivant (la ligne existe alors,
    // `onChange(of: isEditing)` peut y poser le focus).
    let id = header.persistentModelID
    DispatchQueue.main.async {
      withAnimation(taskFlow) {
        selectedID = id
        editingID = id
      }
    }
  }

  /// Une couleur pas déjà portée par une en-tête de CETTE liste, pour que les en-têtes se
  /// distinguent d'un coup d'œil par défaut. Palette épuisée (7 en-têtes déjà toutes teintées) :
  /// on retombe sur la palette complète — l'utilisateur reste libre de changer la couleur à la main.
  private func randomUnusedHeaderColor() -> HeaderColor {
    let used = Set(list.tasks.filter(\.isHeader).compactMap(\.headerColor))
    let available = HeaderColor.allCases.filter { !used.contains($0) }
    return (available.isEmpty ? HeaderColor.allCases : available).randomElement()!
  }
}

/// Barre d'outils flottante du bas, commune à TOUTES les pages (liste, projet, pomodoro, vues à
/// venir) : même capsule Liquid Glass partout. `onNewTask`/`onInsertHeader` sont optionnels — une
/// page projet ou une vue stub n'ont pas de bloc de tâches unique où insérer directement ; le
/// bouton correspondant disparaît alors plutôt que de faire semblant.
struct BottomToolbar: View {
  var onNewTask: (() -> Void)?
  var onInsertHeader: (() -> Void)?
  var onSearch: () -> Void

  var body: some View {
    buttonGroup {
      if let onNewTask {
        toolbarButton(
          "Nouvelle tâche", shortcut: "⌘N",
          description: "Le raccourci clavier crée la tâche et ouvre directement son édition.",
          action: onNewTask
        ) {
          Image(systemName: "plus").font(.system(size: 16)).foregroundStyle(.secondary)
        }
        groupDivider
      }
      if let onInsertHeader {
        toolbarButton(
          "Insérer une en-tête", shortcut: "⌘⇧N",
          description: "Couleur attribuée au hasard, modifiable depuis son menu.",
          action: onInsertHeader
        ) { headerGlyph }
        groupDivider
      }
      toolbarButton("Recherche", action: onSearch) {
        Image(systemName: "magnifyingglass").font(.system(size: 16)).foregroundStyle(.secondary)
      }
    }
    // Capsule flottante centrée : elle garde sa largeur intrinsèque, le frame full-width la centre.
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.bottom, 16)
    // `.overlayPreferenceValue` rend la bulle dans une couche à PART, au-dessus de tout ce bloc —
    // et surtout HORS du `.glassEffect`/`.background` de `buttonGroup` : celui-ci compose son
    // contenu dans une texture bornée à la Capsule, donc une bulle en overlay LOCAL d'un bouton
    // (essayé d'abord) se faisait rogner par ce bord dès qu'elle dépassait vers le haut.
    .overlayPreferenceValue(ToolbarTooltipKey.self) { request in
      if let request { ToolbarTooltipOverlay(request: request) }
    }
  }

  /// « Button group » flottant : une capsule unique posée au-dessus du contenu, toutes les actions
  /// regroupées dedans, séparées par des traits internes. Rendu Liquid Glass natif via `.glassEffect`
  /// (bouts arrondis + réfraction + ombre portée fournis par le système), `.interactive()` fait réagir
  /// le verre au survol/press. Repli material + ombre sous macOS 26 (Package.swift cible .v14, donc
  /// le `#available` est obligatoire — le compilateur refuse l'API sinon).
  @ViewBuilder
  private func buttonGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    let base = HStack(spacing: 3) { content() }
      .padding(.horizontal, 7)
      .padding(.vertical, 6)
    if #available(macOS 26, *) {
      base.glassEffect(.regular.interactive(), in: Capsule())
    } else {
      base
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
    }
  }

  private var groupDivider: some View {
    Divider().frame(height: 20)
  }

  private func toolbarButton<Icon: View>(
    _ help: String, shortcut: String? = nil, description: String? = nil,
    action: @escaping () -> Void, @ViewBuilder icon: @escaping () -> Icon
  ) -> some View {
    ToolbarButton(
      help: help, shortcut: shortcut, description: description, action: action, icon: icon)
  }

  /// Lettre « T » dans un carré à bordure fine : remplace l'icône générique pour signifier
  /// « insérer un intertitre texte ». `Color.primary` pour le trait ET la lettre — s'inverse tout
  /// seul entre light et dark mode, pas de couleur figée à adapter à la main.
  private var headerGlyph: some View {
    Text("T")
      .font(.system(size: 12, weight: .bold, design: .rounded))
      .foregroundStyle(.primary)
      .frame(width: 19, height: 19)
      .overlay {
        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
          .strokeBorder(Color.primary, lineWidth: 1.2)
      }
  }
}

/// Un bouton de la toolbar : fond arrondi + léger agrandissement au survol, et curseur en main
/// (même geste que la sidebar). État `hovering` propre à CHAQUE bouton — c'est pour ça que c'est
/// une vue à part (une méthode ne peut pas porter de `@State`), sinon tous les boutons du groupe
/// auraient partagé un seul et même survol.
private struct ToolbarButton<Icon: View>: View {
  var help: String
  /// Non nil ⇒ bulle façon Reminders.app (titre + raccourci + description) au survol, à la place
  /// du tooltip système `.help` — ce style précis (gras, badge aligné, texte secondaire) n'est pas
  /// exposé par l'API AppKit publique, cf. `RichTooltip`.
  var shortcut: String? = nil
  var description: String? = nil
  var action: () -> Void
  @ViewBuilder var icon: () -> Icon

  @State private var hovering = false
  @State private var showTooltip = false

  var body: some View {
    let button = Button(action: action) {
      icon()
        .frame(width: 41, height: 33)
        .contentShape(Rectangle())
        // Capsule, pas un rectangle arrondi : le fond de survol doit reprendre le langage très
        // arrondi de la pilule qui l'englobe (`buttonGroup`), pas une forme plus carrée qui jure
        // avec elle.
        .background(hovering ? Color.primary.opacity(0.09) : .clear, in: Capsule())
        .scaleEffect(hovering ? 1.08 : 1)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(help)
    .animation(.easeOut(duration: 0.15), value: hovering)
    .onHover { inside in
      hovering = inside
      inside ? NSCursor.pointingHand.set() : NSCursor.arrow.set()
      guard shortcut != nil else { return }
      if inside {
        // Même délai qu'un tooltip système avant apparition ; `hovering` revérifié à l'échéance
        // au cas où la souris serait déjà repartie entre-temps.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          if hovering {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { showTooltip = true }
          }
        }
      } else {
        withAnimation(.easeOut(duration: 0.1)) { showTooltip = false }
      }
    }

    if let shortcut {
      button.anchorPreference(key: ToolbarTooltipKey.self, value: .bounds) { anchor in
        showTooltip
          ? ToolbarTooltipRequest(
            title: help, shortcut: shortcut, description: description ?? "", anchor: anchor)
          : nil
      }
    } else {
      button.help(help)
    }
  }
}

/// Contenu + ancre (position du bouton survolé) transmis par `ToolbarButton` à `BottomToolbar`,
/// qui rend la bulle hors du groupe de boutons — cf. commentaire sur `.overlayPreferenceValue`.
private struct ToolbarTooltipRequest {
  var title: String
  var shortcut: String
  var description: String
  var anchor: Anchor<CGRect>
}

private struct ToolbarTooltipKey: PreferenceKey {
  static let defaultValue: ToolbarTooltipRequest? = nil
  static func reduce(value: inout ToolbarTooltipRequest?, nextValue: () -> ToolbarTooltipRequest?) {
    if let next = nextValue() { value = next }
  }
}

/// Convertit l'ancre du bouton en position réelle (le `GeometryReader` fournit l'espace de coords
/// de `BottomToolbar`), puis pose la bulle juste au-dessus, centrée sur le bouton. `measuredHeight`
/// affiné au premier layout (`onAppear`/`onChange` sur sa propre taille) : sans ça, centrer la bulle
/// par rapport à SA PROPRE hauteur avant de la connaître la ferait d'abord apparaître mal calée.
private struct ToolbarTooltipOverlay: View {
  var request: ToolbarTooltipRequest
  @State private var measuredHeight: CGFloat = 70

  var body: some View {
    GeometryReader { proxy in
      let anchor = proxy[request.anchor]
      RichTooltip(
        title: request.title, shortcut: request.shortcut, description: request.description
      )
      .background {
        GeometryReader { size in
          Color.clear
            .onAppear { measuredHeight = size.size.height }
            .onChange(of: size.size.height) { _, new in measuredHeight = new }
        }
      }
      .position(x: anchor.midX, y: anchor.minY - 14 - measuredHeight / 2)
      .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
    }
  }
}

/// Bulle d'aide façon Reminders.app : titre en gras, raccourci aligné à droite sur la même ligne,
/// description secondaire en dessous. PAS le tooltip système (`.help`, texte plat sans mise en
/// forme ni badge) — cette mise en page précise n'est pas exposée par l'API AppKit publique, donc
/// reconstruite à la main. Décor seulement : aucune interaction, jamais de premier plan aux clics.
private struct RichTooltip: View {
  var title: String
  var shortcut: String
  var description: String

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 10) {
        Text(title).font(.system(size: 13, weight: .semibold))
        Spacer(minLength: 8)
        Text(shortcut)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
      }
      if !description.isEmpty {
        Text(description)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(10)
    .frame(width: 220, alignment: .leading)
    // Matériau et PAS un gris figé (#F5F6F7 auparavant) : en sombre, ce fond clair restait clair
    // sous un texte `.primary` devenu blanc — bulle illisible. `.regularMaterial` est déjà la
    // surface flottante de l'app (cf. la carte de `QuickFindPanel`) et suit les deux apparences.
    .background(
      .regularMaterial,
      in: RoundedRectangle(cornerRadius: 10, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
    }
    .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
    .allowsHitTesting(false)
  }
}

/// Page d'un projet : ses to-do lists dépliées. Chaque liste montre son titre (cliquable pour
/// l'ouvrir en édition) puis ses tâches en LECTURE (case à cocher + titre) — un survol du projet
/// sans avoir à ouvrir chaque liste. L'édition d'une tâche reste sur la page de sa liste.
private struct ProjectPageView: View {
  @Bindable var project: Project
  @Binding var selection: SidebarSelection?
  @Binding var searchPresented: Bool
  @Environment(RemindersService.self) private var remindersService
  @FocusState private var notesFocused: Bool

  var body: some View {
    // Header dans la List, pour la même raison que sur la page d'une liste : un header
    // au-dessus d'une List dans un VStack se fait recouvrir par elle (cf. ListPageView).
    List {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 12) {
          ProgressRing(progress: project.progress, size: 26, lineWidth: 3)
          TextField("Nom du projet", text: $project.title)
            .textFieldStyle(.plain)
            .font(.title.bold())
        }
        // Même encadré que la page de liste (cf. `NotesBox`) : les deux avaient deux visuels
        // distincts (ici un simple ZStack sans fond), plus de raison de diverger.
        NotesBox(
          notes: $project.notes,
          font: .systemFont(ofSize: NSFont.systemFontSize),
          textColor: .labelColor,
          focused: $notesFocused
        ) {
          notesFocused = false
        }
      }
      .padding(.bottom, 14)
      .listRowSeparator(.hidden)
      .selectionDisabled()

      ForEach(project.orderedLists) { list in
        // Titre de la liste : cliquer ouvre sa page (édition, création, réordonnancement).
        Button {
          selection = .list(list)
        } label: {
          HStack(spacing: 10) {
            // Pas de `showsFill` ici : cette variante garde un contour bleu PLEIN en permanence,
            // qu'un petit anneau de 16pt rend comme une pastille bleue — une liste sans rien de
            // coché s'affichait donc comme terminée. Le rendu sidebar (trait gris + arc) dit vrai.
            ProgressRing(progress: list.progress, size: 16)
            Text(list.title.isEmpty ? "Sans titre" : list.title).font(.headline)
            Spacer(minLength: 0)
            Text("\(list.countableTasks.filter { !$0.isCompleted }.count)")
              .foregroundStyle(.secondary)
          }
          .padding(.top, 8)
          .padding(.bottom, 4)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        // Par rangée : une `List` est paresseuse elle aussi (même précaution que
        // `ListPageView.draggableRow`). Le bloc anneau + titre + notes au-dessus reste hors du
        // fondu.
        .pageReveal()

        ForEach(list.orderedTasks) { task in
          taskRow(task).listRowSeparator(.hidden).pageReveal()
        }

        if list.tasks.isEmpty {
          Text("Aucune tâche")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.leading, 26)
            .listRowSeparator(.hidden)
            .selectionDisabled()
            .pageReveal()
        }
      }

      if project.lists.isEmpty {
        Text("Aucune liste. Crée-en une depuis la barre latérale.")
          .foregroundStyle(.tertiary)
          .listRowSeparator(.hidden)
          .selectionDisabled()
      }
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .environment(\.defaultMinListRowHeight, 1)
    .padding(.horizontal, gutter - 8)
    .padding(.top, 30)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      BottomToolbar(onNewTask: nil, onInsertHeader: nil, onSearch: { searchPresented = true })
    }
  }

  /// Tâche en lecture sous le titre de sa liste. Une en-tête devient un intertitre discret ; une
  /// tâche garde sa case à cocher active (comme partout ailleurs), le titre n'est pas éditable ici.
  @ViewBuilder
  private func taskRow(_ task: TaskItem) -> some View {
    if task.isHeader {
      Text(task.title.isEmpty ? "En-tête" : task.title)
        .font(.subheadline.bold())
        .foregroundStyle(
          task.headerColor.map { AnyShapeStyle($0.color) } ?? AnyShapeStyle(.secondary)
        )
        .padding(.leading, 20)
        .padding(.top, 6)
    } else {
      HStack(spacing: 10) {
        TaskCheckbox(isCompleted: task.isCompleted) {
          withAnimation(taskInsert) {
            task.toggleCompletion()
            if task.isCompleted { task.list?.moveToEndOfSection(task) }
          }
          Task { await remindersService.pushCompletion(for: task) }
        }
        Text(task.title.isEmpty ? "Sans titre" : task.title)
          .strikethrough(task.isCompleted)
          .foregroundStyle(task.isCompleted ? .secondary : .primary)
        Spacer(minLength: 0)
      }
      .padding(.leading, 20)
      .padding(.vertical, 2)
    }
  }
}

/// Notes de tâche/liste/projet : encadré au fond légèrement plus foncé que la page, gros rayon,
/// même retrait pour le placeholder et le texte tapé. Partagé par `ListPageView` et
/// `ProjectPageView` (auparavant deux visuels distincts : ce cadre est le SEUL, plus de raison de
/// diverger).
private struct NotesBox: View {
  @Binding var notes: Data
  var font: NSFont
  var textColor: NSColor
  var focused: FocusState<Bool>.Binding
  /// Entrée SANS Maj : ferme le focus des notes plutôt que d'insérer un retour à la ligne — sinon
  /// une ligne vide traînante grandit le cadre d'une hauteur de ligne sans raison visible. Maj+Entrée
  /// garde le retour à la ligne natif. `onEnter` permet à l'appelant d'enchaîner sur autre chose
  /// (ex. le champ « Nouvelle tâche » d'une liste vide) au lieu du simple retrait de focus par défaut.
  var onEnter: (() -> Void)? = nil

  var body: some View {
    ZStack(alignment: .topLeading) {
      // Placeholder et éditeur SANS retrait propre : le retrait est posé une seule fois sur le
      // ZStack (padding commun ci-dessous), donc le texte tapé et « Notes » partent du même x.
      if notes.isEmpty {
        Text("Notes")
          .font(.body)
          .foregroundStyle(.tertiary)
          .allowsHitTesting(false)
      }
      RichTextEditor(
        data: $notes, font: font, textColor: textColor,
        handleReturn: { shiftHeld in
          guard !shiftHeld else { return false }
          if let onEnter { onEnter() } else { focused.wrappedValue = false }
          return true
        }
      )
      .fixedSize(horizontal: false, vertical: true)
      .focused(focused)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .padding(.top, 4)
    .padding(.bottom, 10)
  }
}

/// Une tâche dans la liste. Deux modes :
/// - **affichage** : case à cocher + titre. Double-clic pour éditer.
/// - **édition** (double-clic) : carte détachée avec titre, notes, et une rangée d'actions
///   (date, tags, checklist, priorité), façon Things.
///
/// Le double-clic est un simple `.onTapGesture(count: 2)` — possible parce qu'on n'est plus sur
/// une `List`/NSTableView (qui avalait ses clics). C'est tout le bénéfice de la refonte.
/// Internal et pas `private` : « Aujourd'hui » la réutilise telle quelle (cf. `TodayPageView`).
/// C'était la seule façon d'y avoir édition, suppression, dates et durée sans réécrire la ligne —
/// une deuxième implémentation aurait dérivé de celle-ci au premier changement.
struct TaskRow: View {
  @Bindable var task: TaskItem
  let isSelected: Bool
  let isEditing: Bool
  /// Listes vers lesquelles déplacer la tâche (toutes sauf la sienne).
  var moveTargets: [TodoList]
  /// Faux dans « Aujourd'hui » : la page ne montre QUE le jour même, la date répétée sur chaque
  /// ligne n'apprend rien. Elle reste indispensable dans une liste, qui mélange les échéances.
  var showsDate: Bool = true
  /// Rattachement affiché à droite du titre. `nil` dans une page de liste (on sait déjà où l'on
  /// est) ; renseigné dans « Aujourd'hui », qui mélange les provenances.
  var parentLabel: String? = nil
  /// Raccourci « faire aujourd'hui » (⊕ au survol). Posé uniquement par la réserve sans date
  /// d'« Aujourd'hui » : y dater une tâche est le geste de la section, il ne doit pas coûter un
  /// passage par « Quand… » et son sélecteur.
  var onSchedule: (() -> Void)? = nil
  var onBeginEditing: () -> Void
  var onEndEditing: () -> Void
  var onMove: (TodoList) -> Void
  var onDuplicate: () -> Void
  var onDelete: () -> Void
  /// Cocher/décocher : la page décide ce qu'elle en fait (ici, programmer l'archivage).
  var onCompletionChanged: () -> Void

  @Environment(RemindersService.self) private var remindersService
  @Environment(\.modelContext) private var modelContext
  /// Focus de la sous-tâche en cours d'édition (clé = uuid stable, pas `persistentModelID` qui
  /// mute à l'autosave), pour poser le focus sur celle qu'on vient de créer.
  /// uuid de la sous-tâche à focaliser (clé de focus stable, cf. `SubtaskRowView`).
  @FocusState private var focusedSubtask: UUID?
  /// Dépliant de sous-tâches ouvert/fermé : permet de replier une longue checklist pour ne pas
  /// surcharger la tâche. ponytail: état éphémère (par vue de tâche), non persisté — se réinitialise
  /// à `true` au redémarrage. À porter sur `TaskItem` si l'on veut le mémoriser.
  @State private var subtasksExpanded = true

  @FocusState private var titleFocused: Bool
  @State private var hovering = false
  // Révélation du corps d'édition. `editorHeight` = sa hauteur naturelle mesurée (cache, sert de
  // cible d'ouverture) ; `editorReveal` = la hauteur RÉELLEMENT dévoilée (animée), 0 = fermé. On
  // anime la fenêtre qui découvre le contenu, jamais le contenu lui-même — il reste figé à sa place.
  @State private var editorHeight: CGFloat = 0
  @State private var editorReveal: CGFloat = 0
  // Le corps d'édition survit à la sortie de `isEditing` : `showEditor` le garde monté pendant la
  // fermeture animée (la fenêtre rétrécit, le clipping ravale le contenu), puis on le démonte pour
  // ne pas garder son NSTextView en vie. `editSession` annule un démontage programmé si une nouvelle
  // session d'édition démarre entre-temps (réouverture rapide).
  @State private var showEditor = false
  @State private var editSession = 0
  // Icône « note » au survol (tâche sans notes) : true entre le clic sur l'icône et l'ouverture de
  // l'édition, pour que le focus atterrisse dans les notes plutôt que dans le titre (cf.
  // `.onChange(of: isEditing)`). Retombe à false à la fin de CETTE édition, pas seulement après usage
  // — sinon une édition suivante ouverte autrement (double-clic) hériterait du focus notes.
  @State private var focusNotesOnAppear = false
  @State private var showReminderSheet = false
  // UN SEUL popover à la fois. Deux `.popover(isPresented:)` sur la même vue = comportement
  // indéfini sur macOS (le second plantait à l'ouverture de l'échéance). Un seul `.popover(item:)`
  // dont le contenu dépend du champ édité.
  @State private var activePicker: DateField?

  private enum DateField: String, Identifiable {
    case when, deadline
    var id: String { rawValue }
  }

  /// UN SEUL arbre de vues, jamais un if/else entre deux racines : c'est ce qui rend la
  /// transition fluide. La ligne titre (case + titre) est TOUJOURS là et garde son identité ;
  /// l'édition ne fait qu'ajouter le corps sous elle et grossir le padding. SwiftUI a donc une
  /// hauteur continue à animer — un if/else échangerait deux vues d'un coup, d'où le « snap ».
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        TaskCheckbox(isCompleted: task.isCompleted) {
          withAnimation(taskInsert) {
            task.toggleCompletion()
            if task.isCompleted { task.list?.moveToEndOfSection(task) }
          }
          Task { await remindersService.pushCompletion(for: task) }
          onCompletionChanged()
        }
        if !isEditing, showsDate { dateTag }
        // Durée estimée, à gauche du titre comme la date : ce sont les deux faces d'une même
        // décision (quand, et pour combien de temps). Rien tant que rien n'est estimé — la page
        // « Aujourd'hui » est le seul endroit qui réclame l'absence de durée.
        if !isEditing, let estimate = Estimate.label(task.estimateMinutes) {
          Text(estimate)
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        titleView
        if !isEditing && task.notes.isEmpty { noteHint }
        Spacer(minLength: 0)
        // À droite plutôt qu'en sous-titre : la ligne garde sa hauteur d'une seule ligne, donc la
        // même que dans une page de liste — l'ouverture de la carte d'édition reste continue.
        if !isEditing, let parentLabel {
          Text(parentLabel)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize()
        }
        if !isEditing, let onSchedule {
          Button(action: onSchedule) {
            Image(systemName: "plus.circle")
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
          .help("Faire aujourd'hui")
          .opacity(hovering ? 1 : 0)
        }
        if !isEditing { trailing }
      }

      // Aperçu de la note au repos : sa première ligne sous le titre. Disparaît en édition — le
      // corps d'édition ci-dessous prend le relais avec la note complète et modifiable.
      if !isEditing && !task.notes.isEmpty { notePreview }

      // Montée sur `showEditor`, pas `isEditing` : le corps reste affiché pendant la fermeture animée.
      if showEditor {
        // OUVERTURE **ET** FERMETURE PAR RÉVÉLATION, jamais par translation ni disparition sèche. Le
        // contenu (notes + actions) est posé UNE fois à sa place définitive sous le titre — `fixedSize`
        // lui garde sa hauteur naturelle — et ne bouge JAMAIS : c'est la fenêtre qui le découvre
        // (`frame(height: editorReveal)` + `clipped`, ancrée en haut) qui grandit puis rapetisse.
        // Ouverture : `editorReveal` 0 → hauteur mesurée (le contenu se dévoile du haut vers le bas).
        // Fermeture : hauteur → 0, le clipping ravale icônes puis notes (tout reste affiché, on ne
        // masque rien à la main). Une fois refermée et hors édition, le corps est démonté (cf.
        // `.onChange(of: isEditing)`) pour libérer son NSTextView.
        editorBody
          .padding(.top, 12)
          // Petite respiration sous les icônes, DANS la fenêtre révélée : l'éditeur n'est plus le bas
          // de la carte (le trait + les sous-tâches suivent), inutile d'y porter toute la marge basse.
          .padding(.bottom, 4)
          .fixedSize(horizontal: false, vertical: true)
          .background {
            GeometryReader { g in
              Color.clear.preference(key: EditorHeightKey.self, value: g.size.height)
            }
          }
          .frame(height: editorReveal, alignment: .top)
          .clipped()
          // Pas d'interaction hors édition : pendant la fermeture le contenu est encore là mais inerte.
          .allowsHitTesting(isEditing)
          .onPreferenceChange(EditorHeightKey.self) { h in
            guard h > 0 else { return }
            editorHeight = h
            // Ne (re)déployer QUE si l'on édite : sinon la mesure du contenu encore monté pendant la
            // fermeture rouvrirait la fenêtre. En édition : 1re mesure → déploie ; sinon suit le
            // contenu (notes multi-lignes tapées).
            guard isEditing else { return }
            if editorReveal == 0 {
              withAnimation(taskFlow) { editorReveal = h }
            } else {
              editorReveal = h
            }
          }
          .onAppear {
            // Réouverture (hauteur déjà en cache) : déployer tout de suite. Sinon la 1re mesure
            // ci-dessus s'en charge — l'un OU l'autre déclenche l'animation, jamais un saut.
            if isEditing, editorHeight > 0 {
              withAnimation(taskFlow) { editorReveal = editorHeight }
            }
          }
          .transition(.identity)
      }

      // Sous-tâches : montées au repos comme en édition, APRÈS l'éditeur de notes pour respecter
      // l'ordre titre → notes → sous-tâches. Séparées de ce qui précède (aperçu de note au repos,
      // éditeur de notes en édition) par un trait.
      if !task.orderedSubtasks.isEmpty {
        subtasksSection
      }
    }
    // Ajout/suppression d'une sous-tâche : `withAnimation` autour de la mutation ne suffit PAS —
    // SwiftData notifie le changement de relation hors de la transaction, la carte sautait donc à sa
    // nouvelle hauteur. On anime ici sur le compte, qui, lui, est observé au rendu.
    .animation(taskFlow, value: task.subtasks.count)
    // Borne le contenu aux limites de la ligne pendant que la carte s'ouvre/se referme.
    .clipped()
    // Décrue : une tâche que personne ne réveille s'efface. Posé sur le CONTENU seulement (avant
    // `.background`), pour que le fond de sélection reste franc — c'est la tâche qui pâlit, pas
    // le fait qu'elle soit sélectionnée. Pleine opacité dès qu'on l'édite : on la touche, elle
    // redevient nette le temps qu'on s'en occupe.
    .opacity(isEditing ? 1 : task.dormancyFade)
    .animation(.easeOut(duration: 0.2), value: isEditing)
    // Le padding grandit en édition : la hauteur de la carte s'ouvre autour du titre resté en place.
    // Sélection et normal partagent le même padding — le texte ne saute donc pas au clic simple.
    // Bas en édition : les sous-tâches sont désormais le dernier élément de la carte (après
    // l'éditeur), il leur faut une respiration jusqu'au bord bas.
    .padding(.top, isEditing ? 16 : 6)
    // Au repos, une tâche à sous-tâches finit sur une rangée de sous-tâche et non sur son titre :
    // il lui faut un peu plus de fond que les 6 pt d'une ligne simple.
    .padding(.bottom, isEditing ? 14 : (task.subtasks.isEmpty ? 6 : 10))
    .padding(.horizontal, isEditing ? 16 : rowInset)
    .background { rowBackground }
    .contentShape(Rectangle())
    // Survol : révèle le ••• à droite. Clic droit : même menu que le •••, via contentShape ;
    // bascule aussi en édition, via `RightClickObserver` posé par la page (cf. ce type).
    .onHover { hovering = $0 }
    .contextMenu { taskMenu }
    // Les deux sélecteurs de date sont posés sur la ligne (pas sur un bouton du menu, qui
    // disparaît hors survol) : ils ont ainsi toujours une ancre valide, en repos comme en édition.
    .popover(item: $activePicker, arrowEdge: .trailing) { field in
      switch field {
      case .when: whenPicker
      case .deadline: deadlinePicker
      }
    }
    .sheet(isPresented: $showReminderSheet) {
      SchedulePlannerView(task: task, remindersService: remindersService)
    }
    // Sélection / édition / réordonnancement sont pilotés par le geste UNIQUE posé par la page
    // (cf. `dragGesture(for:)`), pour que la sélection réagisse au mouseDown sans voler le drag.
    .onExitCommand(perform: onEndEditing)
    // Le champ titre existe déjà avant l'édition (même TextField) : le focus ne peut plus se
    // poser à son .onAppear. On le pose/retire au basculement d'état — sauf si l'édition a été
    // ouverte depuis l'icône « note » (`focusNotesOnAppear`), auquel cas le focus doit atterrir dans
    // les notes, pas dans le titre.
    // Tâche qui naît déjà en édition (création, insertion d'en-tête) : `onChange` ne se déclenche pas
    // (pas de transition false→true observée), on monte donc le corps ici.
    .onAppear { if isEditing { showEditor = true } }
    // Pas de sous-tâche vide : dès que le focus quitte une sous-tâche restée sans texte, on la
    // supprime (annule une création vide). Couvre aussi la fermeture de la tâche — le focus retombe
    // alors à `nil`, ce qui déclenche la vérification sur la dernière sous-tâche éditée.
    .onChange(of: focusedSubtask) { old, _ in deleteIfEmpty(old) }
    // Tâche cochée : le dépliant se referme tout seul — le détail de ce qui reste à faire n'a plus
    // d'intérêt une fois la tâche finie. Le rouvrir reste possible d'un clic sur le chevron.
    .onChange(of: task.isCompleted) { _, done in
      if done { withAnimation(.easeInOut(duration: 0.2)) { subtasksExpanded = false } }
    }
    .onChange(of: isEditing) { _, editing in
      if editing {
        // Nouvelle session : (ré)affiche le corps et invalide un démontage en attente (réouverture
        // pendant la fermeture animée).
        editSession += 1
        showEditor = true
        titleFocused = !focusNotesOnAppear
        // Réouverture alors que le corps est encore monté (fermeture en cours) : `onAppear` ne
        // rejoue pas, on redéploie ici. La 1re ouverture passe, elle, par la mesure (onPreferenceChange).
        if editorHeight > 0 { withAnimation(taskFlow) { editorReveal = editorHeight } }
      } else {
        titleFocused = false
        focusNotesOnAppear = false
        // Fermeture ANIMÉE : la fenêtre rétrécit (le clipping ravale notes + icônes, laissés
        // affichés), puis on démonte le corps une fois à 0 — sauf si une nouvelle session a redémarré.
        editSession += 1
        let token = editSession
        withAnimation(taskFlow) { editorReveal = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
          if token == editSession { showEditor = false }
        }
      }
    }
    // Pas de .animation(value:) ici : les transitions sont déclenchées en explicite
    // (withAnimation) côté page. Une ligne au repos ne porte donc rien à animer → fluide.
  }

  // MARK: Titre

  /// Le titre est UN SEUL et même `TextField` pour le repos (tâche active) ET l'édition : aucune
  /// bascule d'identité de vue entre les deux, donc SwiftUI n'échange rien. C'est ce qui
  /// supprime l'impression de « rechargement » — un `Text` au repos puis un `TextField` en
  /// édition sont deux types distincts que SwiftUI détruit/recrée en fondu croisé, d'où le
  /// shimmer sur une donnée pourtant identique.
  ///
  /// Au repos le champ ne capte pas les clics (`allowsHitTesting(false)`) : le clic va à la ligne
  /// (sélection), pas au curseur. Seule exception, une tâche complétée au repos : un `TextField`
  /// ne sait pas barrer son contenu, on rend alors un `Text` barré — cas hors de la transition.
  /// Titre : TOUJOURS le même `TextField`, y compris pour une tâche complétée. Aucune bascule
  /// `Text` ↔ `TextField` — ce qui garantit une identité de vue stable (pas de shimmer) ET une
  /// gestion clavier cohérente : un champ recréé à l'édition d'une tâche complétée avait un field
  /// editor « frais » qui avalait le premier Échap, d'où le double appui pour fermer.
  /// Le barré (qu'un `TextField` ne rend pas sur son contenu) est tracé en overlay au repos.
  private var titleView: some View {
    TextField("Nouvelle tâche", text: $task.title)
      .textFieldStyle(.plain)
      .font(.body)
      .foregroundStyle(titleColor)
      .focused($titleFocused)
      .allowsHitTesting(isEditing)
      .onSubmit(onEndEditing)
      .overlay(alignment: .leading) {
        if task.isCompleted && !isEditing {
          // Trait de barré, dimensionné par un Text fantôme de même contenu/police.
          Text(task.title).font(.body).hidden()
            .overlay(Rectangle().frame(height: 1).foregroundStyle(.secondary))
        }
      }
  }

  private var titleColor: HierarchicalShapeStyle {
    task.isCompleted ? .secondary : (task.title.isEmpty ? .tertiary : .primary)
  }

  // MARK: Corps d'édition

  private var editorBody: some View {
    VStack(alignment: .leading, spacing: 12) {
      notesField

      HStack(spacing: 16) {
        Spacer(minLength: 0)
        dateControl
        // ponytail: tags décoratif pour l'instant (présent dans le visuel Things demandé).
        // À brancher quand le modèle le portera.
        actionIcon("tag")
        // Reste en place (la rangée d'icônes ne bouge pas) mais devient inerte dès la première
        // sous-tâche : c'est le « + » de l'en-tête du dépliant qui prend alors le relais.
        Button(action: addNewSubtask) {
          actionIcon("list.bullet")
        }
        .buttonStyle(.plain)
        .disabled(!task.subtasks.isEmpty)
        priorityControl
      }
    }
  }

  /// `TextEditor` (et pas un `TextField`, cf. `notesBox` de la page de liste) : un `TextField`
  /// multiligne (`axis: .vertical`) n'insère pas de vrai retour à la ligne sur Entrée/Maj+Entrée,
  /// seul `TextEditor` le fait nativement. Aligné sous le titre (case 16 + espace 10), pas sous
  /// la case.
  private var notesField: some View {
    ZStack(alignment: .topLeading) {
      if task.notes.isEmpty {
        // Aucun retrait propre : le retrait est posé une seule fois sur le ZStack (padding
        // commun ci-dessous), donc le placeholder part exactement du même x que le texte tapé.
        Text("Notes")
          .foregroundStyle(.tertiary)
          .allowsHitTesting(false)
      }
      RichTextEditor(
        data: $task.notes,
        font: .systemFont(ofSize: NSFont.systemFontSize),
        textColor: .labelColor,
        // Entrée valide la tâche (comme le titre) plutôt que d'ouvrir une ligne dans la note :
        // le retour à la ligne reste possible, mais seulement via Maj+Entrée.
        handleReturn: { shiftHeld in
          guard !shiftHeld else { return false }
          onEndEditing()
          return true
        },
        autoFocus: focusNotesOnAppear
      )
      .fixedSize(horizontal: false, vertical: true)
    }
    .font(.body)
    .foregroundStyle(.secondary)
    .padding(.leading, 26)
  }

  // MARK: Fond

  /// UN SEUL fond pour les trois états, jamais deux formes qui se remplacent — c'est ce qui rend
  /// la transition select→édition fluide (la pilule GRANDIT en carte au lieu qu'une carte d'une
  /// autre forme apparaisse par-dessus). La même `RoundedRectangle` est toujours là ; seuls des
  /// nombres varient, et comme la bascule d'état est enveloppée d'un `withAnimation` côté page,
  /// SwiftUI les interpole :
  /// - `cornerRadius` 8 → 14 : le coin s'ouvre en même temps que la hauteur.
  /// - calque lavande : visible en SÉLECTION SEULE (`isSelected && !isEditing`), jamais sous la
  ///   carte. S'il restait à pleine opacité pendant l'édition, la fermeture (blanc + lavande qui
  ///   s'effacent ensemble) le laisserait transparaître une fraction de seconde sous le blanc qui
  ///   part → un flash « edit → select → normal ». Caché en édition, il n'a rien à révéler.
  /// - calque blanc : ne monte qu'en édition, par-dessus le lavande → à l'ouverture la pilule
  ///   « devient » carte (crossfade lavande→blanc sur le même rect qui grandit).
  /// - bordure : ne se révèle qu'en édition.
  /// On n'interpole PAS entre deux `Color` dynamiques (lavande accent ↔ blanc système), ce qui
  /// scintille ; on anime l'OPACITÉ de calques à couleur fixe, c'est stable.
  ///
  /// L'ombre reste à zéro hors édition : un `.shadow` réellement rendu sur chaque ligne force un
  /// rendu offscreen et fait saccader le scroll. À couleur `.clear` / rayon 0, Core Animation
  /// court-circuite la passe d'ombre — le coût n'existe que sur la ligne éditée (une seule à la fois).
  /// ponytail: si le scroll saccade malgré le rayon nul, remettre l'ombre derrière un garde d'état.
  private var rowBackground: some View {
    let radius: CGFloat = isEditing ? 14 : 8
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    return ZStack {
      shape.fill(thingsSelectionFill).opacity(isSelected && !isEditing ? 1 : 0)
      shape.fill(Color(nsColor: .controlBackgroundColor)).opacity(isEditing ? 1 : 0)
      shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        .opacity(isEditing ? 1 : 0)
    }
    .shadow(
      color: .black.opacity(isEditing ? 0.18 : 0),
      radius: isEditing ? 12 : 0, y: isEditing ? 4 : 0)
  }

  // MARK: Date

  /// Tag de jour planifié (`when`), à GAUCHE du titre (cf. Things) : petit fond gris arrondi,
  /// « 31 juil. ». Distinct de l'échéance (drapeau, à droite). Rien si aucune date.
  @ViewBuilder
  private var dateTag: some View {
    if let when = task.when {
      TokenPill(text: when.formatted(.dateTime.day().month(.abbreviated)))
    }
  }

  private var dateControl: some View {
    Button {
      activePicker = .when
    } label: {
      actionIcon("calendar", active: task.when != nil)
    }
    .buttonStyle(.plain)
  }

  /// Contenu du sélecteur « Quand » (jour planifié). Posé en popover sur la ligne.
  private var whenPicker: some View {
    VStack(spacing: 10) {
      DatePicker(
        "",
        // La tâche n'a pas forcément de date : le picker en exige une. Aujourd'hui
        // sert de point de départ, écrit seulement si l'utilisateur choisit.
        selection: Binding(get: { task.when ?? Date() }, set: { task.when = $0 }),
        displayedComponents: .date
      )
      .datePickerStyle(.graphical)
      .labelsHidden()

      if task.when != nil {
        Divider()
        Button("Retirer la date") {
          task.when = nil
          task.hasTime = false
          activePicker = nil
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
    .padding(12)
  }

  // MARK: Échéance

  /// Contenu du sélecteur « Échéance » (deadline). Même gabarit que `whenPicker`.
  private var deadlinePicker: some View {
    VStack(spacing: 10) {
      DatePicker(
        "",
        selection: Binding(get: { task.deadline ?? Date() }, set: { task.deadline = $0 }),
        displayedComponents: .date
      )
      .datePickerStyle(.graphical)
      .labelsHidden()

      if task.deadline != nil {
        Divider()
        Button("Retirer l'échéance") {
          task.deadline = nil
          activePicker = nil
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
    .padding(12)
  }

  /// Badge d'échéance à droite de la ligne (cf. Things) : un drapeau + une date relative,
  /// rouge une fois l'échéance atteinte ou passée, gris sinon.
  @ViewBuilder
  private var deadlineBadge: some View {
    if let deadline = task.deadline {
      let overdue = daysUntil(deadline) <= 0
      HStack(spacing: 4) {
        Image(systemName: "flag.fill").font(.system(size: 11))
        Text(deadlineLabel(deadline)).font(.callout)
      }
      .foregroundStyle(overdue ? Color.red : Color.secondary)
    }
  }

  private func daysUntil(_ date: Date) -> Int {
    let cal = Calendar.current
    return cal.dateComponents(
      [.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)
    ).day ?? 0
  }

  private func deadlineLabel(_ date: Date) -> String {
    switch daysUntil(date) {
    case 0: return "aujourd'hui"
    case 1: return "dans 1 jour"
    case let d where d > 1: return "dans \(d) jours"
    case -1: return "hier"
    case let d: return "il y a \(-d) jours"
    }
  }

  private var subtasksSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      // Dans le VStack (donc décalé comme lui) : le trait part de l'anneau de progression, pas de
      // la case de la tâche parente — il ouvre le bloc sous-tâches au lieu de couper la carte.
      Divider().padding(.bottom, 2)
      subtasksHeader
      // En édition, toujours tout afficher (on manipule les sous-tâches) ; en mode normal, le repli
      // est piloté par `subtasksExpanded`.
      if isEditing || subtasksExpanded {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(task.orderedSubtasks, id: \.uuid) { subtask in
            SubtaskRowView(
              subtask: subtask,
              isEditing: isEditing,
              focus: $focusedSubtask,
              onEnter: { enterOnSubtask(subtask) },
              onDelete: { removeSubtask(subtask) }
            )
            // La rangée se fond en glissant depuis le haut pendant que la carte s'ouvre ; sans
            // transition elle apparaît nette d'un coup au milieu d'une hauteur encore en mouvement.
            .transition(.opacity.combined(with: .move(edge: .top)))
          }
        }
      }
    }
    // Le bloc entier (trait + en-tête) naît avec la 1re sous-tâche : même fondu.
    .transition(.opacity)
    // Aligné sur le DÉBUT DU TEXTE du titre (case 16 + espace 10 = 26), comme l'aperçu de note :
    // trait, anneau et cases des sous-tâches partent tous de cette colonne.
    .padding(.leading, 26)
    .padding(.top, 14)
  }

  /// En-tête du dépliant, sur une ligne : anneau de progression + « fait/total », un « + » (en
  /// édition) pour ajouter une sous-tâche, et à droite le chevron pour déplier/replier.
  private var subtasksHeader: some View {
    let total = task.subtasks.count
    let done = task.subtasks.filter(\.isDone).count
    return HStack(spacing: 8) {
      SubtaskProgressRing(fraction: total == 0 ? 0 : Double(done) / Double(total))
        .frame(width: 13, height: 13)
      Text("\(done)/\(total) sous-tâches")
        .font(.body.weight(.semibold))
        .foregroundStyle(.primary)
        .monospacedDigit()
      if isEditing {
        Button(action: addNewSubtask) {
          Image(systemName: "plus")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      Spacer(minLength: 0)
      // Chevron de repli UNIQUEMENT en mode normal : en édition la liste est toujours dépliée.
      if !isEditing {
        Button {
          withAnimation(.easeInOut(duration: 0.2)) { subtasksExpanded.toggle() }
        } label: {
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(subtasksExpanded ? 90 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
  }

  /// Ajoute une sous-tâche vide, déplie le dépliant (pour la voir) et pose le focus dessus.
  /// `withAnimation` : sans lui la carte saute à sa nouvelle hauteur (la mutation SwiftData tombe
  /// hors transaction animée) — cf. `removeSubtask`/`deleteIfEmpty`, même raison.
  private func addNewSubtask() {
    withAnimation(taskFlow) {
      subtasksExpanded = true
      focusedSubtask = task.addSubtask().uuid
    }
  }

  /// Entrée sur une sous-tâche : vide → termine (défocalise) ; non vide → nouvelle sous-tâche + focus.
  /// ponytail: la nouvelle va toujours en FIN (pas d'insertion au milieu) — sans réordonnancement,
  /// le flux « taper, Entrée, taper » reste toujours sur la dernière, donc « en dessous » en pratique.
  private func enterOnSubtask(_ subtask: Subtask) {
    if subtask.title.trimmingCharacters(in: .whitespaces).isEmpty {
      focusedSubtask = nil
    } else {
      focusedSubtask = task.addSubtask().uuid
    }
  }

  /// Suppression d'une sous-tâche (corbeille au survol ou clic droit).
  private func removeSubtask(_ subtask: Subtask) {
    withAnimation(taskFlow) { modelContext.delete(subtask) }
  }

  /// Supprime la sous-tâche d'uuid donné si son titre est vide (appelé au départ du focus). Suppression
  /// d'un SEUL objet retrouvé par uuid — pas d'énumération de `task.subtasks` pendant la mutation
  /// (le piège qui a causé le crash `_maintainInverseRelationship`).
  private func deleteIfEmpty(_ uuid: UUID?) {
    guard let uuid,
      let subtask = task.subtasks.first(where: { $0.uuid == uuid }),
      subtask.title.trimmingCharacters(in: .whitespaces).isEmpty
    else { return }
    withAnimation(taskFlow) { modelContext.delete(subtask) }
  }

  // MARK: Actions au survol / clic droit

  /// Icône discrète révélée au survol quand la tâche n'a pas encore de notes : sans elle,
  /// l'existence même du champ notes (caché derrière un double-clic) n'est pas devinable. Un clic
  /// ouvre directement l'édition avec le focus posé dans les notes (cf. `focusNotesOnAppear`).
  private var noteHint: some View {
    Button {
      focusNotesOnAppear = true
      onBeginEditing()
    } label: {
      Image(systemName: "note.text")
        .font(.system(size: 12, weight: .regular))
        .foregroundStyle(.tertiary)
    }
    .buttonStyle(.plain)
    .opacity(hovering ? 1 : 0)
    .animation(.easeOut(duration: 0.15), value: hovering)
  }

  /// Aperçu de la note au repos : sa première ligne en gris, tronquée. Rappelle le CONTENU de la
  /// note sans l'ouvrir — une simple icône dirait juste « il y en a une », pas ce qu'elle contient.
  /// Aligné sous le titre (case 16 + espace 10 = 26), comme le champ d'édition. Une ligne : les
  /// retours à la ligne sont repliés en amont (cf. `NotesCodec.plainText`).
  private var notePreview: some View {
    Text(NotesCodec.plainText(task.notes))
      .font(.body)
      .foregroundStyle(.primary)
      .lineLimit(1)
      .truncationMode(.tail)
      .padding(.leading, 26)
  }

  /// Zone de droite, collée au bord. Badge d'échéance et menu ••• sont SUPERPOSÉS (ZStack), pas
  /// côte à côte : le badge n'a donc aucun espace réservé à sa droite (le ••• ne le pousse plus).
  /// Au survol, le badge GLISSE vers la gauche pour libérer la place du •••, qui apparaît en fondu
  /// tout à droite — comme Things. Le badge reste donc lisible pendant qu'on pointe la ligne.
  /// L'animation est bornée à `value: hovering` : elle ne se recalcule qu'au survol, pas au scroll.
  private var trailing: some View {
    ZStack(alignment: .trailing) {
      deadlineBadge.offset(x: hovering ? -26 : 0)
      Menu {
        taskMenu
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .contentShape(Rectangle())
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .opacity(hovering ? 1 : 0)
    }
    .animation(.easeOut(duration: 0.15), value: hovering)
  }

  /// Cibles de classement groupées par projet, les listes libres en dernier — un projet est ce
  /// qu'on cherche d'abord quand on range une tâche qui traîne. `filter` plutôt qu'un `sorted` :
  /// le tri de Swift n'est pas stable, il aurait mélangé l'ordre des projets entre eux.
  private var targetsByProject: [(project: String?, lists: [TodoList])] {
    var order: [String?] = []
    var buckets: [String?: [TodoList]] = [:]
    for target in moveTargets {
      let key = target.project?.title
      if buckets[key] == nil { order.append(key) }
      buckets[key, default: []].append(target)
    }
    let sorted = order.filter { $0 != nil } + order.filter { $0 == nil }
    return sorted.map { (project: $0, lists: buckets[$0] ?? []) }
  }

  /// Menu partagé par le ••• et le clic droit.
  @ViewBuilder
  private var taskMenu: some View {
    Button {
      activePicker = .when
    } label: {
      Label("Quand…", systemImage: "calendar")
    }
    Menu {
      if moveTargets.isEmpty {
        Text("Aucune autre liste")
      } else {
        ForEach(targetsByProject, id: \.project) { group in
          // Un projet ne porte pas de tâche directement (cf. `Project`) : l'« assigner à un
          // projet » revient à choisir l'une de ses listes, d'où le sous-menu.
          if let project = group.project {
            Menu(project) {
              ForEach(group.lists) { target in
                Button(target.title) { onMove(target) }
              }
            }
          } else {
            ForEach(group.lists) { target in
              Button(target.title) { onMove(target) }
            }
          }
        }
      }
    } label: {
      // Une tâche sans projet n'est pas « déplacée », elle est CLASSÉE — c'est le geste qui
      // manquait à la page « Tâches », où tout le non-classé arrive.
      Label(
        task.project == nil ? "Assigner la tâche" : "Déplacer vers…", systemImage: "arrow.right")
    }
    Button {
      activePicker = .deadline
    } label: {
      Label("Échéance…", systemImage: "flag")
    }
    // Durée estimée : elle n'a d'effet visible que dans « Aujourd'hui » (la barre de capacité),
    // mais elle se pose ici, là où l'on planifie.
    Menu {
      ForEach(Estimate.presets, id: \.self) { minutes in
        Button(Estimate.label(minutes) ?? "") { task.estimateMinutes = minutes }
      }
      if task.estimateMinutes > 0 {
        Divider()
        Button("Retirer la durée") { task.estimateMinutes = 0 }
      }
    } label: {
      Label("Durée…", systemImage: "timer")
    }
    Button {
      showReminderSheet = true
    } label: {
      Label(
        task.reminderIdentifier == nil ? "Envoyer vers Rappels…" : "Modifier le rappel…",
        systemImage: "bell")
    }
    Divider()
    Button {
      onDuplicate()
    } label: {
      Label("Dupliquer", systemImage: "plus.square.on.square")
    }
    Button(role: .destructive) {
      onDelete()
    } label: {
      Label("Supprimer", systemImage: "trash")
    }
  }

  // MARK: Priorité

  private var priorityControl: some View {
    Menu {
      // `.none` est dans allCases : il fait office de « retirer », pas besoin d'un bouton
      // séparé.
      ForEach(Priority.allCases) { priority in
        Button {
          task.priority = priority
        } label: {
          Label(priority.label, systemImage: priority.systemImage)
        }
      }
    } label: {
      actionIcon("flag", active: task.priority != .none, tint: task.priority.color)
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }

  /// Icône de la rangée d'actions : éteinte tant que rien n'est défini, teintée dès qu'une
  /// valeur existe.
  private func actionIcon(_ name: String, active: Bool = false, tint: Color? = nil) -> some View {
    Image(systemName: name)
      .font(.system(size: 15))
      .foregroundStyle(
        active
          ? (tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(Color.accentColor))
          : AnyShapeStyle(.secondary)
      )
      .frame(width: 22, height: 22)
      .contentShape(Rectangle())
  }
}

/// En-tête de section dans la liste. La pilule lavande (ou teintée si une `HeaderColor` est
/// choisie) est TOUJOURS visible, repos comme sélection/édition — ce n'est plus un indicateur de
/// sélection mais l'apparence permanente de l'en-tête. Le ••• apparaît au survol ou en
/// sélection/édition ; en édition le champ devient actif + focus (curseur de saisie).
/// - **drag** : la pilule est portée sous le curseur, avec DERRIÈRE elle des calques en cascade
///   (un par tâche rattachée, plafonné à 3, de plus en plus petits et pâles) et, en haut à gauche,
///   une bulle rouge portant le nombre RÉEL de tâches emportées.
private struct HeaderRow: View {
  @Bindable var task: TaskItem
  let isSelected: Bool
  let isEditing: Bool
  let isDragging: Bool
  /// Nombre réel de tâches rattachées, connu seulement pendant le drag (0 sinon).
  let attachedTaskCount: Int
  /// Autres listes où déplacer l'en-tête (et son bloc). Vide ⇒ entrée de menu désactivée.
  let moveTargets: [TodoList]
  var onEndEditing: () -> Void
  var onMove: (TodoList) -> Void
  var onCopy: () -> Void
  var onDelete: () -> Void

  @FocusState private var titleFocused: Bool
  @State private var hovering = false
  /// Bascule brièvement l'icône de copie en checkmark après un clic, pour confirmer visuellement
  /// que le texte est bien dans le presse-papiers (sinon rien à l'écran ne le montre).
  @State private var copied = false

  /// Cascade du drag : décalage vertical d'un calque et retrait horizontal (plus étroit, centré) par
  /// niveau. Couleurs OPAQUES, du même bleu, de plus en plus claires — assez SATURÉES pour se lire
  /// comme des cartes (des tons quasi blancs ne montraient que leur ombre → aspect brouillon).
  private static let layerStep: CGFloat = 7
  private static let layerInset: CGFloat = 6

  /// Marges de la RANGÉE autour de la pilule. Nommées parce que `dragPlaceholderRect` les retire :
  /// une en-tête, contrairement à une tâche, porte ses marges À L'EXTÉRIEUR de son fond — le trou
  /// d'insertion doit valoir la pilule qu'on transporte, pas la rangée qui la contient.
  static let topInset: CGFloat = 20
  static let bottomInset: CGFloat = 4

  /// Les trois teintes de la cascade, du calque le plus proche au plus lointain.
  ///
  /// Elles doivent rester OPAQUES (les calques se recouvrent : la moindre translucidité les ferait
  /// transparaître les uns à travers les autres), donc figées, donc à doubler pour le mode sombre —
  /// même contrainte et même solution que `SidebarView.rowFill`. Sans ce doublon, tout le drag
  /// d'en-tête s'affichait en bleu pâle de mode clair par-dessus une page sombre.
  ///
  /// Les valeurs claires sont celles de la maquette Things. Les sombres ne sont pas inventées : ce
  /// sont les équivalents OPAQUES de la pilule AU REPOS en sombre (`thingsSelectionFill`, soit
  /// l'accent à 28 % sur le fond de page), déclinés dans les mêmes proportions que les claires. La
  /// pilule tirée garde donc exactement la teinte perçue qu'elle a au repos, et le titre en accent
  /// y conserve la lisibilité qu'il avait déjà — aucun pari de contraste à prendre.
  private static let dragTop = dragLayer(light: 0xCA_E1FF, dark: 0x18_3A5D)
  private static let dragLayer1 = dragLayer(light: 0xDC_EAFF, dark: 0x1A_3149)
  private static let dragLayer2 = dragLayer(light: 0xEA_F1FF, dark: 0x1C_2937)

  private static func dragLayer(light: Int, dark: Int) -> Color {
    func srgb(_ hex: Int) -> NSColor {
      NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1)
    }
    return Color(
      nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? srgb(dark) : srgb(light)
      })
  }

  var body: some View {
    let active = isSelected || isEditing
    // Calques DERRIÈRE l'en-tête : 2 au plus, pour un total de 3 avec l'en-tête (elle + deux calques
    // de plus en plus transparents). Le compte réel vit dans la bulle rouge, pas dans la pile.
    let layers = min(max(attachedTaskCount, 0), 2)
    VStack(alignment: .leading, spacing: 6) {
      ZStack(alignment: .topLeading) {
        // Calques en cascade DERRIÈRE la pilule (dessinés avant elle), décalés vers le bas et
        // rétrécis. Chacun est une pilule périwinkle OPAQUE globalement atténuée : nettement visible
        // (pas noyée comme un simple lavande translucide) mais de plus en plus transparente.
        if isDragging {
          // Du plus LOINTAIN au plus proche : le calque le plus décalé/clair est dessiné en premier
          // (donc DERRIÈRE), sinon il passait par-dessus le plus proche et la cascade s'inversait.
          ForEach(Array((0..<layers).reversed()), id: \.self) { i in
            let step = CGFloat(i + 1)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(i == 0 ? Self.dragLayer1 : Self.dragLayer2)
              // Plus étroit (centré) + décalé vers le bas → l'empilement de papiers. Ombre propre et
              // douce par calque : chaque carte se détache de celle du dessous, proprement.
              .padding(.horizontal, step * Self.layerInset)
              .offset(y: step * Self.layerStep)
              .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
              // Apparition/disparition NETTE (pas de fondu) : au drop, un fondu de sortie suivrait
              // l'en-tête en vol et se lirait comme une doublure fantôme.
              .transition(.identity)
          }
        }
        pill(active: active)
      }
    }
    .padding(.top, Self.topInset)
    .padding(.bottom, Self.bottomInset)
    // Bulle rouge du compte réel, en haut à gauche de la pilule (elle déborde le coin).
    .overlay(alignment: .topLeading) {
      if isDragging && attachedTaskCount > 0 {
        Text("\(attachedTaskCount)")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.white)
          .frame(minWidth: 20, minHeight: 20)
          .background(Circle().fill(Color.red))
          .offset(x: -6, y: 12)
          .transition(.identity)  // disparaît net au drop, pas de fondu fantôme
      }
    }
    .contentShape(Rectangle())
    .onHover { hovering = $0 }
    // Le champ existe déjà au repos : le focus ne peut se poser à son .onAppear. On le pose/retire
    // au basculement d'état (comme TaskRow).
    .onChange(of: isEditing) { _, editing in titleFocused = editing }
  }

  /// Le corps de l'en-tête : titre + menu, sur une pilule lavande quand elle est active.
  private func pill(active: Bool) -> some View {
    HStack(spacing: 8) {
      // TOUJOURS le même TextField (repos comme édition) : identité de vue stable, pas de bascule
      // Text↔TextField qui « recharge » le titre. Au repos il ne capte pas les clics — ils vont au
      // geste de la page (sélection, drag) — et l'édition le rend actif + focus (curseur).
      TextField("Nouvel en-tête", text: $task.title)
        .textFieldStyle(.plain)
        .font(.headline)
        .foregroundStyle((task.headerColor?.color ?? Color.accentColor).opacity(0.85))
        .focused($titleFocused)
        .allowsHitTesting(isEditing)
        .onSubmit(onEndEditing)
      Spacer(minLength: 0)
      // Copie texte du bloc entier (en-tête + tâches rattachées) dans le presse-papiers, sans
      // passer par le menu ; mêmes conditions d'apparition que le •••, juste à sa gauche. Checkmark
      // temporaire au clic : la copie est silencieuse côté système, sans ce retour rien ne confirme
      // à l'utilisateur qu'elle a eu lieu.
      Button {
        onCopy()
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
      } label: {
        Image(systemName: copied ? "checkmark" : "doc.on.doc")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
          // Largeur figée : "doc.on.doc" et "checkmark" n'ont pas la même largeur intrinsèque, sans
          // ce cadre la pilule respire d'un pixel ou deux au moment du bascule.
          .frame(width: 16, height: 16)
      }
      .buttonStyle(.plain)
      .opacity((hovering || active || copied) && !isDragging ? 1 : 0)
      .animation(.easeOut(duration: 0.15), value: copied)
      .help("Copier l'en-tête et ses tâches")
      Menu {
        menuItems
      } label: {
        Image(systemName: "ellipsis")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(Color.accentColor.opacity(0.85))
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      // ••• visible en survol et à l'état actif, mais pas pendant le drag (la pilule est en vol).
      .opacity((hovering || active) && !isDragging ? 1 : 0)
    }
    .padding(.vertical, 6)
    .padding(.horizontal, rowInset)
    .background {
      // La pilule est TOUJOURS visible (plus un indicateur de sélection) : c'est l'apparence
      // permanente de l'en-tête. Pendant le drag, l'en-tête est le calque du DESSUS de la
      // cascade : couleur OPAQUE dédiée (#CAE1FF), sinon les calques derrière transparaissent à
      // travers. Hors drag, le lavande translucide (comme une tâche sélectionnée) suffit, ou la
      // teinte choisie si définie. Ombre de soulevé seulement au drag.
      // ponytail: opacité fixe (0.22) plutôt que le double palier clair/sombre de
      // `thingsSelectionFill` — à aligner si l'écart se voit trop en mode sombre.
      let tinted = task.headerColor.map { AnyShapeStyle($0.color.opacity(0.22)) }
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(
          isDragging
            ? AnyShapeStyle(Self.dragTop) : (tinted ?? AnyShapeStyle(thingsSelectionFill))
        )
        .shadow(color: .black.opacity(isDragging ? 0.14 : 0), radius: 6, y: 3)
    }
    // Clic droit = le même jeu d'actions que le •••, qui n'apparaît qu'au survol : sans ça,
    // supprimer une en-tête demandait de viser un bouton invisible au repos.
    .contextMenu { menuItems }
  }

  /// Les actions d'une en-tête, écrites une fois pour ses deux points d'entrée (••• et clic droit).
  @ViewBuilder private var menuItems: some View {
    Menu("Couleur") {
      Button("Par défaut") { task.headerColor = nil }
      ForEach(HeaderColor.allCases) { option in
        Button {
          task.headerColor = option
        } label: {
          Label(option.label, systemImage: "circle.fill")
            .foregroundStyle(option.color)
        }
      }
    }
    Menu {
      if moveTargets.isEmpty {
        Text("Aucune autre liste")
      } else {
        ForEach(moveTargets) { target in
          Button(target.title) { onMove(target) }
        }
      }
    } label: {
      Text("Déplacer vers…")
    }
    Divider()
    Button("Supprimer", role: .destructive, action: onDelete)
  }
}

/// Case à cocher façon Things : un carré à coin arrondi, vide et cerné d'un filet gris ;
/// rempli en accent avec une coche blanche une fois complété.
///
/// Custom et pas `.toggleStyle(.checkbox)` : la case native de macOS 26 est un carré **plein**,
/// impossible d'en tirer ce rendu par un simple restylage.
struct TaskCheckbox: View {
  let isCompleted: Bool
  /// Sous-tâche = cercle ; tâche = rectangle arrondi (défaut). Même case, seule la forme change :
  /// on ne duplique pas le tracé du check animé, le bounce ni le curseur main.
  var circular: Bool = false
  var onToggle: () -> Void

  private static let size: CGFloat = 16

  var body: some View {
    Button(action: onToggle) {
      // Forme branchée UNE fois en gardant un type `InsettableShape` concret (Circle /
      // RoundedRectangle) : `.strokeBorder` (trait posé À L'INTÉRIEUR du contour, cf. le rendu
      // Things d'origine) n'existe que sur `InsettableShape`, pas sur un `AnyShape` type-effacé.
      Group {
        if circular {
          fillAndBorder(Circle())
        } else {
          fillAndBorder(RoundedRectangle(cornerRadius: 4.5, style: .continuous))
        }
      }
      .overlay {
        // `.trim` = strokeEnd de Core Animation exposé en SwiftUI : le trait se *trace*
        // (0→1) au lieu d'apparaître. lineCap/Join .round pour la même douceur que Things.
        Checkmark()
          .trim(from: 0, to: isCompleted ? 1 : 0)
          .stroke(.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
          .frame(width: Self.size * 0.55, height: Self.size * 0.55)
      }
      .frame(width: Self.size, height: Self.size)
      .contentShape(Rectangle())
    }
    // Bounce au press/release via un ButtonStyle dédié ; le tracé + le fond restent animés par le
    // withAnimation de la page.
    .buttonStyle(PressBounceButtonStyle())
    .animation(.bouncy(duration: 0.3, extraBounce: 0.15), value: isCompleted)
    // PAS `.onHover` + `NSCursor.set()` : cette case vit DANS une ligne qui a déjà son propre
    // `.onHover` ; les cursor rects AppKit sont résolus par la fenêtre à partir de la géométrie.
    .overlay { PointingHandCursorArea().allowsHitTesting(false) }
  }

  /// Fond + bordure d'une case, génériques sur la forme concrète (donc `.strokeBorder` disponible).
  /// Bordure et fond coexistent en permanence (opacité pilotée par isCompleted) : pas de `if` qui
  /// insère/retire une vue, sinon l'anim n'aurait rien à interpoler.
  private func fillAndBorder<S: InsettableShape>(_ shape: S) -> some View {
    shape
      .fill(isCompleted ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
      .overlay {
        shape
          .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1)
          .opacity(isCompleted ? 0 : 1)
      }
  }
}

/// Curseur « main » fiable sur une zone précise, via les cursor rects AppKit natifs — cf. le
/// commentaire sur `TaskCheckbox`. `resetCursorRects()` est appelé par AppKit lui-même à chaque
/// invalidation de layout, pas par un `.onHover` concurrent d'une vue englobante.
private struct PointingHandCursorArea: NSViewRepresentable {
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
private struct RightClickObserver: NSViewRepresentable {
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
private struct LeftClickOutsideObserver: NSViewRepresentable {
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
private struct DeleteKeyMonitor: NSViewRepresentable {
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
private struct KeyCommandMonitor: NSViewRepresentable {
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

/// Le chemin du check, en proportions de son cadre (dessiné du bras court vers le bras long, sens
/// dans lequel `.trim` le trace). Aucun SF Symbol ne sait se *tracer* — d'où le Path maison.
private struct Checkmark: Shape {
  func path(in rect: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: rect.minX + rect.width * 0.20, y: rect.minY + rect.height * 0.52))
    p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.74))
    p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.80, y: rect.minY + rect.height * 0.28))
    return p
  }
}

/// Rétrécit tant que le bouton est maintenu, puis rebondit au relâchement (spring peu amorti →
/// léger dépassement). C'est le « bounce au clic » de Things, sans dépendre de la pression réelle.
private struct PressBounceButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.8 : 1)
      .animation(.spring(response: 0.3, dampingFraction: 0.45), value: configuration.isPressed)
  }
}

/// Position de repos de chaque ligne (par `persistentModelID`), collectée par préférence pendant le
/// layout et lue pour calculer où ouvrir le trou pendant un réordonnancement (cf. `dragTargets`).
/// Un bloc = une en-tête (optionnelle) et les tâches qui la suivent jusqu'à la prochaine en-tête.
/// Le bloc « top » (en-tête nil) réunit les tâches d'avant la première en-tête, ou toute la liste
/// s'il n'y a aucune en-tête.
private struct TaskBlock: Identifiable {
  let id: String
  let header: TaskItem?
  let tasks: [TaskItem]

  /// Les lignes du bloc dans l'ordre (en-tête d'abord si présente), pour le drag d'un bloc entier.
  var items: [TaskItem] { (header.map { [$0] } ?? []) + tasks }
  var rowCount: Int { (header == nil ? 0 : 1) + tasks.count }
}

/// Hauteur naturelle du corps d'édition d'une tâche (notes + rangée d'actions), pour animer sa
/// RÉVÉLATION — la fenêtre qui s'ouvre — sans faire bouger le contenu. Une seule tâche est éditée à
/// la fois, donc une seule valeur en vol ; `max` par prudence si deux mesures se chevauchent.
private struct EditorHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// Position de repos de chaque ligne physique — tâche/en-tête RÉELLE ou champ « Nouvelle tâche »
/// VIRTUEL, cf. `ListPageView.RowKey` — dans le même espace de coordonnées. Une seule clé pour les
/// deux : un champ participe au MÊME calcul de décalage qu'une tâche (cf. `dragTargets`), jamais un
/// cas séparé à maintenir à la main.
private struct RowFrameKey: PreferenceKey {
  static let defaultValue: [ListPageView.RowKey: CGRect] = [:]
  static func reduce(
    value: inout [ListPageView.RowKey: CGRect], nextValue: () -> [ListPageView.RowKey: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { $1 })
  }
}

private func comingSoon(_ title: String, searchPresented: Binding<Bool>) -> some View {
  VStack(alignment: .leading, spacing: 8) {
    // Le titre de l'onglet reste hors du fondu, comme partout ailleurs.
    Text(title).font(.title.bold())
    Text("À rebrancher.").foregroundStyle(.tertiary).pageReveal()
  }
  .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  .padding(.top, 30)
  .padding(.horizontal, gutter)
  .safeAreaInset(edge: .bottom, spacing: 0) {
    BottomToolbar(
      onNewTask: nil, onInsertHeader: nil, onSearch: { searchPresented.wrappedValue = true })
  }
}

/// Pastille grise d'un jeton : même gabarit pour le tag de jour planifié d'une ligne au repos
/// (`dateTag`) et pour les jetons en attente du champ « Nouvelle tâche » — ce qu'on voit en tapant
/// est exactement ce que la tâche portera.
struct TokenPill: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.callout)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .background(
        Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous)
      )
      .fixedSize()
  }
}

/// Jetons de saisie rapide validés dans un champ « Nouvelle tâche », en attente de la création.
struct DraftTokens {
  var when: Date?
  var target: String?
}
