import Foundation

enum CompletedTaskRetention: String, CaseIterable, Identifiable {
  case untilViewChange
  case timer
  case never

  static let storageKey = "completedTaskRetention"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .untilViewChange: return "Jusqu'à ce que je quitte la liste"
    case .timer: return "Automatiquement après 1,5 s"
    case .never: return "Ne jamais les masquer"
    }
  }
}
