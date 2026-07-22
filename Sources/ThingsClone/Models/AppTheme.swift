import Foundation
import SwiftUI

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

  var colorScheme: ColorScheme? {
    switch self {
    case .light: return .light
    case .dark: return .dark
    case .system: return nil
    }
  }
}
