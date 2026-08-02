import Foundation

enum CompletedTaskRetention: String, CaseIterable, Identifiable {
  case untilViewChange
  case timer
  case never

  static let storageKey = "completedTaskRetention"

  /// Délai du mode `.timer`, partagé : `TaskListView` l'utilise pour faire sortir la ligne du flux,
  /// les modèles pour savoir si la tâche compte encore dans une progression. Deux constantes
  /// auraient divergé.
  static let timerDelay: TimeInterval = 1.5

  /// Le réglage vu d'un modèle. `@AppStorage` n'existe que dans une vue — même clé, même défaut.
  static var current: CompletedTaskRetention {
    UserDefaults.standard.string(forKey: storageKey).flatMap(Self.init(rawValue:))
      ?? .untilViewChange
  }

  var id: String { rawValue }

  /// LA règle : une tâche cochée à `completedAt` a-t-elle quitté le flux ?
  ///
  /// Écrite une seule fois, pour deux appelants qui ne voient pas la même chose. Une page de liste
  /// sait DEPUIS QUAND elle est ouverte et passe son `pageOpenedAt` ; la sidebar et les anneaux de
  /// progression, non — ils regardent une tâche sans page autour, et passent `nil`.
  ///
  /// `nil` retombe alors sur le seuil du mode minuté, ce qui est une APPROXIMATION assumée du mode
  /// « jusqu'à ce que je quitte la liste » : l'écart ne dure que les 1,5 s qui suivent une case
  /// cochée, et le redessin d'un anneau attend de toute façon la prochaine mutation du modèle.
  /// C'est ce cas-là, et lui seul, qui justifiait deux implémentations ; il est désormais écrit
  /// dans la règle plutôt que recopié de part et d'autre.
  func hasLeftTheFlow(completedAt: Date, now: Date, pageOpenedAt: Date?) -> Bool {
    switch self {
    case .never:
      return false
    case .untilViewChange:
      guard let pageOpenedAt else { return now.timeIntervalSince(completedAt) >= Self.timerDelay }
      return completedAt < pageOpenedAt
    case .timer:
      return now.timeIntervalSince(completedAt) >= Self.timerDelay
    }
  }

  var label: String {
    switch self {
    case .untilViewChange: return "Jusqu'à ce que je quitte la liste"
    case .timer: return "Automatiquement après 1,5 s"
    case .never: return "Ne jamais les masquer"
    }
  }
}

extension TaskItem {
  /// Une tâche cochée a-t-elle quitté le flux ? Une en-tête ne se coche pas, une tâche à faire n'a
  /// rien quitté : ces deux gardes valent partout, elles vivent donc ici plutôt que chez chaque
  /// appelant. Le reste est `CompletedTaskRetention.hasLeftTheFlow`, l'unique règle.
  ///
  /// Rien n'est supprimé : une tâche « partie du flux » ne compte simplement plus dans une
  /// progression, et reste retrouvable dans « Archives ».
  func hasLeftTheFlow(
    _ retention: CompletedTaskRetention, now: Date = Date(), pageOpenedAt: Date? = nil
  ) -> Bool {
    guard !isHeader, isCompleted, let completedAt else { return false }
    return retention.hasLeftTheFlow(completedAt: completedAt, now: now, pageOpenedAt: pageOpenedAt)
  }

  /// Vu d'AILLEURS que la page d'une liste (sidebar, anneaux de progression) : pas de page, donc
  /// pas de `pageOpenedAt`, et le réglage se relit depuis les défauts.
  var isArchived: Bool { hasLeftTheFlow(CompletedTaskRetention.current) }
}
