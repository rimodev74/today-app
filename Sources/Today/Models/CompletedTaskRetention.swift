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

  var label: String {
    switch self {
    case .untilViewChange: return "Jusqu'à ce que je quitte la liste"
    case .timer: return "Automatiquement après 1,5 s"
    case .never: return "Ne jamais les masquer"
    }
  }
}

extension TaskItem {
  /// Une tâche cochée qui a quitté le flux de sa liste, vue d'AILLEURS que la page de cette liste
  /// (sidebar, projet). Rien n'est supprimé : elle ne compte simplement plus dans une progression.
  ///
  /// ponytail: le mode « jusqu'à ce que je quitte la liste » est lu ici comme le mode minuté —
  /// la règle exacte de `TaskListView.isArchived` s'appuie sur `pageOpenedAt`, un état de vue que
  /// la sidebar n'a pas. Écart visible seulement dans les 1,5 s qui suivent une case cochée, et le
  /// redessin de l'anneau attend de toute façon la prochaine mutation du modèle. Remonter
  /// `pageOpenedAt` dans un modèle observable partagé si ça se voit à l'usage.
  var isArchived: Bool {
    guard !isHeader, isCompleted, let completedAt else { return false }
    switch CompletedTaskRetention.current {
    case .never: return false
    case .untilViewChange, .timer:
      return Date().timeIntervalSince(completedAt) >= CompletedTaskRetention.timerDelay
    }
  }
}
