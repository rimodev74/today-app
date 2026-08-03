import SwiftUI

/// Palette fermée de l'app (pas de `ColorPicker` libre) — mêmes teintes que les tags Finder, pour
/// rester dans un vocabulaire de couleur déjà familier sur macOS. Stockée en `rawValue` partout où
/// une teinte se choisit : `TaskItem.headerColorRaw`, `Project.colorRaw` (même pattern que
/// `Priority`/`priorityRaw`).
///
/// S'appelait `HeaderColor` quand seules les en-têtes de section se teintaient ; le nom aurait
/// menti dès qu'un projet a pu porter une couleur. Le `rawValue` n'a pas bougé — c'est lui qui est
/// en base, pas le nom du type.
enum PaletteColor: String, CaseIterable, Identifiable {
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
  /// figé : le plus natif possible pour une pastille de menu.
  var nsColor: NSColor {
    switch self {
    case .red: return .systemRed
    case .orange: return .systemOrange
    case .yellow: return .systemYellow
    case .green: return .systemGreen
    case .blue: return .systemBlue
    case .purple: return .systemPurple
    case .pink: return .systemPink
    }
  }

  var color: Color { Color(nsColor: nsColor) }
}
