import Foundation
import SwiftData

/// Une to-do list : le seul endroit où vivent les tâches.
@Model
final class TodoList {
  var title: String
  var notes: Data
  var sortIndex: Int = 0
  var createdAt: Date = Date()
  /// Date planifiée de la liste (menu « Définir une date » de l'en-tête).
  var scheduledWhen: Date?
  var priorityRaw: Int = 0
  var project: Project?
  @Relationship(deleteRule: .cascade, inverse: \TaskItem.list) var tasks: [TaskItem]

  // Stocké en Int comme sur TaskItem : SwiftData persiste le stocké, pas le calculé.
  var priority: Priority {
    get { Priority(rawValue: priorityRaw) ?? .none }
    set { priorityRaw = newValue.rawValue }
  }

  init(title: String, notes: Data = Data(), project: Project? = nil) {
    self.title = title
    self.notes = notes
    self.project = project
    self.tasks = []
    self.createdAt = Date()
  }

  /// Ordre manuel. `createdAt` départage les ex æquo (deux tâches créées avant
  /// tout réordonnancement partagent sortIndex 0) pour que l'ordre reste stable.
  var orderedTasks: [TaskItem] {
    tasks.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
  }

  /// Les en-têtes ne sont pas des tâches : elles ne comptent pas dans la progression.
  var countableTasks: [TaskItem] { tasks.filter { !$0.isHeader } }

  /// Nombre de tâches restantes (non complétées) — le badge de la sidebar.
  var remainingCount: Int { countableTasks.filter { !$0.isCompleted }.count }

  var progress: Double {
    guard !countableTasks.isEmpty else { return 0 }
    return Double(countableTasks.filter(\.isCompleted).count) / Double(countableTasks.count)
  }

  /// Réglage (Réglages) : descendre automatiquement une tâche cochée en bas de sa section.
  /// Activé par défaut — `object(forKey:)` plutôt que `bool(forKey:)` pour distinguer « jamais
  /// réglé » (→ true) de « explicitement désactivé ».
  static let autoSortCompletedStorageKey = "autoSortCompletedToBottom"

  private static var autoSortCompletedEnabled: Bool {
    UserDefaults.standard.object(forKey: autoSortCompletedStorageKey) as? Bool ?? true
  }

  /// Renvoie `task` en bas de sa section (juste avant l'en-tête suivant, ou la fin de liste) en
  /// réécrivant les `sortIndex` — appelé quand une tâche passe cochée, pour que les tâches
  /// terminées descendent sous celles encore à faire sans mélanger les sections entre elles.
  /// No-op si l'utilisateur a désactivé ce comportement dans les réglages.
  func moveToEndOfSection(_ task: TaskItem) {
    guard Self.autoSortCompletedEnabled else { return }
    var ordered = orderedTasks
    guard
      let taskIndex = ordered.firstIndex(where: { $0.persistentModelID == task.persistentModelID })
    else { return }
    let nextHeaderIndex = ordered[(taskIndex + 1)...].firstIndex(where: \.isHeader) ?? ordered.count
    guard nextHeaderIndex > taskIndex + 1 else { return }
    let moved = ordered.remove(at: taskIndex)
    ordered.insert(moved, at: nextHeaderIndex - 1)
    for (index, t) in ordered.enumerated() { t.sortIndex = index }
  }
}
