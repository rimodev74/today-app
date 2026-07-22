import Foundation
import SwiftData

/// Une étape cochable rattachée à une `TaskItem`. Entité distincte des notes (texte libre) : une
/// sous-tâche porte un état fait / pas fait et un ordre, rien d'autre. Miroir volontaire du pattern
/// `TodoList` ↔ `TaskItem` (relation + `sortIndex`).
@Model
final class Subtask {
  var title: String
  var isDone: Bool = false
  var sortIndex: Int = 0
  var createdAt: Date = Date()
  var task: TaskItem?

  init(title: String = "") {
    self.title = title
    self.createdAt = Date()
  }
}
