import SwiftData
import SwiftUI

/// Page « Tâches » : la boîte de réception. Ce qu'on note sans avoir encore décidé où ça va.
///
/// Elle a été l'inventaire complet — le non-classé, « Aujourd'hui », un dépliant par projet et par
/// liste, les événements du Calendrier. Retiré le 12 août 2026 au profit d'une ZONE DE DÉPÔT nue :
/// ce qui est rangé se lit là où il est rangé, et l'inventaire n'en était qu'une seconde vue. Le
/// pourquoi du retrait est dans `AllTasksPage` ; ce qu'il a fallu défaire, dans `PIEGES.md`.
///
/// Elle ressemble donc de nouveau à une page de liste — c'est assumé : c'est bien une liste, celle
/// de l'Inbox, avec un titre et une icône de vue intelligente. Ce qui la distingue tient en une
/// ligne : elle ne sait ni renommer son titre, ni porter des en-têtes de section, ni archiver.
///
/// ponytail: pas d'en-têtes de section (cf. `ListPageView` pour ça). Le reste — édition,
/// suppression, dates, durée, rappels, sous-tâches, glisser — vient de la `TaskRow` et du socle
/// partagés, comme sur toutes les autres pages.
struct AllTasksPageView: View {
  @Binding var searchPresented: Bool

  @Environment(\.modelContext) private var modelContext
  @Environment(RemindersService.self) private var remindersService
  /// Le glisser vers la barre latérale : la page n'en connaît que le nom, tout se joue au
  /// relâchement (cf. `dropTaskDrag`).
  @Environment(SidebarDrop.self) private var filing
  @Query private var allTasks: [TaskItem]
  /// Cibles du « Déplacer vers… ». Toutes les listes : une tâche à classer peut aller n'importe où
  /// — c'est même le geste principal de cette page.
  @Query private var allLists: [TodoList]
  @Query(filter: #Predicate<TodoList> { $0.isInbox }) private var inboxLists: [TodoList]

  /// Brouillon du champ de création : une tâche notée ici n'a ni projet ni date, c'est la
  /// définition même de l'Inbox.
  @State private var draft = ""
  @FocusState private var draftFocused: Bool
  @State private var focus = TaskFocus()
  /// Le glissement en cours. Une seule zone désormais — la page entière —, et ses deux bouts sont
  /// ses butées.
  @State private var reorder = TaskPageReorder()
  /// Ligne dont les sous-tâches sont repliées le temps du geste (cf. `TaskDragCollapse`).
  @State private var dragCollapse = TaskDragCollapse()

  var body: some View {
    // Construite UNE fois par rendu, puis distribuée. Avant, chaque lecture refiltrait et retriait
    // toute la base — plusieurs fois par image.
    let page = AllTasksPage.build(tasks: allTasks)
    let offsets = reorder.offsets()
    // Largeur EXPLICITE et pas `maxWidth: .infinity`, sans quoi le titre d'une tâche en édition
    // disparaît. Le pourquoi est dans `PIEGES.md` § Layout, avec la mesure.
    return GeometryReader { geo in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          header
          rowsView(of: page, offsets: offsets)
          if showsNewTaskField(page) { newTaskRow }
        }
        .frame(width: max(geo.size.width - 2 * gutter, 1), alignment: .leading)
        .padding(.horizontal, gutter)
        .padding(.top, 30)
      }
    }
    // Le trou d'insertion : même brique que « Aujourd'hui », même courbe.
    .taskReorderPlaceholder(reorder)
    // Le socle commun des pages de tâches : ⌫, ↑/↓, clic dans le vide, et les cadres des lignes que
    // le glissement lui emprunte. Le même pan unique que le `body` rend.
    .taskPageBase(
      focus: $focus,
      blocks: { page.blocks },
      delete: delete,
      reorder: $reorder,
      // Le MÊME geste que le ⊕ de la barre du bas : le champ de saisie prend le focus.
      newTask: createTaskInEditMode
    )
    .onChange(of: page.tasks.count) { _, _ in
      // Une ligne qui apparaît ou disparaît sous le geste (la synchro Rappels, un ⌘Z) invaliderait
      // la séquence figée : on désarme plutôt que de viser dans le vide.
      if reorder.isDragging { reorder.end() }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      BottomToolbar(
        // Sans champ affiché, le ⊕ retombe sur ⌘N plutôt que de rester muet.
        onNewTask: {
          if showsNewTaskField(page) {
            draftFocused = true
          } else {
            createTaskInEditMode()
          }
        },
        onInsertHeader: nil,
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
    // Colonne des repères de section (même règle que `TodayPageView.header`).
    .padding(.leading, taskContentColumn)
    .padding(.bottom, 14)
  }

  // MARK: Lignes de tâche

  /// Les lignes dans leur propre `VStack` plutôt que posées à même celui du `body` : c'est lui qui
  /// porte la largeur explicite, et l'intercaler garde les rangées à la largeur de la page (cf.
  /// `PIEGES.md` § Layout — un `VStack` laisse ses enfants se réduire à leur taille idéale).
  private func rowsView(of page: AllTasksPage, offsets: [TaskRowKey: CGSize]) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(page.tasks) { task in
        taskRow(
          for: task, offset: offsets[.task(task.persistentModelID)] ?? .zero, rows: page.tasks)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// La MÊME `TaskRow` que partout ailleurs. La date compte (rien ne la rend implicite ici) ; le
  /// rattachement, non : toutes ces tâches sont dans l'Inbox, la pilule dirait la même chose à
  /// chaque ligne.
  private func taskRow(
    for task: TaskItem, offset: CGSize = .zero, rows: [TaskItem] = []
  ) -> some View {
    TaskRow(
      task: task,
      isSelected: focus.isSelected(task),
      isEditing: focus.isEditing(task),
      moveTargets: allLists.filter { $0.persistentModelID != task.list?.persistentModelID },
      showsDate: true,
      parentTag: nil,
      onBeginEditing: { beginEditing(task) },
      onEndEditing: { endEditing(task) },
      onMove: { move(task, to: $0) },
      onDuplicate: { duplicate(task) },
      onDelete: { delete(task) },
      onCompletionChanged: {},
      collapsedForDrag: dragCollapse.isCollapsed(task)
    )
    .rowPressGesture(
      isSelected: focus.isSelected(task),
      isEditing: focus.isEditing(task),
      onSelect: { select(task) },
      onEdit: { beginEditing(task) },
      onDrag: { translation, start in
        // Replier AVANT d'armer, et renoncer à cette image : cf. `TaskDragCollapse`.
        guard !dragCollapse.collapseIfNeeded(task, translation: translation) else { return }
        reorder.track(task, by: translation, in: rows)
        filing.arm(grabbedAt: start, restingFrame: reorder.frames[.task(task.persistentModelID)])
      },
      onDrop: { dropDraggedTask() }
    )
    .taskRowDragLayer(reorder, task: task, offset: offset, airborne: filing.isAirborne)
    // La même entrée que sur une page de liste : créée, ou revenue par ⌘Z.
    .taskRowInsertion()
    // Ce qui permet au socle de savoir qu'un clic est tombé À CÔTÉ des tâches.
    .measureTaskRow(task)
  }

  /// Relâchement. La mécanique est partagée (`dropTaskDrag`) ; ce qui reste à la page, c'est le
  /// RANG — et lui seul, depuis que la page n'a plus qu'une liste à montrer. Le rattachement et la
  /// date que `AllTasksPage.applyDrop` écrivait sont partis avec les sections : ici tout appartient
  /// déjà à l'Inbox, et déplacer une tâche AILLEURS se fait par la barre latérale ou par
  /// ▸ *Déplacer vers…*.
  private func dropDraggedTask() {
    // AVANT le garde ci-dessous : les sous-tâches se rouvrent même quand le geste s'est arrêté sur
    // le repli, sans avoir armé le moindre glissement.
    if dragCollapse.isCollapsing {
      withAnimation(disclosureFlow) { dragCollapse.reset() }
    }
    guard reorder.draggedTask != nil else { return }
    dropTaskDrag(&reorder, onto: filing, lists: allLists, in: modelContext) { ordered in
      // Toutes comparables entre elles (même liste) : renuméroter la séquence entière est juste.
      TaskItem.stampSmartOrder(ordered)
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

  // MARK: Création

  /// Page vide seulement — ou champ focalisé, pour ne pas se dérober en pleine saisie enchaînée.
  /// Cf. `ListPageView.showsNewTaskField`. Lu aussi par le ⊕ de la barre du bas, qui ne peut donc
  /// pas viser un champ absent.
  private func showsNewTaskField(_ page: AllTasksPage) -> Bool {
    page.tasks.isEmpty || draftFocused
  }

  /// Création SANS date — c'est ce qui la distingue du champ d'« Aujourd'hui », qui date d'office :
  /// ici on note, on classera plus tard.
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
    guard let inbox = inboxLists.first else { return }
    // ⌘N martelé enchaîne les lignes au lieu de rouvrir la même carte (cf. `nameIfBlank`).
    keepEditedTaskIfBlank(focus, in: modelContext)
    let task = TaskItem(title: "", list: inbox)
    task.sortIndex = (inbox.tasks.map(\.sortIndex).max() ?? -1) + 1
    // Juste SOUS la ligne visée. Cette page range par ordre manuel (cf. `AllTasksPage.build`), pas
    // par `sortIndex` : c'est lui qu'on renumérote, et seulement quand une ligne est visée — même
    // règle que sur « Aujourd'hui ».
    var ordered = AllTasksPage.build(tasks: allTasks).tasks
    withAnimation(taskInsert) {
      if let index = ordered.firstIndex(where: { focus.isSelected($0) }) {
        ordered.insert(task, at: index + 1)
        TaskItem.stampSmartOrder(ordered)
      }
      modelContext.insertAndSave(task)
    }
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
