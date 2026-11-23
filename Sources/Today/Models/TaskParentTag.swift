import Foundation

/// D'où vient une tâche, sur une page qui mélange les provenances : **le nom de sa liste**, teinté
/// de la couleur de son projet.
///
/// La liste et pas le projet, alors que les quatre vues qui portaient ce calcul faisaient l'inverse
/// (`task.project?.title ?? task.list?.title`) : c'est la liste qui est le rangement RÉEL d'une
/// tâche — un projet à trois listes annonçait le même mot sur trois provenances différentes, ce qui
/// est précisément ce qu'on veut distinguer. Le projet n'est pas perdu pour autant : il donne sa
/// teinte, et c'est la même que son icône dans la sidebar.
///
/// **Une tâche de l'Inbox rattachée à un projet** (`TaskItem.inboxProject`) annonce le PROJET : elle
/// n'a pas de liste à nommer, et c'est précisément ce que la pastille vient dire sur « Tâches ».
///
/// `nil` quand il n'y a rien à dire — et la **boîte de réception** nue en fait partie. C'est le
/// rangement par défaut de toute tâche non classée (l'onglet « Tâches ») : l'écrire sur chaque
/// ligne d'« Aujourd'hui » ne distingue rien, ça ne fait qu'ajouter du gris à côté d'un titre.
///
/// Sorti de la vue parce que les QUATRE pages qui l'affichaient — « Aujourd'hui », « Tâches »,
/// « À venir », « Archives » — en avaient chacune leur copie, mot pour mot. Les deux règles
/// ci-dessus seraient donc nées à un seul endroit, et les trois autres auraient continué d'annoncer
/// le projet, boîte de réception comprise, sans que rien ne le signale.
struct TaskParentTag: Equatable {
  let title: String
  /// Teinte de la pastille : celle du projet de la liste. `nil` pour une liste hors projet — une
  /// liste ne porte pas de couleur à elle (cf. `Project.color`) — et pour un projet dont la couleur
  /// n'est pas choisie : la pastille se peint alors en gris.
  let color: ProjectColor?

  init?(of task: TaskItem) {
    guard let list = task.list else { return nil }
    if list.isInbox {
      guard let project = task.inboxProject, !project.title.isEmpty else { return nil }
      title = project.title
      color = project.color
      return
    }
    guard !list.title.isEmpty else { return nil }
    title = list.title
    color = list.project?.color
  }
}
