import Foundation
import SwiftData

@Model
final class TaskItem {
  var title: String
  var notes: String
  var isCompleted: Bool
  /// Une en-tête est une ligne de séparation titrée dans la liste, pas une tâche.
  var isHeader: Bool = false
  var completedAt: Date?
  var sortIndex: Int = 0
  /// Jour planifié. `hasTime` dit si l'heure portée par cette date est significative
  /// (sans lui, impossible de distinguer « le 12 » de « le 12 à 00:00 »).
  var when: Date?
  var hasTime: Bool = false
  /// Échéance (deadline) — distincte de `when` (jour planifié). Affichée à droite de la ligne
  /// avec un drapeau, en rouge une fois atteinte ou dépassée.
  var deadline: Date?
  var priorityRaw: Int = 0
  var createdAt: Date
  /// Identifiant du rappel Apple Rappels associé, s'il existe.
  /// Permet de re-modifier le rappel au lieu d'en recréer un.
  var reminderIdentifier: String?
  var list: TodoList?

  init(
    title: String,
    notes: String = "",
    when: Date? = nil,
    isHeader: Bool = false,
    list: TodoList? = nil
  ) {
    self.title = title
    self.notes = notes
    self.isCompleted = false
    self.isHeader = isHeader
    self.when = when
    self.list = list
    self.createdAt = Date()
  }

  // Stocké en Int : SwiftData persiste les propriétés stockées, pas les calculées.
  var priority: Priority {
    get { Priority(rawValue: priorityRaw) ?? .none }
    set { priorityRaw = newValue.rawValue }
  }

  var project: Project? { list?.project }

  func toggleCompletion() {
    isCompleted.toggle()
    completedAt = isCompleted ? Date() : nil
  }
}
