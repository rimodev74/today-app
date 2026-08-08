import Foundation
import SwiftData

/// Ce que la barre latérale affiche de chaque liste : son anneau de progression et son badge de
/// reste-à-faire, calculés EN UNE passe sur les tâches puis distribués aux rangées.
///
/// C'est la règle du projet — « construire une fois en tête de `body`, puis distribuer » (cf.
/// `TodayPage.build`) — et ici elle se payait comptant. `SidebarView.listRow` lisait
/// `list.progress`, puis `list.remainingCount` DEUX fois (le `if` et le `Text`) : **trois
/// traversées de la relation `TodoList.tasks` par rangée**, chacune relisant les propriétés de
/// chaque tâche à travers la machinerie SwiftData (cf. l'en-tête de `SortedByKey`). Sur dix listes,
/// trente traversées à chaque reconstruction de la sidebar.
///
/// Et elle se reconstruit bien plus souvent qu'on ne le croit. Mesuré le 6 août 2026 avec
/// `Self._printChanges()` : SwiftData ré-invalide le `@Query` sur `TodoList` à CHAQUE ouverture et
/// à chaque fermeture d'une carte de tâche —
/// `_QueryController<TodoList, String>.<computed (Bool)> changed` — alors qu'**aucune écriture
/// n'a lieu** : vérifié en écoutant `ModelContext.didSave`, `willSave` et
/// `NSManagedObjectContextObjectsDidChange`, aucune des trois ne sonne. C'est une sur-notification
/// de SwiftData, qu'on ne peut pas empêcher depuis ici. Ce qu'on peut, c'est rendre bon marché ce
/// qu'elle relance : une reconstruction de sidebar coûtait ~13 ms, soit plus d'une image entière à
/// 120 Hz, pile au démarrage de l'animation d'ouverture.
struct SidebarCounts {
  /// Ce qu'une rangée de liste a besoin de savoir, et rien de plus. `Equatable` à dessein : une
  /// rangée qui reçoit la même valeur n'a aucune raison de se redessiner.
  struct Row: Equatable {
    /// Les tâches qui comptent — en-têtes exclues.
    var countable = 0
    var done = 0

    /// Le badge de la sidebar. 0 ⇒ pas de badge.
    var remaining: Int { countable - done }

    /// L'anneau. Une liste VIDE reste à 0 et pas à « tout fait » : sans ce garde, 0/0 vaudrait
    /// `nan` et l'anneau se remplirait pour une liste où il n'y a rien à faire.
    var progress: Double { countable == 0 ? 0 : Double(done) / Double(countable) }
  }

  private var rows: [PersistentIdentifier: Row] = [:]

  /// Une seule passe. Les en-têtes ne comptent pas : ce ne sont pas des tâches — même règle que
  /// `TodoList.countableTasks`, dont ceci est le déplacement, pas une seconde version. Une tâche
  /// archivée (cochée avant `bounds.startOfToday`) ne compte plus non plus — même règle que
  /// `TodoList.progress`, calculée une fois pour toutes les rangées plutôt qu'à chaque lecture.
  init(tasks: [TaskItem], bounds: DayBounds = DayBounds()) {
    for task in tasks where !task.isHeader && task.countsTowardProgress(bounds) {
      guard let list = task.list?.persistentModelID else { continue }
      rows[list, default: Row()].countable += 1
      if task.isCompleted { rows[list]!.done += 1 }
    }
  }

  /// Une liste sans aucune tâche n'apparaît pas dans la passe : elle vaut le compte vide, qui rend
  /// bien 0 restantes et un anneau à 0.
  subscript(list: TodoList) -> Row { rows[list.persistentModelID] ?? Row() }
}
