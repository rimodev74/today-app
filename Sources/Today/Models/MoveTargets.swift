import SwiftData

/// Les listes où une tâche peut être rangée (« Déplacer vers… »), lues UNE fois par page.
///
/// Chaque rangée filtrait avant `activeLists` en relisant `persistentModelID` de chaque liste (et
/// `==` de `TaskRow` le refaisait pour comparer), puis son menu relisait `project?.title` de chacune
/// pour les grouper : N lectures SwiftData par rangée et par rendu, pour une réponse identique d'une
/// rangée à l'autre. L'index lit l'identifiant et le titre de projet de chaque liste une seule fois ;
/// chaque rangée n'a plus qu'à écarter la sienne, sur des valeurs ordinaires.
struct MoveTargetIndex: Equatable {
  struct Entry {
    let list: TodoList
    let id: PersistentIdentifier
    /// Le titre du projet de la liste, lu une fois. `nil` = liste libre.
    let project: String?
  }

  let entries: [Entry]
  /// Les mêmes identifiants, à part : c'est ce que `==` compare, et un tableau dont le stockage est
  /// partagé entre toutes les rangées d'une page se compare en temps constant.
  let ids: [PersistentIdentifier]

  init(_ lists: [TodoList]) {
    entries = lists.map { Entry(list: $0, id: $0.persistentModelID, project: $0.project?.title) }
    ids = entries.map(\.id)
  }

  /// Les cibles d'UNE rangée : toutes sauf la liste de la tâche.
  func excluding(_ own: PersistentIdentifier?) -> MoveTargets {
    MoveTargets(index: self, excluded: own)
  }

  /// Les titres de projet entrent dans l'égalité : renommer un projet doit rafraîchir le
  /// « Déplacer vers… » des rangées, qui sont `Equatable` et ne se redessineraient pas sinon.
  static func == (a: MoveTargetIndex, b: MoveTargetIndex) -> Bool {
    a.ids == b.ids && a.entries.map(\.project) == b.entries.map(\.project)
  }
}

/// Ce qu'une rangée reçoit : l'index de la page, et la liste à écarter (la sienne).
struct MoveTargets: Equatable {
  let index: MoveTargetIndex
  let excluded: PersistentIdentifier?

  /// Les listes proposées, dans l'ordre de l'index.
  var lists: [TodoList] {
    index.entries.filter { $0.id != excluded }.map(\.list)
  }

  var isEmpty: Bool { !index.ids.contains { $0 != excluded } }

  /// Les cibles groupées par projet, les listes libres en dernier — un projet est ce qu'on cherche
  /// d'abord quand on range une tâche qui traîne. Les projets suivent leur première apparition
  /// PARMI LES LISTES PROPOSÉES (d'où un groupement par rangée, sur des valeurs déjà lues : écarter
  /// la liste de la tâche peut changer quel projet vient en premier). `filter` plutôt qu'un
  /// `sorted` : le tri de Swift n'est pas stable, il aurait mélangé l'ordre des projets entre eux.
  var byProject: [(project: String?, lists: [TodoList])] {
    var order: [String?] = []
    var buckets: [String?: [TodoList]] = [:]
    for entry in index.entries where entry.id != excluded {
      if buckets[entry.project] == nil { order.append(entry.project) }
      buckets[entry.project, default: []].append(entry.list)
    }
    let sorted = order.filter { $0 != nil } + order.filter { $0 == nil }
    return sorted.map { (project: $0, lists: buckets[$0] ?? []) }
  }

  static func == (a: MoveTargets, b: MoveTargets) -> Bool {
    a.excluded == b.excluded && a.index == b.index
  }
}
