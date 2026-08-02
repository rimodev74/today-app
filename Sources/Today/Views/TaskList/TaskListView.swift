import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Aiguillage du panneau de détail. Seule la page d'une to-do list est construite pour
/// l'instant ; les vues intelligentes sont à rebrancher. La recherche vit dans la sidebar
/// (cf. `SearchPopover`) et pilote la sélection, elle n'a plus de branche ici.
struct TaskListView: View {
  @Binding var selection: SidebarSelection?
  @Binding var searchPresented: Bool
  @Binding var pendingTitleFocus: PersistentIdentifier?

  var body: some View { page }

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
    case nil:
      // Aucune destination : le seul état sans page. `selection` démarre sur « Aujourd'hui » et
      // rien ne la remet à nil aujourd'hui — la branche existe parce que le type l'autorise, pas
      // parce qu'un chemin y mène.
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
  @AppStorage(TextShortcut.storageKey) private var shortcutData = Data()
  /// Sélection (clic) et édition (clic sur une ligne déjà sélectionnée) — c'est `TaskRow` qui les
  /// consomme. Même type que « Aujourd'hui » et « Tâches » (cf. `TaskFocus`) : les transitions y sont
  /// écrites une fois, les courbes restent ici.
  @State private var focus = TaskFocus()
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
  // (`dragState`). `draggedFieldHeight` = hauteur du champ du bloc tiré, figée à l'empoignade
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
    let state = dragState()
    // Calculés UNE fois par rendu et distribués aux lignes : chaque rangée devait sinon se chercher
    // elle-même dans la séquence, soit un balayage quadratique à chaque image de glissement.
    let offsets = state?.rows.offsets() ?? [:]
    let placeholder = state.flatMap(dragPlaceholderRect)
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
              draggableRow(for: header, offsets: offsets)
            }
            ForEach(block.tasks) { task in
              draggableRow(for: task, offsets: offsets)
            }
            // Pendant N'IMPORTE QUEL drag (en-tête OU tâche), TOUS les champs « Nouvelle tâche »
            // disparaissent : ils encombreraient le déplacement. Restent MONTÉS (juste rendus
            // invisibles par opacité, pas retirés de l'arbre) : `rowFrames`/`dragState` sont GELÉS
            // à l'empoignade en supposant que chaque ligne (champs compris) garde sa place dans la
            // mise en page — les retirer aurait fait s'effondrer cet espace pendant TOUT le drag et
            // cassé le calcul du trou d'insertion (le placeholder).
            //
            // Le décalage vient de `fieldOffset` — EXACTEMENT `rowOffset`, pour un champ : au drop,
            // la position CIBLE (anticipée dès le live-drag, cf. `dragState`) devient la position
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
                y: blockLifted ? dragOffset.height : fieldOffset(for: block, offsets: offsets)
              )
              .zIndex(blockLifted ? 1 : 0)
              .animation(
                blockLifted ? nil : .snappy(duration: 0.22),
                value: fieldOffset(for: block, offsets: offsets)
              )
              .animation(.easeInOut(duration: 0.15), value: draggingID != nil)
          }

          // Repliée pendant un drag : elle n'entre pas dans `rowFrames`/`dragState` (gelés à
          // l'empoignade), une ouverture en cours de drag décalerait le calcul du trou.
          if draggingID == nil {
            dormantSummary
            archiveSection
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
      if focus.editing != nil {
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
    // Le socle commun des pages de tâches : ⌫ sur la sélection, ↑/↓ pour la déplacer. Un seul pan,
    // toujours visible : cette page n'a pas de section repliable, mais elle passe par les mêmes
    // `TaskPageBlock` que les autres — une page ne choisit pas sa façon de déclarer ses lignes.
    // `blocks` est déjà ce que le `body` parcourt, en-têtes de section comprises (`items`), donc
    // l'ordre AFFICHÉ (les archivées n'y sont pas) et non celui du modèle.
    .taskPageBase(
      focus: $focus,
      blocks: { [.visible(blocks.flatMap(\.items))] },
      delete: requestDelete,
      // Cette page a son PROPRE moteur de glissement (en-têtes, blocs, champs) : le socle n'a rien
      // à réordonner ici.
      reorder: nil
    )
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
      focus.dismiss()
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
    guard let id = focus.selected else { return nil }
    return list.tasks.first { $0.persistentModelID == id && $0.isHeader }
  }

  /// Bloc contenant la sélection courante (tâche ou en-tête), ou nil hors sélection. Cible du
  /// « + » de la toolbar : insérer dans le bloc qu'on regarde, pas systématiquement le dernier.
  private var selectedBlockID: String? {
    guard let id = focus.selected else { return nil }
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

  /// ⌫ sur une ligne : délègue à la confirmation d'en-tête si elle en est une, sinon supprime la
  /// tâche directement (pas de tâches rattachées à protéger, contrairement à l'en-tête).
  ///
  /// Prend sa cible en paramètre plutôt que de la chercher : c'est le socle commun
  /// (`TaskPageBase`) qui la désigne, à partir de l'ordre AFFICHÉ de la page.
  private func requestDelete(_ task: TaskItem) {
    guard task.isHeader else {
      delete(task)
      return
    }
    if attachedTasks(of: task).isEmpty { delete(task) } else { headerDeletionCandidate = task }
  }

  /// Découpe les lignes en blocs : une en-tête et les tâches qui la suivent jusqu'à la prochaine.
  /// Les tâches AVANT toute en-tête forment un bloc sans en-tête ; une liste vide reste un bloc
  /// (avec son champ de création). `id` stable (id de l'en-tête, ou "top") pour l'identité SwiftUI,
  /// le focus et le brouillon de saisie de chaque bloc.
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

  /// Une tâche cochée quitte le flux de la liste — jamais la base. La règle est commune (cf.
  /// `CompletedTaskRetention.hasLeftTheFlow`) ; ce qui est PROPRE à cette page, c'est qu'elle sait
  /// depuis quand elle est ouverte, et c'est la seule chose qu'elle ajoute.
  private func isArchived(_ task: TaskItem) -> Bool {
    task.hasLeftTheFlow(retention, now: tick, pageOpenedAt: pageOpenedAt)
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
          .font(.app(11))
        Text("\(count) tâche\(plural) en sommeil")
      }
      .font(.app(.callout))
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
              .font(.app(10, weight: .semibold))
              .rotationEffect(.degrees(archivesExpanded ? 90 : 0))
            Text("\(archived.count) tâche\(plural) archivée\(plural)")
              .font(.app(.subheadline).weight(.semibold))
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
          ForEach(ArchiveMonth.group(archived)) { month in
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
  private func draggableRow(for task: TaskItem, offsets: [RowKey: CGFloat])
    -> some View
  {
    // `lifted` = cette ligne fait partie du groupe tiré (bloc entier pour une en-tête) → elle se
    // soulève. `grabbed` = c'est LA ligne empoignée → elle porte l'ancre du léger agrandissement.
    // `folding` = une tâche du bloc dont on tire l'en-tête : elle s'estompe (se replie dans le
    // bloc), seule l'en-tête reste visible pendant le transport (cf. `ReorderLayout.collapse`).
    let lifted = draggedGroup.contains { $0.persistentModelID == task.persistentModelID }
    let grabbed = draggingID == task.persistentModelID
    let folding = lifted && !task.isHeader && draggedGroup.first?.isHeader == true
    return
      row(for: task)
      // Carte éditée : marge basse pour ne pas coller la ligne suivante (ou « Nouvelle tâche »).
      // Pas pour une en-tête : elle n'a pas de carte de notes qui s'étend, la marge ne ferait
      // qu'ajouter un vide sous sa pilule.
      .padding(.bottom, focus.isEditing(task) && !task.isHeader ? 12 : 0)
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
      .offset(rowOffset(for: task, offsets: offsets))
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
        value: rowOffset(for: task, offsets: offsets)
      )
      .animation(.easeOut(duration: 0.15), value: lifted)
      .animation(.easeInOut(duration: 0.2), value: folding)
      // Rebond à la création (déclenché par le withAnimation de `createTask`), et au retour d'un
      // ⌘Z (par celui du socle). La courbe vit dans `TaskPageChrome` — les trois pages entrent
      // leurs lignes de la même façon.
      .taskRowInsertion()
      // En édition, `.subviews` désactive ce geste : les clics/glissers vont au champ texte.
      .gesture(
        dragGesture(for: task),
        including: focus.isEditing(task) ? .subviews : .all
      )
    // Posé sur la LIGNE et non sur un `Group` englobant : un modificateur sur le `ForEach` d'un
    // `LazyVStack` risque de lui faire évaluer d'un coup toutes ses rangées — la lenteur qu'on
    // vient justement de retirer. `pageHeader` (anneau, titre, notes) reste au-dessus, intact.
  }

  /// En-tête de section ou tâche : deux rendus distincts, même enveloppe drag/drop (posée par
  /// l'appelant). L'en-tête a désormais, comme la tâche, un état repos (titre en lecture) et un état
  /// édition (double-clic), pilotés par `focus`.
  @ViewBuilder
  private func row(for task: TaskItem) -> some View {
    if task.isHeader {
      HeaderRow(
        task: task,
        isSelected: focus.isSelected(task),
        isEditing: focus.isEditing(task),
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
        isSelected: focus.isSelected(task),
        isEditing: focus.isEditing(task),
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
      focus.select(task)
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
      focus.edit(task)
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
    guard focus.isEditing(task) else { return }
    applyQuickEntry(to: task)
    withAnimation(taskFlow) { focus.endEditing(task) }
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
      focus.forget(task)
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
    if let editing = list.tasks.first(where: { $0.persistentModelID == focus.editing }) {
      applyQuickEntry(to: editing)
    }
    withAnimation(taskFlow) {
      focus.dismiss()
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
    guard !focus.isIdle || focusedDraft != nil || notesFocused
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
  /// `dragState`) : un champ n'est jamais un cas spécial à calculer à la main, juste une ligne non
  /// déplaçable de plus dans la séquence — c'est cette uniformité qui lui garantit une continuité
  /// exacte au drop (même principe que la rangée « + Nouvelle liste » de la sidebar, cf.
  /// `SidebarView.RowKey.addList`, qui participe déjà à son propre moteur de réordonnancement).
  fileprivate enum RowKey: Hashable {
    case task(PersistentIdentifier)
    case field(String)
  }

  /// Séquence physique complète, dans l'ordre d'affichage : chaque bloc = son en-tête (s'il y en a
  /// une), ses tâches, puis son champ « Nouvelle tâche ». Base commune du calcul de décalage pour
  /// les tâches ET les champs (cf. `dragState`).
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

  /// Tout ce que le glissement courant produit, en une seule passe. `nil` hors drag (ou tant que
  /// les positions ne sont pas mesurées).
  ///
  /// DEUX espaces d'index, et c'est délibéré :
  ///
  /// - `rows` — les lignes PHYSIQUES (tâches, en-têtes ET champs « Nouvelle tâche ») : c'est là que
  ///   se calculent les décalages. Un champ y participe comme n'importe quelle autre ligne, sans
  ///   traitement séparé — c'est cette uniformité, et pas une astuce d'animation, qui lui donne une
  ///   continuité exacte au drop ;
  /// - `tasks` — les seules TÂCHES : c'est là que s'ancre le trou d'insertion et que s'écrit
  ///   l'ordre. Le trou doit se caler sous une tâche, jamais sous un champ (invisible pendant le
  ///   transport, il le poserait un cran trop bas), et `sortIndex` ne numérote que des tâches.
  ///
  /// Un drag d'EN-TÊTE n'a qu'un espace : ses voisines se calculent en tâches seulement, les champs
  /// des autres blocs restant simplement invisibles. Les deux mises en page sont alors la même.
  private struct DragState {
    let dragged: [TaskItem]
    let others: [TaskItem]
    let rows: ReorderLayout<RowKey>
    let tasks: ReorderLayout<RowKey>
  }

  private func dragState() -> DragState? {
    guard draggingID != nil, let first = draggedGroup.first,
      let dragFrame = rowFrames[.task(first.persistentModelID)],
      let groupFrame = groupRect(draggedGroup)
    else { return nil }
    let ordered = list.orderedTasks
    let draggedIDs = Set(draggedGroup.map(\.persistentModelID))
    let others = ordered.filter { !draggedIDs.contains($0.persistentModelID) }
    guard
      let origin = ordered.firstIndex(where: { $0.persistentModelID == first.persistentModelID })
    else { return nil }
    let otherKeys = others.map { RowKey.task($0.persistentModelID) }
    // Ce qui VOYAGE : l'en-tête seule pour un bloc, la ligne pour une tâche. Dans les deux cas la
    // première ligne du groupe — d'où une seule expression, sans branche.
    let unit = dragFrame.height

    if first.isHeader {
      let collapse = blockDelta ?? 0
      let insert = headerInsert(
        center: dragFrame.midY + dragOffset.height, others: others, collapse: collapse,
        origin: origin)
      let layout = ReorderLayout(
        others: otherKeys, origin: origin, insert: insert, unit: unit, collapse: collapse)
      return DragState(dragged: draggedGroup, others: others, rows: layout, tasks: layout)
    }

    // Tâche : visée ligne à ligne, sur la séquence de repos COMPLÈTE — la tâche tirée y comprise,
    // dont le créneau sert de pivot (cf. `ReorderTarget.byBoundary`).
    let tasks = ReorderLayout(
      others: otherKeys, origin: origin,
      insert: ReorderTarget.byBoundary(
        center: groupFrame.midY + dragOffset.height,
        centers: ordered.map { rowFrames[.task($0.persistentModelID)]?.midY }),
      unit: unit)

    // Le même dépôt, retraduit dans l'espace des lignes physiques : la tâche devant laquelle on se
    // pose y a simplement un autre rang, les champs comptant eux aussi.
    let allRows = physicalRows
    let draggedKey = RowKey.task(first.persistentModelID)
    guard let rowOrigin = allRows.firstIndex(of: draggedKey) else { return nil }
    let rowOthers = allRows.filter { $0 != draggedKey }
    let rowInsert =
      tasks.insert < otherKeys.count
      ? (rowOthers.firstIndex(of: otherKeys[tasks.insert]) ?? rowOthers.count)
      : rowOthers.count
    let rows = ReorderLayout(
      others: rowOthers, origin: rowOrigin, insert: rowInsert, unit: unit)
    return DragState(dragged: draggedGroup, others: others, rows: rows, tasks: tasks)
  }

  /// Insertion d'une EN-TÊTE : au DÉBUT d'un autre bloc, jamais au milieu — même politique que le
  /// drag d'un projet dans la sidebar, d'où `ReorderTarget.byBlockStart` partagé avec elle. Ce qui
  /// reste ici est l'énumération des blocs, propre à cette page.
  private func headerInsert(
    center: CGFloat, others: [TaskItem], collapse: CGFloat, origin: Int
  ) -> Int {
    guard let first = draggedGroup.first,
      let dragged = blocks.firstIndex(where: {
        $0.header?.persistentModelID == first.persistentModelID
      })
    else { return others.count }

    var candidates: [(insert: Int, center: CGFloat)] = []
    for (index, block) in blocks.enumerated() where index != dragged {
      guard let rect = groupRect(block.items) else { continue }
      // Rang dans `others`, et PAS un cumul de lignes visibles : `blocks` a écarté les tâches
      // archivées alors qu'`others` les garde, et additionner les rangées affichées donnait un
      // index trop petit d'autant de tâches cochées — l'en-tête se posait trop haut.
      let insert =
        others.firstIndex { $0.persistentModelID == block.items.first?.persistentModelID }
        ?? others.count
      // Un bloc entier est soit tout au-dessus, soit tout au-dessous du bloc tiré : celui du
      // dessous a déjà remonté du repli.
      candidates.append((insert: insert, center: rect.midY - (index > dragged ? collapse : 0)))
    }
    return ReorderTarget.byBlockStart(center: center, blocks: candidates, fallback: others.count)
  }

  /// Rectangle du trou d'insertion, dans l'espace de la liste.
  ///
  /// `ReorderLayout` en donne le haut ; ce qui s'ajoute ici est purement visuel. La hauteur de
  /// RANGÉE (`unit`) reste celle dont les voisines s'écartent, mais le rectangle DESSINÉ se ramène
  /// à la pilule : une en-tête porte ses marges HORS de son fond, un trou à la hauteur de la rangée
  /// serait visiblement plus grand que ce qu'on transporte. Une tâche a ses marges dedans, l'inset
  /// vaut donc 0 et l'expression retombe sur le cas simple.
  private func dragPlaceholderRect(_ state: DragState) -> CGRect? {
    guard let first = state.dragged.first,
      let dragFrame = rowFrames[.task(first.persistentModelID)],
      let top = state.tasks.placeholderTop(frames: rowFrames, draggedTop: dragFrame.minY)
    else { return nil }
    let inset =
      first.isHeader
      ? (top: HeaderRow.topInset, bottom: HeaderRow.bottomInset)
      : (top: CGFloat(0), bottom: CGFloat(0))
    return CGRect(
      x: dragFrame.minX, y: top + inset.top,
      width: dragFrame.width, height: state.tasks.unit - inset.top - inset.bottom)
  }

  /// Décalage d'une ligne : le groupe tiré suit le curseur en 2D (soulevé), les autres rejoignent
  /// verticalement la place qu'elles auront une fois l'ordre écrit.
  private func rowOffset(for task: TaskItem, offsets: [RowKey: CGFloat]) -> CGSize {
    if draggedGroup.contains(where: { $0.persistentModelID == task.persistentModelID }) {
      return dragOffset
    }
    return CGSize(width: 0, height: offsets[.task(task.persistentModelID)] ?? 0)
  }

  /// Décalage d'un champ « Nouvelle tâche » : rigoureusement le même mécanisme que `rowOffset`,
  /// aucun calcul qui lui soit propre — `offsets` contient déjà le sien s'il doit bouger.
  private func fieldOffset(for block: TaskBlock, offsets: [RowKey: CGFloat]) -> CGFloat {
    offsets[.field(block.id)] ?? 0
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
          pressWasSelected = focus.isSelected(task)
          if !focus.isEditing(task) && !focus.isSelected(task) {
            select(task)
          }
        }
        // Empoignade au-delà du seuil : pas de drag d'une carte/en-tête ouverte en édition.
        if draggingID == nil {
          guard !focus.isEditing(task) else { return }
          guard abs(value.translation.height) > 6 || abs(value.translation.width) > 6 else {
            return
          }
          focus.select(task)
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
        guard !moved, !focus.isEditing(task) else { return }
        if pressWasSelected {
          beginEditing(task)
        }
      }
  }

  /// Écrit l'ordre atteint dans les `sortIndex` et retombe les décalages à 0. Comme les lignes
  /// (ET les champs « Nouvelle tâche », cf. `dragState`) sont déjà visuellement à leur cible, la
  /// bascule ordre↔offset ne produit aucun saut — révélation immédiate, sans exception.
  private func endDrag() {
    // `dragState` lit `draggingID`/`draggedGroup` : on capture le plan AVANT de désarmer.
    let state = dragState()
    withAnimation(.snappy(duration: 0.22)) {
      if let state {
        let newOrder = state.tasks.reordered(state.dragged, among: state.others)
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
            .font(.app(9, weight: .semibold))
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
      // Raccourci texte : « ajd » + Tab devient « @today », que l'`onChange` ci-dessous change
      // aussitôt en pastille. Sans déclencheur reconnu, Tab reste le Tab du système (champ
      // suivant) — on n'avale pas une touche de navigation pour rien.
      .onKeyPress(.tab) {
        guard let resolved = QuickEntry.resolving(drafts[block.id] ?? "", shortcuts: shortcuts)
        else { return .ignored }
        // Une commande d'app change de page : `createTask` la reconnaît par le même chemin
        // qu'Entrée, et emmène d'abord la tâche commencée dans sa liste — sinon elle
        // disparaîtrait avec la vue qu'on quitte.
        if resolved.command == nil {
          drafts[block.id] = resolved.text
        } else {
          createTask(in: block, refocus: false)
        }
        return .handled
      }
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
    // Le raccourci texte resté en fin de champ est validé ici aussi, pas seulement par ⇥ : sans ça
    // « ajd ↩ » créerait une tâche nommée « ajd ». La commande d'app, elle, part en `defer` — après
    // que la tâche commencée soit posée dans SA liste, avant de quitter la page.
    let resolved = QuickEntry.resolving(drafts[block.id] ?? "", shortcuts: shortcuts)
    defer { resolved?.command?.run() }
    // Un jeton peut aussi être encore dans le texte (Entrée sans espace final) : le parseur repasse.
    let entry = QuickEntry(
      parsing: resolved?.text ?? drafts[block.id] ?? "", names: quickEntryNames)
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

  private var shortcuts: [TextShortcut] { TextShortcut.decode(shortcutData) }

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
        .font(.app(.title).bold())
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
          .font(.app(.title).bold())
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
        .font(.app(16, weight: .semibold))
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
      font: .app(),
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
    withAnimation(taskSelectFade) { focus.deselect() }
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
      withAnimation(taskFlow) { focus.edit(id: id) }
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
    focus.forget(task)
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
    for item in block { focus.forget(item) }
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
      withAnimation(taskFlow) { focus.edit(id: id) }
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
            .font(.app(.title).bold())
        }
        // Même encadré que la page de liste (cf. `NotesBox`) : les deux avaient deux visuels
        // distincts (ici un simple ZStack sans fond), plus de raison de diverger.
        NotesBox(
          notes: $project.notes,
          font: .app(),
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
            Text(list.title.isEmpty ? "Sans titre" : list.title).font(.app(.headline))
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

        ForEach(list.orderedTasks) { task in
          taskRow(task).listRowSeparator(.hidden)
        }

        if list.tasks.isEmpty {
          Text("Aucune tâche")
            .font(.app(.callout))
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
        .font(.app(.subheadline).bold())
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
          .font(.app(.body))
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

/// Position de repos de chaque ligne (par `persistentModelID`), collectée par préférence pendant le
/// layout et lue pour calculer où ouvrir le trou pendant un réordonnancement (cf. `dragState`).
/// Un bloc = une en-tête (optionnelle) et les tâches qui la suivent jusqu'à la prochaine en-tête.
/// Le bloc « top » (en-tête nil) réunit les tâches d'avant la première en-tête, ou toute la liste
/// s'il n'y a aucune en-tête.
private struct TaskBlock: Identifiable {
  let id: String
  let header: TaskItem?
  let tasks: [TaskItem]

  /// Les lignes du bloc dans l'ordre (en-tête d'abord si présente), pour le drag d'un bloc entier.
  var items: [TaskItem] { (header.map { [$0] } ?? []) + tasks }
}

/// Hauteur naturelle du corps d'édition d'une tâche (notes + rangée d'actions), pour animer sa
/// RÉVÉLATION — la fenêtre qui s'ouvre — sans faire bouger le contenu. Une seule tâche est éditée à
/// la fois, donc une seule valeur en vol ; `max` par prudence si deux mesures se chevauchent.
struct EditorHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = max(value, nextValue())
  }
}

/// Position de repos de chaque ligne physique — tâche/en-tête RÉELLE ou champ « Nouvelle tâche »
/// VIRTUEL, cf. `ListPageView.RowKey` — dans le même espace de coordonnées. Une seule clé pour les
/// deux : un champ participe au MÊME calcul de décalage qu'une tâche (cf. `dragState`), jamais un
/// cas séparé à maintenir à la main.
private struct RowFrameKey: PreferenceKey {
  static let defaultValue: [ListPageView.RowKey: CGRect] = [:]
  static func reduce(
    value: inout [ListPageView.RowKey: CGRect], nextValue: () -> [ListPageView.RowKey: CGRect]
  ) {
    value.merge(nextValue(), uniquingKeysWith: { $1 })
  }
}

@MainActor
private func comingSoon(_ title: String, searchPresented: Binding<Bool>) -> some View {
  VStack(alignment: .leading, spacing: 8) {
    // Le titre de l'onglet reste hors du fondu, comme partout ailleurs.
    Text(title).font(.app(.title).bold())
    Text("À rebrancher.").foregroundStyle(.tertiary)
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
      .font(.app(.callout))
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
