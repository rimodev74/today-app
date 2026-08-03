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
  /// Le glissement en cours. Ici il traverse les sections : lâcher une tâche dans un autre
  /// dépliant la rattache à cette liste (cf. `AllTasksPage.applyDrop`). C'est la page fourre-tout,
  /// on y range en déplaçant.
  @State private var reorder = TaskPageReorder()
  /// Sections dont le repli DIFFÈRE de leur défaut (cf. `expansion(of:)`) — stocker l'écart plutôt
  /// que l'état permet à chaque section de garder son propre défaut sans initialisation.
  /// ponytail: état de session, non persisté. Le persister demanderait une clé stable par projet ;
  /// à faire si retrouver ses dépliants au relancement manque vraiment.
  @State private var toggled: Set<String> = []
  /// Où commence et finit chaque section à l'écran. Sert UNIQUEMENT au relâchement, pour désigner
  /// une section vide — une section qui porte des lignes se lit par sa voisine, sans géométrie.
  @State private var sectionBands: [String: CGRect] = [:]

  var body: some View {
    // Construite UNE fois par rendu, puis distribuée. Avant, chaque lecture de `sections`
    // refiltrait et retriait toute la base — plusieurs fois par image.
    let page = AllTasksPage.build(tasks: allTasks, projects: allProjects, lists: allLists)
    // La séquence affichée, toutes sections confondues : c'est elle que le glissement parcourt, et
    // c'est pour ça qu'une tâche peut passer d'un dépliant à l'autre. Le geste en fige sa propre
    // copie à l'empoignade (cf. `TaskPageReorder`) ; ce qui est RENDU reste vivant.
    let rows = page.blocks(isExpanded: isExpanded).displayedRows
    let offsets = reorder.offsets()
    return ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header

        // UNE seule énumération, celle que le socle clavier reçoit aussi. La boîte de réception a
        // longtemps été rendue à part, et c'est exactement comme ça qu'elle a fini par manquer à
        // l'ordre du clavier sans que rien ne le montre.
        ForEach(page.sections) { section in
          sectionView(section, rows: rows, offsets: offsets)
            // Ce qui rend une section VIDE désignable : sans sa bande, un dépôt dessus se rabat
            // sur la section du dessus (cf. `AllTasksPage.emptySection`).
            .measureSectionBand(section.id)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, gutter)
      .padding(.top, 30)
    }
    // Le socle commun des pages de tâches : ⌫ et ↑/↓. Les mêmes sections que le `body` rend.
    // Le trou d'insertion : même brique que « Aujourd'hui », même courbe.
    .taskReorderPlaceholder(reorder)
    .onPreferenceChange(SectionBandKey.self) { sectionBands = $0 }
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
        onNewTask: { draftFocused = true }, onInsertHeader: nil,
        onSearch: { searchPresented = true })
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      PageHeaderIcon(systemImage: SmartList.all.systemImage, tint: SmartList.all.color)
      Text(SmartList.all.label)
        .font(.app(.title).bold())
      Spacer(minLength: 0)
    }
    // Même retrait que les lignes, qui portent `rowInset` À L'INTÉRIEUR de leur fond (même règle
    // que `TodayPageView.header`).
    .padding(.leading, rowInset)
    .padding(.bottom, 14)
  }

  // MARK: Sections

  /// Un seul rendu pour toutes les sections — y compris « Aujourd'hui », qui s'ouvre par défaut
  /// mais se replie comme les autres si l'on ne veut voir que ses projets.
  @ViewBuilder private func sectionView(
    _ section: AllTasksPage.Section, rows: [TaskItem], offsets: [PersistentIdentifier: CGSize]
  ) -> some View {
    if section.hasHeader {
      DisclosureGroup(isExpanded: expansion(of: section)) {
        rowsView(of: section, rows: rows, offsets: offsets)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: symbol(of: section.kind))
            .font(.app(11))
            // Teinte de la vue intelligente quand elle en a une (le jaune d'« Aujourd'hui ») : la
            // section se repère du coin de l'œil, comme sa ligne dans la sidebar.
            .foregroundStyle(tint(of: section.kind) ?? Color.secondary)
          Text(section.title)
          Text("\(section.tasks.count)")
            .foregroundStyle(.tertiary)
        }
        .font(.app(.subheadline).weight(.semibold))
        .foregroundStyle(.secondary)
      }
      .padding(.top, 14)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        rowsView(of: section, rows: rows, offsets: offsets)
        // Le champ « Nouvelle tâche » appartient au pan à nu : c'est le non-classé, et la seule
        // section où l'on crée (une tâche notée ici n'a ni projet ni date — la définition de
        // l'Inbox).
        newTaskRow
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func rowsView(
    of section: AllTasksPage.Section, rows: [TaskItem], offsets: [PersistentIdentifier: CGSize]
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(section.tasks) { task in
        taskRow(
          for: task, isToday: section.kind == .today,
          offset: offsets[task.persistentModelID] ?? .zero, rows: rows)
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
  /// Lu par le `DisclosureGroup` ET par le socle clavier (les flèches ne parcourent que le
  /// visible) : la règle vit à un seul endroit.
  private func isExpanded(_ section: AllTasksPage.Section) -> Bool {
    guard section.hasHeader else { return true }
    return toggled.contains(section.id) != section.defaultExpanded
  }

  private func expansion(of section: AllTasksPage.Section) -> Binding<Bool> {
    Binding(
      get: { isExpanded(section) },
      set: { open in
        if open == section.defaultExpanded {
          toggled.remove(section.id)
        } else {
          toggled.insert(section.id)
        }
      })
  }

  // MARK: Lignes de tâche

  /// La MÊME `TaskRow` que partout ailleurs. Dans « Aujourd'hui » : ni date (elle est implicite) ni
  /// ⊕ (elles y sont déjà) mais le rattachement, puisque la section mélange les provenances.
  /// Ailleurs : la date compte, le rattachement est celui de la section, et le ⊕ au survol fait
  /// passer la tâche au jour même sans détour par « Quand… ».
  private func taskRow(
    for task: TaskItem, isToday: Bool, offset: CGSize = .zero, rows: [TaskItem] = []
  ) -> some View {
    TaskRow(
      task: task,
      isSelected: focus.isSelected(task),
      isEditing: focus.isEditing(task),
      moveTargets: allLists.filter { $0.persistentModelID != task.list?.persistentModelID },
      showsDate: !isToday,
      parentLabel: isToday ? parentLabel(of: task) : nil,
      onSchedule: isToday ? nil : { schedule(task) },
      onBeginEditing: { beginEditing(task) },
      onEndEditing: { endEditing(task) },
      onMove: { move(task, to: $0) },
      onDuplicate: { duplicate(task) },
      onDelete: { delete(task) },
      onCompletionChanged: {}
    )
    .rowPressGesture(
      isSelected: focus.isSelected(task),
      isEditing: focus.isEditing(task),
      onSelect: { select(task) },
      onEdit: { beginEditing(task) },
      onDrag: { reorder.track(task, by: $0, in: rows) },
      onDrop: { dropDraggedTask() }
    )
    .taskRowDragLayer(reorder, task: task, offset: offset)
    // La même entrée que sur une page de liste : créée, ou revenue par ⌘Z.
    .taskRowInsertion()
    // Ce qui permet au socle de savoir qu'un clic est tombé À CÔTÉ des tâches.
    .measureTaskRow(task)
  }

  /// Relâchement. La mécanique est partagée (`dropTaskDrag`) ; ce qui appartient à cette page,
  /// c'est la règle de rattachement — une tâche lâchée dans un dépliant rejoint sa liste.
  private func dropDraggedTask() {
    guard let dragged = reorder.draggedTask else { return }
    // Reconstruite ici plutôt que passée de rangée en rangée : ça n'arrive qu'une fois par geste,
    // au relâchement, et la faire descendre jusqu'à chaque ligne pour ce seul usage encombrerait
    // toute la chaîne.
    let page = AllTasksPage.build(tasks: allTasks, projects: allProjects, lists: allLists)
    // Lu AVANT `dropTaskDrag`, qui prend `reorder` en `inout` : le relire depuis la closure serait
    // un accès exclusif interdit, et l'état est de toute façon désarmé à ce moment-là.
    let landing = reorder.draggedCenterY.flatMap {
      page.emptySection(at: $0, bands: sectionBands)
    }
    dropTaskDrag(&reorder) { ordered in
      page.applyDrop(
        of: dragged, in: ordered, today: Calendar.current.startOfDay(for: Date()),
        landing: landing)
      try? modelContext.save()
    }
  }

  private func parentLabel(of task: TaskItem) -> String? {
    let title = task.project?.title ?? task.list?.title
    return (title?.isEmpty ?? true) ? nil : title
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
    task.list = target
    task.sortIndex = (target.tasks.map(\.sortIndex).max() ?? -1) + 1
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
      modelContext.delete(task)
      try? modelContext.save()
    }
  }

  /// Fait passer une tâche au jour même. Pas d'heure, comme partout ailleurs dans l'app.
  private func schedule(_ task: TaskItem) {
    withAnimation(taskInsert) { task.when = Calendar.current.startOfDay(for: Date()) }
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
