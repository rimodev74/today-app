import Foundation
import SwiftData

/// Un regroupement de projets — l'agence au-dessus de ses clients. C'est la « Zone » de Things.
///
/// UN niveau, jamais un arbre : une zone ne contient que des projets, et on ne lui rattache aucune
/// tâche (`TaskItem.inboxProject` couvre déjà le besoin un cran plus bas). Des sous-projets
/// récursifs auraient rendu récursifs les compteurs, le glisser de la sidebar, `#Projet` et
/// « Déplacer vers… » ; une zone ne touche à aucun d'eux.
@Model
final class Area {
  /// Identité stable entre appareils — mêmes raisons que `Project.uuid`.
  var uuid: UUID = UUID()
  var title: String = ""
  var sortIndex: Int = 0
  var createdAt: Date = Date()
  /// Repli dans la sidebar, persistant pour la même raison que `Project.isCollapsed`.
  var isCollapsed: Bool = false
  /// `.nullify` : supprimer une zone rend ses projets à la racine — une zone n'est qu'une étiquette
  /// de rangement, rien ne disparaît avec elle.
  @Relationship(deleteRule: .nullify, inverse: \Project.area) var projects: [Project] = []

  init(title: String) {
    self.title = title
    self.createdAt = Date()
  }
}

/// La sidebar et « Projets » groupent de la même façon : d'abord les projets SANS zone, puis chaque
/// zone dans son ordre, avec ses projets dans l'ordre manuel global (`Project.sortIndex`).
/// Construit une fois en tête de `body`, testable sans écran.
struct AreaGrouping {
  struct Section {
    /// `nil` = les projets hors zone, en tête.
    let area: Area?
    let projects: [Project]
  }

  let sections: [Section]

  /// `projects` doivent déjà être dans l'ordre manuel. Une lecture de `area` par projet.
  init(projects: [Project], areas: [Area]) {
    let ordered = sortedByKey(areas, key: { ($0.sortIndex, $0.createdAt) }, areInIncreasingOrder: <)
    var byArea: [PersistentIdentifier: [Project]] = [:]
    var loose: [Project] = []
    for project in projects {
      if let area = project.area {
        byArea[area.persistentModelID, default: []].append(project)
      } else {
        loose.append(project)
      }
    }
    sections =
      [Section(area: nil, projects: loose)]
      + ordered.map { Section(area: $0, projects: byArea[$0.persistentModelID] ?? []) }
  }
}
