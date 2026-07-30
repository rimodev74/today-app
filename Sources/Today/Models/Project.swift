import Foundation
import SwiftData

/// Conteneur de plus haut niveau. Ne porte pas de tâche directement : un projet
/// contient des to-do lists, et ce sont elles qui portent les tâches.
@Model
final class Project {
  var title: String
  var notes: Data
  var sortIndex: Int = 0
  var createdAt: Date = Date()
  @Relationship(deleteRule: .cascade, inverse: \TodoList.project) var lists: [TodoList]

  init(title: String, notes: Data = Data()) {
    self.title = title
    self.notes = notes
    self.lists = []
    self.createdAt = Date()
  }

  var orderedLists: [TodoList] {
    lists.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
  }

  var allTasks: [TaskItem] { lists.flatMap(\.tasks) }

  /// Progression du projet = celle de toutes ses tâches confondues, en-têtes exclues. Même règle
  /// d'archivage que `TodoList.progress` : un projet entièrement archivé revient à l'anneau vide.
  var progress: Double {
    let countable = allTasks.filter { !$0.isHeader }
    guard countable.contains(where: { !$0.isArchived }) else { return 0 }
    return Double(countable.filter(\.isCompleted).count) / Double(countable.count)
  }
}
