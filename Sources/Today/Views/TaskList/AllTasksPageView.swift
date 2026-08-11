import EventKit
import SwiftData
import SwiftUI

/// Page « Tâches » : l'inventaire complet. Tout ce qui reste à faire, où que ça vive.
///
/// Elle ne répond PAS à la même question qu'« Aujourd'hui » : celle-là montre ce qu'on a décidé de
/// faire aujourd'hui, celle-ci montre tout, pour aller y piocher. Avant, « Tâches » n'affichait que
/// l'Inbox — indiscernable d'une page de liste, et les tâches des projets restaient invisibles tant
/// qu'on n'ouvrait pas chaque projet un par un.
///
/// D'abord le non-classé, à nu — sans en-tête ni dépliant : c'est le flux d'arrivée, la première
/// chose qu'on lit et le seul endroit où l'on crée. Puis « Aujourd'hui » (déplié), puis un dépliant
/// par projet et par liste hors projet (repliés). Une tâche n'apparaît QU'UNE fois : celles du jour
/// sont retirées de tout le reste, sinon la même ligne se serait sélectionnée à deux endroits.
///
/// ponytail: pas de réordonnancement ni d'en-têtes de section (cf. `ListPageView` pour ça) —
/// l'ordre vient de `SmartList.sort`. Le reste (édition, suppression, dates, durée, rappels,
/// sous-tâches) vient de la `TaskRow` partagée, comme sur « Aujourd'hui ».
struct AllTasksPageView: View {
  @Binding var searchPresented: Bool

  @Environment(\.modelContext) private var modelContext
  @Environment(RemindersService.self) private var remindersService
  /// Le glisser vers la barre latérale : la page n'en connaît que le nom, tout se joue au
  /// relâchement (cf. `dropTaskDrag`).
  @Environment(SidebarDrop.self) private var filing
  @Query private var allTasks: [TaskItem]
  /// Cibles du « Déplacer vers… » : toutes les listes, comme sur « Aujourd'hui » — les tâches
  /// affichées viennent déjà d'un peu partout.
  @Query private var allLists: [TodoList]
  @Query private var allProjects: [Project]
  @Query(filter: #Predicate<TodoList> { $0.isInbox }) private var inboxLists: [TodoList]

  /// Brouillon de la section « Non classé » — la seule qui crée : une tâche notée ici n'a ni
  /// projet ni date, c'est la définition même de l'Inbox.
  @State private var draft = ""
  @FocusState private var draftFocused: Bool
  @State private var focus = TaskFocus()
  /// Le glissement en cours. Il est borné à la section de la tâche tirée — chaque dépliant est sa
  /// propre zone, avec ses butées (cf. `rowsView`, qui dit pourquoi la traversée a été retirée).
  @State private var reorder = TaskPageReorder()
  /// Ligne dont les sous-tâches sont repliées le temps du geste (cf. `TaskRow.collapsedForDrag`).
  @State private var dragCollapsedID: PersistentIdentifier?
  /// Sections dont le repli DIFFÈRE de leur défaut (cf. `expansion(of:)`) — stocker l'écart plutôt
  /// que l'état permet à chaque section de garder son propre défaut sans initialisation.
  /// ponytail: état de session, non persisté. Le persister demanderait une clé stable par projet ;
  /// à faire si retrouver ses dépliants au relancement manque vraiment.
  @State private var toggled: Set<String> = []
  // Les bandes de section (`measureSectionBand`) ont été DÉBRANCHÉES. Elles servaient à désigner
  // une section vide comme cible de dépôt — ce qui n'a plus de sens depuis que le glisser est borné
  // à sa propre section (cf. `rowsView`). Elles étaient par ailleurs la source de mesures republiées
  // en continu qui faisaient planter le panneau de date sur cette page, et elles ne manquent donc à
  // personne. `AllTasksPage.emptySection` est parti avec elles — rien à retirer de plus.
  /// Repli de la section « Calendrier ». Elle n'est pas une section de `AllTasksPage` — elle ne
  /// porte aucune tâche —, donc elle ne passe pas par `toggled` : son état lui appartient.
  @State private var calendarExpanded = true

  var body: some View {
    // Construite UNE fois par rendu, puis distribuée. Avant, chaque lecture de `sections`
    // refiltrait et retriait toute la base — plusieurs fois par image.
    let page = AllTasksPage.build(tasks: allTasks, projects: allProjects, lists: allLists)
    let offsets = reorder.offsets()
    // `GeometryReader` + largeur EXPLICITE, pas `maxWidth: .infinity` : un `ScrollView` ne borne
    // pas la largeur de son contenu, et un `VStack` ne propose pas la sienne à ses enfants — un
    // `TextField` focalisé (le titre en édition) délègue alors son rendu au field editor d'AppKit,
    // de largeur idéale nulle, et le titre disparaît purement et simplement. Même correctif que
    // `ListPageView` (cf. son en-tête de fichier), qui manquait ici. Les `.frame(maxWidth: .infinity)`
    // plus bas (sections, lignes) restent tels quels : une fois la racine bornée à une largeur
    // CONCRÈTE, ils la relaient sans avoir besoin de la recalculer eux-mêmes.
    return GeometryReader { geo in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          header

          // UNE seule énumération, celle que le socle clavier reçoit aussi. La boîte de réception a
          // longtemps été rendue à part, et c'est exactement comme ça qu'elle a fini par manquer à
          // l'ordre du clavier sans que rien ne le montre.
          ForEach(page.sections) { section in
            sectionView(section, offsets: offsets)
            // Juste après le jour : ce que le calendrier impose aujourd'hui se lit avec ce qu'on a
            // décidé d'y faire, comme sur « Aujourd'hui » qui les montre l'un au-dessus de l'autre.
            if section.kind == .today { calendarSection }
          }
        }
        .frame(width: max(geo.size.width - 2 * gutter, 1), alignment: .leading)
        .padding(.horizontal, gutter)
        .padding(.top, 30)
      }
    }
    // Le socle commun des pages de tâches : ⌫ et ↑/↓. Les mêmes sections que le `body` rend.
    // Le trou d'insertion : même brique que « Aujourd'hui », même courbe.
    .taskReorderPlaceholder(reorder)
    // Le socle commun des pages de tâches : ⌫, ↑/↓, clic dans le vide, et les cadres des lignes que
    // le glissement lui emprunte. Les mêmes sections que le `body` rend.
    .taskPageBase(
      focus: $focus,
      blocks: { page.blocks(isExpanded: isExpanded) },
      delete: delete,
      reorder: $reorder,
      // Le MÊME geste que le ⊕ de la barre du bas : le champ de saisie prend le focus.
      newTask: createTaskInEditMode
    )
    .onChange(of: page.sections.count) { _, _ in
      // Une section qui apparaît ou disparaît sous le geste (la dernière tâche d'un projet vient
      // de le quitter) invaliderait la séquence figée : on désarme plutôt que de viser dans le vide.
      if reorder.isDragging { reorder.end() }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      BottomToolbar(
        // Sans champ affiché, le ⊕ retombe sur ⌘N plutôt que de rester muet.
        onNewTask: {
          if page.sections.first(where: { !$0.hasHeader }).map(showsNewTaskField) == true {
            draftFocused = true
          } else {
            createTaskInEditMode()
          }
        },
        onInsertHeader: nil,
        onSearch: { searchPresented = true })
    }
    // Le cache vit dans le service (cf. `RemindersService`), pas ici : cette page est recréée à
    // chaque fois que l'onglet redevient la sélection, une `@State` locale repartirait de zéro.
    .task { await remindersService.refreshToday(now: Date()) }
  }

  // MARK: Calendrier (lecture seule)

  /// Les événements du Calendrier Apple du jour, dans leur propre section — le MÊME contenu et la
  /// MÊME `EventRow` que « Aujourd'hui », qui les montre en tête de page. Ils ne sont pas des
  /// tâches : ils ne se sélectionnent pas, ne se glissent pas et ne comptent pas pour le clavier,
  /// donc ils restent hors de `AllTasksPage`.
  ///
  /// Absente si vide, comme les sections « Rappels »/« Événements » d'« Aujourd'hui ».
  @ViewBuilder private var calendarSection: some View {
    let events = remindersService.todayEvents
    if !events.isEmpty {
      // Le MÊME dépliant fait main que les sections de tâches juste au-dessus. Ici le rognage d'un
      // `DisclosureGroup` ne gênerait pas (rien ne se glisse dans le calendrier), mais deux
      // dépliants d'aspect différent sur la même page se verraient — et c'est exactement la
      // divergence que `disclosureFlow` a été créé pour éteindre.
      VStack(alignment: .leading, spacing: 0) {
        Button {
          calendarExpansion.wrappedValue.toggle()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "calendar")
              .font(.app(11))
              .foregroundStyle(Color.secondary)
            Text("Calendrier")
            Text("\(events.count)")
              .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            // À droite, comme tous les autres dépliants de l'app (cf. `sectionView` juste
            // au-dessus, `archiveSection`) — jamais à gauche.
            Image(systemName: "chevron.right")
              .font(.app(10, weight: .semibold))
              .rotationEffect(.degrees(calendarExpanded ? 90 : 0))
          }
          .font(.app(.subheadline).weight(.semibold))
          .foregroundStyle(.secondary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Même colonne que les sections de tâches juste au-dessus (cf. `sectionView`,
        // `taskContentColumn`).
        .padding(.horizontal, taskContentColumn)

        if calendarExpanded {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(events, id: \.eventIdentifier) { EventRow(event: $0) }
          }
          .padding(.top, 6)
          .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, 14)
    }
  }

  /// `withAnimation` sur la MUTATION : le triangle change le binding depuis son bouton AppKit,
  /// hors de notre code (même règle que `expansion(of:)`).
  private var calendarExpansion: Binding<Bool> {
    Binding(
      get: { calendarExpanded },
      set: { open in withAnimation(disclosureFlow) { calendarExpanded = open } })
  }

  private var header: some View {
    HStack(spacing: 10) {
      PageHeaderIcon(systemImage: SmartList.all.systemImage, tint: SmartList.all.color)
      Text(SmartList.all.label)
        .font(.app(.title).bold())
      Spacer(minLength: 0)
    }
    // Colonne des repères de section (même règle que `TodayPageView.header`).
    .padding(.leading, taskContentColumn)
    .padding(.bottom, 14)
  }

  // MARK: Sections

  /// Un seul rendu pour toutes les sections — y compris « Aujourd'hui », qui s'ouvre par défaut
  /// mais se replie comme les autres si l'on ne veut voir que ses projets.
  @ViewBuilder private func sectionView(
    _ section: AllTasksPage.Section, offsets: [TaskRowKey: CGSize]
  ) -> some View {
    if section.hasHeader {
      // **Dépliant fait main, et PAS un `DisclosureGroup`** — le seul écart au « natif d'abord » du
      // projet, et il est mesuré : un `DisclosureGroup` se replie en ROGNANT son contenu, c'est le
      // mécanisme même de son animation. Or cette page est la seule où l'on glisse une tâche d'une
      // section à l'autre : la ligne tirée sort du cadre de sa section et se faisait couper net,
      // puis disparaissait. `.zIndex` ne sert à rien contre ça — il ordonne des voisines, il ne
      // fait pas sortir d'un cadre qui rogne.
      //
      // Le même dépliant existait déjà à la main pour les archives d'une liste (cf.
      // `ListPageView.archiveSection`) : c'est le motif qu'on reprend, pas un troisième inventé.
      // Bénéfice au passage : le contenu est vraiment RETIRÉ quand la section est repliée (un
      // `DisclosureGroup` le garde monté), donc `.transition(.opacity)` s'applique pour de vrai et
      // les lignes repliées ne se mesurent plus.
      let open = isExpanded(section)
      VStack(alignment: .leading, spacing: 0) {
        Button {
          expansion(of: section).wrappedValue.toggle()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: symbol(of: section.kind))
              .font(.app(11))
              // Teinte de la vue intelligente quand elle en a une (le jaune d'« Aujourd'hui ») : la
              // section se repère du coin de l'œil, comme sa ligne dans la sidebar.
              .foregroundStyle(tint(of: section.kind) ?? Color.secondary)
              .frame(width: 16)
            Text(section.title)
            Text("\(section.tasks.count)")
              .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
              .font(.app(10, weight: .semibold))
              .rotationEffect(.degrees(open ? 90 : 0))
          }
          .font(.app(.subheadline).weight(.semibold))
          .foregroundStyle(.secondary)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Colonne des repères de section, comme le titre de page (cf. `header`) : les lignes qu'elle
        // coiffe décrochent d'un `rowInset` de plus (cf. `taskRowColumn`).
        .padding(.horizontal, taskContentColumn)

        if open {
          rowsView(of: section, offsets: offsets)
            .transition(.opacity)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.top, section.kind == .today ? 100 : 14)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        rowsView(of: section, offsets: offsets)
        // Le champ appartient au pan à nu : c'est le non-classé, et la seule section où l'on crée
        // (une tâche notée ici n'a ni projet ni date — la définition de l'Inbox).
        if showsNewTaskField(section) { newTaskRow }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  /// **Chaque section est sa PROPRE zone de glissement.** La séquence donnée au moteur est
  /// `section.tasks`, jamais les lignes de toute la page — et c'est toute la correction.
  ///
  /// Avant, le moteur recevait l'inventaire complet et raisonnait donc sur une liste PLATE : les
  /// titres de section occupent de la hauteur à l'écran, mais cette hauteur n'existait pas pour le
  /// calcul. Plus on traversait de titres, plus l'écart se creusait entre l'endroit où la ligne est
  /// dessinée et celui où le trou s'ouvre — c'est le « flou » constaté à l'usage. Et un titre
  /// n'étant pas une ligne, lâcher dessus faisait lire la tâche du DESSUS : on atterrissait dans la
  /// section précédente, pas dans celle qu'on visait.
  ///
  /// Bornée à sa section, la séquence est homogène et contiguë : plus de trou d'air, et les deux
  /// bouts du dépliant deviennent des BUTÉES naturelles — une tâche déjà en tête n'ouvre plus de
  /// trou au-dessus d'elle, exactement comme sur les autres pages.
  ///
  /// Conséquence assumée : on ne fait plus voyager une tâche d'une section à l'autre au doigt. Ce
  /// déplacement-là existe déjà, et il est plus sûr — le menu ▸ *Déplacer vers…* et le sélecteur
  /// *Quand…* disent explicitement ce que le glisser devait deviner.
  private func rowsView(
    of section: AllTasksPage.Section, offsets: [TaskRowKey: CGSize]
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(section.tasks) { task in
        taskRow(
          for: task, isToday: section.kind == .today,
          offset: offsets[.task(task.persistentModelID)] ?? .zero, rows: section.tasks)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// L'habillage d'un bandeau, déduit de la PROVENANCE de la section. Le modèle ne connaît ni
  /// icône ni couleur : ce sont des choix d'affichage, ils vivent ici.
  private func symbol(of kind: AllTasksPage.Kind) -> String {
    switch kind {
    case .inbox: return ""
    case .today: return SmartList.today.systemImage
    case .project: return "folder"
    case .list: return "list.bullet"
    }
  }

  private func tint(of kind: AllTasksPage.Kind) -> Color? {
    kind == .today ? SmartList.today.color : nil
  }

  /// Une section est-elle dépliée ? `toggled` retient l'ÉCART au défaut et pas l'état — une `Set`
  /// des ouvertes aurait demandé de l'amorcer au premier rendu —, d'où le XOR. Sans bandeau, il n'y
  /// a rien à replier.
  ///
  /// Lu par le dépliant ET par le socle clavier (les flèches ne parcourent que le visible) :
  /// la règle vit à un seul endroit.
  private func isExpanded(_ section: AllTasksPage.Section) -> Bool {
    guard section.hasHeader else { return true }
    return toggled.contains(section.id) != section.defaultExpanded
  }

  /// Le `withAnimation` enveloppe la MUTATION, pas le rendu. La raison a changé depuis que le
  /// dépliant est fait main — c'était le bouton AppKit du `DisclosureGroup` qui écrivait `toggled`
  /// hors de notre code —, mais la règle tient toujours : ce qui s'anime ici, c'est l'apparition et
  /// la disparition RÉELLES des lignes, et seul un `withAnimation` autour de l'écriture les met
  /// dans la même transaction que la `.transition` du bloc. Même geste que `toggleCollapse` côté
  /// sidebar : sans lui, saccadé et quasi instantané au lieu de `disclosureFlow`.
  private func expansion(of section: AllTasksPage.Section) -> Binding<Bool> {
    Binding(
      get: { isExpanded(section) },
      set: { open in
        withAnimation(disclosureFlow) {
          if open == section.defaultExpanded {
            toggled.remove(section.id)
          } else {
            toggled.insert(section.id)
          }
        }
      })
  }

  // MARK: Lignes de tâche

  /// La MÊME `TaskRow` que partout ailleurs. Dans « Aujourd'hui » : pas de date (elle est
  /// implicite) mais le rattachement, puisque la section mélange les provenances. Ailleurs : la
  /// date compte, le rattachement est celui de la section.
  private func taskRow(
    for task: TaskItem, isToday: Bool, offset: CGSize = .zero, rows: [TaskItem] = []
  ) -> some View {
    TaskRow(
      task: task,
      isSelected: focus.isSelected(task),
      isEditing: focus.isEditing(task),
      moveTargets: allLists.filter { $0.persistentModelID != task.list?.persistentModelID },
      showsDate: !isToday,
      parentTag: isToday ? TaskParentTag(of: task) : nil,
      onBeginEditing: { beginEditing(task) },
      onEndEditing: { endEditing(task) },
      onMove: { move(task, to: $0) },
      onDuplicate: { duplicate(task) },
      onDelete: { delete(task) },
      onCompletionChanged: {},
      collapsedForDrag: dragCollapsedID == task.persistentModelID
    )
    .rowPressGesture(
      isSelected: focus.isSelected(task),
      isEditing: focus.isEditing(task),
      onSelect: { select(task) },
      onEdit: { beginEditing(task) },
      onDrag: { translation, start in
        // Replier AVANT d'armer, et renoncer à CETTE image du geste : les cadres se gèlent dès le
        // premier `track`. Cf. `TaskRow.collapsedForDrag`.
        if !reorder.isDragging, dragCollapsedID == nil, !task.subtasks.isEmpty {
          dragCollapsedID = task.persistentModelID
          return
        }
        reorder.track(task, by: translation, in: rows)
        // Cadre de repos gelé dès l'empoignade : toujours la même valeur pendant tout le geste.
        if let restingMinX = reorder.frames[.task(task.persistentModelID)]?.minX {
          filing.arm(grabOffsetX: start.x - restingMinX)
        }
      },
      onDrop: { dropDraggedTask() }
    )
    .taskRowDragLayer(reorder, task: task, offset: offset, airborne: filing.isAirborne)
    // La même entrée que sur une page de liste : créée, ou revenue par ⌘Z.
    .taskRowInsertion()
    // Ce qui permet au socle de savoir qu'un clic est tombé À CÔTÉ des tâches.
    .measureTaskRow(task)
  }

  /// Relâchement. La mécanique est partagée (`dropTaskDrag`) ; ce qui appartient à cette page,
  /// c'est la règle de rattachement — une tâche lâchée dans un dépliant rejoint sa liste.
  private func dropDraggedTask() {
    // Le dépliant se rouvre en partant, quoi qu'il arrive ensuite — y compris quand le geste s'est
    // arrêté sur le repli, avant d'avoir armé le moindre glissement (d'où la place AVANT le garde).
    if dragCollapsedID != nil {
      withAnimation(disclosureFlow) { dragCollapsedID = nil }
    }
    guard let dragged = reorder.draggedTask else { return }
    // Reconstruite ici plutôt que passée de rangée en rangée : ça n'arrive qu'une fois par geste,
    // au relâchement, et la faire descendre jusqu'à chaque ligne pour ce seul usage encombrerait
    // toute la chaîne.
    let page = AllTasksPage.build(tasks: allTasks, projects: allProjects, lists: allLists)
    // Pas de `landing` : il désignait une section d'ACCUEIL par la géométrie, pour les cas où la
    // tâche changeait de section en cours de route. Le glisser étant borné à sa section (cf.
    // `rowsView`), `ordered` ne contient que des voisines de la MÊME section — la destination est
    // donc celle d'origine, et la lire par la voisine suffit et reste la plus précise (dans un
    // projet à plusieurs listes, elle dit laquelle).
    dropTaskDrag(&reorder, onto: filing, lists: allLists, in: modelContext) { ordered in
      page.applyDrop(
        of: dragged, in: ordered, today: Calendar.current.startOfDay(for: Date()))
      try? modelContext.save()
    }
  }

  private func select(_ task: TaskItem) {
    withAnimation(taskSelectFade) { focus.select(task) }
    // Même raison que dans `ListPageView.select` : sans ça le champ « Nouvelle tâche » reste le
    // premier répondeur AppKit et intercepte ⌫ au lieu de la suppression de la sélection.
    draftFocused = false
  }

  private func beginEditing(_ task: TaskItem) {
    withAnimation(taskFlow) { focus.edit(task) }
    draftFocused = false
  }

  private func endEditing(_ task: TaskItem) {
    guard focus.isEditing(task) else { return }
    withAnimation(taskFlow) { focus.endEditing(task) }
  }

  private func move(_ task: TaskItem, to target: TodoList) {
    focus.forget(task)
    task.move(to: target)
    try? modelContext.save()
  }

  private func duplicate(_ task: TaskItem) {
    guard let list = task.list else { return }
    let clone = task.copy(into: list)
    clone.sortIndex = task.sortIndex + 1
    modelContext.insertAndSave(clone)
  }

  private func delete(_ task: TaskItem) {
    focus.forget(task)
    withAnimation(taskInsert) {
      modelContext.deleteTasksAndSave([task], forgetReminders: remindersService.forgetReminders)
    }
  }

  /// Pan à nu vide seulement — ou focalisé, pour ne pas se dérober en pleine saisie enchaînée. Cf.
  /// `ListPageView.showsNewTaskField`. Lu aussi par le ⊕ de la barre du bas, qui ne peut donc pas
  /// viser un champ absent.
  private func showsNewTaskField(_ section: AllTasksPage.Section) -> Bool {
    section.tasks.isEmpty || draftFocused
  }

  /// Création dans la boîte de réception, SANS date — c'est ce qui la distingue du champ
  /// d'« Aujourd'hui », qui date d'office : ici on note, on classera plus tard.
  private var newTaskRow: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 4.5, style: .continuous)
        .strokeBorder(Color(nsColor: .tertiaryLabelColor), lineWidth: 1)
        .overlay {
          Image(systemName: "plus")
            .font(.app(9, weight: .semibold))
            .foregroundStyle(.tertiary)
        }
        .frame(width: 16, height: 16)
      TextField("Nouvelle tâche…", text: $draft)
        .textFieldStyle(.plain)
        // Même police qu'un titre de tâche (cf. `ListPageView.newTaskRow`) : le `body` natif est
        // 1 pt plus petit que l'échelle `Typo` de l'app.
        .font(.app(.body))
        .focused($draftFocused)
        .onSubmit(createTask)
    }
    // Mêmes paddings qu'une `TaskRow` au repos : la rangée de création garde le rythme des tâches.
    .padding(.vertical, 6)
    .padding(.horizontal, rowInset)
    // Même décalage que `TaskRow` : ce ＋ tient la place d'une case, il suit donc `taskRowColumn`.
    .padding(.leading, taskContentColumn)
    // Pendant un glisser, le champ s'efface — il encombrerait le déplacement, et une page de liste
    // le fait depuis toujours (cf. `ListPageView`, même modificateur). Deux pages qui se comportent
    // différemment pendant le MÊME geste, c'est exactement ce que le socle commun sert à éviter.
    //
    // Opacité et PAS un retrait de l'arbre : les cadres des lignes sont gelés à l'empoignade en
    // supposant que la mise en page ne bouge plus. Retirer le champ ferait s'effondrer sa hauteur
    // pendant tout le geste et fausserait le calcul du trou d'insertion.
    .opacity(reorder.isDragging ? 0 : 1)
    .animation(.easeInOut(duration: 0.15), value: reorder.isDragging)
  }

  /// ⌘N : la tâche est créée VIDE et s'ouvre AUSSITÔT en édition — carte complète, avec notes,
  /// sous-tâches, date et priorité. C'est le geste de `ListPageView.createTaskInEditMode`, et il
  /// vaut désormais sur toutes les pages qui savent créer : le même raccourci ne peut pas donner
  /// deux résultats selon l'onglet.
  ///
  /// À ne pas confondre avec le ⊕ de la barre du bas (et le clic dans le champ « Nouvelle tâche »),
  /// qui posent seulement le focus sur ce champ : là on tape un titre et on valide, sans ouvrir la
  /// carte. Les deux chemins coexistent volontairement — l'un pour noter vite, l'autre pour
  /// détailler tout de suite.
  private func createTaskInEditMode() {
    // Dans la boîte de réception : une tâche notée ici n'a ni projet ni date, comme celle du champ
    // du bas. C'est la seule section de cette page qui crée.
    guard let inbox = inboxLists.first else { return }
    let task = TaskItem(title: "", list: inbox)
    task.sortIndex = (inbox.tasks.map(\.sortIndex).max() ?? -1) + 1
    withAnimation(taskInsert) { modelContext.insertAndSave(task) }
    let id = task.persistentModelID
    // Au tour de boucle SUIVANT : la rangée doit exister dans l'arbre de vues avant que le focus
    // puisse s'y poser. Même raison, et même remède, que sur une page de liste.
    DispatchQueue.main.async {
      withAnimation(taskFlow) { focus.edit(id: id) }
    }
  }

  private func createTask() {
    let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    draft = ""
    guard !title.isEmpty, let inbox = inboxLists.first else {
      draftFocused = false
      return
    }
    let task = TaskItem(title: title, list: inbox)
    task.sortIndex = (inbox.tasks.map(\.sortIndex).max() ?? -1) + 1
    withAnimation(taskInsert) { modelContext.insertAndSave(task) }
    draftFocused = true
  }
}
