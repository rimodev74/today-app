import Foundation
import SwiftData

@Model
final class TaskItem {
  var title: String
  var notes: Data
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
  /// Durée estimée en minutes, 0 = non estimée (cf. `Estimate`). C'est elle que la page
  /// « Aujourd'hui » additionne pour confronter la journée planifiée au temps qui reste.
  var estimateMinutes: Int = 0
  var createdAt: Date
  /// Identifiant du rappel Apple Rappels associé, s'il existe.
  /// Permet de re-modifier le rappel au lieu d'en recréer un.
  var reminderIdentifier: String?
  var list: TodoList?
  /// Couleur de l'en-tête (uniquement significatif si `isHeader`). `nil` = style par défaut.
  /// Stocke `HeaderColor.rawValue` — voir `headerColor` ci-dessous, même pattern que `priority`.
  var headerColorRaw: String?
  @Relationship(deleteRule: .cascade, inverse: \Subtask.task) var subtasks: [Subtask] = []

  init(
    title: String,
    notes: Data = Data(),
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

  /// Stocké en String (rawValue) : SwiftData persiste les propriétés stockées, pas les calculées.
  var headerColor: HeaderColor? {
    get { headerColorRaw.flatMap(HeaderColor.init(rawValue:)) }
    set { headerColorRaw = newValue?.rawValue }
  }

  var project: Project? { list?.project }

  func toggleCompletion() {
    isCompleted.toggle()
    completedAt = isCompleted ? Date() : nil
  }

  /// Ordre manuel des sous-tâches ; `createdAt` départage les ex æquo (même pattern que
  /// `TodoList.orderedTasks`).
  var orderedSubtasks: [Subtask] {
    subtasks.sorted { ($0.sortIndex, $0.createdAt) < ($1.sortIndex, $1.createdAt) }
  }

  /// Copie complète de la tâche, posée dans `list` — contenu, réglages et checklist.
  ///
  /// SEUL endroit qui sait ce qu'est « la même tâche ». Les deux chemins de duplication (une
  /// tâche via son menu, une liste entière via le sien) recopiaient chacun leur propre liste de
  /// champs et divergeaient à chaque ajout au modèle : la couleur d'en-tête, puis les sous-tâches,
  /// puis la durée estimée ont chacune été oubliées d'un côté ou de l'autre. Un champ ajouté à
  /// `TaskItem` se recopie désormais ici, ou nulle part.
  ///
  /// Volontairement NON copiés : la complétion (`isCompleted`/`completedAt` — une copie est une
  /// tâche à faire) et `reminderIdentifier` (un rappel Apple appartient à une seule tâche ; le
  /// partager ferait que cocher la copie cocherait l'originale).
  func copy(into list: TodoList?) -> TaskItem {
    let clone = TaskItem(title: title, notes: notes, when: when, isHeader: isHeader, list: list)
    clone.hasTime = hasTime
    clone.deadline = deadline
    clone.estimateMinutes = estimateMinutes
    clone.sortIndex = sortIndex
    // Les bruts (`…Raw`) et pas les propriétés calculées : ce sont eux que SwiftData persiste,
    // les lire ici rend la liste des champs à recopier vérifiable d'un coup d'œil sur le modèle.
    clone.priorityRaw = priorityRaw
    clone.headerColorRaw = headerColorRaw
    for sub in orderedSubtasks {
      let subCopy = Subtask(title: sub.title)
      subCopy.isDone = sub.isDone
      subCopy.sortIndex = sub.sortIndex
      clone.subtasks.append(subCopy)
    }
    return clone
  }

  /// Crée une sous-tâche vide en fin de liste et la renvoie (pour poser le focus dessus).
  @discardableResult
  func addSubtask() -> Subtask {
    let subtask = Subtask()
    subtask.sortIndex = (orderedSubtasks.last?.sortIndex ?? -1) + 1
    subtasks.append(subtask)
    return subtask
  }
}
