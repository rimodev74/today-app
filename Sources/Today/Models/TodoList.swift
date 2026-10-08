import Foundation
import SwiftData

/// Une to-do list : le seul endroit où vivent les tâches.
@Model
final class TodoList {
  /// Identité stable entre appareils — mêmes raisons et mêmes contraintes que `TaskItem.uuid`.
  var uuid: UUID = UUID()
  var title: String = ""
  var notes: Data = Data()
  var sortIndex: Int = 0
  var createdAt: Date = Date()
  /// Date planifiée de la liste (menu « Définir une date » de l'en-tête).
  var scheduledWhen: Date?
  var priorityRaw: Int = 0
  var project: Project?
  /// La liste singleton qui porte les tâches sans projet — page « Tâches » de la sidebar
  /// (équivalent d'« À classer » dans Things). Créée une fois au lancement (cf. `ThingsCloneApp`).
  var isInbox: Bool = false
  /// Quand la liste a été rangée dans les archives de son projet, ou `nil` si elle ne l'est pas.
  /// Une date plutôt qu'un booléen : c'est aussi l'ordre des archives, la plus récente en tête.
  ///
  /// Archivée, elle quitte les endroits où l'on PARCOURT et où l'on RANGE — barre latérale,
  /// grille du projet, menus « Déplacer vers… », destinations de la capsule. Elle reste là où on
  /// la NOMME ou la CHERCHE (`#Nom`, raccourcis, recherche) : archiver ne casse rien de ce qui la
  /// vise. Retirer un nom du jeu des Réglages le ferait réconcilier par PRÉFIXE contre les autres
  /// listes (`QuickEntry.reconciledListToken`), et un raccourci changerait de cible sans un mot.
  var archivedAt: Date?
  @Relationship(deleteRule: .cascade, inverse: \TaskItem.list) var tasks: [TaskItem] = []

  // Stocké en Int comme sur TaskItem : SwiftData persiste le stocké, pas le calculé.
  var priority: Priority {
    get { Priority(rawValue: priorityRaw) ?? .none }
    set { priorityRaw = newValue.rawValue }
  }

  init(title: String, notes: Data = Data(), project: Project? = nil) {
    self.title = title
    self.notes = notes
    self.project = project
    self.tasks = []
    self.createdAt = Date()
  }

  var isArchived: Bool { archivedAt != nil }

  /// Ordre manuel. `createdAt` départage les ex æquo (deux tâches créées avant
  /// tout réordonnancement partagent sortIndex 0) pour que l'ordre reste stable.
  var orderedTasks: [TaskItem] {
    sortedByKey(tasks, key: { ($0.sortIndex, $0.createdAt) }, areInIncreasingOrder: <)
  }

  /// Les en-têtes ne sont pas des tâches : elles ne comptent pas dans la progression.
  var countableTasks: [TaskItem] { tasks.filter { !$0.isHeader } }

  /// Nombre de tâches restantes (non complétées) — le badge de la sidebar.
  var remainingCount: Int { countableTasks.filter { !$0.isCompleted }.count }

  /// Progression de la LISTE : ce qui est coché sur ce qu'elle contient AUJOURD'HUI, en-têtes
  /// exclues. La borne est le JOUR CALENDAIRE (`TaskItem.countsTowardProgress`), jamais
  /// `CompletedTaskRetention`.
  ///
  /// Troisième version de cette règle ; les deux précédentes et ce qui les a tuées sont dans
  /// `PIEGES.md` § L'anneau de progression. À lire avant d'y toucher une quatrième fois.
  func progress(bounds: DayBounds = DayBounds()) -> Double {
    Self.progress(of: tasks, bounds: bounds)
  }

  /// La même règle sur des tâches DÉJÀ lues : une page qui vient de parcourir la relation n'a pas
  /// à la retraverser pour son anneau.
  static func progress(of tasks: [TaskItem], bounds: DayBounds = DayBounds()) -> Double {
    let countable = tasks.filter { !$0.isHeader && $0.countsTowardProgress(bounds) }
    guard !countable.isEmpty else { return 0 }
    return Double(countable.filter(\.isCompleted).count) / Double(countable.count)
  }

  /// Réglage (Réglages) : descendre automatiquement une tâche cochée en bas de sa section.
  /// Activé par défaut — `object(forKey:)` plutôt que `bool(forKey:)` pour distinguer « jamais
  /// réglé » (→ true) de « explicitement désactivé ».
  static let autoSortCompletedStorageKey = "autoSortCompletedToBottom"

  /// Lu aussi par `SmartList.sort` : les vues intelligentes n'ont pas d'ordre manuel à réécrire,
  /// le réglage s'y applique donc au tri (cf. ce fichier) plutôt que par `moveToEndOfSection`.
  static var autoSortCompletedEnabled: Bool {
    UserDefaults.standard.object(forKey: autoSortCompletedStorageKey) as? Bool ?? true
  }

  /// Renvoie `task` en bas de sa section (juste avant l'en-tête suivant, ou la fin de liste) en
  /// réécrivant les `sortIndex` — appelé quand une tâche passe cochée, pour que les tâches
  /// terminées descendent sous celles encore à faire sans mélanger les sections entre elles.
  /// No-op si l'utilisateur a désactivé ce comportement dans les réglages.
  func moveToEndOfSection(_ task: TaskItem) {
    guard Self.autoSortCompletedEnabled else { return }
    var ordered = orderedTasks
    guard
      let taskIndex = ordered.firstIndex(where: { $0.persistentModelID == task.persistentModelID })
    else { return }
    let nextHeaderIndex = ordered[(taskIndex + 1)...].firstIndex(where: \.isHeader) ?? ordered.count
    guard nextHeaderIndex > taskIndex + 1 else { return }
    let moved = ordered.remove(at: taskIndex)
    ordered.insert(moved, at: nextHeaderIndex - 1)
    Self.renumber(ordered)
  }

  /// Symétrique de `moveToEndOfSection` : une tâche qu'on DÉCOCHE remonte en TÊTE de sa section.
  ///
  /// Une première version la remontait juste au-dessus des autres tâches encore cochées — l'ancre
  /// d'`appendAnchor`. Faux : quand c'est la SEULE tâche cochée de la section (le cas le plus
  /// courant, cocher puis décocher la même tâche), cette ancre est déjà sa position courante —
  /// `moveToEndOfSection` l'avait posée juste après la dernière active, qui est exactement là
  /// qu'une ancre « au-dessus des cochées » retombe. Résultat : aucun mouvement, symptôme rapporté
  /// telle quelle (« je décoche, elle reste en bas »). La tête de section est le seul repère qui ne
  /// coïncide jamais avec la position qu'on quitte.
  func moveAboveCompleted(_ task: TaskItem) {
    guard Self.autoSortCompletedEnabled else { return }
    var ordered = orderedTasks
    guard
      let taskIndex = ordered.firstIndex(where: { $0.persistentModelID == task.persistentModelID })
    else { return }
    let sectionStart = ordered[..<taskIndex].lastIndex(where: \.isHeader).map { $0 + 1 } ?? 0
    guard sectionStart < taskIndex else { return }  // déjà en tête de section
    let moved = ordered.remove(at: taskIndex)
    ordered.insert(moved, at: sectionStart)
    Self.renumber(ordered)
  }

  /// Renumérote `ordered` en 0…n, en n'ÉCRIVANT que les rangs qui changent.
  ///
  /// Une écriture SwiftData n'est jamais gratuite, même à l'identique : le setter d'un `@Model` ne
  /// compare rien, il notifie chaque vue qui lit la propriété et marque la tâche à enregistrer. Une
  /// coche renumérotait ainsi toute la liste — la boîte de réception réelle en porte 142 — pour en
  /// déplacer une seule, et le `save()` qui suit réécrivait autant de lignes.
  static func renumber(_ ordered: [TaskItem]) {
    for (index, task) in ordered.enumerated() where task.sortIndex != index {
      task.sortIndex = index
    }
  }

  /// Libère dans `tasks` le rang qui suit `anchor` (`-1` = tout en tête) et le rend : c'est celui
  /// de la tâche qu'on insère.
  ///
  /// Les rangs se décalent du côté le MOINS peuplé. Pousser d'un cran tout ce qui suit l'ancre
  /// était juste mais coûteux : une tâche notée dans la boîte de réception s'insère avant les
  /// cochées, soit 7 tâches avant elle et 135 après dans la base réelle — 135 écritures, 135
  /// notifications, 135 lignes réenregistrées pour une seule tâche ajoutée. Reculer d'un cran ce
  /// qui PRÉCÈDE donne le même ordre ; un rang négatif ne gêne rien (`SidebarDrop` en pose déjà).
  static func makeRoom(after anchor: Int, in tasks: [TaskItem]) -> Int {
    let following = tasks.filter { $0.sortIndex > anchor }
    guard following.count > tasks.count - following.count else {
      for task in following { task.sortIndex += 1 }
      return anchor + 1
    }
    for task in tasks where task.sortIndex <= anchor { task.sortIndex -= 1 }
    return anchor
  }

  /// Où une tâche NEUVE doit s'accrocher dans `tasks` (déjà triées par `sortIndex`) : la dernière
  /// tâche NON cochée, jamais la toute dernière — sans quoi la neuve atterrirait sous les cochées
  /// que `moveToEndOfSection` repousse en bas, l'inverse du geste qui vient de les y envoyer.
  /// `nil` s'il n'y a rien de non coché (section neuve ou entièrement terminée) : elle se pose
  /// alors en tête, avant tout ce qui est coché.
  static func appendAnchor(among tasks: [TaskItem]) -> TaskItem? {
    tasks.last(where: { !$0.isCompleted })
  }
}
