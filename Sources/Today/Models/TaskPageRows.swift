import Foundation

/// Un pan de lignes tel qu'une page de tâches l'affiche : les tâches à nu en tête de page, ou le
/// contenu d'une section repliable.
///
/// ## Pourquoi ce type existe
///
/// Le socle clavier (`TaskPageBase`) a besoin de l'ordre AFFICHÉ des lignes — celui que suivent ↑
/// et ↓, celui où ⌫ retrouve la sélection. Chaque page le lui REDÉCRIVAIT à la main, dans une
/// closure, à côté de son `body` :
///
/// ```swift
/// rows: { inboxTasks + sections.filter(isExpanded).flatMap(\.tasks) }  // ← doit refléter le body
/// ```
///
/// Rien ne garantissait la correspondance : ni le compilateur, ni un test. L'erreur a été commise
/// (la boîte de réception de « Tâches » manquait à l'appel) et son symptôme est « la touche ne
/// marche pas » — aucune trace à l'écran, aucun test rouge, juste des lignes que le clavier
/// n'atteint plus.
///
/// La page ne décrit donc plus un ORDRE, elle déclare ses PANS — les mêmes valeurs que son `body`
/// parcourt. L'aplatissement, lui, n'est écrit qu'ici : une page ne peut plus se tromper sur une
/// règle qu'elle n'écrit pas.
///
/// ## Ce que ce n'est pas
///
/// Pas une description de la mise en page : ni bandeau, ni titre, ni icône. Un pan ne répond qu'à
/// « quelles lignes, et sont-elles visibles ? » — de quoi naviguer au clavier, rien de plus.
struct TaskPageBlock {
  let tasks: [TaskItem]
  /// Un pan replié reste déclaré mais ne fournit AUCUNE ligne : les flèches ne peuvent pas emmener
  /// la sélection sur une ligne que l'œil ne voit pas.
  let isExpanded: Bool

  /// Le cas courant : des lignes à nu, toujours visibles (elles n'ont pas de dépliant).
  static func visible(_ tasks: [TaskItem]) -> TaskPageBlock {
    TaskPageBlock(tasks: tasks, isExpanded: true)
  }
}

extension Array where Element == TaskPageBlock {
  /// L'ordre affiché : les pans dans l'ordre déclaré, les repliés sautés.
  var displayedRows: [TaskItem] {
    flatMap { $0.isExpanded ? $0.tasks : [] }
  }

  /// Toutes les lignes que la page PORTE, repliées comprises. Ne bouge donc que si une tâche entre
  /// ou sort vraiment — replier une section n'y change rien, contrairement à `displayedRows`.
  /// C'est le repère qui sert à animer une apparition dont nous ne sommes pas l'auteur (cf.
  /// `TaskPageBase`, ⌘Z) sans transformer chaque dépliant en ressort.
  var carriedRowCount: Int {
    reduce(0) { $0 + $1.tasks.count }
  }
}
