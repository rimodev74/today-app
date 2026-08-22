import Foundation

/// Ce que la rangée a besoin de savoir de ses sous-tâches, lu en UNE traversée.
///
/// Lire `task.subtasks` n'est pas un accès mémoire : chaque lecture traverse SwiftData, et
/// `orderedSubtasks` trie par-dessus. La rangée en faisait CINQ par rendu — `orderedSubtasks` pour
/// savoir s'il y en a, `isEmpty` pour afficher le résumé, `count` puis `filter` pour le remplir,
/// `count` encore pour la courbe. Les pages se construisent EN ENTIER (jamais de `LazyVStack`,
/// cf. `PIEGES.md` § Layout), donc chaque rangée paie à chaque rendu.
///
/// Mesuré en release, par rendu de page : **0,73 ms à 136 tâches et 10,8 à 2 000** pour les cinq
/// accès, **0,18 et 3,05** en une passe. Pour comparaison, la même boucle sur une propriété
/// STOCKÉE (`title`) coûte 0,07 ms — dix fois moins qu'une traversée de relation.
struct SubtaskTally {
  let total: Int
  let done: Int
  var isEmpty: Bool { total == 0 }
  var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }

  init(_ task: TaskItem) {
    var total = 0
    var done = 0
    // Sans `filter` ni `count` séparés : deux passes de plus sur la même relation.
    for subtask in task.subtasks {
      total += 1
      if subtask.isDone { done += 1 }
    }
    self.total = total
    self.done = done
  }
}
