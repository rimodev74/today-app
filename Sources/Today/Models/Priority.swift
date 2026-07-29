import SwiftUI

/// Priorité d'une tâche. Indicateur visuel dans une to-do list (où l'ordre manuel fait loi),
/// clé de tri dans les listes intelligentes (où il n'y a pas d'ordre manuel).
enum Priority: Int, CaseIterable, Identifiable {
  case none = 0
  case low = 1
  case medium = 2
  case high = 3

  var id: Int { rawValue }

  var label: String {
    switch self {
    case .none: return "Aucune"
    case .low: return "Basse"
    case .medium: return "Moyenne"
    case .high: return "Haute"
    }
  }

  /// `nil` = rien à afficher sur la ligne.
  var color: Color? {
    switch self {
    case .none: return nil
    case .low: return .blue
    case .medium: return .orange
    case .high: return .red
    }
  }

  var systemImage: String {
    switch self {
    case .none: return "minus"
    case .low: return "chevron.down"
    case .medium: return "equal"
    case .high: return "chevron.up"
    }
  }
}
