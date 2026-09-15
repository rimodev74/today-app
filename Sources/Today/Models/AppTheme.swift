import AppKit
import Foundation

enum AppTheme: String, CaseIterable, Identifiable {
  case light
  case dark
  case system

  static let storageKey = "appTheme"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .light: return "Clair"
    case .dark: return "Sombre"
    case .system: return "Système"
    }
  }

  /// L'apparence AppKit du thème. `nil` pour « Système » : c'est le seul `nil` qui rend vraiment une
  /// fenêtre au système (cf. `AppAppearance`).
  var appearance: NSAppearance? {
    switch self {
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    case .system: return nil
    }
  }
}
