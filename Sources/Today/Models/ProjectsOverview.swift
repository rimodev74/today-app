import Foundation
import SwiftData

/// Ce que la vue « Projets » présente : une carte par projet, avec son AVANCEMENT CUMULÉ et celui de
/// chacune de ses listes en cours.
///
/// Même raison d'être que `ProjectBoard` : construit UNE fois en tête du `body`, interrogeable par un
/// test sans écran. Et aucun comptage neuf — `SidebarCounts` fait déjà la passe unique par liste ;
/// ici on ne fait qu'additionner ses rangées par projet.
///
/// **Cumulé, et c'est délibéré.** L'anneau d'une liste se remet à zéro chaque jour par défaut
/// (`countsTowardProgress`) : il mesure l'élan du JOUR. Sur une vue de projets, cette règle
/// afficherait tout à ~0 % chaque matin. Un projet est une chose qu'on termine une fois — c'est le
/// cas où `PIEGES.md` § L'anneau dit juste de compter tout ce qui a été coché, depuis toujours. D'où
/// `cumulativeBounds`, et une BARRE à l'écran, jamais un anneau : quantité différente, forme
/// différente.
struct ProjectsOverview {
  struct Card: Identifiable {
    let project: Project
    /// La clé de la couverture (`ProjectCovers`), lue une fois ici plutôt qu'au rendu de la carte.
    let uuid: UUID
    /// Tout le projet, listes ARCHIVÉES comprises : elles sont finies, leurs tâches font partie
    /// de ce qui a été fait.
    let total: SidebarCounts.Row
    /// Les listes EN COURS, dans l'ordre manuel.
    let lists: [ListLine]

    var id: PersistentIdentifier { project.persistentModelID }
  }

  struct ListLine: Identifiable {
    let list: TodoList
    let row: SidebarCounts.Row

    var id: PersistentIdentifier { list.persistentModelID }
  }

  let cards: [Card]

  /// Les bornes qui rendent `SidebarCounts` cumulatif, quel que soit le réglage de l'anneau.
  static func cumulativeBounds(now: Date = Date()) -> DayBounds {
    DayBounds(now: now, progressResetsDaily: false)
  }

  /// `counts` DOIT avoir été construit avec `cumulativeBounds` — c'est l'appelant qui détient les
  /// tâches (un `@Query` sur la vue Projets, la relation sur la page d'un projet).
  static func build(projects: [Project], counts: SidebarCounts) -> ProjectsOverview {
    ProjectsOverview(
      cards: projects.map { project in
        var total = SidebarCounts.Row()
        var lines: [ListLine] = []
        // UNE lecture de `archivedAt` par liste, dans l'ordre manuel déjà trié.
        for list in project.orderedLists {
          let row = counts[list]
          total = total + row
          if !list.isArchived { lines.append(ListLine(list: list, row: row)) }
        }
        return Card(project: project, uuid: project.uuid, total: total, lists: lines)
      })
  }

  /// L'avancement d'UN projet, pour la barre de sa page — même somme que sa carte, pas une seconde
  /// écrite à la main.
  static func total(of project: Project, now: Date = Date()) -> SidebarCounts.Row {
    let counts = SidebarCounts(tasks: project.allTasks, bounds: cumulativeBounds(now: now))
    return build(projects: [project], counts: counts).cards[0].total
  }
}

extension SidebarCounts.Row {
  static func + (lhs: Self, rhs: Self) -> Self {
    Self(
      countable: lhs.countable + rhs.countable, done: lhs.done + rhs.done,
      hasTasks: lhs.hasTasks || rhs.hasTasks)
  }
}
