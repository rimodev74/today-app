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
  /// Sections dont le repli DIFFÈRE de leur défaut (cf. `expansion(of:)`) — stocker l'écart plutôt
  /// que l'état permet à chaque section de garder son propre défaut sans initialisation.
  /// ponytail: état de session, non persisté. Le persister demanderait une clé stable par projet ;
  /// à faire si retrouver ses dépliants au relancement manque vraiment.
  @State private var toggled: Set<String> = []

  private var openTasks: [TaskItem] {
    allTasks.filter { !$0.isCompleted && !$0.isHeader }
  }

  /// Ce que le jour montre déjà — retiré de tout ce qui s'affiche en dessous, pour qu'une tâche
  /// n'apparaisse jamais à deux endroits (elle s'y serait sélectionnée deux fois).
  private var todayIDs: Set<PersistentIdentifier> {
    Set(SmartList.today.scoped(allTasks).map(\.persistentModelID))
  }

  /// La boîte de réception, en tête de page : ce qui est noté mais pas encore classé.
  private var inboxTasks: [TaskItem] {
    let shown = todayIDs
    return SmartList.today.sort(
      openTasks.filter { $0.list?.isInbox == true && !shown.contains($0.persistentModelID) })
  }

  private var sections: [TaskSection] {
    let shown = todayIDs
    func remaining(_ tasks: [TaskItem]) -> [TaskItem] {
      SmartList.today.sort(
        tasks.filter {
          !$0.isCompleted && !$0.isHeader && !shown.contains($0.persistentModelID)
        })
    }

    var result = [
      TaskSection(
        id: "today",
        header: .init(
          title: SmartList.today.label, systemImage: SmartList.today.systemImage,
          tint: SmartList.today.color, defaultExpanded: true),
        // Même règle que la page « Aujourd'hui » : cochées comprises jusqu'au lendemain.
        tasks: SmartList.today.sort(SmartList.today.scoped(allTasks)))
    ]

    for project in allProjects.sorted(by: ordered) {
      let tasks = remaining(project.allTasks)
      guard !tasks.isEmpty else { continue }
      result.append(
        TaskSection(
          id: "project-\(project.persistentModelID)",
          header: .init(
            title: label(project.title), systemImage: "folder", tint: nil, defaultExpanded: false),
          tasks: tasks))
    }

    // Les listes d'un projet sont déjà dedans (`Project.allTasks`) ; seules les listes libres
    // manquent — sans elles, la page ne serait pas l'inventaire qu'elle prétend être.
    for list in allLists.filter({ !$0.isInbox && $0.project == nil }).sorted(by: ordered) {
      let tasks = remaining(list.tasks)
      guard !tasks.isEmpty else { continue }
      result.append(
        TaskSection(
          id: "list-\(list.persistentModelID)",
          header: .init(
            title: label(list.title), systemImage: "list.bullet", tint: nil,
            defaultExpanded: false),
          tasks: tasks))
    }
    return result
  }

  private func ordered(_ a: Project, _ b: Project) -> Bool {
    (a.sortIndex, a.createdAt) < (b.sortIndex, b.createdAt)
  }

  private func ordered(_ a: TodoList, _ b: TodoList) -> Bool {
    (a.sortIndex, a.createdAt) < (b.sortIndex, b.createdAt)
  }

  private func label(_ title: String) -> String { title.isEmpty ? "Sans titre" : title }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        header

        // UNE seule énumération, celle que le socle clavier reçoit aussi (cf. `displayedSections`).
        // La boîte de réception a longtemps été rendue à part, et c'est exactement comme ça qu'elle
        // a fini par manquer à l'ordre du clavier sans que rien ne le montre.
        ForEach(displayedSections) { sectionView($0) }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, gutter)
      .padding(.top, 30)
      // Clic dans le vide = on referme, comme sur « Aujourd'hui » : les lignes captent déjà les
      // leurs, rien ne se réordonne ici, un simple tap sur le fond suffit.
      .contentShape(Rectangle())
      .onTapGesture { dismissEditing() }
    }
    // Le socle commun des pages de tâches : ⌫ et ↑/↓. Les mêmes sections que le `body` rend.
    .taskPageBase(
      focus: $focus,
      blocks: {
        displayedSections.map { TaskPageBlock(tasks: $0.tasks, isExpanded: isExpanded($0)) }
      },
      delete: delete
    )
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

  /// Tout ce que la page affiche, dans l'ordre. La boîte de réception est une section comme les
  /// autres — simplement sans bandeau (cf. `TaskSection.header`), parce qu'elle ouvre la page et
  /// n'a rien à déplier.
  private var displayedSections: [TaskSection] {
    [TaskSection(id: "inbox", header: nil, tasks: inboxTasks)] + sections
  }

  /// Un seul rendu pour toutes les sections — y compris « Aujourd'hui », qui s'ouvre par défaut
  /// mais se replie comme les autres si l'on ne veut voir que ses projets.
  @ViewBuilder private func sectionView(_ section: TaskSection) -> some View {
    if let header = section.header {
      DisclosureGroup(isExpanded: expansion(of: section, header: header)) {
        rows(of: section)
      } label: {
        HStack(spacing: 6) {
          Image(systemName: header.systemImage)
            .font(.app(11))
            // Teinte de la vue intelligente quand elle en a une (le jaune d'« Aujourd'hui ») : la
            // section se repère du coin de l'œil, comme sa ligne dans la sidebar.
            .foregroundStyle(header.tint ?? Color.secondary)
          Text(header.title)
          Text("\(section.tasks.count)")
            .foregroundStyle(.tertiary)
        }
        .font(.app(.subheadline).weight(.semibold))
        .foregroundStyle(.secondary)
      }
      .padding(.top, 14)
    } else {
      VStack(alignment: .leading, spacing: 0) {
        rows(of: section)
        // Le champ « Nouvelle tâche » appartient au pan à nu : c'est le non-classé, et la seule
        // section où l'on crée (une tâche notée ici n'a ni projet ni date — la définition de
        // l'Inbox).
        newTaskRow
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func rows(of section: TaskSection) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(section.tasks) { task in
        taskRow(for: task, isToday: section.id == "today")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// Une section est-elle dépliée ? `toggled` retient l'ÉCART au défaut et pas l'état — une `Set`
  /// des ouvertes aurait demandé de l'amorcer au premier rendu —, d'où le XOR. Sans bandeau, il n'y
  /// a rien à replier.
  ///
  /// Lu par le `DisclosureGroup` ET par le socle clavier (les flèches ne parcourent que le
  /// visible) : la règle vit à un seul endroit.
  private func isExpanded(_ section: TaskSection) -> Bool {
    guard let header = section.header else { return true }
    return toggled.contains(section.id) != header.defaultExpanded
  }

  private func expansion(of section: TaskSection, header: TaskSection.Header) -> Binding<Bool> {
    Binding(
      get: { isExpanded(section) },
      set: { open in
        if open == header.defaultExpanded {
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
  private func taskRow(for task: TaskItem, isToday: Bool) -> some View {
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
      onEdit: { beginEditing(task) }
    )
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

  private func dismissEditing() {
    guard !focus.isIdle else { return }
    withAnimation(taskFlow) { focus.dismiss() }
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
        .focused($draftFocused)
        .onSubmit(createTask)
    }
    // Mêmes paddings qu'une `TaskRow` au repos : la rangée de création garde le rythme des tâches.
    .padding(.vertical, 6)
    .padding(.horizontal, rowInset)
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

/// Un dépliant de la page : le jour, la boîte de réception, un projet ou une liste libre. Un seul
/// type pour les quatre — ils ne diffèrent que par leur titre, leur icône et leur repli par défaut.
private struct TaskSection: Identifiable {
  let id: String
  /// `nil` = section à NU : ni bandeau ni dépliant, ses lignes ouvrent la page. C'est la boîte de
  /// réception — le flux d'arrivée se lit d'emblée, le reste est rangé quelque part, donc repliable
  /// derrière un titre.
  let header: Header?
  let tasks: [TaskItem]

  struct Header {
    let title: String
    let systemImage: String
    /// Teinte de l'icône, `nil` = gris comme le reste du bandeau.
    let tint: Color?
    let defaultExpanded: Bool
  }
}
