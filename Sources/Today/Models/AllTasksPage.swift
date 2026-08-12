import Foundation

/// Ce que la page « Tâches » affiche : la boîte de réception, et rien d'autre.
///
/// Elle a montré l'inventaire complet — le non-classé, puis « Aujourd'hui », puis un dépliant par
/// projet et par liste. Retiré le 12 août 2026 : l'onglet redevient une ZONE DE DÉPÔT, l'endroit où
/// l'on note sans classer. Ce qui est déjà rangé se lit là où il est rangé — dans sa liste, dans son
/// projet, ou sur « Aujourd'hui » —, et l'inventaire n'en était qu'une seconde vue. Les événements
/// du Calendrier sont partis avec : ils ne sont rien à classer.
///
/// Ce type survit à la simplification pour deux raisons, pas par habitude : le filtre reste TESTÉ
/// hors de la vue, et le corps de la vue n'a toujours qu'UN calcul à faire par rendu.
struct AllTasksPage {
  let tasks: [TaskItem]

  /// Un seul pan, toujours visible : c'est ce que le socle clavier parcourt (cf. `TaskPageBase`).
  var blocks: [TaskPageBlock] { [TaskPageBlock(tasks: tasks, isExpanded: true)] }

  /// L'ordre est celui des vues intelligentes (`SmartList.sort`) : le manuel d'abord, le tri
  /// automatique pour PLACER ce qui n'a jamais été glissé. C'est celui que la page a toujours eu —
  /// et pas le `sortIndex` de la liste Inbox, qui donnerait à la même liste deux ordres selon qu'on
  /// la lit ici ou depuis la barre latérale.
  static func build(tasks: [TaskItem]) -> AllTasksPage {
    AllTasksPage(
      tasks: SmartList.today.sort(
        tasks.filter { $0.list?.isInbox == true && !$0.isCompleted && !$0.isHeader }))
  }
}
