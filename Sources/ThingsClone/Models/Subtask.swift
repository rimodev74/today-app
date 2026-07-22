import Foundation
import SwiftData

/// Une étape cochable rattachée à une `TaskItem`. Entité distincte des notes (texte libre) : une
/// sous-tâche porte un état fait / pas fait et un ordre, rien d'autre. Miroir volontaire du pattern
/// `TodoList` ↔ `TaskItem` (relation + `sortIndex`).
@Model
final class Subtask {
  // Clé de focus stable : `persistentModelID` mute quand l'autosave SwiftData bascule une
  // instance fraîche de temporaire à permanent, ce qui ferait sauter le focus au pire moment
  // (juste après la création). Un UUID généré une fois ne bouge jamais.
  var uuid: UUID = UUID()
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
