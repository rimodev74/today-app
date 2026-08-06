import Foundation

/// Ce que la page « Aujourd'hui » affiche : les tâches datées du jour même.
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
  /// Les tâches datées du JOUR MÊME, cochées comprises (elles restent barrées jusqu'au lendemain).
  let tasks: [TaskItem]

  /// Le seul pan de la page : toujours visible, pas de dépliant.
  var blocks: [TaskPageBlock] { [.visible(tasks)] }

  /// Une tâche datée d'hier n'est PAS repêchée — elle est retournée dans sa liste (cf.
  /// `SmartList.today`), c'est ce qui empêche la page de devenir une pile de retards.
  static func build(from all: [TaskItem]) -> TodayPage {
    TodayPage(tasks: SmartList.today.sort(SmartList.today.scoped(all)))
  }
}
