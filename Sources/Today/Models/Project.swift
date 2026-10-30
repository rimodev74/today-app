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
  /// Stocke `ProjectColor.raw` — un nom de la palette (`"blue"`, comme `TaskItem.headerColorRaw`)
  /// ou une couleur libre (`"#3A7BD5"`). Optionnel : `nil` = teinte d'accent du système.
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
  var color: ProjectColor? {
    get { colorRaw.flatMap(ProjectColor.init(raw:)) }
    set { colorRaw = newValue?.raw }
  }

  /// TOUTES les listes, archivées comprises, dans l'ordre manuel. Ce que la barre latérale, la
  /// grille et les destinations montrent, c'est `activeLists`.
  var orderedLists: [TodoList] {
    sortedByKey(lists, key: { ($0.sortIndex, $0.createdAt) }, areInIncreasingOrder: <)
  }

  /// Les listes en cours, dans l'ordre manuel — sans les archivées (cf. `TodoList.archivedAt`).
  var activeLists: [TodoList] { orderedLists.filter { !$0.isArchived } }

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

  /// Supprime le projet et tout ce qu'il contient, puis ce qui vit HORS de la base : rappels et
  /// événements Apple de ses tâches (`forget`), couverture sur le disque (`removeCover`).
  ///
  /// Seul chemin de suppression d'un projet : la barre latérale et le MCP. Il vivait en privé dans
  /// `SidebarView` : un second appelant aurait laissé couvertures et rappels orphelins.
  /// `deleteCascadeAndSave` (cascade la plus large de l'app, cf. son en-tête), identifiants lus
  /// AVANT la mutation ; enregistrement raté ⇒ les effets attendent le prochain réussi.
  @discardableResult
  func delete(
    in context: ModelContext, forget: @escaping ([String]) -> Void,
    removeCover: @escaping (UUID) -> Void
  ) -> Bool {
    let doomedItems = RemindersService.appleIdentifiers(of: lists.flatMap(\.tasks))
    let coverID = uuid
    guard context.deleteCascadeAndSave(self) else {
      context.runAfterNextSave {
        forget(doomedItems)
        removeCover(coverID)
      }
      return false
    }
    // EventKit APRÈS, jamais pendant : effacer un rappel fait poster `.EKEventStoreChanged`, qui
    // relance la synchro, qui réenregistre le MÊME contexte SwiftData. Ce n'est PAS ce qui faisait
    // planter l'app le 6 août 2026 (la vraie cause était l'annulation, cf.
    // `deleteCascadeAndSave`), mais écrire dans un contexte pendant qu'on l'enregistre n'a rien à
    // faire là.
    forget(doomedItems)
    removeCover(coverID)
    return true
  }

  /// Progression du JOUR du projet = celle de toutes ses tâches confondues, en-têtes exclues. Même
  /// règle que `TodoList.progress` — ancrée sur le jour calendaire, pas sur `CompletedTaskRetention`.
  /// Plus affichée depuis que la page projet montre l'avancement CUMULÉ (`ProjectBoard.total`) ;
  /// gardée parce que `ListProgressTests` y tient l'équivalence avec la règle des listes.
  func progress(bounds: DayBounds = DayBounds()) -> Double {
    let countable = allTasks.filter { !$0.isHeader && $0.countsTowardProgress(bounds) }
    guard !countable.isEmpty else { return 0 }
    return Double(countable.filter(\.isCompleted).count) / Double(countable.count)
  }
}
