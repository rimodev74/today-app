import Foundation

enum CompletedTaskRetention: String, CaseIterable, Identifiable {
  case untilNextDay
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
      ?? .untilNextDay
  }

  var id: String { rawValue }

  /// LA règle : une tâche cochée à `completedAt` a-t-elle quitté le flux ?
  ///
  /// Le mode par défaut se règle sur le CALENDRIER, pas sur la navigation : ce qui a été fait
  /// aujourd'hui reste sous les yeux jusqu'à demain, quel que soit le nombre d'allers-retours entre
  /// les onglets. C'est ce qui remplace l'ancien « jusqu'à ce que je quitte la liste », qui faisait
  /// disparaître le travail de la journée au premier changement de page — et rendait la règle
  /// dépendante de l'appelant (une page savait depuis quand elle était ouverte, un anneau de
  /// progression non). Elle ne dépend plus que de deux dates.
  func hasLeftTheFlow(completedAt: Date, now: Date) -> Bool {
    switch self {
    case .never:
      return false
    case .untilNextDay:
      return completedAt < Calendar.current.startOfDay(for: now)
    case .timer:
      return now.timeIntervalSince(completedAt) >= Self.timerDelay
    }
  }

  var label: String {
    switch self {
    case .untilNextDay: return "Jusqu'au lendemain"
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
  func hasLeftTheFlow(_ retention: CompletedTaskRetention, now: Date = Date()) -> Bool {
    guard !isHeader, isCompleted, let completedAt else { return false }
    return retention.hasLeftTheFlow(completedAt: completedAt, now: now)
  }

}
