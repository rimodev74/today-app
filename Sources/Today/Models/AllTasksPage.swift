import Foundation

/// Ce que la page « Tâches » affiche : l'inventaire complet, section par section.
///
/// D'abord le non-classé à nu, puis « Aujourd'hui », puis un dépliant par projet et par liste hors
/// projet. Une tâche n'apparaît QU'UNE fois : celles du jour sont retirées de tout le reste, sinon
/// la même ligne se sélectionnerait à deux endroits.
///
/// Même raison d'être que `TodayPage` : ce calcul vivait dans la vue, donc il repartait de zéro à
/// chaque rendu et aucun test ne pouvait l'interroger. Il ne connaît toujours ni couleur ni icône —
/// ça, c'est de l'affichage, et ça reste dans la page.
struct AllTasksPage {
  /// D'où vient une section. La vue en tire son bandeau (icône, teinte) ; le modèle n'en sait rien.
  enum Kind: Equatable {
    /// La boîte de réception : elle ouvre la page, SANS bandeau ni dépliant. C'est le flux
    /// d'arrivée, il se lit d'emblée — tout le reste est rangé quelque part, donc repliable.
    case inbox
    case today
    case project(Project)
    case list(TodoList)
  }

  struct Section: Identifiable {
    let id: String
    let kind: Kind
    /// Vide pour la boîte de réception, qui n'a pas de bandeau.
    let title: String
    let tasks: [TaskItem]
    /// Seul « Aujourd'hui » s'ouvre d'office : c'est ce qu'on vient voir en premier.
    let defaultExpanded: Bool

    var hasHeader: Bool { kind != .inbox }
  }

  let sections: [Section]

  /// Les pans dans l'ordre du rendu. Le repli n'est pas connu d'ici : il vit dans l'état de la vue
  /// (ce que l'utilisateur a ouvert ou fermé pendant sa session), la page le fournit.
  func blocks(isExpanded: (Section) -> Bool) -> [TaskPageBlock] {
    sections.map { TaskPageBlock(tasks: $0.tasks, isExpanded: isExpanded($0)) }
  }

  static func build(tasks: [TaskItem], projects: [Project], lists: [TodoList]) -> AllTasksPage {
    // Ce que le jour montre déjà, retiré de tout ce qui s'affiche en dessous.
    let shown = Set(SmartList.today.scoped(tasks).map(\.persistentModelID))
    func remaining(_ candidates: [TaskItem]) -> [TaskItem] {
      SmartList.today.sort(
        candidates.filter {
          !$0.isCompleted && !$0.isHeader && !shown.contains($0.persistentModelID)
        })
    }

    var result = [
      Section(
        id: "inbox", kind: .inbox, title: "",
        tasks: remaining(tasks.filter { $0.list?.isInbox == true }),
        defaultExpanded: true),
      Section(
        id: "today", kind: .today, title: SmartList.today.label,
        // Même règle que la page « Aujourd'hui » : cochées comprises jusqu'au lendemain.
        tasks: SmartList.today.sort(SmartList.today.scoped(tasks)),
        defaultExpanded: true),
    ]

    for project in projects.sorted(by: ordered) {
      let tasks = remaining(project.allTasks)
      guard !tasks.isEmpty else { continue }
      result.append(
        Section(
          id: "project-\(project.persistentModelID)", kind: .project(project),
          title: label(project.title), tasks: tasks, defaultExpanded: false))
    }

    // Les listes d'un projet sont déjà dedans (`Project.allTasks`) ; seules les listes libres
    // manquent — sans elles, la page ne serait pas l'inventaire qu'elle prétend être.
    for list in lists.filter({ !$0.isInbox && $0.project == nil }).sorted(by: ordered) {
      let tasks = remaining(list.tasks)
      guard !tasks.isEmpty else { continue }
      result.append(
        Section(
          id: "list-\(list.persistentModelID)", kind: .list(list),
          title: label(list.title), tasks: tasks, defaultExpanded: false))
    }
    return AllTasksPage(sections: result)
  }

  private static func label(_ title: String) -> String { title.isEmpty ? "Sans titre" : title }
  private static func ordered(_ a: Project, _ b: Project) -> Bool {
    (a.sortIndex, a.createdAt) < (b.sortIndex, b.createdAt)
  }
  private static func ordered(_ a: TodoList, _ b: TodoList) -> Bool {
    (a.sortIndex, a.createdAt) < (b.sortIndex, b.createdAt)
  }
}
