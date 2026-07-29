import SwiftUI

/// Palette fermée pour la couleur d'un en-tête de section (pas de `ColorPicker` libre) — mêmes
/// teintes que les tags Finder, pour rester dans un vocabulaire de couleur déjà familier sur macOS.
/// Stockée sur `TaskItem.headerColorRaw` (même pattern que `Priority`/`priorityRaw`).
enum HeaderColor: String, CaseIterable, Identifiable {
  case red, orange, yellow, green, blue, purple, pink

  var id: String { rawValue }

  var label: String {
    switch self {
    case .red: return "Rouge"
    case .orange: return "Orange"
    case .yellow: return "Jaune"
    case .green: return "Vert"
    case .blue: return "Bleu"
    case .purple: return "Violet"
    case .pink: return "Rose"
    }
  }

  /// Couleur système dynamique (s'adapte au mode sombre et à l'accessibilité) plutôt qu'un hex
  /// figé : rung le plus natif possible pour un pastille de menu.
  var color: Color {
    switch self {
    case .red: return Color(nsColor: .systemRed)
    case .orange: return Color(nsColor: .systemOrange)
    case .yellow: return Color(nsColor: .systemYellow)
    case .green: return Color(nsColor: .systemGreen)
    case .blue: return Color(nsColor: .systemBlue)
    case .purple: return Color(nsColor: .systemPurple)
    case .pink: return Color(nsColor: .systemPink)
    }
  }
}
