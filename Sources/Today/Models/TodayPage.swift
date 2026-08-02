import Foundation

/// Ce que la page « Aujourd'hui » affiche : les tâches du jour, puis la réserve des tâches sans
/// date, groupée par projet.
///
/// ## Pourquoi ce type existe
///
/// La page calculait tout ça dans ses propres propriétés, à l'intérieur de la vue. Deux
/// conséquences, et aucune n'était visible :
///
/// - **c'était recalculé sans arrêt.** Une propriété calculée d'une `View` repart de zéro à chaque
///   lecture ET à chaque rendu : filtrer, trier, regrouper toute la base, plusieurs fois par image.
///   Le glisser-déposer s'y est cassé les dents — saccadé, pour cette seule raison ;
/// - **c'était invérifiable.** Mêlé à `@Query` et `@State`, ce calcul ne se contrôlait qu'en
///   cliquant. Aucun test ne pouvait dire « voici 5 tâches, voilà ce que la page doit montrer ».
///
/// Ici c'est une valeur : construite UNE fois par rendu, et interrogeable par un test sans écran.
/// C'est le même mouvement que `Reorder` et `TaskFocus` avant elle — une vue orchestre et anime,
/// elle ne calcule pas.
struct TodayPage {
  /// Un groupe de la réserve : les tâches sans date d'un même projet (ou d'une même liste).
  struct Group: Identifiable {
    let name: String
    let tasks: [TaskItem]
    var id: String { name }
  }

  /// Les tâches datées du JOUR MÊME, cochées comprises (elles restent barrées jusqu'au lendemain).
  let tasks: [TaskItem]
  /// La réserve, groupée par provenance. Ces tâches n'apparaissent nulle part ailleurs : les autres
  /// vues filtrent sur la date, et il faudrait ouvrir chaque projet pour les retrouver.
  let undated: [Group]

  var undatedCount: Int { undated.reduce(0) { $0 + $1.tasks.count } }

  /// Les pans dans l'ordre du rendu — le jour, puis la réserve groupe par groupe. Repliée, la
  /// réserve reste DÉCLARÉE mais ne fournit aucune ligne au clavier (cf. `TaskPageBlock`).
  func blocks(undatedExpanded: Bool) -> [TaskPageBlock] {
    [.visible(tasks)] + undated.map { TaskPageBlock(tasks: $0.tasks, isExpanded: undatedExpanded) }
  }

  /// Le partage se lit d'un coup : le jour d'un côté, ce qui n'a pas de date de l'autre. Une tâche
  /// datée d'hier n'est dans NI l'un NI l'autre — elle est retournée dans sa liste (cf.
  /// `SmartList.today`), c'est ce qui empêche la page de devenir une pile de retards.
  static func build(from all: [TaskItem]) -> TodayPage {
    let day = SmartList.today.sort(SmartList.today.scoped(all))
    let undated = SmartList.today.sort(
      all.filter { !$0.isCompleted && !$0.isHeader && $0.when == nil })

    // Groupes dans l'ordre d'apparition de leur première tâche, donc dans celui de `SmartList.sort` :
    // les projets qui portent les priorités hautes remontent d'eux-mêmes, sans second tri.
    var order: [String] = []
    var buckets: [String: [TaskItem]] = [:]
    for task in undated {
      let title = task.project?.title ?? task.list?.title ?? ""
      let key = title.isEmpty ? "Sans projet" : title
      if buckets[key] == nil { order.append(key) }
      buckets[key, default: []].append(task)
    }

    return TodayPage(
      tasks: day,
      undated: order.map { Group(name: $0, tasks: buckets[$0] ?? []) })
  }
}
