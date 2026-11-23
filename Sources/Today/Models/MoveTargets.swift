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
    /// Le projet lui-même : c'est la cible de « Sans liste » (cf. `TaskDestination.project`).
    let projectModel: Project?
  }

  let entries: [Entry]
  /// Les mêmes identifiants, à part : c'est ce que `==` compare, et un tableau dont le stockage est
  /// partagé entre toutes les rangées d'une page se compare en temps constant.
  let ids: [PersistentIdentifier]

  init(_ lists: [TodoList]) {
    entries = lists.map {
      let project = $0.project
      return Entry(
        list: $0, id: $0.persistentModelID, project: project?.title, projectModel: project)
    }
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

  /// Vide seulement s'il n'y a ni autre liste ni projet : un projet reste une destination même
  /// quand sa seule liste est celle de la tâche (« Sans liste » la sort de la liste).
  var isEmpty: Bool {
    !index.ids.contains { $0 != excluded } && !index.entries.contains { $0.projectModel != nil }
  }

  /// Les cibles groupées par projet, les listes libres en dernier — un projet est ce qu'on cherche
  /// d'abord quand on range une tâche qui traîne. Les projets suivent leur première apparition
  /// PARMI LES LISTES PROPOSÉES (d'où un groupement par rangée, sur des valeurs déjà lues : écarter
  /// la liste de la tâche peut changer quel projet vient en premier). `filter` plutôt qu'un
  /// `sorted` : le tri de Swift n'est pas stable, il aurait mélangé l'ordre des projets entre eux.
  ///
  /// Un projet dont la SEULE liste est celle de la tâche reste proposé, sans liste, en fin de
  /// projets : c'est le cas même qui sort une tâche utile de sa liste pour la rattacher au projet.
  ///
  /// ponytail: groupé par TITRE, comme avant — deux projets homonymes fusionnent leurs listes, et
  /// « Sans liste » vise le premier. À grouper par identité le jour où ça arrive.
  var byProject: [(project: String?, model: Project?, lists: [TodoList])] {
    var order: [String?] = []
    var buckets: [String?: [TodoList]] = [:]
    var models: [String: Project] = [:]
    for entry in index.entries {
      if let title = entry.project, models[title] == nil { models[title] = entry.projectModel }
      guard entry.id != excluded else { continue }
      if buckets[entry.project] == nil { order.append(entry.project) }
      buckets[entry.project, default: []].append(entry.list)
    }
    let orphaned = index.entries.first { $0.id == excluded }?.project.flatMap {
      buckets[$0] == nil ? $0 : nil
    }
    let sorted =
      order.filter { $0 != nil } + (orphaned.map { [$0] } ?? []) + order.filter { $0 == nil }
    return sorted.map { (project: $0, model: $0.flatMap { models[$0] }, lists: buckets[$0] ?? []) }
  }

  static func == (a: MoveTargets, b: MoveTargets) -> Bool {
    a.excluded == b.excluded && a.index == b.index
  }
}
