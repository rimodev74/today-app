import SwiftData

/// Ce qu'une page de tâches MESURE et DÉPLACE : une ligne de tâche, ou une rangée « Nouvelle
/// tâche ».
///
/// Une page n'est pas faite que de tâches. La page d'une liste intercale une rangée de création par
/// bloc, et cette rangée occupe de la hauteur : un glissement qui la traverse doit la compter comme
/// n'importe quelle autre ligne, sinon le trou d'insertion se décale d'autant. C'est ce que dit
/// déjà l'en-tête de `ReorderLayout` — « seule compte leur POSITION dans la séquence », pas leur
/// type.
///
/// Ce type existait, mais **caché dans `TaskListView`**, en `fileprivate`. Le moteur partagé, lui,
/// ne savait mesurer que des tâches, et c'est l'une des trois raisons pour lesquelles la page d'une
/// liste a dû garder son propre moteur. Le sortir ici est ce qui permet aux deux de parler la même
/// langue.
///
/// Les pages qui n'ont que des tâches (« Aujourd'hui », « Tâches », « À venir », « Archives »)
/// n'émettent que des `.task` et ne voient jamais la différence.
enum TaskRowKey: Hashable {
  case task(PersistentIdentifier)
  /// Le champ « Nouvelle tâche » d'un bloc, désigné par l'identifiant de ce bloc.
  case field(String)
}
