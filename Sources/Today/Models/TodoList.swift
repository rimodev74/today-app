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
  /// exclues.
  ///
  /// Troisième version de cette règle. La PREMIÈRE mesurait le flux VISIBLE — une tâche sortie de
  /// la page ne comptait ni au numérateur ni au dénominateur, pour qu'une liste au long cours
  /// n'affiche pas un disque quasi plein devant une page où rien n'est fait. Retirée : vu d'un
  /// anneau il n'y a AUCUNE page, et la règle retombait sur `CompletedTaskRetention` — son mode
  /// « 1,5 s » faisait sortir toute tâche cochée une seconde et demie après le clic. Mesuré : 2
  /// faites sur 4 → 0,0. L'anneau montait puis retombait à zéro tout seul, partout.
  ///
  /// La DEUXIÈME (celle d'au-dessus) ignorait donc l'âge d'une coche : une tâche complétée compte
  /// pour toujours, quel que soit le nombre de jours écoulés. Juste pour une liste qu'on termine
  /// une fois. Faux pour une liste au long cours jamais terminée (ex. « Bugs & fix ») : chaque
  /// tâche archivée reste au dénominateur pour toujours, l'anneau plafonne près du plein et une
  /// tâche neuve ne le fait quasiment plus bouger.
  ///
  /// Celle-ci ancre l'exclusion sur le JOUR CALENDAIRE (`TaskItem.countsTowardProgress`) plutôt que
  /// sur `CompletedTaskRetention` : la borne ne bouge qu'une fois par jour, à minuit — jamais en
  /// cours de journée comme le mode « 1,5 s », donc jamais le clignotement qui avait fait retirer
  /// la première version. Une tâche cochée AUJOURD'HUI compte encore ; une tâche archivée avant
  /// aujourd'hui ne compte plus dans AUCUN des deux termes, comme si elle n'avait jamais existé —
  /// exactement ce que fait déjà une liste neuve.
  func progress(bounds: DayBounds = DayBounds()) -> Double {
    let countable = countableTasks.filter { $0.countsTowardProgress(bounds) }
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
    for (index, t) in ordered.enumerated() { t.sortIndex = index }
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
    for (index, t) in ordered.enumerated() { t.sortIndex = index }
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
