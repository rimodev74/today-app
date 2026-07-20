import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Marge latérale du contenu du panneau de détail.
private let gutter: CGFloat = 75

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
private let taskFlow = Animation.timingCurve(0.4, 0, 0.2, 1, duration: 0.2)
private let taskSelectFade = Animation.easeOut(duration: 0.05)
/// Apparition d'une tâche fraîchement créée : ressort peu amorti pour un léger rebond. N'anime que
/// la CRÉATION (seul `createTask` l'enveloppe d'un `withAnimation`) : la suppression n'est pas
/// animée et le réordonnancement passe par des offsets, pas des insertions — la transition des
/// rangées n'y répond donc pas.
private let taskInsert = Animation.spring(response: 0.32, dampingFraction: 0.62)

/// Aiguillage du panneau de détail. Seule la page d'une to-do list est construite pour
/// l'instant ; les vues intelligentes sont à rebrancher. La recherche vit dans la sidebar
/// (cf. `SearchPopover`) et pilote la sélection, elle n'a plus de branche ici.
struct TaskListView: View {
  @Binding var selection: SidebarSelection?
  @Binding var searchPresented: Bool
  @Binding var pendingTitleFocus: PersistentIdentifier?

  var body: some View {
    switch selection {
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
      ProjectPageView(project: project, selection: $selection)
    case .pomodoro:
      PomodoroView()
    case .smartList(let smart):
      comingSoon(smart.label)
    case nil:
      comingSoon("Sélectionne une liste")
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
  // Un brouillon de saisie par bloc (clé = `TaskBlock.id`) : chaque champ « Nouvelle tâche » garde
  // son texte indépendamment des autres.
  @State private var drafts: [String: String] = [:]
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
  @State private var rowFrames: [PersistentIdentifier: CGRect] = [:]
  // Hauteur mesurée de la rangée « Nouvelle tâche » de chaque bloc (clé = `TaskBlock.id`). Elle
  // n'est pas une TaskItem donc absente de `rowFrames` ; il faut pourtant la compter dans le repli
  // d'un bloc tiré, sinon un trou de sa hauteur subsiste. `draggedFieldHeight` = celle du bloc tiré,
  // figée à l'empoignade.
  @State private var fieldHeights: [String: CGFloat] = [:]
  @State private var draggedFieldHeight: CGFloat = 0
  @State private var headerHovering = false
  @State private var pickingListDate = false
  @FocusState private var focusedDraft: String?
  @FocusState private var notesFocused: Bool

  var body: some View {
    // Position de repos cible de chaque ligne pendant un drag (trou ouvert sous le curseur).
    // Vide hors drag : chaque ligne reste alors à son offset 0.
    let targets = dragTargets()
    let placeholder = dragPlaceholderRect()
    return GeometryReader { geo in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          header
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
            // disparaissent : ils encombreraient le déplacement. Pour une en-tête, celui du bloc tiré
            // voyage en plus avec elle. Leur hauteur est mesurée (clé = block.id) pour entrer dans le
            // repli — cf. `draggedFieldHeight`.
            let blockLifted = block.header != nil && block.header?.persistentModelID == draggingID
            newTaskRow(for: block)
              .background {
                GeometryReader { g in
                  Color.clear.preference(key: FieldHeightKey.self, value: [block.id: g.size.height])
                }
              }
              .opacity(draggingID != nil ? 0 : 1)
              .offset(blockLifted ? dragOffset : .zero)
              .zIndex(blockLifted ? 1 : 0)
              .animation(blockLifted ? nil : .snappy(duration: 0.22), value: dragOffset)
              .animation(.easeInOut(duration: 0.2), value: draggingID != nil)
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
        // GEL pendant le drag. `frame(in: .named(...))` inclut le `.offset` appliqué aux
        // lignes : réinjecter ces frames décalées dans le calcul (qui suppose les positions de
        // REPOS) bouclait — offset → frame → offset… → « update multiple times per frame » et
        // saccade. Le layout de repos ne bouge pas d'un drag (on ne fait que décaler) : les
        // frames capturées avant l'empoignade restent valides jusqu'au relâchement.
        .onPreferenceChange(RowFrameKey.self) { frames in
          guard draggingID == nil else { return }
          rowFrames = frames
        }
        .onPreferenceChange(FieldHeightKey.self) { heights in
          guard draggingID == nil else { return }
          fieldHeights = heights
        }
        // Le contenu remplit AU MOINS la hauteur du viewport, pour que son fond (le
        // rattrapeur de clic) couvre aussi le vide SOUS la liste. Un `.background` posé sur
        // le ScrollView lui-même ne reçoit pas les clics de sa zone vide (bug constaté) ;
        // ici le rattrapeur est du CONTENU de ScrollView, où le clic est bien délivré.
        .frame(minHeight: geo.size.height, alignment: .top)
        .background {
          // Rattrapeur de clic sur le vide : referme l'édition ET retire le focus des
          // notes (un clic dans du vide ne défocalise pas un champ tout seul).
          if editingID != nil || notesFocused {
            Color.clear
              .contentShape(Rectangle())
              .onTapGesture {
                dismissEditing()
                notesFocused = false
              }
          }
        }
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
      // Retour arrière (⌫) sur une en-tête SÉLECTIONNÉE (hors édition) : la supprime. Même mécanique
      // que Échap ci-dessus — bouton caché au niveau fenêtre. Absent en édition (le champ mange ⌫).
      if editingID == nil, selectedHeader != nil {
        Button("", action: requestDeleteSelectedHeader)
          .keyboardShortcut(.delete, modifiers: [])
          .hidden()
      }
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

  /// Découpe les lignes en blocs : une en-tête et les tâches qui la suivent jusqu'à la prochaine.
  /// Les tâches AVANT toute en-tête forment un bloc sans en-tête ; une liste vide reste un bloc
  /// (avec son champ de création). `id` stable (id de l'en-tête, ou "top") pour l'identité SwiftUI,
  /// le focus et le brouillon de saisie de chaque bloc.
  /// Vrai pendant qu'on tire une EN-TÊTE (par opposition à une tâche) : pilote le repli des tâches
  /// et la disparition de tous les champs « Nouvelle tâche ».
  private var isHeaderDragging: Bool {
    draggingID != nil && draggedGroup.first?.isHeader == true
  }

  private var blocks: [TaskBlock] {
    func key(_ header: TaskItem?) -> String {
      header.map { String(describing: $0.persistentModelID) } ?? "top"
    }
    var result: [TaskBlock] = []
    var header: TaskItem?
    var tasks: [TaskItem] = []
    for item in list.orderedTasks {
      if item.isHeader {
        if header != nil || !tasks.isEmpty {
          result.append(TaskBlock(id: key(header), header: header, tasks: tasks))
        }
        header = item
        tasks = []
      } else {
        tasks.append(item)
      }
    }
    result.append(TaskBlock(id: key(header), header: header, tasks: tasks))
    return result
  }

  /// Enveloppe drag/drop d'une ligne (en-tête ou tâche), mutualisée entre les deux : mesure de la
  /// position de repos, décalage/soulevé pendant le drag, et le geste unique de la page.
  private func draggableRow(for task: TaskItem, targets: [PersistentIdentifier: CGFloat])
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
      .padding(.bottom, editingID == task.persistentModelID ? 12 : 0)
      // Position de repos mesurée, pour calculer où ouvrir le trou pendant un drag.
      .background {
        GeometryReader { g in
          Color.clear.preference(
            key: RowFrameKey.self,
            value: [task.persistentModelID: g.frame(in: .named(Self.dragSpace))]
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
        onEndEditing: { endEditing(task) },
        onDelete: { delete(task) }
      )
    } else {
      TaskRow(
        task: task,
        isSelected: selectedID == task.persistentModelID,
        isEditing: editingID == task.persistentModelID,
        moveTargets: allLists.filter { $0.persistentModelID != list.persistentModelID },
        onEndEditing: { endEditing(task) },
        onMove: { move(task, to: $0) },
        onDuplicate: { duplicate(task) },
        onDelete: { delete(task) }
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
  }

  /// Double-clic : passe en édition.
  private func beginEditing(_ task: TaskItem) {
    withAnimation(taskFlow) {
      selectedID = task.persistentModelID
      editingID = task.persistentModelID
    }
  }

  /// Fin d'édition (Entrée / Échap / clic à l'extérieur) : repasse en état « normal ».
  private func endEditing(_ task: TaskItem) {
    guard editingID == task.persistentModelID else { return }
    withAnimation(taskFlow) {
      editingID = nil
      selectedID = nil
    }
  }

  /// Ferme l'édition en cours, quelle que soit la tâche (Échap au niveau fenêtre, clic dehors).
  private func dismissEditing() {
    withAnimation(taskFlow) {
      editingID = nil
      selectedID = nil
    }
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

  /// Rectangle englobant d'un ensemble de lignes contiguës (position de repos), pour traiter un bloc
  /// comme une seule « grande ligne ». `nil` tant qu'aucune n'est mesurée.
  private func groupRect(_ items: [TaskItem]) -> CGRect? {
    let frames = items.compactMap { rowFrames[$0.persistentModelID] }
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
      let hf = rowFrames[header.persistentModelID],
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
  private func dragInsertion() -> (dragged: [TaskItem], others: [TaskItem], index: Int)? {
    guard draggingID != nil, let first = draggedGroup.first,
      let groupF = groupRect(draggedGroup)
    else { return nil }
    let ordered = list.orderedTasks
    let draggedIDs = Set(draggedGroup.map(\.persistentModelID))
    let others = ordered.filter { !draggedIDs.contains($0.persistentModelID) }

    if first.isHeader {
      guard let hf = rowFrames[first.persistentModelID],
        let di = blocks.firstIndex(where: {
          $0.header?.persistentModelID == first.persistentModelID
        })
      else { return nil }
      let delta = blockDelta ?? 0
      // Centre de l'EN-TÊTE (le bloc replié ne fait plus que sa hauteur) sous le curseur.
      let center = hf.midY + dragOffset.height
      let all = blocks
      var acc = 0
      var flat = others.count
      for (bi, b) in all.enumerated() {
        if bi == di { continue }  // le bloc tiré n'est pas dans `others`
        if let r = groupRect(b.items) {
          // Un bloc entier est soit tout au-dessus, soit tout au-dessous du bloc tiré : son centre
          // replié remonte de Δ s'il est en dessous.
          let blockCenter = r.midY - (bi > di ? delta : 0)
          if center < blockCenter {
            flat = acc
            break
          }
        }
        acc += b.rowCount
      }
      return (draggedGroup, others, min(flat, others.count))
    }

    let center = groupF.midY + dragOffset.height
    var index = ordered.count
    for i in ordered.indices {
      guard let f = rowFrames[ordered[i].persistentModelID] else { continue }
      let nextMid = i + 1 < ordered.count ? rowFrames[ordered[i + 1].persistentModelID]?.midY : nil
      let boundary = nextMid.map { ($0 + f.midY) / 2 } ?? .greatestFiniteMagnitude
      if center < boundary {
        index = i
        break
      }
    }
    return (draggedGroup, others, min(index, others.count))
  }

  /// Position de repos cible de chaque ligne, trou réservé à l'emplacement d'insertion.
  ///
  /// Fondé sur les positions de repos MESURÉES (`rowFrames.minY`), pas sur un ré-empilement
  /// contigu : retirer la ligne tirée puis la réinsérer décale les lignes situées ENTRE son
  /// ancienne et sa nouvelle place d'exactement sa hauteur (les autres ne bougent pas). Partir des
  /// positions mesurées garde le calcul juste même quand des vues non-tâches (les champs « Nouvelle
  /// tâche » de chaque bloc) créent des trous entre les lignes.
  /// ponytail: recalcul O(n) par rendu de drag — négligeable à l'échelle d'une to-do list.
  ///
  /// Drag d'une en-tête : calcul dans l'espace REPLIÉ. `h` = hauteur de la SEULE en-tête (le
  /// placeholder fait la taille d'une en-tête, comme une tâche fait la sienne). Les lignes situées
  /// sous le bloc tiré (indice `j >= B` dans `others`) sont d'abord remontées de Δ (le bloc s'est
  /// réduit à son en-tête), puis décalées de ±h selon l'insertion.
  private func dragTargets() -> [PersistentIdentifier: CGFloat] {
    guard let (dragged, others, insert) = dragInsertion(),
      let first = dragged.first,
      let dragFrame = rowFrames[first.persistentModelID],
      let origInsert = list.orderedTasks.firstIndex(where: {
        $0.persistentModelID == first.persistentModelID
      })
    else { return [:] }
    let h = dragFrame.height
    let delta = first.isHeader ? (blockDelta ?? 0) : 0
    let B = origInsert  // lignes avant le bloc/la ligne = indice d'origine dans `others`
    var map: [PersistentIdentifier: CGFloat] = [:]
    for (j, other) in others.enumerated() {
      guard let home = rowFrames[other.persistentModelID]?.minY else { continue }
      let base = home - (j >= B ? delta : 0)
      let shift: CGFloat =
        (insert < B && (insert..<B).contains(j))
        ? h
        : (insert > B && (B..<insert).contains(j))
          ? -h
          : 0
      map[other.persistentModelID] = base + shift
    }
    return map
  }

  /// Rectangle du trou d'insertion (le « placeholder ») dans l'espace de la liste : là où la ligne
  /// tirée se posera. Bas de la ligne (déplacée) qui précède le trou, ou le sommet si insertion en
  /// tête. Positions mesurées → juste malgré les trous entre blocs. Drag d'en-tête : taille d'une
  /// en-tête et positions corrigées du repli Δ, comme `dragTargets`.
  private func dragPlaceholderRect() -> CGRect? {
    guard let first = draggedGroup.first,
      let dragFrame = rowFrames[first.persistentModelID],
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
      gapTop = list.orderedTasks.compactMap { rowFrames[$0.persistentModelID]?.minY }.min() ?? 0
    } else {
      guard let f = rowFrames[others[insert - 1].persistentModelID] else { return nil }
      let j = insert - 1
      let base = f.minY - (j >= B ? delta : 0)
      let shift: CGFloat = (insert > B && j >= B) ? -h : 0
      gapTop = base + shift + f.height
    }
    return CGRect(x: dragFrame.minX, y: gapTop, width: dragFrame.width, height: h)
  }

  /// Décalage d'une ligne : la ligne tirée suit le curseur en 2D (soulevée), les autres rejoignent
  /// verticalement leur cible (différence entre position cible et position de repos mesurée).
  private func rowOffset(for task: TaskItem, targets: [PersistentIdentifier: CGFloat]) -> CGSize {
    if draggedGroup.contains(where: { $0.persistentModelID == task.persistentModelID }) {
      return dragOffset
    }
    guard let target = targets[task.persistentModelID],
      let home = rowFrames[task.persistentModelID]?.minY
    else { return .zero }
    return CGSize(width: 0, height: target - home)
  }

  /// Ancre du soulevé (agrandissement) : la position relative du point empoigné dans la ligne
  /// tirée. Scaler autour de CE point le laisse fixe sous le curseur ; `.center` par défaut le
  /// ferait dériver d'autant que le curseur est loin du milieu d'une ligne large.
  private var dragAnchor: UnitPoint {
    guard let draggingID, let f = rowFrames[draggingID], f.width > 0, f.height > 0
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
            .flatMap { fieldHeights[$0.id] } ?? 0
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
  /// sont déjà visuellement à leur cible, la bascule ordre↔offset ne produit aucun saut.
  private func endDrag() {
    // `dragInsertion` lit `draggingID`/`draggedGroup` : on capture le plan AVANT de désarmer.
    let plan = dragInsertion()
    // Réordonnancement ET désarmement du drag dans LA MÊME transaction animée. Séparés (l'ancien
    // `defer` désarmait dans une seconde passe), l'en-tête filait une frame vers son ancienne place
    // avant de rejoindre la nouvelle — le « fantôme qui part vers le haut en s'estompant ».
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
      TextField(
        "Nouvelle tâche…",
        text: Binding(get: { drafts[block.id] ?? "" }, set: { drafts[block.id] = $0 })
      )
      .textFieldStyle(.plain)
      .focused($focusedDraft, equals: block.id)
      .onSubmit { createTask(in: block) }
    }
    // Mêmes paddings qu'une TaskRow au repos (vertical 6, horizontal 10) : la rangée de
    // création garde exactement le rythme des tâches, sans détachement visuel.
    .padding(.vertical, 6)
    .padding(.horizontal, 10)
    .contentShape(Rectangle())
    .onTapGesture { focusedDraft = block.id }
  }

  private func createTask(in block: TaskBlock) {
    let trimmed = (drafts[block.id] ?? "").trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else {
      focusedDraft = nil
      return
    }
    let task = TaskItem(title: trimmed, list: list)
    // Insère à la fin du bloc : juste après sa dernière tâche (ou son en-tête si le bloc est vide),
    // avant le bloc suivant. Les tâches situées après glissent d'un cran.
    let anchor = block.tasks.last?.sortIndex ?? block.header?.sortIndex ?? -1
    withAnimation(taskInsert) {
      for t in list.tasks where t.sortIndex > anchor { t.sortIndex += 1 }
      task.sortIndex = anchor + 1
      modelContext.insertAndSave(task)
    }
    drafts[block.id] = ""
    focusedDraft = block.id
  }

  // MARK: En-tête de liste

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
    // Aucun retrait horizontal : l'anneau, le titre et le notesBox sont FLUSH à gauche sur la même
    // ligne d'alignement que le fond de sélection des tâches. Les cases à cocher, elles, gardent leur
    // retrait de 10 à l'intérieur de ce fond (respiration de la surbrillance) — l'anneau n'a pas à le
    // suivre : c'est un élément d'en-tête, calé sur le bord de section, pas sur les cases.
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

  /// Notes de la liste : encadré au fond légèrement plus foncé que la page, gros rayon.
  /// `TextEditor` (et pas un `TextField`) pour que Entrée fasse un vrai retour à la ligne.
  /// Aligné à gauche sur l'anneau/titre (aucun retrait) ; marges haute et basse pour le détacher.
  private var notesBox: some View {
    ZStack(alignment: .topLeading) {
      // Placeholder et éditeur SANS retrait propre : le retrait est posé une seule fois sur le
      // ZStack (padding commun ci-dessous), donc le texte tapé et « Notes » partent du même x.
      if list.notes.isEmpty {
        Text("Notes")
          .font(.body)
          .foregroundStyle(.tertiary)
          // Léger retrait : le caret du TextEditor démarre au même x que ce texte, sans
          // ce décalage il se superposerait au « N ». N'affecte que l'indication (vide).
          .padding(.leading, 5)
          .allowsHitTesting(false)
      }
      RichTextEditor(
        data: $list.notes,
        font: .systemFont(ofSize: NSFont.systemFontSize),
        textColor: .labelColor,
        // Page sans tâche : Entrée dans les notes saute au champ « Nouvelle tâche » plutôt que
        // d'ouvrir une ligne — sinon Entrée dans le seul champ actif de la page ressemble à un
        // « valider » mort. Saut de ligne toujours possible via Maj+Entrée. Liste non vide :
        // comportement natif inchangé (Entrée = retour à la ligne).
        handleReturn: { shiftHeld in
          guard list.countableTasks.isEmpty, !shiftHeld else { return false }
          focusedDraft = blocks.first?.id
          return true
        }
      )
      .fixedSize(horizontal: false, vertical: true)
      .focused($notesFocused)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
    .background(
      Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .padding(.top, 4)
    .padding(.bottom, 10)
  }

  // MARK: Barre d'outils du bas

  private var bottomBar: some View {
    buttonGroup {
      toolbarButton("plus", "Nouvelle tâche") { focusedDraft = blocks.last?.id }
      groupDivider
      toolbarButton("line.3.horizontal", "Insérer une en-tête") { insertHeader() }
      groupDivider
      toolbarButton("magnifyingglass", "Recherche") { searchPresented = true }
    }
    // Capsule flottante centrée : elle garde sa largeur intrinsèque, le frame full-width la centre.
    .frame(maxWidth: .infinity, alignment: .center)
    .padding(.bottom, 16)
  }

  /// « Button group » flottant : une capsule unique posée au-dessus du contenu, toutes les actions
  /// regroupées dedans, séparées par des traits internes. Rendu Liquid Glass natif via `.glassEffect`
  /// (bouts arrondis + réfraction + ombre portée fournis par le système), `.interactive()` fait réagir
  /// le verre au survol/press. Repli material + ombre sous macOS 26 (Package.swift cible .v14, donc
  /// le `#available` est obligatoire — le compilateur refuse l'API sinon).
  @ViewBuilder
  private func buttonGroup<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    let base = HStack(spacing: 2) { content() }
      .padding(.horizontal, 6)
      .padding(.vertical, 5)
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
    Divider().frame(height: 18)
  }

  private func toolbarButton(_ icon: String, _ help: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      Image(systemName: icon)
        .font(.system(size: 15))
        .foregroundStyle(.secondary)
        .frame(width: 38, height: 30)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }

  // MARK: Actions de liste

  private func completeAllTasks() {
    let toggled = list.countableTasks.filter { !$0.isCompleted }
    for task in toggled { task.toggleCompletion() }
    try? modelContext.save()
    for task in toggled {
      Task { await remindersService.pushCompletion(for: task) }
    }
  }

  private func duplicateList() {
    let copy = TodoList(title: list.title + " copie", notes: list.notes, project: list.project)
    copy.sortIndex = list.sortIndex + 1
    modelContext.insert(copy)
    for task in list.orderedTasks {
      let clone = TaskItem(
        title: task.title, notes: task.notes, when: task.when,
        isHeader: task.isHeader, list: copy
      )
      clone.sortIndex = task.sortIndex
      clone.priority = task.priority
      modelContext.insert(clone)
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
    modelContext.delete(task)
    try? modelContext.save()
  }

  /// Déplace une tâche vers une autre liste, en la posant à la fin de sa nouvelle liste.
  private func move(_ task: TaskItem, to target: TodoList) {
    task.list = target
    task.sortIndex = (target.tasks.map(\.sortIndex).max() ?? -1) + 1
    try? modelContext.save()
  }

  /// Duplique une tâche juste sous l'originale (les suivantes glissent d'un cran).
  private func duplicate(_ task: TaskItem) {
    let clone = TaskItem(
      title: task.title, notes: task.notes, when: task.when,
      isHeader: task.isHeader, list: list
    )
    clone.priority = task.priority
    clone.deadline = task.deadline
    for t in list.tasks where t.sortIndex > task.sortIndex { t.sortIndex += 1 }
    clone.sortIndex = task.sortIndex + 1
    modelContext.insertAndSave(clone)
  }

  private func insertHeader() {
    let header = TaskItem(title: "", isHeader: true, list: list)
    header.sortIndex = (list.tasks.map(\.sortIndex).max() ?? -1) + 1
    modelContext.insertAndSave(header)
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
}

/// Page d'un projet : ses to-do lists dépliées. Chaque liste montre son titre (cliquable pour
/// l'ouvrir en édition) puis ses tâches en LECTURE (case à cocher + titre) — un survol du projet
/// sans avoir à ouvrir chaque liste. L'édition d'une tâche reste sur la page de sa liste.
private struct ProjectPageView: View {
  @Bindable var project: Project
  @Binding var selection: SidebarSelection?
  @Environment(RemindersService.self) private var remindersService

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
        ZStack(alignment: .topLeading) {
          if project.notes.isEmpty {
            Text("Notes")
              .font(.subheadline)
              .foregroundStyle(.tertiary)
              .padding(.leading, 5)
              .allowsHitTesting(false)
          }
          RichTextEditor(
            data: $project.notes,
            font: .systemFont(ofSize: NSFont.systemFontSize - 1),
            textColor: .secondaryLabelColor
          )
          .fixedSize(horizontal: false, vertical: true)
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
            ProgressRing(progress: list.progress, size: 16, showsFill: true)
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

        ForEach(list.orderedTasks) { task in
          taskRow(task).listRowSeparator(.hidden)
        }

        if list.tasks.isEmpty {
          Text("Aucune tâche")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.leading, 26)
            .listRowSeparator(.hidden)
            .selectionDisabled()
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
  }

  /// Tâche en lecture sous le titre de sa liste. Une en-tête devient un intertitre discret ; une
  /// tâche garde sa case à cocher active (comme partout ailleurs), le titre n'est pas éditable ici.
  @ViewBuilder
  private func taskRow(_ task: TaskItem) -> some View {
    if task.isHeader {
      Text(task.title.isEmpty ? "En-tête" : task.title)
        .font(.subheadline.bold())
        .foregroundStyle(.secondary)
        .padding(.leading, 20)
        .padding(.top, 6)
    } else {
      HStack(spacing: 10) {
        TaskCheckbox(isCompleted: task.isCompleted) {
          task.toggleCompletion()
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

/// Une tâche dans la liste. Deux modes :
/// - **affichage** : case à cocher + titre. Double-clic pour éditer.
/// - **édition** (double-clic) : carte détachée avec titre, notes, et une rangée d'actions
///   (date, tags, checklist, priorité), façon Things.
///
/// Le double-clic est un simple `.onTapGesture(count: 2)` — possible parce qu'on n'est plus sur
/// une `List`/NSTableView (qui avalait ses clics). C'est tout le bénéfice de la refonte.
private struct TaskRow: View {
  @Bindable var task: TaskItem
  let isSelected: Bool
  let isEditing: Bool
  /// Listes vers lesquelles déplacer la tâche (toutes sauf la sienne).
  var moveTargets: [TodoList]
  var onEndEditing: () -> Void
  var onMove: (TodoList) -> Void
  var onDuplicate: () -> Void
  var onDelete: () -> Void

  @Environment(RemindersService.self) private var remindersService

  @FocusState private var titleFocused: Bool
  @State private var hovering = false
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
    VStack(alignment: .leading, spacing: isEditing ? 12 : 0) {
      HStack(spacing: 10) {
        TaskCheckbox(isCompleted: task.isCompleted) {
          task.toggleCompletion()
          Task { await remindersService.pushCompletion(for: task) }
        }
        if !isEditing { dateTag }
        titleView
        Spacer(minLength: 0)
        if !isEditing { trailing }
      }

      if isEditing {
        // Le fondu fait naître notes + actions avec la carte, au lieu de les révéler
        // d'un coup pendant que la hauteur, elle, grandit en douceur.
        editorBody.transition(.opacity)
      } else if !task.notes.isEmpty {
        // Au repos : aperçu de la note sous le titre (1 ligne tronquée, façon Things). Aligné
        // sous le titre (case 16 + espace 10), pas sous la case. Texte brut seulement — la mise
        // en forme (gras/italique/liens) ne sert qu'en édition.
        Text(NotesCodec.plainText(task.notes))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .padding(.leading, 26)
          .padding(.top, 2)
      }
    }
    // Le padding grandit en édition : le titre glisse vers l'intérieur de la carte, la
    // hauteur s'ouvre. Sélection et normal partagent le même padding — seul le fond change,
    // le texte ne saute donc pas au clic simple.
    .padding(.vertical, isEditing ? 16 : 6)
    .padding(.horizontal, isEditing ? 16 : 10)
    .background { rowBackground }
    .contentShape(Rectangle())
    // Survol : révèle le ••• à droite. Clic droit : même menu que le •••, via contentShape.
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
    // poser à son .onAppear. On le pose/retire au basculement d'état.
    .onChange(of: isEditing) { _, editing in titleFocused = editing }
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
        // ponytail: tags et checklist sont décoratifs pour l'instant (présents dans le
        // visuel Things demandé). À brancher quand le modèle les portera.
        actionIcon("tag")
        actionIcon("list.bullet")
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
        Text("Notes")
          .foregroundStyle(.tertiary)
          .padding(.leading, 5)
          .allowsHitTesting(false)
      }
      RichTextEditor(
        data: $task.notes,
        font: .systemFont(ofSize: NSFont.systemFontSize),
        textColor: .secondaryLabelColor
      )
      .fixedSize(horizontal: false, vertical: true)
    }
    .font(.body)
    .foregroundStyle(.secondary)
    .padding(.leading, 26)
  }

  // MARK: Fond

  /// Fond conditionnel, et surtout LÉGER au repos. Une tâche normale ne rend AUCUN fond —
  /// donc ni ombre, ni forme, rien. Seule la ligne éditée porte l'ombre : un `.shadow`
  /// permanent sur chaque ligne force un rendu offscreen par ligne et fait saccader le scroll.
  /// Le fondu (`.transition`) anime l'apparition ; la hauteur est animée par le withAnimation
  /// parent. La ligne titre reste en place, donc pas de « snap » malgré le fond conditionnel.
  @ViewBuilder
  private var rowBackground: some View {
    if isEditing {
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color(nsColor: .controlBackgroundColor))
        .overlay {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .transition(.opacity)
    } else if isSelected {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(thingsSelectionFill)
        .transition(.opacity)
    }
  }

  // MARK: Date

  /// Tag de jour planifié (`when`), à GAUCHE du titre (cf. Things) : petit fond gris arrondi,
  /// « 31 juil. ». Distinct de l'échéance (drapeau, à droite). Rien si aucune date.
  @ViewBuilder
  private var dateTag: some View {
    if let when = task.when {
      Text(when, format: .dateTime.day().month(.abbreviated))
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

  // MARK: Actions au survol / clic droit

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
        ForEach(moveTargets) { target in
          Button(target.title) { onMove(target) }
        }
      }
    } label: {
      Label("Déplacer vers…", systemImage: "arrow.right")
    }
    Button {
      activePicker = .deadline
    } label: {
      Label("Échéance…", systemImage: "flag")
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

/// En-tête de section dans la liste. Trois états, comme une tâche :
/// - **repos** : titre bleu, souligné d'un filet. Le clic va au geste de la page.
/// - **sélection / édition** : le titre passe sur une PILULE lavande (le filet s'efface), le •••
///   apparaît ; en édition le champ devient actif + focus (curseur de saisie).
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
  var onEndEditing: () -> Void
  var onDelete: () -> Void

  @FocusState private var titleFocused: Bool
  @State private var hovering = false

  /// Cascade du drag : décalage vertical d'un calque et retrait horizontal (plus étroit, centré) par
  /// niveau. Couleurs OPAQUES, du même bleu, de plus en plus claires — assez SATURÉES pour se lire
  /// comme des cartes (des tons quasi blancs ne montraient que leur ombre → aspect brouillon).
  private static let layerStep: CGFloat = 7
  private static let layerInset: CGFloat = 6
  private static let dragTop = Color(red: 202 / 255, green: 225 / 255, blue: 255 / 255)  // #CAE1FF
  private static let dragLayer1 = Color(red: 220 / 255, green: 234 / 255, blue: 255 / 255)  // #DCEAFF
  private static let dragLayer2 = Color(red: 234 / 255, green: 241 / 255, blue: 255 / 255)  // #EAF1FF

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
      // Filet du bas : seulement au repos ; la pilule le remplace en sélection/édition/drag. Opacité
      // (et non un `if`) pour garder une hauteur stable, sans saut au passage en sélection.
      Divider().opacity(active ? 0 : 1)
    }
    .padding(.top, 20)
    .padding(.bottom, 4)
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
        .foregroundStyle(Color.accentColor.opacity(0.85))
        .focused($titleFocused)
        .allowsHitTesting(isEditing)
        .onSubmit(onEndEditing)
      Spacer(minLength: 0)
      Menu {
        Button("Supprimer", role: .destructive, action: onDelete)
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
    .padding(.horizontal, 10)
    .background {
      if active {
        // Pendant le drag, l'en-tête est le calque du DESSUS de la cascade : couleur OPAQUE dédiée
        // (#CAE1FF), sinon les calques derrière transparaissent à travers. Hors drag, le lavande
        // translucide (comme une tâche sélectionnée) suffit. Ombre de soulevé seulement au drag.
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isDragging ? AnyShapeStyle(Self.dragTop) : AnyShapeStyle(thingsSelectionFill))
          .shadow(color: .black.opacity(isDragging ? 0.14 : 0), radius: 6, y: 3)
      }
    }
  }
}

/// Case à cocher façon Things : un carré à coin arrondi, vide et cerné d'un filet gris ;
/// rempli en accent avec une coche blanche une fois complété.
///
/// Custom et pas `.toggleStyle(.checkbox)` : la case native de macOS 26 est un carré **plein**,
/// impossible d'en tirer ce rendu par un simple restylage.
private struct TaskCheckbox: View {
  let isCompleted: Bool
  var onToggle: () -> Void

  private static let size: CGFloat = 16
  private static let shape = RoundedRectangle(cornerRadius: 4.5, style: .continuous)

  var body: some View {
    Button(action: onToggle) {
      Self.shape
        .fill(isCompleted ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
        // Bordure et check coexistent en permanence (opacité / trim pilotés par isCompleted) :
        // pas de `if` qui insère/retire une vue, sinon le trim n'aurait rien à animer.
        .overlay {
          Self.shape
            .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1)
            .opacity(isCompleted ? 0 : 1)
        }
        .overlay {
          // `.trim` = strokeEnd de Core Animation exposé en SwiftUI : le trait se *trace*
          // (0→1) au lieu d'apparaître. lineCap/Join .round pour la même douceur que Things.
          Checkmark()
            .trim(from: 0, to: isCompleted ? 1 : 0)
            .stroke(
              .white,
              style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
            )
            .frame(width: Self.size * 0.55, height: Self.size * 0.55)
        }
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
    }
    // Bounce au press/release (l'état pressé du bouton, pas la pression trackpad) via un
    // ButtonStyle dédié ; le tracé + le fond restent animés par le withAnimation de la page.
    .buttonStyle(PressBounceButtonStyle())
    .animation(.bouncy(duration: 0.3, extraBounce: 0.15), value: isCompleted)
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

private struct RowFrameKey: PreferenceKey {
  static let defaultValue: [PersistentIdentifier: CGRect] = [:]
  static func reduce(
    value: inout [PersistentIdentifier: CGRect], nextValue: () -> [PersistentIdentifier: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { $1 })
  }
}

/// Hauteur de la rangée « Nouvelle tâche » de chaque bloc (clé = `TaskBlock.id`). Elle n'est pas une
/// TaskItem — donc absente de `RowFrameKey` — mais il faut la compter dans le repli d'un bloc tiré.
private struct FieldHeightKey: PreferenceKey {
  static let defaultValue: [String: CGFloat] = [:]
  static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { $1 })
  }
}

private func comingSoon(_ title: String) -> some View {
  VStack(alignment: .leading, spacing: 8) {
    Text(title).font(.title.bold())
    Text("À rebrancher.").foregroundStyle(.tertiary)
  }
  .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  .padding(.top, 30)
  .padding(.horizontal, gutter)
}
