import Foundation
import SwiftData

/// Conteneur de plus haut niveau. Ne porte pas de tâche directement : un projet
/// contient des to-do lists, et ce sont elles qui portent les tâches.
@Model
final class Project {
  /// Identité stable entre appareils — mêmes raisons et mêmes contraintes que `TaskItem.uuid`.
  var uuid: UUID = UUID()
  var title: String = ""
  var notes: Data = Data()
  var sortIndex: Int = 0
  var createdAt: Date = Date()
  /// Repli du dossier dans la sidebar. Dans le modèle et pas en `@State` : l'état doit survivre au
  /// relancement, et c'est le seul stockage déjà persistant indexé par projet.
  var isCollapsed: Bool = false
  /// Stocke `PaletteColor.rawValue` — voir `color` ci-dessous, même pattern que
  /// `TaskItem.headerColorRaw`. Optionnel : `nil` = teinte d'accent du système.
  var colorRaw: String?
  @Relationship(deleteRule: .cascade, inverse: \TodoList.project) var lists: [TodoList] = []

  init(title: String, notes: Data = Data()) {
    self.title = title
    self.notes = notes
    self.lists = []
    self.createdAt = Date()
  }

  /// La teinte du projet : son icône dans la sidebar, et les anneaux de progression de TOUTES ses
  /// listes (une liste ne porte pas de couleur à elle — elle hérite de son projet, sinon deux
  /// endroits diraient la même chose et finiraient par se contredire).
  var color: PaletteColor? {
    get { colorRaw.flatMap(PaletteColor.init(rawValue:)) }
    set { colorRaw = newValue?.rawValue }
  }

  var orderedLists: [TodoList] {
    sortedByKey(lists, key: { ($0.sortIndex, $0.createdAt) }, areInIncreasingOrder: <)
  }

  var allTasks: [TaskItem] { lists.flatMap(\.tasks) }

  /// Ajoute une liste À LA FIN du projet. Point de passage commun à la sidebar et à la page du
  /// projet : le calcul du rang de fin s'écrivait des deux côtés, et le second à l'avoir écrit
  /// n'aurait rien su du premier. `insertAndSave` fige l'identifiant tout de suite — l'appelant
  /// s'en sert aussitôt pour sélectionner et ouvrir le renommage.
  @discardableResult
  func appendList(titled title: String, in context: ModelContext) -> TodoList {
    let list = TodoList(title: title, project: self)
    list.sortIndex = (lists.map(\.sortIndex).max() ?? -1) + 1
    context.insertAndSave(list)
    return list
  }

  /// Progression du projet = celle de toutes ses tâches confondues, en-têtes exclues. Même règle
  /// que `TodoList.progress` — ancrée sur le jour calendaire, pas sur `CompletedTaskRetention`
  /// (cf. son commentaire pour ce que ça a remplacé, et pourquoi).
  func progress(bounds: DayBounds = DayBounds()) -> Double {
    let countable = allTasks.filter { !$0.isHeader && $0.countsTowardProgress(bounds) }
    guard !countable.isEmpty else { return 0 }
    return Double(countable.filter(\.isCompleted).count) / Double(countable.count)
  }
}
