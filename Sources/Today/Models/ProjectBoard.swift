import Foundation
import SwiftData

/// Ce que la page d'un projet affiche : une carte par to-do list, avec un aperçu de ce qu'il reste
/// à y faire.
///
/// Même raison d'être que `TodayPage` : la page tirait ces chiffres depuis son `body`
/// (`list.countableTasks.filter { !$0.isCompleted }.count` par rangée), donc recalculés à chaque
/// rendu et invérifiables autrement qu'en cliquant. Ici c'est une valeur, construite UNE fois par
/// rendu et interrogeable par un test sans écran.
struct ProjectBoard {
  /// Une carte = une liste, résumée.
  struct Card: Identifiable {
    let list: TodoList
    /// Les premières tâches à faire, dans l'ordre de la liste. Volontairement PLUS nombreuses que
    /// ce que la carte laisse voir : les dernières passent sous le fondu, qui est ce qui dit
    /// « ça continue » (cf. `ListCardView`). D'où l'absence d'un « +3 » à afficher.
    let preview: [TaskItem]
    /// Ce qui reste à faire — même définition que `TodoList.remainingCount` (en-têtes exclues).
    let remainingCount: Int

    var id: PersistentIdentifier { list.persistentModelID }
  }

  let cards: [Card]

  /// Total affiché en tête de page. Additionné ici plutôt que recompté dans la vue.
  var remainingCount: Int { cards.reduce(0) { $0 + $1.remainingCount } }

  /// `previewLimit` = ce que la carte peut RENDRE, fondu compris ; c'est une décision de mise en
  /// page, elle vient donc de la vue.
  static func build(
    from project: Project, previewLimit: Int,
    progressResetsDaily: Bool = TaskItem.progressResetsDaily
  ) -> ProjectBoard {
    ProjectBoard(
      cards: project.orderedLists.map { list in
        // UN seul parcours par liste, et c'est tout l'enjeu. Lire une propriété d'un `@Model`
        // traverse SwiftData (cf. `sortedByKey`) : parcourir `orderedTasks` une fois pour l'aperçu
        // et une fois pour le compte, c'était deux fois le même prix.
        var todo: [TaskItem] = []
        var done: [TaskItem] = []
        for task in list.orderedTasks where !task.isHeader {
          if task.isCompleted { done.append(task) } else { todo.append(task) }
        }
        var preview = Array(todo.prefix(previewLimit))
        // `progressResetsDaily` désactivé (Réglages) : l'anneau cumule tout l'archivé, alors la
        // carte fait de même plutôt que de laisser une liste terminée blanche — l'archivé
        // complète l'aperçu, dans l'ordre de la liste, une fois les tâches à faire épuisées.
        // `previewRow` les rend barrées : rien ne les confond avec ce qui reste à faire.
        if preview.count < previewLimit, !progressResetsDaily {
          preview += done.prefix(previewLimit - preview.count)
        }
        return Card(list: list, preview: preview, remainingCount: todo.count)
      })
  }
}
