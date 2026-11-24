import Foundation
import SwiftData

/// Où l'on range une tâche : dans une LISTE, ou dans un PROJET sans liste.
///
/// Les trois gestes qui rangent — « Déplacer vers… », le dépôt sur la barre latérale, la saisie
/// rapide — passent par ce type et par `TaskItem.file(to:in:)`. Chacun savait ranger dans une liste ;
/// le projet sans liste s'y ajoute à UN endroit, pas trois.
enum TaskDestination {
  case list(TodoList)
  /// La tâche va (ou reste) dans l'Inbox, rattachée au projet (cf. `TaskItem.inboxProject`).
  case project(Project)
}

extension ModelContext {
  /// La boîte de réception. Une seule existe, créée au lancement (cf. `TodayApp`).
  var inboxList: TodoList? {
    try? fetch(FetchDescriptor<TodoList>(predicate: #Predicate { $0.isInbox })).first
  }
}

extension TaskItem {
  /// Range la tâche. N'enregistre PAS, comme `move(to:)` : la transaction appartient à l'appelant.
  ///
  /// Vers un projet : la tâche rejoint l'Inbox si elle n'y est pas déjà (en tête, par `move(to:)`),
  /// puis prend le projet. Vers une liste : `move(to:)`, qui efface le projet si la liste n'est pas
  /// l'Inbox.
  func file(to destination: TaskDestination, in context: ModelContext) {
    switch destination {
    case .list(let target):
      move(to: target)
    case .project(let project):
      if list?.isInbox != true, let inbox = context.inboxList { move(to: inbox) }
      inboxProject = project
    }
  }
}
